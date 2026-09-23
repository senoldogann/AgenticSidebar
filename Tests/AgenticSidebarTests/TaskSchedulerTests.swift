import Foundation
import Synchronization
import XCTest

@testable import AgenticSidebar

final class TaskSchedulerTests: XCTestCase {

    // MARK: - Test doubles

    private final class TestTaskSchedulerClock: TaskSchedulerClock, @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date

        init(start: Date) {
            self.current = start
        }

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return current
        }

        func advance(seconds: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            current = current.addingTimeInterval(seconds)
        }
    }

    private struct TestProviderRegistry: TaskProviderRegistryPort {
        let result: TaskProviderCandidate

        func candidate(for task: CodingTask, stage: TaskStage) async -> TaskProviderCandidate {
            result
        }
    }

    private struct TestWorkspacePreflight: TaskWorkspacePreflightPort {
        let isOwned: Bool
        let sharedRepositoryPath: String?

        func preflight(projectID: UUID, taskID: UUID) async -> TaskWorkspacePreflightResult {
            guard isOwned else {
                return .notOwned(reason: "workspace not owned")
            }
            let repositoryPath = sharedRepositoryPath ?? "/tmp/agentic-sidebar-scheduler-tests/repo-\(taskID.uuidString)"
            return .owned(
                TaskWorkspaceDescriptor(
                    workspaceID: taskID,
                    workspacePath: repositoryPath + "/workspace",
                    repositoryPath: repositoryPath
                )
            )
        }
    }

    private struct TestVerifier: TaskVerifying {
        let passed: Bool

        func verify(
            task: CodingTask,
            attempt: TaskAttempt,
            workspace: TaskWorkspaceDescriptor
        ) async -> TaskVerificationReport {
            TaskVerificationReport(
                passed: passed,
                recipeName: "stub-recipe",
                detailsRedacted: "stub-details"
            )
        }
    }

    // MARK: - Fixtures

    private let startDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTask(
        projectID: UUID,
        title: String,
        priority: Int,
        status: TaskStatus,
        createdAt: Date
    ) -> CodingTask {
        CodingTask(
            id: UUID(),
            projectID: projectID,
            title: title,
            objective: title,
            priority: priority,
            status: status,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    private func makeScheduler(
        store: SQLiteTaskStore,
        clock: TestTaskSchedulerClock,
        providers: TaskProviderCandidate,
        workspaceOwned: Bool,
        sharedRepositoryPath: String?,
        verifierPassed: Bool,
        schedulerID: String
    ) -> TaskScheduler {
        TaskScheduler(
            repository: store,
            providers: TestProviderRegistry(result: providers),
            workspaces: TestWorkspacePreflight(isOwned: workspaceOwned, sharedRepositoryPath: sharedRepositoryPath),
            verifier: TestVerifier(passed: verifierPassed),
            clock: clock,
            schedulerID: schedulerID,
            provisioning: nil
        )
    }

    private func claim(in report: TaskScheduleReport, taskID: UUID) -> (attemptID: UUID, generation: Int)? {
        for entry in report.entries where entry.taskID == taskID {
            if case .claimed(let attemptID, let generation) = entry.disposition {
                return (attemptID, generation)
            }
        }
        return nil
    }

    private func entry(in report: TaskScheduleReport, taskID: UUID) throws -> TaskScheduleEntry {
        try XCTUnwrap(report.entries.first { $0.taskID == taskID })
    }

    private func activeLease(for scheduler: TaskScheduler, taskID: UUID) async throws -> TaskLease {
        let lease = await scheduler.activeLease(taskID: taskID)
        return try XCTUnwrap(lease)
    }

    private func finish(
        scheduler: TaskScheduler,
        taskID: UUID,
        attemptID: UUID,
        generation: Int,
        ownerNonce: String,
        outcome: AttemptOutcome,
        usage: TaskAttemptUsage
    ) async throws -> TaskAttemptCompletionReport {
        try await scheduler.attemptDidComplete(
            taskID: taskID,
            attemptID: attemptID,
            generation: generation,
            ownerNonce: ownerNonce,
            outcome: outcome,
            usage: usage
        )
    }

    // MARK: - Eligibility and determinism

    func testScheduleClaimsDependencyReadyTasksInDeterministicOrder() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let scheduler = makeScheduler(
            store: store,
            clock: clock,
            providers: .eligible(runtimeID: "runtime", modelID: "model"),
            workspaceOwned: true,
            sharedRepositoryPath: nil,
            verifierPassed: true,
            schedulerID: "scheduler-order"
        )

        let prerequisiteDone = makeTask(
            projectID: projectID, title: "Prerequisite Done", priority: 1, status: .done,
            createdAt: startDate)
        let prerequisitePending = makeTask(
            projectID: projectID, title: "Prerequisite Pending", priority: 1, status: .backlog,
            createdAt: startDate.addingTimeInterval(1))
        let highPriority = makeTask(
            projectID: projectID, title: "High Priority", priority: 9, status: .ready,
            createdAt: startDate.addingTimeInterval(2))
        let lowPriority = makeTask(
            projectID: projectID, title: "Low Priority", priority: 1, status: .ready,
            createdAt: startDate.addingTimeInterval(3))
        let blockedDependent = makeTask(
            projectID: projectID, title: "Blocked Dependent", priority: 10, status: .ready,
            createdAt: startDate.addingTimeInterval(4))

        for task in [prerequisiteDone, prerequisitePending, highPriority, lowPriority, blockedDependent] {
            try await store.createTask(task)
        }
        try await store.addDependency(
            TaskDependency(projectID: projectID, prerequisiteTaskID: prerequisiteDone.id, dependentTaskID: highPriority.id))
        try await store.addDependency(
            TaskDependency(projectID: projectID, prerequisiteTaskID: prerequisitePending.id, dependentTaskID: blockedDependent.id))

        let report = try await scheduler.schedule(projectID: projectID)

        XCTAssertEqual(report.entries.map(\.taskID), [highPriority.id, lowPriority.id])
        let highClaim = try XCTUnwrap(claim(in: report, taskID: highPriority.id))
        let lowClaim = try XCTUnwrap(claim(in: report, taskID: lowPriority.id))
        XCTAssertEqual(highClaim.generation, 1)
        XCTAssertEqual(lowClaim.generation, 1)
        XCTAssertNil(claim(in: report, taskID: blockedDependent.id))
        XCTAssertNil(claim(in: report, taskID: prerequisitePending.id))

        let snapshot = try await store.snapshot(projectID: projectID)
        XCTAssertEqual(snapshot.activeAttempts.count, 2)
    }

    func testScheduleDefersUntilWorkspacePreflightReturnsOwnedWorkspace() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let scheduler = makeScheduler(
            store: store,
            clock: clock,
            providers: .eligible(runtimeID: "runtime", modelID: "model"),
            workspaceOwned: false,
            sharedRepositoryPath: nil,
            verifierPassed: true,
            schedulerID: "scheduler-preflight"
        )
        let task = makeTask(projectID: projectID, title: "Needs Workspace", priority: 1, status: .ready, createdAt: startDate)
        try await store.createTask(task)

        let report = try await scheduler.schedule(projectID: projectID)

        guard case .deferred = try entry(in: report, taskID: task.id).disposition else {
            XCTFail("Expected deferred entry while workspace is not owned")
            return
        }
        let snapshot = try await store.snapshot(projectID: projectID)
        XCTAssertTrue(snapshot.activeAttempts.isEmpty)
        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertTrue(history.isEmpty)
        let stored = try await store.task(id: task.id)
        XCTAssertEqual(stored?.status, .ready)
    }

    // MARK: - Workspace-before-claim provisioning

    private actor SchedulerEventLog {
        private var events: [String] = []

        func append(_ event: String) {
            events.append(event)
        }

        func snapshot() -> [String] {
            events
        }
    }

    private struct TestWorkspaceProvisioning: TaskWorkspaceProvisioningPort {
        let log: SchedulerEventLog
        let workspaceID: UUID
        let baseSHA: String
        let repositoryPath: String
        let createRefusal: WorkspaceGuardError?

        func resolveBase(for task: CodingTask) async throws -> WorkspaceBase {
            await log.append("resolveBase")
            return WorkspaceBase(commitSHA: baseSHA)
        }

        func create(task: CodingTask, attempt: TaskAttempt, base: WorkspaceBase) async throws -> WorkspaceRecord {
            await log.append("create:\(attempt.id.uuidString):\(base.commitSHA)")
            if let createRefusal {
                throw createRefusal
            }
            return WorkspaceRecord(
                workspaceID: workspaceID,
                projectID: task.projectID,
                taskID: task.id,
                attemptID: attempt.id,
                repositoryPath: repositoryPath,
                workspacePath: repositoryPath + "/workspace-\(workspaceID.uuidString)",
                commonDirIdentity: repositoryPath + "/.git",
                baseSHA: base.commitSHA,
                nonce: UUID().uuidString,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }

        func discardUnclaimed(workspaceID: UUID, attemptID: UUID) async throws {
            await log.append("discard:\(workspaceID.uuidString):\(attemptID.uuidString)")
        }
    }

    private func makeProvisioningScheduler(
        store: SQLiteTaskStore,
        repository: CodingTaskRepository,
        clock: TestTaskSchedulerClock,
        providers: TaskProviderCandidate,
        provisioning: TestWorkspaceProvisioning,
        verifierPassed: Bool,
        schedulerID: String
    ) -> TaskScheduler {
        TaskScheduler(
            repository: repository,
            providers: TestProviderRegistry(result: providers),
            workspaces: TestWorkspacePreflight(isOwned: false, sharedRepositoryPath: nil),
            verifier: TestVerifier(passed: verifierPassed),
            clock: clock,
            schedulerID: schedulerID,
            provisioning: provisioning
        )
    }

    func testScheduleProvisionsWorkspaceBeforeClaimAndBindsWorkspaceID() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let repositoryPath = "/tmp/agentic-sidebar-scheduler-tests/provisioned-repo"
        let workspaceID = UUID()
        let baseSHA = String(repeating: "a", count: 40)
        let log = SchedulerEventLog()
        let provisioning = TestWorkspaceProvisioning(
            log: log,
            workspaceID: workspaceID,
            baseSHA: baseSHA,
            repositoryPath: repositoryPath,
            createRefusal: nil
        )
        let repository = HookingTaskRepository(base: store)
        await repository.setClaimObserver { await log.append("claim") }
        let scheduler = makeProvisioningScheduler(
            store: store,
            repository: repository,
            clock: clock,
            providers: .eligible(runtimeID: "runtime", modelID: "model"),
            provisioning: provisioning,
            verifierPassed: true,
            schedulerID: "scheduler-provisioning"
        )
        let task = makeTask(projectID: projectID, title: "Provisioned Task", priority: 1, status: .ready, createdAt: startDate)
        try await store.createTask(task)

        let report = try await scheduler.schedule(projectID: projectID)
        let claimed = try XCTUnwrap(claim(in: report, taskID: task.id))

        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(
            history.first?.workspaceID,
            workspaceID,
            "The claimed attempt must be bound to the workspace created for its exact identity"
        )
        XCTAssertEqual(history.first?.id, claimed.attemptID)

        let events = await log.snapshot()
        XCTAssertEqual(
            events,
            ["resolveBase", "create:\(claimed.attemptID.uuidString):\(baseSHA)", "claim"],
            "The owned workspace must be created before the attempt is claimed"
        )
    }

    func testClaimRejectionDiscardsProvisionedWorkspaceAndReleasesLease() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let repositoryPath = "/tmp/agentic-sidebar-scheduler-tests/discarded-repo"
        let workspaceID = UUID()
        let log = SchedulerEventLog()
        let provisioning = TestWorkspaceProvisioning(
            log: log,
            workspaceID: workspaceID,
            baseSHA: String(repeating: "b", count: 40),
            repositoryPath: repositoryPath,
            createRefusal: nil
        )
        let repository = HookingTaskRepository(base: store)
        let task = makeTask(projectID: projectID, title: "Rejected Claim", priority: 1, status: .ready, createdAt: startDate)
        try await store.createTask(task)
        await repository.setClaimAttemptError(
            .activeAttemptConflict(taskID: task.id, existingAttemptID: UUID())
        )
        let scheduler = makeProvisioningScheduler(
            store: store,
            repository: repository,
            clock: clock,
            providers: .eligible(runtimeID: "runtime", modelID: "model"),
            provisioning: provisioning,
            verifierPassed: true,
            schedulerID: "scheduler-claim-rejected"
        )

        let report = try await scheduler.schedule(projectID: projectID)

        XCTAssertEqual(try entry(in: report, taskID: task.id).disposition, .deferred(reason: "claimRejected"))
        let events = await log.snapshot()
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0], "resolveBase")
        XCTAssertTrue(events[1].hasPrefix("create:"))
        let createAttemptID = events[1].split(separator: ":")[1]
        XCTAssertTrue(
            events[2].hasPrefix("discard:\(workspaceID.uuidString):"),
            "The unclaimed workspace must be discarded by exact identity, got \(events[2])"
        )
        XCTAssertEqual(events[2].split(separator: ":")[2], createAttemptID)

        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertTrue(history.isEmpty, "A rejected claim must not persist an attempt")
        let snapshot = try await store.snapshot(projectID: projectID)
        XCTAssertTrue(snapshot.activeAttempts.isEmpty)
        let stored = try await store.task(id: task.id)
        XCTAssertEqual(stored?.status, .ready)

        let replacementAttemptID = UUID()
        try await store.acquireRepositoryLease(
            repositoryPath: repositoryPath, taskID: UUID(), attemptID: replacementAttemptID, leaseTimeoutSeconds: 60)
        try await store.releaseRepositoryLease(
            repositoryPath: repositoryPath, taskID: UUID(), attemptID: replacementAttemptID)
    }

    func testNonContentionClaimFailureDiscardsProvisionedWorkspaceWithoutDispatch() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let repositoryPath = "/tmp/agentic-sidebar-scheduler-tests/failed-claim-repo"
        let workspaceID = UUID()
        let log = SchedulerEventLog()
        let provisioning = TestWorkspaceProvisioning(
            log: log,
            workspaceID: workspaceID,
            baseSHA: String(repeating: "c", count: 40),
            repositoryPath: repositoryPath,
            createRefusal: nil
        )
        let repository = HookingTaskRepository(base: store)
        let task = makeTask(projectID: projectID, title: "Failing Claim", priority: 1, status: .ready, createdAt: startDate)
        try await store.createTask(task)
        await repository.setClaimAttemptError(.underlying("injected claim failure"))
        let scheduler = makeProvisioningScheduler(
            store: store,
            repository: repository,
            clock: clock,
            providers: .eligible(runtimeID: "runtime", modelID: "model"),
            provisioning: provisioning,
            verifierPassed: true,
            schedulerID: "scheduler-claim-failed"
        )

        let report = try await scheduler.schedule(projectID: projectID)

        guard case .deferred(let reason) = try entry(in: report, taskID: task.id).disposition else {
            XCTFail("A failed claim must be reported deferred, never as a dispatch")
            return
        }
        XCTAssertTrue(reason.hasPrefix("claimFailed"), "Unexpected reason \(reason)")
        XCTAssertTrue(reason.contains("injected claim failure"))
        let events = await log.snapshot()
        XCTAssertTrue(events.last?.hasPrefix("discard:\(workspaceID.uuidString):") == true)
        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertTrue(history.isEmpty)
        let stored = try await store.task(id: task.id)
        XCTAssertEqual(stored?.status, .ready)
    }

    func testProvisioningRefusalDefersWithoutClaimOrLease() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let repositoryPath = "/tmp/agentic-sidebar-scheduler-tests/refused-provisioning-repo"
        let log = SchedulerEventLog()
        let provisioning = TestWorkspaceProvisioning(
            log: log,
            workspaceID: UUID(),
            baseSHA: String(repeating: "d", count: 40),
            repositoryPath: repositoryPath,
            createRefusal: .worktreeDirty(path: repositoryPath, status: " M tracked.txt")
        )
        let repository = HookingTaskRepository(base: store)
        let task = makeTask(projectID: projectID, title: "Refused Workspace", priority: 1, status: .ready, createdAt: startDate)
        try await store.createTask(task)
        let scheduler = makeProvisioningScheduler(
            store: store,
            repository: repository,
            clock: clock,
            providers: .eligible(runtimeID: "runtime", modelID: "model"),
            provisioning: provisioning,
            verifierPassed: true,
            schedulerID: "scheduler-provisioning-refused"
        )

        let report = try await scheduler.schedule(projectID: projectID)

        guard case .deferred(let reason) = try entry(in: report, taskID: task.id).disposition else {
            XCTFail("A refused provisioning pass must defer the task")
            return
        }
        XCTAssertTrue(reason.hasPrefix("workspaceProvisioningFailed"), "Unexpected reason \(reason)")
        XCTAssertTrue(reason.contains("WORKTREE_DIRTY"))
        let events = await log.snapshot()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first, "resolveBase")
        XCTAssertTrue(events.last?.hasPrefix("create:") == true)
        XCTAssertFalse(events.contains { $0.hasPrefix("discard:") }, "Nothing was created, so nothing may be discarded")

        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertTrue(history.isEmpty)
        let stored = try await store.task(id: task.id)
        XCTAssertEqual(stored?.status, .ready)

        let replacementAttemptID = UUID()
        try await store.acquireRepositoryLease(
            repositoryPath: repositoryPath, taskID: UUID(), attemptID: replacementAttemptID, leaseTimeoutSeconds: 60)
        try await store.releaseRepositoryLease(
            repositoryPath: repositoryPath, taskID: UUID(), attemptID: replacementAttemptID)
    }

    // MARK: - Writer exclusivity

    func testScheduleAllowsOnlyOneActiveWriterPerRepository() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let sharedPath = "/tmp/agentic-sidebar-scheduler-tests/shared-repo"
        let scheduler = makeScheduler(
            store: store,
            clock: clock,
            providers: .eligible(runtimeID: "runtime", modelID: "model"),
            workspaceOwned: true,
            sharedRepositoryPath: sharedPath,
            verifierPassed: true,
            schedulerID: "scheduler-writer-lock"
        )

        let firstTask = makeTask(projectID: projectID, title: "First Writer", priority: 5, status: .ready, createdAt: startDate)
        let secondTask = makeTask(
            projectID: projectID, title: "Second Writer", priority: 1, status: .ready, createdAt: startDate.addingTimeInterval(1))
        try await store.createTask(firstTask)
        try await store.createTask(secondTask)

        let report = try await scheduler.schedule(projectID: projectID)

        XCTAssertNotNil(claim(in: report, taskID: firstTask.id))
        guard case .deferred = try entry(in: report, taskID: secondTask.id).disposition else {
            XCTFail("Second task must be deferred while the repository is leased")
            return
        }
        let snapshot = try await store.snapshot(projectID: projectID)
        XCTAssertEqual(snapshot.activeAttempts.count, 1)
        XCTAssertEqual(snapshot.activeAttempts.first?.taskID, firstTask.id)
    }

    func testConcurrentSchedulersRaceToExactlyOneClaim() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let sharedPath = "/tmp/agentic-sidebar-scheduler-tests/race-repo"
        let task = makeTask(projectID: projectID, title: "Raced Task", priority: 1, status: .ready, createdAt: startDate)
        try await store.createTask(task)

        let schedulerA = makeScheduler(
            store: store, clock: clock, providers: .eligible(runtimeID: "runtime", modelID: "model"),
            workspaceOwned: true, sharedRepositoryPath: sharedPath, verifierPassed: true, schedulerID: "scheduler-a")
        let schedulerB = makeScheduler(
            store: store, clock: clock, providers: .eligible(runtimeID: "runtime", modelID: "model"),
            workspaceOwned: true, sharedRepositoryPath: sharedPath, verifierPassed: true, schedulerID: "scheduler-b")

        async let reportA = schedulerA.schedule(projectID: projectID)
        async let reportB = schedulerB.schedule(projectID: projectID)
        let reports = try await [reportA, reportB]

        let claimedTaskIDs = reports.flatMap(\.claimedTaskIDs)
        XCTAssertEqual(claimedTaskIDs, [task.id])
        let snapshot = try await store.snapshot(projectID: projectID)
        XCTAssertEqual(snapshot.activeAttempts.count, 1)
    }

    func testHundredContendersClaimExactlyOneAttempt() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let sharedPath = "/tmp/agentic-sidebar-scheduler-tests/contended-repo"
        let task = makeTask(projectID: projectID, title: "Contended Task", priority: 1, status: .ready, createdAt: startDate)
        try await store.createTask(task)

        let schedulers = (0..<100).map { index in
            makeScheduler(
                store: store, clock: clock, providers: .eligible(runtimeID: "runtime", modelID: "model"),
                workspaceOwned: true, sharedRepositoryPath: sharedPath, verifierPassed: true,
                schedulerID: "contender-\(index)")
        }

        let reports = try await withThrowingTaskGroup(of: TaskScheduleReport.self) { group in
            for scheduler in schedulers {
                group.addTask {
                    try await scheduler.schedule(projectID: projectID)
                }
            }
            var collected: [TaskScheduleReport] = []
            for try await report in group {
                collected.append(report)
            }
            return collected
        }

        XCTAssertEqual(reports.flatMap(\.claimedTaskIDs).count, 1)
        let snapshot = try await store.snapshot(projectID: projectID)
        XCTAssertEqual(snapshot.activeAttempts.count, 1)
        XCTAssertEqual(snapshot.activeAttempts.first?.taskID, task.id)
    }

    // MARK: - Attempt budgets

    func testMaximumThreeAttemptsThenRetryIsRefused() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let scheduler = makeScheduler(
            store: store, clock: clock, providers: .eligible(runtimeID: "runtime", modelID: "model"),
            workspaceOwned: true, sharedRepositoryPath: nil, verifierPassed: true, schedulerID: "scheduler-attempts")
        let task = makeTask(projectID: projectID, title: "Budgeted Task", priority: 1, status: .ready, createdAt: startDate)
        try await store.createTask(task)

        let firstReport = try await scheduler.schedule(projectID: projectID)
        let firstClaim = try XCTUnwrap(claim(in: firstReport, taskID: task.id))
        XCTAssertEqual(firstClaim.generation, 1)
        let firstLease = try await activeLease(for: scheduler, taskID: task.id)
        let firstCompletion = try await finish(
            scheduler: scheduler, taskID: task.id, attemptID: firstClaim.attemptID, generation: firstClaim.generation,
            ownerNonce: firstLease.ownerNonce, outcome: .failed, usage: TaskAttemptUsage(toolCallCount: nil, durationSeconds: nil))
        XCTAssertEqual(firstCompletion.disposition, .accepted)

        let secondEntry = try await scheduler.retry(taskID: task.id)
        guard case .claimed(let secondAttemptID, let secondGeneration) = secondEntry.disposition else {
            XCTFail("Expected retry to claim the second attempt")
            return
        }
        XCTAssertEqual(secondGeneration, 2)
        let secondLease = try await activeLease(for: scheduler, taskID: task.id)
        _ = try await finish(
            scheduler: scheduler, taskID: task.id, attemptID: secondAttemptID, generation: secondGeneration,
            ownerNonce: secondLease.ownerNonce, outcome: .failed, usage: TaskAttemptUsage(toolCallCount: nil, durationSeconds: nil))

        let thirdEntry = try await scheduler.retry(taskID: task.id)
        guard case .claimed(let thirdAttemptID, let thirdGeneration) = thirdEntry.disposition else {
            XCTFail("Expected retry to claim the third attempt")
            return
        }
        XCTAssertEqual(thirdGeneration, 3)
        let thirdLease = try await activeLease(for: scheduler, taskID: task.id)
        _ = try await finish(
            scheduler: scheduler, taskID: task.id, attemptID: thirdAttemptID, generation: thirdGeneration,
            ownerNonce: thirdLease.ownerNonce, outcome: .failed, usage: TaskAttemptUsage(toolCallCount: nil, durationSeconds: nil))

        do {
            _ = try await scheduler.retry(taskID: task.id)
            XCTFail("Expected attemptBudgetExhausted on the fourth claim")
        } catch let error as TaskSchedulerError {
            XCTAssertEqual(error, .attemptBudgetExhausted(taskID: task.id, used: 3, maximum: 3))
        }

        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.map(\.generation).sorted(), [1, 2, 3])
        XCTAssertEqual(history.filter { $0.outcome == .failed }.count, 3)

        for _ in 0..<3 {
            let report = try await scheduler.schedule(projectID: projectID)
            XCTAssertTrue(report.claimedTaskIDs.isEmpty)
        }
        let remainingHistory = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(remainingHistory.count, 3)
        let stored = try await store.task(id: task.id)
        XCTAssertEqual(stored?.status, .blocked)
    }

    func testTimeBudgetExhaustionBlocksWithoutAnotherAttempt() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let scheduler = makeScheduler(
            store: store, clock: clock, providers: .eligible(runtimeID: "runtime", modelID: "model"),
            workspaceOwned: true, sharedRepositoryPath: nil, verifierPassed: true, schedulerID: "scheduler-time-budget")
        let task = makeTask(projectID: projectID, title: "Timed Task", priority: 1, status: .ready, createdAt: startDate)
        try await store.createTask(task)

        let firstReport = try await scheduler.schedule(projectID: projectID)
        let firstClaim = try XCTUnwrap(claim(in: firstReport, taskID: task.id))
        clock.advance(seconds: 1800)
        let firstLease = try await activeLease(for: scheduler, taskID: task.id)
        _ = try await finish(
            scheduler: scheduler, taskID: task.id, attemptID: firstClaim.attemptID, generation: firstClaim.generation,
            ownerNonce: firstLease.ownerNonce, outcome: .failed, usage: TaskAttemptUsage(toolCallCount: nil, durationSeconds: nil))

        let secondEntry = try await scheduler.retry(taskID: task.id)
        guard case .claimed(let secondAttemptID, let secondGeneration) = secondEntry.disposition else {
            XCTFail("Expected retry to claim the second attempt")
            return
        }
        XCTAssertEqual(secondGeneration, 2)
        clock.advance(seconds: 1900)
        let secondLease = try await activeLease(for: scheduler, taskID: task.id)
        _ = try await finish(
            scheduler: scheduler, taskID: task.id, attemptID: secondAttemptID, generation: secondGeneration,
            ownerNonce: secondLease.ownerNonce, outcome: .failed, usage: TaskAttemptUsage(toolCallCount: nil, durationSeconds: nil))

        let blockedTask = try await store.task(id: task.id)
        XCTAssertEqual(blockedTask?.status, .blocked)
        XCTAssertEqual(blockedTask?.blockReason, .custom("timeBudgetExhausted"))

        do {
            _ = try await scheduler.retry(taskID: task.id)
            XCTFail("Expected timeBudgetExhausted on retry")
        } catch let error as TaskSchedulerError {
            XCTAssertEqual(error, .timeBudgetExhausted(taskID: task.id, usedSeconds: 3700, maximumSeconds: 3600))
        }
        let report = try await scheduler.schedule(projectID: projectID)
        XCTAssertTrue(report.claimedTaskIDs.isEmpty)
        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.count, 2)
    }

    func testToolCallBudgetExhaustionBlocksWithoutAnotherAttempt() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let scheduler = makeScheduler(
            store: store, clock: clock, providers: .eligible(runtimeID: "runtime", modelID: "model"),
            workspaceOwned: true, sharedRepositoryPath: nil, verifierPassed: true, schedulerID: "scheduler-tool-budget")
        let task = makeTask(projectID: projectID, title: "Tool Hungry Task", priority: 1, status: .ready, createdAt: startDate)
        try await store.createTask(task)

        let firstReport = try await scheduler.schedule(projectID: projectID)
        let firstClaim = try XCTUnwrap(claim(in: firstReport, taskID: task.id))
        let firstLease = try await activeLease(for: scheduler, taskID: task.id)
        _ = try await finish(
            scheduler: scheduler, taskID: task.id, attemptID: firstClaim.attemptID, generation: firstClaim.generation,
            ownerNonce: firstLease.ownerNonce, outcome: .failed, usage: TaskAttemptUsage(toolCallCount: 301, durationSeconds: 10))

        let blockedTask = try await store.task(id: task.id)
        XCTAssertEqual(blockedTask?.status, .blocked)
        XCTAssertEqual(blockedTask?.blockReason, .custom("toolCallBudgetExceeded"))

        do {
            _ = try await scheduler.retry(taskID: task.id)
            XCTFail("Expected toolCallBudgetExhausted on retry")
        } catch let error as TaskSchedulerError {
            XCTAssertEqual(error, .toolCallBudgetExhausted(taskID: task.id, used: 301, maximum: 300))
        }
        let report = try await scheduler.schedule(projectID: projectID)
        XCTAssertTrue(report.claimedTaskIDs.isEmpty)
        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.toolCallCount, 301)
    }

    func testUnknownUsageStaysUnknownAndDoesNotExhaustToolBudget() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let scheduler = makeScheduler(
            store: store, clock: clock, providers: .eligible(runtimeID: "runtime", modelID: "model"),
            workspaceOwned: true, sharedRepositoryPath: nil, verifierPassed: true, schedulerID: "scheduler-unknown-usage")
        let task = makeTask(projectID: projectID, title: "Unknown Usage Task", priority: 1, status: .ready, createdAt: startDate)
        try await store.createTask(task)

        let firstReport = try await scheduler.schedule(projectID: projectID)
        let firstClaim = try XCTUnwrap(claim(in: firstReport, taskID: task.id))
        clock.advance(seconds: 120)
        let firstLease = try await activeLease(for: scheduler, taskID: task.id)
        _ = try await finish(
            scheduler: scheduler, taskID: task.id, attemptID: firstClaim.attemptID, generation: firstClaim.generation,
            ownerNonce: firstLease.ownerNonce, outcome: .failed, usage: TaskAttemptUsage(toolCallCount: nil, durationSeconds: nil))

        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.count, 1)
        XCTAssertNil(history.first?.toolCallCount, "Unknown tool usage must never be coerced to zero")
        XCTAssertEqual(history.first?.durationSeconds, 120)

        let retryEntry = try await scheduler.retry(taskID: task.id)
        guard case .claimed(_, let generation) = retryEntry.disposition else {
            XCTFail("Unknown tool usage must not exhaust the tool-call budget")
            return
        }
        XCTAssertEqual(generation, 2)
        let refreshedHistory = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(refreshedHistory.count, 2)
    }

    // MARK: - Capabilities

    func testUnsupportedRuntimeBlocksTaskWithoutClaimingAnAttempt() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let scheduler = makeScheduler(
            store: store, clock: clock, providers: .unsupported(missingCapabilities: ["workspaceWrite"]),
            workspaceOwned: true, sharedRepositoryPath: nil, verifierPassed: true, schedulerID: "scheduler-unsupported")
        let task = makeTask(projectID: projectID, title: "Unsupported Task", priority: 1, status: .ready, createdAt: startDate)
        try await store.createTask(task)

        let report = try await scheduler.schedule(projectID: projectID)

        guard case .blocked(let reason) = try entry(in: report, taskID: task.id).disposition else {
            XCTFail("Expected the task to be blocked when no runtime supports it")
            return
        }
        XCTAssertEqual(reason, .unsupportedCapability("workspaceWrite"))
        let snapshot = try await store.snapshot(projectID: projectID)
        XCTAssertTrue(snapshot.activeAttempts.isEmpty)
        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertTrue(history.isEmpty)
        let stored = try await store.task(id: task.id)
        XCTAssertEqual(stored?.status, .blocked)
        XCTAssertEqual(stored?.blockReason, .unsupportedCapability("workspaceWrite"))
    }

    // MARK: - Lease ownership

    func testStaleCompletionIsRejectedForForeignAndSupersededLeases() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let scheduler = makeScheduler(
            store: store, clock: clock, providers: .eligible(runtimeID: "runtime", modelID: "model"),
            workspaceOwned: true, sharedRepositoryPath: nil, verifierPassed: true, schedulerID: "scheduler-stale")
        let task = makeTask(projectID: projectID, title: "Stale Task", priority: 1, status: .ready, createdAt: startDate)
        try await store.createTask(task)

        let firstReport = try await scheduler.schedule(projectID: projectID)
        let firstClaim = try XCTUnwrap(claim(in: firstReport, taskID: task.id))
        let firstLease = try await activeLease(for: scheduler, taskID: task.id)

        let foreignCompletion = try await finish(
            scheduler: scheduler, taskID: task.id, attemptID: firstClaim.attemptID, generation: firstClaim.generation,
            ownerNonce: "foreign-nonce", outcome: .failed, usage: TaskAttemptUsage(toolCallCount: nil, durationSeconds: nil))
        XCTAssertEqual(foreignCompletion.disposition, .stale)
        let untouchedHistory = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(untouchedHistory.count, 1)
        XCTAssertEqual(untouchedHistory.first?.outcome, .inProgress)

        _ = try await finish(
            scheduler: scheduler, taskID: task.id, attemptID: firstClaim.attemptID, generation: firstClaim.generation,
            ownerNonce: firstLease.ownerNonce, outcome: .failed, usage: TaskAttemptUsage(toolCallCount: nil, durationSeconds: nil))

        let secondEntry = try await scheduler.retry(taskID: task.id)
        guard case .claimed(let secondAttemptID, let secondGeneration) = secondEntry.disposition else {
            XCTFail("Expected retry to claim the second attempt")
            return
        }
        XCTAssertEqual(secondGeneration, 2)

        let lateCompletion = try await finish(
            scheduler: scheduler, taskID: task.id, attemptID: firstClaim.attemptID, generation: firstClaim.generation,
            ownerNonce: firstLease.ownerNonce, outcome: .succeeded, usage: TaskAttemptUsage(toolCallCount: nil, durationSeconds: nil))
        XCTAssertEqual(lateCompletion.disposition, .stale)

        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.count, 2)
        let firstAttempt = try XCTUnwrap(history.first { $0.id == firstClaim.attemptID })
        XCTAssertEqual(firstAttempt.outcome, .failed)
        let secondAttempt = try XCTUnwrap(history.first { $0.id == secondAttemptID })
        XCTAssertEqual(secondAttempt.outcome, .inProgress)
        let stored = try await store.task(id: task.id)
        XCTAssertEqual(stored?.status, .running)
    }

    // MARK: - Pause and stop

    func testPauseSuspendsTaskWithoutEndingAttemptAndRejectsLateCompletion() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let scheduler = makeScheduler(
            store: store, clock: clock, providers: .eligible(runtimeID: "runtime", modelID: "model"),
            workspaceOwned: true, sharedRepositoryPath: nil, verifierPassed: true, schedulerID: "scheduler-pause")
        let task = makeTask(projectID: projectID, title: "Pausable Task", priority: 1, status: .ready, createdAt: startDate)
        try await store.createTask(task)

        let firstReport = try await scheduler.schedule(projectID: projectID)
        let firstClaim = try XCTUnwrap(claim(in: firstReport, taskID: task.id))
        let firstLease = try await activeLease(for: scheduler, taskID: task.id)

        try await scheduler.pause(taskID: task.id)

        let pausedTask = try await store.task(id: task.id)
        XCTAssertEqual(pausedTask?.status, .blocked)
        XCTAssertEqual(pausedTask?.blockReason, .custom("paused"))
        let pausedHistory = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(pausedHistory.count, 1)
        XCTAssertEqual(pausedHistory.first?.outcome, .inProgress)
        XCTAssertNil(pausedHistory.first?.endedAt)

        let reportWhilePaused = try await scheduler.schedule(projectID: projectID)
        XCTAssertTrue(reportWhilePaused.claimedTaskIDs.isEmpty)

        let lateCompletion = try await finish(
            scheduler: scheduler, taskID: task.id, attemptID: firstClaim.attemptID, generation: firstClaim.generation,
            ownerNonce: firstLease.ownerNonce, outcome: .failed, usage: TaskAttemptUsage(toolCallCount: nil, durationSeconds: nil))
        XCTAssertEqual(lateCompletion.disposition, .stale)

        let retryEntry = try await scheduler.retry(taskID: task.id)
        guard case .claimed(_, let generation) = retryEntry.disposition else {
            XCTFail("Expected retry to claim a fresh attempt after pause")
            return
        }
        XCTAssertEqual(generation, 2)
        let historyAfterRetry = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(historyAfterRetry.count, 2)
        let cancelledAttempt = try XCTUnwrap(historyAfterRetry.first { $0.id == firstClaim.attemptID })
        XCTAssertEqual(cancelledAttempt.outcome, .cancelled)
    }

    func testPauseRetainsRepositoryLeaseUntilAttemptIsReconciled() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let sharedPath = "/tmp/agentic-sidebar-scheduler-tests/paused-writer-repo"
        let scheduler = makeScheduler(
            store: store, clock: clock, providers: .eligible(runtimeID: "runtime", modelID: "model"),
            workspaceOwned: true, sharedRepositoryPath: sharedPath, verifierPassed: true, schedulerID: "scheduler-pause-writer")
        let firstTask = makeTask(projectID: projectID, title: "Paused Writer", priority: 5, status: .ready, createdAt: startDate)
        let secondTask = makeTask(
            projectID: projectID, title: "Waiting Writer", priority: 1, status: .ready, createdAt: startDate.addingTimeInterval(1))
        try await store.createTask(firstTask)
        try await store.createTask(secondTask)

        let firstReport = try await scheduler.schedule(projectID: projectID)
        XCTAssertNotNil(claim(in: firstReport, taskID: firstTask.id))
        XCTAssertNil(claim(in: firstReport, taskID: secondTask.id))

        try await scheduler.pause(taskID: firstTask.id)

        let reportWhilePaused = try await scheduler.schedule(projectID: projectID)
        XCTAssertNil(
            claim(in: reportWhilePaused, taskID: secondTask.id),
            "A paused in-progress attempt must retain repository ownership until it is stopped or reconciled"
        )
        guard case .deferred = try entry(in: reportWhilePaused, taskID: secondTask.id).disposition else {
            XCTFail("Second writer must remain deferred while the paused attempt is still in progress")
            return
        }
        let history = try await store.attemptHistory(taskID: firstTask.id)
        XCTAssertEqual(history.first?.outcome, .inProgress)
    }

    func testStopEndsAttemptAndRequiresExplicitRetry() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let scheduler = makeScheduler(
            store: store, clock: clock, providers: .eligible(runtimeID: "runtime", modelID: "model"),
            workspaceOwned: true, sharedRepositoryPath: nil, verifierPassed: true, schedulerID: "scheduler-stop")
        let task = makeTask(projectID: projectID, title: "Stoppable Task", priority: 1, status: .ready, createdAt: startDate)
        try await store.createTask(task)

        let firstReport = try await scheduler.schedule(projectID: projectID)
        let firstClaim = try XCTUnwrap(claim(in: firstReport, taskID: task.id))
        let firstLease = try await activeLease(for: scheduler, taskID: task.id)

        try await scheduler.stop(taskID: task.id)

        let stoppedTask = try await store.task(id: task.id)
        XCTAssertEqual(stoppedTask?.status, .blocked)
        XCTAssertEqual(stoppedTask?.blockReason, .custom("stopped"))
        let stoppedHistory = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(stoppedHistory.count, 1)
        XCTAssertEqual(stoppedHistory.first?.outcome, .cancelled)

        let reportWhileStopped = try await scheduler.schedule(projectID: projectID)
        XCTAssertTrue(reportWhileStopped.claimedTaskIDs.isEmpty)

        let lateCompletion = try await finish(
            scheduler: scheduler, taskID: task.id, attemptID: firstClaim.attemptID, generation: firstClaim.generation,
            ownerNonce: firstLease.ownerNonce, outcome: .succeeded, usage: TaskAttemptUsage(toolCallCount: nil, durationSeconds: nil))
        XCTAssertEqual(lateCompletion.disposition, .stale)

        let retryEntry = try await scheduler.retry(taskID: task.id)
        guard case .claimed(_, let generation) = retryEntry.disposition else {
            XCTFail("Expected retry to claim a fresh attempt after stop")
            return
        }
        XCTAssertEqual(generation, 2)
        let stored = try await store.task(id: task.id)
        XCTAssertEqual(stored?.status, .running)
    }

    /// `nil` expectations mean "no active attempt is expected": a concurrent claim that
    /// landed first must never be cancelled by a stale start request.
    func testFencedRetryWithNilExpectationsRefusesWhenAttemptWasClaimed() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let scheduler = makeScheduler(
            store: store, clock: clock, providers: .eligible(runtimeID: "runtime", modelID: "model"),
            workspaceOwned: true, sharedRepositoryPath: nil, verifierPassed: true, schedulerID: "scheduler-nil-fence")
        let task = makeTask(projectID: projectID, title: "Fenced Start", priority: 1, status: .ready, createdAt: startDate)
        try await store.createTask(task)

        let report = try await scheduler.schedule(projectID: projectID)
        let claimed = try XCTUnwrap(claim(in: report, taskID: task.id))

        do {
            _ = try await scheduler.retry(taskID: task.id, expectedAttemptID: nil, expectedGeneration: nil)
            XCTFail("A nil-expectation retry must refuse while an active attempt exists")
        } catch let error as TaskSchedulerError {
            XCTAssertEqual(
                error,
                .staleAttempt(
                    taskID: task.id,
                    expectedAttemptID: nil,
                    expectedGeneration: nil,
                    actualAttemptID: claimed.attemptID,
                    actualGeneration: claimed.generation
                )
            )
        }

        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.outcome, .inProgress, "The fenced refusal must not cancel the claimed attempt")
        let stored = try await store.task(id: task.id)
        XCTAssertEqual(stored?.currentAttemptID, claimed.attemptID)
    }

    // MARK: - Verification

    func testSuccessfulCompletionRecordsEvidenceAndSubmitsForReview() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let scheduler = makeScheduler(
            store: store, clock: clock, providers: .eligible(runtimeID: "runtime", modelID: "model"),
            workspaceOwned: true, sharedRepositoryPath: nil, verifierPassed: true, schedulerID: "scheduler-verify")
        let task = makeTask(projectID: projectID, title: "Verifiable Task", priority: 1, status: .ready, createdAt: startDate)
        try await store.createTask(task)

        let report = try await scheduler.schedule(projectID: projectID)
        let claimed = try XCTUnwrap(claim(in: report, taskID: task.id))
        let lease = try await activeLease(for: scheduler, taskID: task.id)
        let completion = try await finish(
            scheduler: scheduler, taskID: task.id, attemptID: claimed.attemptID, generation: claimed.generation,
            ownerNonce: lease.ownerNonce, outcome: .succeeded, usage: TaskAttemptUsage(toolCallCount: 5, durationSeconds: 30))
        XCTAssertEqual(completion.disposition, .accepted)

        let stored = try await store.task(id: task.id)
        XCTAssertEqual(stored?.status, .review)
        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.first?.outcome, .succeeded)

        do {
            _ = try await scheduler.retry(taskID: task.id)
            XCTFail("Tasks under review cannot be retried by the scheduler")
        } catch let error as TaskSchedulerError {
            XCTAssertEqual(error, .retryNotAvailable(taskID: task.id, status: .review))
        }
    }

    // MARK: - Contention cleanup and completion reentrancy regressions

    private actor HookingTaskRepository: CodingTaskRepository {
        private let base: CodingTaskRepository
        private var endAttemptDelay: Duration?
        private var claimAttemptError: TaskRepositoryError?
        private var evidenceWrites: Int = 0
        private var forcedRepositoryLeaseTimeout: TimeInterval?
        private var releaseRepositoryLeaseError: TaskRepositoryError?
        private var claimObserver: (@Sendable () async -> Void)?

        init(base: CodingTaskRepository) {
            self.base = base
        }

        func setClaimObserver(_ observer: (@Sendable () async -> Void)?) {
            claimObserver = observer
        }

        func setEndAttemptDelay(_ delay: Duration?) {
            endAttemptDelay = delay
        }

        func setClaimAttemptError(_ error: TaskRepositoryError?) {
            claimAttemptError = error
        }

        func setForcedRepositoryLeaseTimeout(_ timeout: TimeInterval?) {
            forcedRepositoryLeaseTimeout = timeout
        }

        func setReleaseRepositoryLeaseError(_ error: TaskRepositoryError?) {
            releaseRepositoryLeaseError = error
        }

        func recordedEvidenceCount() -> Int {
            evidenceWrites
        }

        func snapshot(projectID: UUID) async throws -> CodingBoardSnapshot {
            try await base.snapshot(projectID: projectID)
        }

        func createTask(_ task: CodingTask) async throws {
            try await base.createTask(task)
        }

        func updateTaskDetails(
            taskID: UUID,
            expectedVersion: Int,
            title: String,
            objective: String,
            priority: Int,
            budget: ExecutionBudget?
        ) async throws -> CodingTask {
            try await base.updateTaskDetails(
                taskID: taskID,
                expectedVersion: expectedVersion,
                title: title,
                objective: objective,
                priority: priority,
                budget: budget
            )
        }

        func deleteTask(taskID: UUID) async throws {
            try await base.deleteTask(taskID: taskID)
        }

        func addDependency(_ dependency: TaskDependency) async throws {
            try await base.addDependency(dependency)
        }

        func setCriterionCompletion(
            taskID: UUID,
            criterionID: UUID,
            isCompleted: Bool,
            expectedVersion: Int
        ) async throws -> CodingTask {
            try await base.setCriterionCompletion(
                taskID: taskID,
                criterionID: criterionID,
                isCompleted: isCompleted,
                expectedVersion: expectedVersion
            )
        }

        func task(id: UUID) async throws -> CodingTask? {
            try await base.task(id: id)
        }

        func attemptHistory(taskID: UUID) async throws -> [TaskAttempt] {
            try await base.attemptHistory(taskID: taskID)
        }

        func transition(
            taskID: UUID,
            expectedVersion: Int,
            action: TaskAction,
            context: TaskTransitionContext
        ) async throws -> CodingTask {
            try await base.transition(taskID: taskID, expectedVersion: expectedVersion, action: action, context: context)
        }

        func claimAttempt(taskID: UUID, expectedVersion: Int, attempt: TaskAttempt) async throws -> TaskAttempt {
            await claimObserver?()
            let injected = claimAttemptError
            claimAttemptError = nil
            if let injected {
                throw injected
            }
            return try await base.claimAttempt(taskID: taskID, expectedVersion: expectedVersion, attempt: attempt)
        }

        func endAttempt(
            taskID: UUID,
            attemptID: UUID,
            expectedVersion: Int,
            outcome: AttemptOutcome,
            toolCallCount: Int?,
            durationSeconds: Int?
        ) async throws -> CodingTask {
            let delay = endAttemptDelay
            let task = try await base.endAttempt(
                taskID: taskID,
                attemptID: attemptID,
                expectedVersion: expectedVersion,
                outcome: outcome,
                toolCallCount: toolCallCount,
                durationSeconds: durationSeconds
            )
            if let delay {
                try? await Task.sleep(for: delay)
            }
            return task
        }

        func acquireRepositoryLease(
            repositoryPath: String,
            taskID: UUID,
            attemptID: UUID,
            leaseTimeoutSeconds: TimeInterval
        ) async throws {
            let timeout = forcedRepositoryLeaseTimeout ?? leaseTimeoutSeconds
            try await base.acquireRepositoryLease(
                repositoryPath: repositoryPath, taskID: taskID, attemptID: attemptID, leaseTimeoutSeconds: timeout)
        }

        func releaseRepositoryLease(repositoryPath: String, taskID: UUID, attemptID: UUID) async throws {
            let injected = releaseRepositoryLeaseError
            releaseRepositoryLeaseError = nil
            if let injected {
                throw injected
            }
            try await base.releaseRepositoryLease(repositoryPath: repositoryPath, taskID: taskID, attemptID: attemptID)
        }

        func appendEvent(_ event: CodingTaskEvent) async throws {
            try await base.appendEvent(event)
        }

        func recordEvidence(_ evidence: VerificationEvidence) async throws {
            evidenceWrites += 1
            try await base.recordEvidence(evidence)
        }

        func evidence(taskID: UUID) async throws -> [VerificationEvidence] {
            try await base.evidence(taskID: taskID)
        }

        func recordFinding(_ finding: ReviewFinding) async throws {
            try await base.recordFinding(finding)
        }

        func findings(taskID: UUID) async throws -> [ReviewFinding] {
            try await base.findings(taskID: taskID)
        }

        func dismissFinding(findingID: UUID, actor: String, reason: String, at date: Date) async throws -> ReviewFinding {
            try await base.dismissFinding(findingID: findingID, actor: actor, reason: reason, at: date)
        }

        func recordApproval(_ approval: TaskApproval) async throws {
            try await base.recordApproval(approval)
        }

        func approvals(taskID: UUID) async throws -> [TaskApproval] {
            try await base.approvals(taskID: taskID)
        }

        func saveAgentProfile(_ profile: AgentProfile) async throws {
            try await base.saveAgentProfile(profile)
        }

        func saveProject(_ project: CodingProject) async throws {
            try await base.saveProject(project)
        }

        func renameProject(id: UUID, name: String) async throws -> CodingProject {
            try await base.renameProject(id: id, name: name)
        }

        func deleteProject(id: UUID) async throws {
            try await base.deleteProject(id: id)
        }

        func loadProject(id: UUID) async throws -> CodingProject? {
            try await base.loadProject(id: id)
        }

        func listProjects() async throws -> [CodingProject] {
            try await base.listProjects()
        }

        func loadAgentProfile(id: UUID) async throws -> AgentProfile? {
            try await base.loadAgentProfile(id: id)
        }
    }

    private func waitForAttemptEnd(taskID: UUID, attemptID: UUID, in store: SQLiteTaskStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let history = try await store.attemptHistory(taskID: taskID)
            if let attempt = history.first(where: { $0.id == attemptID }), attempt.outcome != .inProgress {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Attempt \(attemptID) did not reach a terminal outcome before timeout")
    }

    func testContendedSameTaskClaimKeepsWinnerLeaseAndDefersSecondTask() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let sharedPath = "/tmp/agentic-sidebar-scheduler-tests/contended-winner-repo"
        let contended = makeTask(projectID: projectID, title: "Contended Winner", priority: 9, status: .ready, createdAt: startDate)
        let waiting = makeTask(
            projectID: projectID, title: "Waiting Writer", priority: 1, status: .ready, createdAt: startDate.addingTimeInterval(1))
        try await store.createTask(contended)
        try await store.createTask(waiting)

        let schedulers = (0..<8).map { index in
            makeScheduler(
                store: store, clock: clock, providers: .eligible(runtimeID: "runtime", modelID: "model"),
                workspaceOwned: true, sharedRepositoryPath: sharedPath, verifierPassed: true, schedulerID: "contender-\(index)")
        }

        let reports = try await withThrowingTaskGroup(of: TaskScheduleReport.self) { group in
            for scheduler in schedulers {
                group.addTask {
                    try await scheduler.schedule(projectID: projectID)
                }
            }
            var collected: [TaskScheduleReport] = []
            for try await report in group {
                collected.append(report)
            }
            return collected
        }

        XCTAssertEqual(reports.flatMap(\.claimedTaskIDs), [contended.id])
        let snapshot = try await store.snapshot(projectID: projectID)
        XCTAssertEqual(snapshot.activeAttempts.count, 1)
        XCTAssertEqual(snapshot.activeAttempts.first?.taskID, contended.id)

        let followUp = try await schedulers[0].schedule(projectID: projectID)
        XCTAssertNil(claim(in: followUp, taskID: waiting.id), "Winner's repository lease must survive loser cleanup")
        guard case .deferred = try entry(in: followUp, taskID: waiting.id).disposition else {
            XCTFail("Second writer on the same repository must stay deferred")
            return
        }
        let afterFollowUp = try await store.snapshot(projectID: projectID)
        XCTAssertEqual(afterFollowUp.activeAttempts.count, 1)
    }

    func testSlowEndAttemptDoesNotClobberRetriedAttemptOrLease() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let sharedPath = "/tmp/agentic-sidebar-scheduler-tests/reentrant-repo"
        let task = makeTask(projectID: projectID, title: "Reentrant Task", priority: 9, status: .ready, createdAt: startDate)
        let other = makeTask(
            projectID: projectID, title: "Other Writer", priority: 1, status: .ready, createdAt: startDate.addingTimeInterval(1))
        try await store.createTask(task)
        try await store.createTask(other)

        let repository = HookingTaskRepository(base: store)
        await repository.setEndAttemptDelay(.milliseconds(500))
        let scheduler = TaskScheduler(
            repository: repository,
            providers: TestProviderRegistry(result: .eligible(runtimeID: "runtime", modelID: "model")),
            workspaces: TestWorkspacePreflight(isOwned: true, sharedRepositoryPath: sharedPath),
            verifier: TestVerifier(passed: true),
            clock: clock,
            schedulerID: "scheduler-reentrancy",
            provisioning: nil
        )

        let report = try await scheduler.schedule(projectID: projectID)
        let firstClaim = try XCTUnwrap(claim(in: report, taskID: task.id))
        let firstLease = try await activeLease(for: scheduler, taskID: task.id)

        async let completion = scheduler.attemptDidComplete(
            taskID: task.id, attemptID: firstClaim.attemptID, generation: firstClaim.generation,
            ownerNonce: firstLease.ownerNonce, outcome: .failed, usage: TaskAttemptUsage(toolCallCount: nil, durationSeconds: nil))

        try await waitForAttemptEnd(taskID: task.id, attemptID: firstClaim.attemptID, in: store)

        let retryEntry = try await scheduler.retry(taskID: task.id)
        guard case .claimed(let retriedAttemptID, let retriedGeneration) = retryEntry.disposition else {
            XCTFail("Expected retry to claim a fresh attempt while completion is suspended")
            return
        }
        XCTAssertEqual(retriedGeneration, 2)

        let completionReport = try await completion
        XCTAssertEqual(
            completionReport.disposition,
            .acceptedWithBookkeepingConcern(.supersededByConcurrentActivity),
            "A completion that loses its record to a retry must report a defined outcome, never a failure"
        )

        let survivingLease = try await activeLease(for: scheduler, taskID: task.id)
        XCTAssertEqual(survivingLease.attemptID, retriedAttemptID, "Completion cleanup must not release the newer attempt's lease")

        let snapshot = try await store.snapshot(projectID: projectID)
        XCTAssertEqual(snapshot.activeAttempts.count, 1)
        XCTAssertEqual(snapshot.activeAttempts.first?.id, retriedAttemptID)
        XCTAssertEqual(snapshot.activeAttempts.first?.outcome, .inProgress)

        let followUp = try await scheduler.schedule(projectID: projectID)
        XCTAssertNil(claim(in: followUp, taskID: other.id), "Repository must stay locked by the surviving attempt")
    }

    func testNonContentionClaimFailureReleasesRepositoryLease() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let sharedPath = "/tmp/agentic-sidebar-scheduler-tests/claim-failure-repo"
        let task = makeTask(
            projectID: projectID, title: "Failing Claim Task", priority: 9, status: .ready, createdAt: startDate)
        let other = makeTask(
            projectID: projectID, title: "Other Writer", priority: 1, status: .ready, createdAt: startDate.addingTimeInterval(1))
        try await store.createTask(task)
        try await store.createTask(other)

        let repository = HookingTaskRepository(base: store)
        await repository.setClaimAttemptError(.underlying("injected claim failure"))
        let scheduler = TaskScheduler(
            repository: repository,
            providers: TestProviderRegistry(result: .eligible(runtimeID: "runtime", modelID: "model")),
            workspaces: TestWorkspacePreflight(isOwned: true, sharedRepositoryPath: sharedPath),
            verifier: TestVerifier(passed: true),
            clock: clock,
            schedulerID: "scheduler-claim-failure",
            provisioning: nil
        )

        do {
            _ = try await scheduler.schedule(projectID: projectID)
            XCTFail("Expected the injected claim failure to propagate")
        } catch let error as TaskRepositoryError {
            XCTAssertEqual(error, .underlying("injected claim failure"))
        }

        let replacementAttemptID = UUID()
        try await store.acquireRepositoryLease(
            repositoryPath: sharedPath, taskID: other.id, attemptID: replacementAttemptID, leaseTimeoutSeconds: 60)
        try await store.releaseRepositoryLease(
            repositoryPath: sharedPath, taskID: other.id, attemptID: replacementAttemptID)
    }

    func testUnavailableProviderDefersWithoutClaim() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let scheduler = makeScheduler(
            store: store, clock: clock, providers: .unavailable(reason: "no-runtime"),
            workspaceOwned: true, sharedRepositoryPath: nil, verifierPassed: true, schedulerID: "scheduler-unavailable")
        let task = makeTask(projectID: projectID, title: "Unavailable Task", priority: 1, status: .ready, createdAt: startDate)
        try await store.createTask(task)

        let report = try await scheduler.schedule(projectID: projectID)

        guard case .deferred(let reason) = try entry(in: report, taskID: task.id).disposition else {
            XCTFail("Unavailable provider must defer the task")
            return
        }
        XCTAssertEqual(reason, "providerUnavailable:no-runtime")
        let snapshot = try await store.snapshot(projectID: projectID)
        XCTAssertTrue(snapshot.activeAttempts.isEmpty)
        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertTrue(history.isEmpty)
        let stored = try await store.task(id: task.id)
        XCTAssertEqual(stored?.status, .ready)
    }

    func testVerifierFailureBlocksWithoutEvidenceOrReviewTransition() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let repository = HookingTaskRepository(base: store)
        let scheduler = TaskScheduler(
            repository: repository,
            providers: TestProviderRegistry(result: .eligible(runtimeID: "runtime", modelID: "model")),
            workspaces: TestWorkspacePreflight(isOwned: true, sharedRepositoryPath: nil),
            verifier: TestVerifier(passed: false),
            clock: clock,
            schedulerID: "scheduler-verifier-failure",
            provisioning: nil
        )
        let task = makeTask(projectID: projectID, title: "Failing Verification", priority: 1, status: .ready, createdAt: startDate)
        try await store.createTask(task)

        let report = try await scheduler.schedule(projectID: projectID)
        let claimed = try XCTUnwrap(claim(in: report, taskID: task.id))
        let lease = try await activeLease(for: scheduler, taskID: task.id)
        let completion = try await finish(
            scheduler: scheduler, taskID: task.id, attemptID: claimed.attemptID, generation: claimed.generation,
            ownerNonce: lease.ownerNonce, outcome: .succeeded, usage: TaskAttemptUsage(toolCallCount: 1, durationSeconds: 5))
        XCTAssertEqual(completion.disposition, .accepted)

        let stored = try await store.task(id: task.id)
        XCTAssertEqual(stored?.status, .blocked)
        XCTAssertEqual(stored?.blockReason, .verificationFailed("stub-details"))
        XCTAssertEqual(stored?.stage, .analysis)
        let recordedEvidenceCount = await repository.recordedEvidenceCount()
        XCTAssertEqual(recordedEvidenceCount, 0)

        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.outcome, .succeeded)
    }

    func testConcurrentDuplicateCompletionIsIdempotent() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let sharedPath = "/tmp/agentic-sidebar-scheduler-tests/duplicate-completion-repo"
        let task = makeTask(
            projectID: projectID, title: "Duplicate Completion", priority: 9, status: .ready, createdAt: startDate)
        let other = makeTask(
            projectID: projectID, title: "Other Writer", priority: 1, status: .ready, createdAt: startDate.addingTimeInterval(1))
        try await store.createTask(task)
        try await store.createTask(other)

        let scheduler = makeScheduler(
            store: store, clock: clock, providers: .eligible(runtimeID: "runtime", modelID: "model"),
            workspaceOwned: true, sharedRepositoryPath: sharedPath, verifierPassed: true, schedulerID: "scheduler-duplicate")
        let report = try await scheduler.schedule(projectID: projectID)
        let claimed = try XCTUnwrap(claim(in: report, taskID: task.id))
        let lease = try await activeLease(for: scheduler, taskID: task.id)

        async let first = scheduler.attemptDidComplete(
            taskID: task.id, attemptID: claimed.attemptID, generation: claimed.generation,
            ownerNonce: lease.ownerNonce, outcome: .failed, usage: TaskAttemptUsage(toolCallCount: nil, durationSeconds: nil))
        async let second = scheduler.attemptDidComplete(
            taskID: task.id, attemptID: claimed.attemptID, generation: claimed.generation,
            ownerNonce: lease.ownerNonce, outcome: .failed, usage: TaskAttemptUsage(toolCallCount: nil, durationSeconds: nil))

        let completions = try await [first, second]
        XCTAssertEqual(completions.filter { $0.disposition == .accepted }.count, 1)
        XCTAssertEqual(completions.filter { $0.disposition == .stale }.count, 1)

        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.outcome, .failed)

        let late = try await finish(
            scheduler: scheduler, taskID: task.id, attemptID: claimed.attemptID, generation: claimed.generation,
            ownerNonce: lease.ownerNonce, outcome: .failed, usage: TaskAttemptUsage(toolCallCount: nil, durationSeconds: nil))
        XCTAssertEqual(late.disposition, .stale)

        let followUp = try await scheduler.schedule(projectID: projectID)
        XCTAssertNotNil(claim(in: followUp, taskID: other.id), "Ended completion must release the repository lease")
    }

    // MARK: - Expired lease reconciliation

    func testRetryReclaimsLeaseFromTerminalAttemptAfterSwallowedRelease() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let sharedPath = "/tmp/agentic-sidebar-scheduler-tests/swallowed-release-repo"
        let task = makeTask(projectID: projectID, title: "Swallowed Release", priority: 9, status: .ready, createdAt: startDate)
        try await store.createTask(task)

        let repository = HookingTaskRepository(base: store)
        await repository.setForcedRepositoryLeaseTimeout(0.01)
        await repository.setReleaseRepositoryLeaseError(.underlying("swallowed release failure"))
        let scheduler = TaskScheduler(
            repository: repository,
            providers: TestProviderRegistry(result: .eligible(runtimeID: "runtime", modelID: "model")),
            workspaces: TestWorkspacePreflight(isOwned: true, sharedRepositoryPath: sharedPath),
            verifier: TestVerifier(passed: true),
            clock: clock,
            schedulerID: "scheduler-swallowed-release",
            provisioning: nil
        )

        let report = try await scheduler.schedule(projectID: projectID)
        let firstClaim = try XCTUnwrap(claim(in: report, taskID: task.id))
        let firstLease = try await activeLease(for: scheduler, taskID: task.id)
        let completion = try await finish(
            scheduler: scheduler, taskID: task.id, attemptID: firstClaim.attemptID, generation: firstClaim.generation,
            ownerNonce: firstLease.ownerNonce, outcome: .failed, usage: TaskAttemptUsage(toolCallCount: nil, durationSeconds: nil))
        XCTAssertEqual(completion.disposition, .accepted)
        let terminalHistory = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(terminalHistory.first?.outcome, .failed)

        clock.advance(seconds: 5000)
        try await Task.sleep(for: .milliseconds(50))

        let retryEntry = try await scheduler.retry(taskID: task.id)
        guard case .claimed(let secondAttemptID, let secondGeneration) = retryEntry.disposition else {
            XCTFail("Retry must reclaim the expired lease of its own terminal attempt")
            return
        }
        XCTAssertNotEqual(secondAttemptID, firstClaim.attemptID)
        XCTAssertEqual(secondGeneration, 2)
        let retriedHistory = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(retriedHistory.count, 2)
        XCTAssertEqual(retriedHistory.last?.outcome, .inProgress)
    }

    func testStopReleasesDanglingAttemptLease() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let sharedPath = "/tmp/agentic-sidebar-scheduler-tests/dangling-stop-repo"
        let owningTask = makeTask(projectID: projectID, title: "Dangling Owner", priority: 9, status: .ready, createdAt: startDate)
        let waitingTask = makeTask(
            projectID: projectID, title: "Waiting Writer", priority: 1, status: .ready, createdAt: startDate.addingTimeInterval(1))
        try await store.createTask(owningTask)
        try await store.createTask(waitingTask)

        let owningScheduler = makeScheduler(
            store: store, clock: clock, providers: .eligible(runtimeID: "runtime", modelID: "model"),
            workspaceOwned: true, sharedRepositoryPath: sharedPath, verifierPassed: true, schedulerID: "scheduler-dangling-owner")
        let report = try await owningScheduler.schedule(projectID: projectID)
        XCTAssertNotNil(claim(in: report, taskID: owningTask.id))

        let danglingScheduler = makeScheduler(
            store: store, clock: clock, providers: .eligible(runtimeID: "runtime", modelID: "model"),
            workspaceOwned: true, sharedRepositoryPath: sharedPath, verifierPassed: true, schedulerID: "scheduler-dangling-stop")
        try await danglingScheduler.stop(taskID: owningTask.id)

        let stoppedTask = try await store.task(id: owningTask.id)
        XCTAssertEqual(stoppedTask?.status, .blocked)
        XCTAssertEqual(stoppedTask?.blockReason, .custom("stopped"))
        let stoppedHistory = try await store.attemptHistory(taskID: owningTask.id)
        XCTAssertEqual(stoppedHistory.count, 1)
        XCTAssertEqual(stoppedHistory.first?.outcome, .cancelled)

        let followUp = try await danglingScheduler.schedule(projectID: projectID)
        XCTAssertNotNil(
            claim(in: followUp, taskID: waitingTask.id),
            "Stopping a dangling attempt must release its repository lease by the exact attempt identity"
        )
    }

    // MARK: - Live dispatch port

    private enum DispatchTestStartError: Error, Equatable {
        case startFailed
    }

    /// Bounded event stream with an observable cancel count; cancel finishes the stream.
    private final class DispatchTestSession: TaskRunSession, @unchecked Sendable {
        let events: AsyncStream<CodingAgentEvent>
        private let continuation: AsyncStream<CodingAgentEvent>.Continuation
        private let cancels = Mutex(0)

        init() {
            let (stream, continuation) = AsyncStream<CodingAgentEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
            self.events = stream
            self.continuation = continuation
        }

        func send(_ kind: CodingAgentEvent.Kind, taskID: UUID, attemptID: UUID, generation: Int) {
            continuation.yield(
                CodingAgentEvent(taskID: taskID, attemptID: attemptID, generation: generation, kind: kind)
            )
        }

        func finish() {
            continuation.finish()
        }

        func cancel() async {
            cancels.withLock { $0 += 1 }
            continuation.finish()
        }

        var cancelCount: Int {
            cancels.withLock { $0 }
        }
    }

    private final class ScriptedTaskRunningPort: TaskRunningPort, @unchecked Sendable {
        private let sessionsByAttemptID: Mutex<[UUID: DispatchTestSession]>
        private let startFailure: Error?
        private let fallbackSessions = Mutex<[UUID: DispatchTestSession]>([:])
        private let requests = Mutex<[TaskRunRequest]>([])
        private let resolvers = Mutex<[TaskRunApprovalResolver]>([])

        init(sessionsByAttemptID: [UUID: DispatchTestSession] = [:], startFailure: Error? = nil) {
            self.sessionsByAttemptID = Mutex(sessionsByAttemptID)
            self.startFailure = startFailure
        }

        func bind(_ session: DispatchTestSession, to attemptID: UUID) {
            sessionsByAttemptID.withLock { $0[attemptID] = session }
        }

        func start(
            _ request: TaskRunRequest,
            approvalResolver: @escaping TaskRunApprovalResolver
        ) async throws -> TaskRunSession {
            if let startFailure {
                throw startFailure
            }
            requests.withLock { $0.append(request) }
            resolvers.withLock { $0.append(approvalResolver) }
            if let session = sessionsByAttemptID.withLock({ $0[request.attempt.id] }) {
                return session
            }
            if let existing = fallbackSessions.withLock({ $0[request.attempt.id] }) {
                return existing
            }
            let session = DispatchTestSession()
            fallbackSessions.withLock { $0[request.attempt.id] = session }
            return session
        }

        var startCount: Int {
            requests.withLock { $0.count }
        }

        var lastRequest: TaskRunRequest? {
            requests.withLock { $0.last }
        }

        var lastResolver: TaskRunApprovalResolver? {
            resolvers.withLock { $0.last }
        }

        func session(for attemptID: UUID) -> DispatchTestSession? {
            sessionsByAttemptID.withLock { $0[attemptID] }
                ?? fallbackSessions.withLock { $0[attemptID] }
        }
    }

    /// Provider registry that parks every candidate call on an injected gate once armed.
    ///
    /// Fixture creation claims through this registry, so gating stays disarmed until a
    /// race test arms it immediately before the dispatch under test.
    private actor ArmedDispatchTestRegistry: TaskProviderRegistryPort {
        private let gate: AsyncGate
        private let result: TaskProviderCandidate
        private var isArmed = false

        init(gate: AsyncGate, result: TaskProviderCandidate) {
            self.gate = gate
            self.result = result
        }

        func arm() {
            isArmed = true
        }

        func candidate(for task: CodingTask, stage: TaskStage) async -> TaskProviderCandidate {
            if isArmed {
                await gate.enter()
            }
            return result
        }
    }

    /// Running port whose `start` parks on an injected gate before handing back its session.
    private final class GatedStartTaskRunningPort: TaskRunningPort, @unchecked Sendable {
        private let session: DispatchTestSession
        private let gate: AsyncGate
        private let starts = Mutex(0)

        init(session: DispatchTestSession, gate: AsyncGate) {
            self.session = session
            self.gate = gate
        }

        func start(
            _ request: TaskRunRequest,
            approvalResolver: @escaping TaskRunApprovalResolver
        ) async throws -> TaskRunSession {
            starts.withLock { $0 += 1 }
            await gate.enter()
            return session
        }

        var startCount: Int {
            starts.withLock { $0 }
        }
    }

    private actor DispatchTestRegistry: TaskProviderRegistryPort {
        private var results: [TaskProviderCandidate]

        init(results: [TaskProviderCandidate]) {
            self.results = results
        }

        func candidate(for task: CodingTask, stage: TaskStage) async -> TaskProviderCandidate {
            if results.count > 1 {
                return results.removeFirst()
            }
            return results.first ?? .unavailable(reason: "no-candidate")
        }
    }

    private actor DispatchTestPreflight: TaskWorkspacePreflightPort {
        private var result: TaskWorkspacePreflightResult

        init(result: TaskWorkspacePreflightResult) {
            self.result = result
        }

        func set(_ result: TaskWorkspacePreflightResult) {
            self.result = result
        }

        func preflight(projectID: UUID, taskID: UUID) async -> TaskWorkspacePreflightResult {
            result
        }
    }

    private actor DispatchCountingVerifier: TaskVerifying {
        private let passed: Bool
        private var calls = 0

        init(passed: Bool) {
            self.passed = passed
        }

        func verify(
            task: CodingTask,
            attempt: TaskAttempt,
            workspace: TaskWorkspaceDescriptor
        ) async -> TaskVerificationReport {
            calls += 1
            return TaskVerificationReport(
                passed: passed,
                recipeName: "dispatch-recipe",
                detailsRedacted: "dispatch-details"
            )
        }

        var callCount: Int { calls }
    }

    private struct DispatchFixture {
        let projectID: UUID
        let task: CodingTask
        let attemptID: UUID
        let generation: Int
        let leaseOwnerNonce: String
    }

    private static let dispatchWorkspacePath = "/tmp/agentic-sidebar-dispatch-tests/workspace"
    private static let dispatchRepositoryPath = "/tmp/agentic-sidebar-dispatch-tests/repo"

    private static func dispatchWorkspace(
        workspaceID: UUID,
        repositoryPath: String
    ) -> TaskWorkspaceDescriptor {
        TaskWorkspaceDescriptor(
            workspaceID: workspaceID,
            workspacePath: (repositoryPath as NSString).appendingPathComponent("workspace"),
            repositoryPath: repositoryPath
        )
    }

    private func makeDispatchFixture(
        store: SQLiteTaskStore,
        clock: TestTaskSchedulerClock,
        providers: any TaskProviderRegistryPort,
        workspaces: any TaskWorkspacePreflightPort,
        verifier: any TaskVerifying,
        port: any TaskRunningPort,
        budget: ExecutionBudget,
        schedulerID: String
    ) async throws -> (scheduler: TaskScheduler, fixture: DispatchFixture) {
        let scheduler = TaskScheduler(
            repository: store,
            providers: providers,
            workspaces: workspaces,
            verifier: verifier,
            clock: clock,
            schedulerID: schedulerID,
            provisioning: nil,
            dispatchPort: port
        )
        let projectID = UUID()
        let now = clock.now()
        let task = CodingTask(
            id: UUID(),
            projectID: projectID,
            title: "Dispatch Task",
            objective: "Dispatch Task objective",
            priority: 1,
            status: .ready,
            stage: .implementation,
            budget: budget,
            createdAt: now,
            updatedAt: now
        )
        try await store.createTask(task)
        let report = try await scheduler.schedule(projectID: projectID)
        let claimed = try XCTUnwrap(claim(in: report, taskID: task.id))
        let activeLease = await scheduler.activeLease(taskID: task.id)
        let lease = try XCTUnwrap(activeLease)
        return (
            scheduler,
            DispatchFixture(
                projectID: projectID,
                task: task,
                attemptID: claimed.attemptID,
                generation: claimed.generation,
                leaseOwnerNonce: lease.ownerNonce
            )
        )
    }

    private func recordExecuteApproval(
        store: SQLiteTaskStore,
        taskID: UUID,
        attemptID: UUID,
        fingerprint: String,
        actor: String = "human@example.com"
    ) async throws {
        try await store.recordApproval(
            TaskApproval(
                taskID: taskID,
                attemptID: attemptID,
                fingerprint: fingerprint,
                actor: actor,
                timestamp: startDate,
                action: .executeRecipe
            )
        )
    }

    private func waitForDispatchStart(_ port: ScriptedTaskRunningPort, count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if port.startCount >= count {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Dispatch did not reach the running port before timeout")
    }

    private func expectDispatchRefusal(
        _ scheduler: TaskScheduler,
        taskID: UUID,
        attemptID: UUID,
        generation: Int,
        fingerprint: String,
        expected: TaskDispatchRefusal,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await scheduler.dispatch(
                taskID: taskID,
                attemptID: attemptID,
                generation: generation,
                fingerprint: fingerprint
            )
            XCTFail("Expected dispatch refusal \(expected)", file: file, line: line)
        } catch let refusal as TaskDispatchRefusal {
            XCTAssertEqual(refusal, expected, file: file, line: line)
        } catch {
            XCTFail("Expected typed dispatch refusal, got \(error)", file: file, line: line)
        }
    }

    func testDispatchWithoutInjectedPortIsRefused() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let scheduler = makeScheduler(
            store: store, clock: clock, providers: .eligible(runtimeID: "runtime", modelID: "model"),
            workspaceOwned: true, sharedRepositoryPath: nil, verifierPassed: true, schedulerID: "scheduler-no-dispatch")
        let task = makeTask(projectID: projectID, title: "No Dispatch Port", priority: 1, status: .ready, createdAt: startDate)
        try await store.createTask(task)
        let report = try await scheduler.schedule(projectID: projectID)
        let claimed = try XCTUnwrap(claim(in: report, taskID: task.id))

        await expectDispatchRefusal(
            scheduler,
            taskID: task.id,
            attemptID: claimed.attemptID,
            generation: claimed.generation,
            fingerprint: "fingerprint",
            expected: .dispatchDisabled(taskID: task.id)
        )
    }

    func testDispatchRefusedWhenWorkspaceIsNoLongerOwned() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let workspace = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath)
        let preflight = DispatchTestPreflight(result: .owned(workspace))
        let port = ScriptedTaskRunningPort()
        let (scheduler, fixture) = try await makeDispatchFixture(
            store: store, clock: clock,
            providers: DispatchTestRegistry(results: [.eligible(runtimeID: "runtime", modelID: "model")]),
            workspaces: preflight, verifier: DispatchCountingVerifier(passed: true), port: port,
            budget: ExecutionBudget(), schedulerID: "scheduler-dispatch-not-owned")
        try await recordExecuteApproval(
            store: store, taskID: fixture.task.id, attemptID: fixture.attemptID, fingerprint: "fingerprint")
        await preflight.set(.notOwned(reason: "manifest missing"))

        await expectDispatchRefusal(
            scheduler,
            taskID: fixture.task.id,
            attemptID: fixture.attemptID,
            generation: fixture.generation,
            fingerprint: "fingerprint",
            expected: .workspaceNotOwned(taskID: fixture.task.id, reason: "manifest missing")
        )
        XCTAssertEqual(port.startCount, 0, "A refused dispatch must never start a runtime")
    }

    func testDispatchRefusedWhenWorkspaceIdentityDiffers() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let bound = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath)
        let swapped = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath + "-other")
        let preflight = DispatchTestPreflight(result: .owned(bound))
        let port = ScriptedTaskRunningPort()
        let (scheduler, fixture) = try await makeDispatchFixture(
            store: store, clock: clock,
            providers: DispatchTestRegistry(results: [.eligible(runtimeID: "runtime", modelID: "model")]),
            workspaces: preflight, verifier: DispatchCountingVerifier(passed: true), port: port,
            budget: ExecutionBudget(), schedulerID: "scheduler-dispatch-identity")
        try await recordExecuteApproval(
            store: store, taskID: fixture.task.id, attemptID: fixture.attemptID, fingerprint: "fingerprint")
        await preflight.set(.owned(swapped))

        await expectDispatchRefusal(
            scheduler,
            taskID: fixture.task.id,
            attemptID: fixture.attemptID,
            generation: fixture.generation,
            fingerprint: "fingerprint",
            expected: .workspaceIdentityMismatch(
                taskID: fixture.task.id,
                expectedWorkspaceID: bound.workspaceID,
                actualWorkspaceID: swapped.workspaceID
            )
        )
        XCTAssertEqual(port.startCount, 0)
    }

    func testDispatchRefusedWhenProviderNoLongerEligible() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let workspace = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath)
        let port = ScriptedTaskRunningPort()
        let (scheduler, fixture) = try await makeDispatchFixture(
            store: store, clock: clock,
            providers: DispatchTestRegistry(results: [
                .eligible(runtimeID: "runtime", modelID: "model"),
                .unsupported(missingCapabilities: ["tools"]),
            ]),
            workspaces: DispatchTestPreflight(result: .owned(workspace)),
            verifier: DispatchCountingVerifier(passed: true), port: port,
            budget: ExecutionBudget(), schedulerID: "scheduler-dispatch-ineligible")
        try await recordExecuteApproval(
            store: store, taskID: fixture.task.id, attemptID: fixture.attemptID, fingerprint: "fingerprint")

        await expectDispatchRefusal(
            scheduler,
            taskID: fixture.task.id,
            attemptID: fixture.attemptID,
            generation: fixture.generation,
            fingerprint: "fingerprint",
            expected: .providerNotEligible(taskID: fixture.task.id, missingCapabilities: ["tools"])
        )
        XCTAssertEqual(port.startCount, 0)
    }

    func testDispatchRefusedWhenTimeBudgetIsExhausted() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let workspace = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath)
        let port = ScriptedTaskRunningPort()
        let budget = ExecutionBudget(maxAttempts: 3, maxTaskDurationSeconds: 60, maxToolCallsPerAttempt: 300)
        let (scheduler, fixture) = try await makeDispatchFixture(
            store: store, clock: clock,
            providers: DispatchTestRegistry(results: [.eligible(runtimeID: "runtime", modelID: "model")]),
            workspaces: DispatchTestPreflight(result: .owned(workspace)),
            verifier: DispatchCountingVerifier(passed: true), port: port,
            budget: budget, schedulerID: "scheduler-dispatch-budget")
        try await recordExecuteApproval(
            store: store, taskID: fixture.task.id, attemptID: fixture.attemptID, fingerprint: "fingerprint")
        clock.advance(seconds: 120)

        await expectDispatchRefusal(
            scheduler,
            taskID: fixture.task.id,
            attemptID: fixture.attemptID,
            generation: fixture.generation,
            fingerprint: "fingerprint",
            expected: .budgetExhausted(taskID: fixture.task.id, reason: "timeBudgetExhausted")
        )
        XCTAssertEqual(port.startCount, 0)
    }

    func testDispatchRefusedWithoutExecuteApprovalBoundToAttemptAndFingerprint() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let workspace = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath)
        let port = ScriptedTaskRunningPort()
        let (scheduler, fixture) = try await makeDispatchFixture(
            store: store, clock: clock,
            providers: DispatchTestRegistry(results: [.eligible(runtimeID: "runtime", modelID: "model")]),
            workspaces: DispatchTestPreflight(result: .owned(workspace)),
            verifier: DispatchCountingVerifier(passed: true), port: port,
            budget: ExecutionBudget(), schedulerID: "scheduler-dispatch-approval")

        await expectDispatchRefusal(
            scheduler,
            taskID: fixture.task.id,
            attemptID: fixture.attemptID,
            generation: fixture.generation,
            fingerprint: "fingerprint",
            expected: .executeApprovalMissing(
                taskID: fixture.task.id, attemptID: fixture.attemptID, fingerprint: "fingerprint")
        )

        try await recordExecuteApproval(
            store: store, taskID: fixture.task.id, attemptID: UUID(), fingerprint: "fingerprint")
        await expectDispatchRefusal(
            scheduler,
            taskID: fixture.task.id,
            attemptID: fixture.attemptID,
            generation: fixture.generation,
            fingerprint: "fingerprint",
            expected: .executeApprovalMissing(
                taskID: fixture.task.id, attemptID: fixture.attemptID, fingerprint: "fingerprint")
        )

        try await recordExecuteApproval(
            store: store, taskID: fixture.task.id, attemptID: fixture.attemptID, fingerprint: "stale-fingerprint")
        await expectDispatchRefusal(
            scheduler,
            taskID: fixture.task.id,
            attemptID: fixture.attemptID,
            generation: fixture.generation,
            fingerprint: "fingerprint",
            expected: .executeApprovalMissing(
                taskID: fixture.task.id, attemptID: fixture.attemptID, fingerprint: "fingerprint")
        )
        XCTAssertEqual(port.startCount, 0)
    }

    func testDispatchRefusedAfterPauseBlocksTheTask() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let workspace = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath)
        let port = ScriptedTaskRunningPort()
        let (scheduler, fixture) = try await makeDispatchFixture(
            store: store, clock: clock,
            providers: DispatchTestRegistry(results: [.eligible(runtimeID: "runtime", modelID: "model")]),
            workspaces: DispatchTestPreflight(result: .owned(workspace)),
            verifier: DispatchCountingVerifier(passed: true), port: port,
            budget: ExecutionBudget(), schedulerID: "scheduler-dispatch-paused")

        try await scheduler.pause(taskID: fixture.task.id)

        await expectDispatchRefusal(
            scheduler,
            taskID: fixture.task.id,
            attemptID: fixture.attemptID,
            generation: fixture.generation,
            fingerprint: "fingerprint",
            expected: .taskNotRunning(taskID: fixture.task.id, status: .blocked)
        )
        XCTAssertEqual(port.startCount, 0)
    }

    func testDispatchRefusedWhenRuntimeStartFails() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let workspace = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath)
        let port = ScriptedTaskRunningPort(startFailure: DispatchTestStartError.startFailed)
        let (scheduler, fixture) = try await makeDispatchFixture(
            store: store, clock: clock,
            providers: DispatchTestRegistry(results: [.eligible(runtimeID: "runtime", modelID: "model")]),
            workspaces: DispatchTestPreflight(result: .owned(workspace)),
            verifier: DispatchCountingVerifier(passed: true), port: port,
            budget: ExecutionBudget(), schedulerID: "scheduler-dispatch-start-failure")
        try await recordExecuteApproval(
            store: store, taskID: fixture.task.id, attemptID: fixture.attemptID, fingerprint: "fingerprint")

        await expectDispatchRefusal(
            scheduler,
            taskID: fixture.task.id,
            attemptID: fixture.attemptID,
            generation: fixture.generation,
            fingerprint: "fingerprint",
            expected: .runtimeStartFailed(taskID: fixture.task.id, reason: "startFailed")
        )
        XCTAssertEqual(port.startCount, 0)
    }

    func testDispatchHappyPathCompletesAttemptAndTriggersVerificationOnce() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let workspace = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath)
        let session = DispatchTestSession()
        let port = ScriptedTaskRunningPort(sessionsByAttemptID: [:])
        let verifier = DispatchCountingVerifier(passed: true)
        let (scheduler, fixture) = try await makeDispatchFixture(
            store: store, clock: clock,
            providers: DispatchTestRegistry(results: [.eligible(runtimeID: "runtime", modelID: "model")]),
            workspaces: DispatchTestPreflight(result: .owned(workspace)),
            verifier: verifier, port: port,
            budget: ExecutionBudget(), schedulerID: "scheduler-dispatch-happy")
        let fingerprint = "fingerprint-happy"
        try await recordExecuteApproval(
            store: store, taskID: fixture.task.id, attemptID: fixture.attemptID, fingerprint: fingerprint)
        port.bind(session, to: fixture.attemptID)

        session.send(.started, taskID: fixture.task.id, attemptID: fixture.attemptID, generation: fixture.generation)
        session.send(
            .activityStarted(id: "tool-1", title: "edit"),
            taskID: fixture.task.id, attemptID: fixture.attemptID, generation: fixture.generation)
        session.send(.terminalSuccess, taskID: fixture.task.id, attemptID: fixture.attemptID, generation: fixture.generation)
        session.finish()

        let report = try await scheduler.dispatch(
            taskID: fixture.task.id,
            attemptID: fixture.attemptID,
            generation: fixture.generation,
            fingerprint: fingerprint
        )

        XCTAssertEqual(report.outcome, .succeeded)
        XCTAssertEqual(report.toolCallCount, 1)
        XCTAssertTrue(report.approvalDecisions.isEmpty)
        XCTAssertEqual(report.completion.disposition, .accepted)
        XCTAssertEqual(port.startCount, 1)
        XCTAssertEqual(session.cancelCount, 0)
        let verifierCalls = await verifier.callCount
        XCTAssertEqual(verifierCalls, 1, "Verification must run exactly once for the completed attempt")

        let request = try XCTUnwrap(port.lastRequest)
        XCTAssertEqual(request.attempt.id, fixture.attemptID)
        XCTAssertEqual(request.workspace.workspaceID, workspace.workspaceID)
        XCTAssertEqual(request.approvalPolicy, .approveSafe)
        XCTAssertNotNil(port.lastResolver)

        let stored = try await store.task(id: fixture.task.id)
        XCTAssertEqual(stored?.status, .review)
        let history = try await store.attemptHistory(taskID: fixture.task.id)
        XCTAssertEqual(history.first?.outcome, .succeeded)
        XCTAssertEqual(history.first?.toolCallCount, 1)
    }

    func testDispatchEOFWithoutTerminalEventIsInterruptionNotSuccess() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let workspace = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath)
        let session = DispatchTestSession()
        let port = ScriptedTaskRunningPort(sessionsByAttemptID: [:])
        let (scheduler, fixture) = try await makeDispatchFixture(
            store: store, clock: clock,
            providers: DispatchTestRegistry(results: [.eligible(runtimeID: "runtime", modelID: "model")]),
            workspaces: DispatchTestPreflight(result: .owned(workspace)),
            verifier: DispatchCountingVerifier(passed: true), port: port,
            budget: ExecutionBudget(), schedulerID: "scheduler-dispatch-eof")
        try await recordExecuteApproval(
            store: store, taskID: fixture.task.id, attemptID: fixture.attemptID, fingerprint: "fingerprint")
        port.bind(session, to: fixture.attemptID)

        session.send(.started, taskID: fixture.task.id, attemptID: fixture.attemptID, generation: fixture.generation)
        session.finish()

        let report = try await scheduler.dispatch(
            taskID: fixture.task.id,
            attemptID: fixture.attemptID,
            generation: fixture.generation,
            fingerprint: "fingerprint"
        )

        XCTAssertEqual(report.outcome, .cancelled, "A stream that ends without a terminal event is an interruption")
        XCTAssertNil(report.toolCallCount, "Unreported tool calls must stay unknown")
        XCTAssertEqual(report.completion.disposition, .accepted)
        XCTAssertEqual(session.cancelCount, 0)
        let stored = try await store.task(id: fixture.task.id)
        XCTAssertEqual(stored?.status, .blocked)
        XCTAssertEqual(stored?.blockReason, .custom("attemptCancelled"))
        let history = try await store.attemptHistory(taskID: fixture.task.id)
        XCTAssertEqual(history.first?.outcome, .cancelled)
    }

    func testDispatchIgnoresStaleGenerationEvents() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let workspace = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath)
        let session = DispatchTestSession()
        let port = ScriptedTaskRunningPort(sessionsByAttemptID: [:])
        let (scheduler, fixture) = try await makeDispatchFixture(
            store: store, clock: clock,
            providers: DispatchTestRegistry(results: [.eligible(runtimeID: "runtime", modelID: "model")]),
            workspaces: DispatchTestPreflight(result: .owned(workspace)),
            verifier: DispatchCountingVerifier(passed: true), port: port,
            budget: ExecutionBudget(), schedulerID: "scheduler-dispatch-stale")
        try await recordExecuteApproval(
            store: store, taskID: fixture.task.id, attemptID: fixture.attemptID, fingerprint: "fingerprint")
        port.bind(session, to: fixture.attemptID)

        let staleGeneration = fixture.generation - 1
        session.send(
            .activityStarted(id: "stale-tool", title: "edit"),
            taskID: fixture.task.id, attemptID: fixture.attemptID, generation: staleGeneration)
        session.send(
            .terminalSuccess,
            taskID: fixture.task.id, attemptID: fixture.attemptID, generation: staleGeneration)
        session.send(
            .terminalError("backend failed"),
            taskID: fixture.task.id, attemptID: fixture.attemptID, generation: fixture.generation)
        session.finish()

        let report = try await scheduler.dispatch(
            taskID: fixture.task.id,
            attemptID: fixture.attemptID,
            generation: fixture.generation,
            fingerprint: "fingerprint"
        )

        XCTAssertEqual(report.outcome, .failed, "A stale success must not win over the current generation's failure")
        XCTAssertNil(report.toolCallCount, "Stale activity must not be counted against this attempt")
        let stored = try await store.task(id: fixture.task.id)
        XCTAssertEqual(stored?.status, .blocked)
        XCTAssertEqual(stored?.blockReason, .custom("attemptFailed"))
    }

    func testDispatchUnknownToolCallsStayUnknown() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let workspace = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath)
        let session = DispatchTestSession()
        let port = ScriptedTaskRunningPort(sessionsByAttemptID: [:])
        let (scheduler, fixture) = try await makeDispatchFixture(
            store: store, clock: clock,
            providers: DispatchTestRegistry(results: [.eligible(runtimeID: "runtime", modelID: "model")]),
            workspaces: DispatchTestPreflight(result: .owned(workspace)),
            verifier: DispatchCountingVerifier(passed: true), port: port,
            budget: ExecutionBudget(), schedulerID: "scheduler-dispatch-unknown-usage")
        try await recordExecuteApproval(
            store: store, taskID: fixture.task.id, attemptID: fixture.attemptID, fingerprint: "fingerprint")
        port.bind(session, to: fixture.attemptID)

        session.send(.started, taskID: fixture.task.id, attemptID: fixture.attemptID, generation: fixture.generation)
        session.send(.textDelta("done"), taskID: fixture.task.id, attemptID: fixture.attemptID, generation: fixture.generation)
        session.send(.terminalSuccess, taskID: fixture.task.id, attemptID: fixture.attemptID, generation: fixture.generation)
        session.finish()

        let report = try await scheduler.dispatch(
            taskID: fixture.task.id,
            attemptID: fixture.attemptID,
            generation: fixture.generation,
            fingerprint: "fingerprint"
        )
        XCTAssertEqual(report.outcome, .succeeded)
        XCTAssertNil(report.toolCallCount)
        let history = try await store.attemptHistory(taskID: fixture.task.id)
        XCTAssertNil(history.first?.toolCallCount)
    }

    func testDispatchCancelsRunWhenToolCallBudgetIsExceeded() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let workspace = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath)
        let session = DispatchTestSession()
        let port = ScriptedTaskRunningPort(sessionsByAttemptID: [:])
        let budget = ExecutionBudget(maxAttempts: 3, maxTaskDurationSeconds: 3600, maxToolCallsPerAttempt: 2)
        let (scheduler, fixture) = try await makeDispatchFixture(
            store: store, clock: clock,
            providers: DispatchTestRegistry(results: [.eligible(runtimeID: "runtime", modelID: "model")]),
            workspaces: DispatchTestPreflight(result: .owned(workspace)),
            verifier: DispatchCountingVerifier(passed: true), port: port,
            budget: budget, schedulerID: "scheduler-dispatch-usage-budget")
        try await recordExecuteApproval(
            store: store, taskID: fixture.task.id, attemptID: fixture.attemptID, fingerprint: "fingerprint")
        port.bind(session, to: fixture.attemptID)

        for index in 1...3 {
            session.send(
                .activityStarted(id: "tool-\(index)", title: "edit"),
                taskID: fixture.task.id, attemptID: fixture.attemptID, generation: fixture.generation)
        }
        session.send(.terminalSuccess, taskID: fixture.task.id, attemptID: fixture.attemptID, generation: fixture.generation)
        session.finish()

        let report = try await scheduler.dispatch(
            taskID: fixture.task.id,
            attemptID: fixture.attemptID,
            generation: fixture.generation,
            fingerprint: "fingerprint"
        )

        XCTAssertEqual(report.toolCallCount, 3)
        XCTAssertEqual(report.outcome, .cancelled, "A budget-fenced run must not be recorded as a success")
        XCTAssertEqual(session.cancelCount, 1)
        let stored = try await store.task(id: fixture.task.id)
        XCTAssertEqual(stored?.status, .blocked)
        XCTAssertEqual(stored?.blockReason, .custom("toolCallBudgetExceeded"))
    }

    func testApprovalResolverApprovesSafeInWorkspaceEdit() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let workspace = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath)
        let session = DispatchTestSession()
        let port = ScriptedTaskRunningPort(sessionsByAttemptID: [:])
        let (scheduler, fixture) = try await makeDispatchFixture(
            store: store, clock: clock,
            providers: DispatchTestRegistry(results: [.eligible(runtimeID: "runtime", modelID: "model")]),
            workspaces: DispatchTestPreflight(result: .owned(workspace)),
            verifier: DispatchCountingVerifier(passed: true), port: port,
            budget: ExecutionBudget(), schedulerID: "scheduler-dispatch-approve-safe")
        try await recordExecuteApproval(
            store: store, taskID: fixture.task.id, attemptID: fixture.attemptID, fingerprint: "fingerprint")
        port.bind(session, to: fixture.attemptID)

        session.send(
            .approvalRequested(id: "req-edit", tool: "edit", params: ["patterns": "Sources/AgenticSidebar/App.swift"]),
            taskID: fixture.task.id, attemptID: fixture.attemptID, generation: fixture.generation)
        session.send(.terminalSuccess, taskID: fixture.task.id, attemptID: fixture.attemptID, generation: fixture.generation)
        session.finish()

        let report = try await scheduler.dispatch(
            taskID: fixture.task.id,
            attemptID: fixture.attemptID,
            generation: fixture.generation,
            fingerprint: "fingerprint"
        )

        XCTAssertEqual(
            report.approvalDecisions,
            [TaskRunApprovalDecision(requestID: "req-edit", toolName: "edit", reply: .approveOnce)]
        )
        XCTAssertEqual(report.outcome, .succeeded)
        XCTAssertEqual(session.cancelCount, 0)

        let resolver = try XCTUnwrap(port.lastResolver)
        let shellReply = await resolver(
            TaskRunApprovalRequest(
                id: "req-shell", toolName: "bash", patterns: ["rm -rf /"], delegationTarget: nil
            )
        )
        XCTAssertEqual(shellReply, .deny(reason: "toolRequiresHumanApproval:bash"))
    }

    func testApprovalResolverRejectsExternalPathAndTerminatesRun() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let workspace = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath)
        let session = DispatchTestSession()
        let port = ScriptedTaskRunningPort(sessionsByAttemptID: [:])
        let (scheduler, fixture) = try await makeDispatchFixture(
            store: store, clock: clock,
            providers: DispatchTestRegistry(results: [.eligible(runtimeID: "runtime", modelID: "model")]),
            workspaces: DispatchTestPreflight(result: .owned(workspace)),
            verifier: DispatchCountingVerifier(passed: true), port: port,
            budget: ExecutionBudget(), schedulerID: "scheduler-dispatch-deny-outside")
        try await recordExecuteApproval(
            store: store, taskID: fixture.task.id, attemptID: fixture.attemptID, fingerprint: "fingerprint")
        port.bind(session, to: fixture.attemptID)

        session.send(
            .approvalRequested(id: "req-outside", tool: "edit", params: ["patterns": "/etc/passwd"]),
            taskID: fixture.task.id, attemptID: fixture.attemptID, generation: fixture.generation)
        session.send(.terminalSuccess, taskID: fixture.task.id, attemptID: fixture.attemptID, generation: fixture.generation)
        session.finish()

        let report = try await scheduler.dispatch(
            taskID: fixture.task.id,
            attemptID: fixture.attemptID,
            generation: fixture.generation,
            fingerprint: "fingerprint"
        )

        XCTAssertEqual(
            report.approvalDecisions,
            [
                TaskRunApprovalDecision(
                    requestID: "req-outside",
                    toolName: "edit",
                    reply: .deny(reason: "outsideWorkspaceRequiresHumanApproval")
                )
            ]
        )
        XCTAssertEqual(report.outcome, .cancelled, "A denied approval must terminate the run, even against a racing success")
        XCTAssertEqual(session.cancelCount, 1)
        let stored = try await store.task(id: fixture.task.id)
        XCTAssertEqual(stored?.status, .blocked)
        XCTAssertEqual(stored?.blockReason, .custom("attemptCancelled"))

        let resolver = try XCTUnwrap(port.lastResolver)
        let networkReply = await resolver(
            TaskRunApprovalRequest(id: "req-net", toolName: "webfetch", patterns: ["https://example.com"], delegationTarget: nil)
        )
        XCTAssertEqual(networkReply, .deny(reason: "networkRequiresHumanApproval"))
    }

    /// Plan aşaması delegasyon yaptırımı (gönderim hattı): araştırma hedefine
    /// delegasyon bir kez onaylanır, yazılabilir ya da bilinmeyen hedef kapalı
    /// kalır. Gözetimsiz koşuda kullanıcı diyaloğu yoktur, karar reddir.
    func testTaskDelegationPolicyAllowsOnlyResearchTarget() {
        XCTAssertEqual(
            TaskRunApprovalPolicy.resolve(
                toolName: "task",
                patterns: [],
                workspacePath: "/tmp/ws",
                delegationTarget: ManagedOpenCodeConfiguration.researchAgentName
            ),
            .approveOnce
        )
        XCTAssertEqual(
            TaskRunApprovalPolicy.resolve(
                toolName: "task",
                patterns: [],
                workspacePath: "/tmp/ws",
                delegationTarget: "build"
            ),
            .deny(reason: "taskDelegationOutsideResearchTarget:build")
        )
        XCTAssertEqual(
            TaskRunApprovalPolicy.resolve(
                toolName: "task",
                patterns: [],
                workspacePath: "/tmp/ws",
                delegationTarget: nil
            ),
            .deny(reason: "taskDelegationOutsideResearchTarget:unknown")
        )
    }

    /// Olay yolundaki hedef taşıma: adaptör `approvalRequested` olayına
    /// `delegationTarget` parametresini koyar, zamanlayıcı kararı aynı kuralla
    /// verir; araştırma delegasyonu koşuyu bitirmez.
    func testApprovalEventCarryingResearchTargetIsApprovedOnce() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let workspace = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath)
        let session = DispatchTestSession()
        let port = ScriptedTaskRunningPort(sessionsByAttemptID: [:])
        let (scheduler, fixture) = try await makeDispatchFixture(
            store: store, clock: clock,
            providers: DispatchTestRegistry(results: [.eligible(runtimeID: "runtime", modelID: "model")]),
            workspaces: DispatchTestPreflight(result: .owned(workspace)),
            verifier: DispatchCountingVerifier(passed: true), port: port,
            budget: ExecutionBudget(), schedulerID: "scheduler-dispatch-task-target")
        try await recordExecuteApproval(
            store: store, taskID: fixture.task.id, attemptID: fixture.attemptID, fingerprint: "fingerprint")
        port.bind(session, to: fixture.attemptID)

        session.send(
            .approvalRequested(
                id: "req-task",
                tool: "task",
                params: ["delegationTarget": ManagedOpenCodeConfiguration.researchAgentName]
            ),
            taskID: fixture.task.id, attemptID: fixture.attemptID, generation: fixture.generation)
        session.send(.terminalSuccess, taskID: fixture.task.id, attemptID: fixture.attemptID, generation: fixture.generation)
        session.finish()

        let report = try await scheduler.dispatch(
            taskID: fixture.task.id,
            attemptID: fixture.attemptID,
            generation: fixture.generation,
            fingerprint: "fingerprint"
        )

        XCTAssertEqual(
            report.approvalDecisions,
            [TaskRunApprovalDecision(requestID: "req-task", toolName: "task", reply: .approveOnce)]
        )
        XCTAssertEqual(report.outcome, .succeeded)
        XCTAssertEqual(session.cancelCount, 0)
    }

    func testStopCancelsDispatchedRunOnce() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let workspace = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath)
        let session = DispatchTestSession()
        let port = ScriptedTaskRunningPort(sessionsByAttemptID: [:])
        let (scheduler, fixture) = try await makeDispatchFixture(
            store: store, clock: clock,
            providers: DispatchTestRegistry(results: [.eligible(runtimeID: "runtime", modelID: "model")]),
            workspaces: DispatchTestPreflight(result: .owned(workspace)),
            verifier: DispatchCountingVerifier(passed: true), port: port,
            budget: ExecutionBudget(), schedulerID: "scheduler-dispatch-stop")
        try await recordExecuteApproval(
            store: store, taskID: fixture.task.id, attemptID: fixture.attemptID, fingerprint: "fingerprint")
        port.bind(session, to: fixture.attemptID)
        session.send(.started, taskID: fixture.task.id, attemptID: fixture.attemptID, generation: fixture.generation)

        async let dispatchCall = scheduler.dispatch(
            taskID: fixture.task.id,
            attemptID: fixture.attemptID,
            generation: fixture.generation,
            fingerprint: "fingerprint"
        )
        try await waitForDispatchStart(port, count: 1)
        try await scheduler.stop(taskID: fixture.task.id)
        let report = try await dispatchCall

        XCTAssertEqual(session.cancelCount, 1, "Stop must cancel the run exactly once")
        XCTAssertEqual(report.completion.disposition, .stale)
        let stored = try await store.task(id: fixture.task.id)
        XCTAssertEqual(stored?.status, .blocked)
        XCTAssertEqual(stored?.blockReason, .custom("stopped"))
        let history = try await store.attemptHistory(taskID: fixture.task.id)
        XCTAssertEqual(history.first?.outcome, .cancelled)
    }

    func testPauseCancelsDispatchedRunOnce() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let workspace = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath)
        let session = DispatchTestSession()
        let port = ScriptedTaskRunningPort(sessionsByAttemptID: [:])
        let (scheduler, fixture) = try await makeDispatchFixture(
            store: store, clock: clock,
            providers: DispatchTestRegistry(results: [.eligible(runtimeID: "runtime", modelID: "model")]),
            workspaces: DispatchTestPreflight(result: .owned(workspace)),
            verifier: DispatchCountingVerifier(passed: true), port: port,
            budget: ExecutionBudget(), schedulerID: "scheduler-dispatch-pause")
        try await recordExecuteApproval(
            store: store, taskID: fixture.task.id, attemptID: fixture.attemptID, fingerprint: "fingerprint")
        port.bind(session, to: fixture.attemptID)
        session.send(.started, taskID: fixture.task.id, attemptID: fixture.attemptID, generation: fixture.generation)

        async let dispatchCall = scheduler.dispatch(
            taskID: fixture.task.id,
            attemptID: fixture.attemptID,
            generation: fixture.generation,
            fingerprint: "fingerprint"
        )
        try await waitForDispatchStart(port, count: 1)
        try await scheduler.pause(taskID: fixture.task.id)
        let report = try await dispatchCall

        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertEqual(report.completion.disposition, .stale)
        let stored = try await store.task(id: fixture.task.id)
        XCTAssertEqual(stored?.status, .blocked)
        XCTAssertEqual(stored?.blockReason, .custom("paused"))
    }

    func testRetryCancelsDispatchedRunAndClaimsFreshAttempt() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let workspace = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath)
        let session = DispatchTestSession()
        let port = ScriptedTaskRunningPort(sessionsByAttemptID: [:])
        let (scheduler, fixture) = try await makeDispatchFixture(
            store: store, clock: clock,
            providers: DispatchTestRegistry(results: [.eligible(runtimeID: "runtime", modelID: "model")]),
            workspaces: DispatchTestPreflight(result: .owned(workspace)),
            verifier: DispatchCountingVerifier(passed: true), port: port,
            budget: ExecutionBudget(), schedulerID: "scheduler-dispatch-retry")
        try await recordExecuteApproval(
            store: store, taskID: fixture.task.id, attemptID: fixture.attemptID, fingerprint: "fingerprint")
        port.bind(session, to: fixture.attemptID)
        session.send(.started, taskID: fixture.task.id, attemptID: fixture.attemptID, generation: fixture.generation)

        async let dispatchCall = scheduler.dispatch(
            taskID: fixture.task.id,
            attemptID: fixture.attemptID,
            generation: fixture.generation,
            fingerprint: "fingerprint"
        )
        try await waitForDispatchStart(port, count: 1)
        let entry = try await scheduler.retry(
            taskID: fixture.task.id,
            expectedAttemptID: fixture.attemptID,
            expectedGeneration: fixture.generation
        )
        let report = try await dispatchCall

        guard case .claimed(let retriedAttemptID, let retriedGeneration) = entry.disposition else {
            XCTFail("Retry must claim a fresh attempt, got \(entry.disposition)")
            return
        }
        XCTAssertNotEqual(retriedAttemptID, fixture.attemptID)
        XCTAssertEqual(retriedGeneration, fixture.generation + 1)
        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertEqual(report.completion.disposition, .stale)
    }

    func testConcurrentDuplicateDispatchIsRefused() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let workspace = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath)
        let session = DispatchTestSession()
        let port = ScriptedTaskRunningPort(sessionsByAttemptID: [:])
        let (scheduler, fixture) = try await makeDispatchFixture(
            store: store, clock: clock,
            providers: DispatchTestRegistry(results: [.eligible(runtimeID: "runtime", modelID: "model")]),
            workspaces: DispatchTestPreflight(result: .owned(workspace)),
            verifier: DispatchCountingVerifier(passed: true), port: port,
            budget: ExecutionBudget(), schedulerID: "scheduler-dispatch-single-flight")
        try await recordExecuteApproval(
            store: store, taskID: fixture.task.id, attemptID: fixture.attemptID, fingerprint: "fingerprint")
        port.bind(session, to: fixture.attemptID)
        session.send(.started, taskID: fixture.task.id, attemptID: fixture.attemptID, generation: fixture.generation)

        async let firstDispatch = scheduler.dispatch(
            taskID: fixture.task.id,
            attemptID: fixture.attemptID,
            generation: fixture.generation,
            fingerprint: "fingerprint"
        )
        try await waitForDispatchStart(port, count: 1)
        await expectDispatchRefusal(
            scheduler,
            taskID: fixture.task.id,
            attemptID: fixture.attemptID,
            generation: fixture.generation,
            fingerprint: "fingerprint",
            expected: .dispatchAlreadyActive(taskID: fixture.task.id)
        )
        XCTAssertEqual(port.startCount, 1, "A duplicate dispatch must not start a second runtime")

        session.send(.terminalSuccess, taskID: fixture.task.id, attemptID: fixture.attemptID, generation: fixture.generation)
        session.finish()
        let firstReport = try await firstDispatch
        XCTAssertEqual(firstReport.outcome, .succeeded)
    }

    func testStopCancelsOnlyTheStoppedTasksRun() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let projectID = UUID()
        let port = ScriptedTaskRunningPort()
        let verifier = DispatchCountingVerifier(passed: true)
        let scheduler = TaskScheduler(
            repository: store,
            providers: DispatchTestRegistry(results: [.eligible(runtimeID: "runtime", modelID: "model")]),
            workspaces: TestWorkspacePreflight(isOwned: true, sharedRepositoryPath: nil),
            verifier: verifier,
            clock: clock,
            schedulerID: "scheduler-dispatch-two-runs",
            provisioning: nil,
            dispatchPort: port
        )
        let taskA = makeTask(projectID: projectID, title: "Run A", priority: 9, status: .ready, createdAt: startDate)
        let taskB = makeTask(
            projectID: projectID, title: "Run B", priority: 1, status: .ready, createdAt: startDate.addingTimeInterval(1))
        try await store.createTask(taskA)
        try await store.createTask(taskB)
        let report = try await scheduler.schedule(projectID: projectID)
        let claimedA = try XCTUnwrap(claim(in: report, taskID: taskA.id))
        let claimedB = try XCTUnwrap(claim(in: report, taskID: taskB.id))
        try await recordExecuteApproval(
            store: store, taskID: taskA.id, attemptID: claimedA.attemptID, fingerprint: "fingerprint-a")
        try await recordExecuteApproval(
            store: store, taskID: taskB.id, attemptID: claimedB.attemptID, fingerprint: "fingerprint-b")

        async let dispatchA = scheduler.dispatch(
            taskID: taskA.id,
            attemptID: claimedA.attemptID,
            generation: claimedA.generation,
            fingerprint: "fingerprint-a"
        )
        async let dispatchB = scheduler.dispatch(
            taskID: taskB.id,
            attemptID: claimedB.attemptID,
            generation: claimedB.generation,
            fingerprint: "fingerprint-b"
        )
        try await waitForDispatchStart(port, count: 2)
        let sessionA = try XCTUnwrap(port.session(for: claimedA.attemptID))
        let sessionB = try XCTUnwrap(port.session(for: claimedB.attemptID))

        try await scheduler.stop(taskID: taskA.id)

        sessionB.send(.terminalSuccess, taskID: taskB.id, attemptID: claimedB.attemptID, generation: claimedB.generation)
        sessionB.finish()

        let completedB = try await dispatchB
        let stoppedA = try await dispatchA

        XCTAssertEqual(completedB.outcome, .succeeded)
        XCTAssertEqual(sessionA.cancelCount, 1)
        XCTAssertEqual(sessionB.cancelCount, 0, "Stopping one task must never cancel another task's run")
        XCTAssertEqual(stoppedA.completion.disposition, .stale)
        let storedA = try await store.task(id: taskA.id)
        XCTAssertEqual(storedA?.status, .blocked)
        XCTAssertEqual(storedA?.blockReason, .custom("stopped"))
        let storedB = try await store.task(id: taskB.id)
        XCTAssertEqual(storedB?.status, .review)
    }

    // MARK: - Live dispatch reentrancy races

    /// Polls until the condition holds, failing the test if the deadline passes.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
    }

    func testStopDuringDispatchGatesPreventsRunStart() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let workspace = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath)
        let gate = AsyncGate()
        let registry = ArmedDispatchTestRegistry(
            gate: gate,
            result: .eligible(runtimeID: "runtime", modelID: "model")
        )
        let session = DispatchTestSession()
        let port = ScriptedTaskRunningPort()
        let (scheduler, fixture) = try await makeDispatchFixture(
            store: store, clock: clock,
            providers: registry,
            workspaces: DispatchTestPreflight(result: .owned(workspace)),
            verifier: DispatchCountingVerifier(passed: true), port: port,
            budget: ExecutionBudget(), schedulerID: "scheduler-dispatch-stop-gates")
        let taskID = fixture.task.id
        let attemptID = fixture.attemptID
        let generation = fixture.generation
        let fingerprint = "fingerprint-stop-gates"
        try await recordExecuteApproval(store: store, taskID: taskID, attemptID: attemptID, fingerprint: fingerprint)
        port.bind(session, to: attemptID)
        await registry.arm()

        async let firstDispatch = dispatchTestOutcome(
            scheduler,
            taskID: taskID,
            attemptID: attemptID,
            generation: generation,
            fingerprint: fingerprint
        )
        await gate.waitUntilEntered()

        try await scheduler.stop(taskID: taskID)
        await gate.release()
        session.finish()

        let outcome = await firstDispatch
        XCTAssertEqual(port.startCount, 0, "A dispatch retired by stop must never start a runtime")
        guard case .refusal(let refusal) = outcome else {
            XCTFail("Expected a typed refusal after stop landed inside the gates, got \(outcome)")
            return
        }
        XCTAssertEqual(
            refusal,
            .staleAttempt(
                taskID: taskID,
                expectedAttemptID: attemptID,
                expectedGeneration: generation,
                actualAttemptID: nil,
                actualGeneration: nil
            )
        )

        // A leaked early reservation would refuse this probe as already-active before
        // the identity guard can report the stop-cleared attempt.
        await expectDispatchRefusal(
            scheduler,
            taskID: taskID,
            attemptID: attemptID,
            generation: generation,
            fingerprint: fingerprint,
            expected: .staleAttempt(
                taskID: taskID,
                expectedAttemptID: attemptID,
                expectedGeneration: generation,
                actualAttemptID: nil,
                actualGeneration: nil
            )
        )
    }

    func testConcurrentDuplicateDispatchDuringGatesStartsExactlyOneRun() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let workspace = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath)
        let gate = AsyncGate()
        let registry = ArmedDispatchTestRegistry(
            gate: gate,
            result: .eligible(runtimeID: "runtime", modelID: "model")
        )
        let session = DispatchTestSession()
        let port = ScriptedTaskRunningPort()
        let (scheduler, fixture) = try await makeDispatchFixture(
            store: store, clock: clock,
            providers: registry,
            workspaces: DispatchTestPreflight(result: .owned(workspace)),
            verifier: DispatchCountingVerifier(passed: true), port: port,
            budget: ExecutionBudget(), schedulerID: "scheduler-dispatch-duplicate-gates")
        let taskID = fixture.task.id
        let attemptID = fixture.attemptID
        let generation = fixture.generation
        let fingerprint = "fingerprint-duplicate-gates"
        try await recordExecuteApproval(store: store, taskID: taskID, attemptID: attemptID, fingerprint: fingerprint)
        port.bind(session, to: attemptID)
        await registry.arm()

        async let firstDispatch = dispatchTestOutcome(
            scheduler,
            taskID: taskID,
            attemptID: attemptID,
            generation: generation,
            fingerprint: fingerprint
        )
        await gate.waitUntilEntered()

        let secondOutcome = DispatchTestOutcomeBox()
        let secondTask = Task {
            let outcome = await dispatchTestOutcome(
                scheduler,
                taskID: taskID,
                attemptID: attemptID,
                generation: generation,
                fingerprint: fingerprint
            )
            await secondOutcome.set(outcome)
        }

        // Fixed: the duplicate loses the reservation race before the gate. Broken: both
        // park in the gate, so wait for the second entry before letting either proceed.
        await waitUntil("the duplicate to settle or join the provider gate") {
            if await secondOutcome.outcome != nil {
                return true
            }
            return await gate.currentEnteredCount() >= 2
        }
        await gate.release()
        try await waitForDispatchStart(port, count: 1)

        try await scheduler.stop(taskID: taskID)
        session.finish()

        let firstResult = await firstDispatch
        _ = await secondTask.value
        let secondResult = await secondOutcome.outcome

        XCTAssertEqual(port.startCount, 1, "Two interleaved dispatches must start exactly one runtime")
        guard let secondResult else {
            XCTFail("The duplicate dispatch never settled")
            return
        }
        guard case .refusal(let refusal) = secondResult else {
            XCTFail("The duplicate dispatch must be refused with a typed refusal, got \(secondResult)")
            return
        }
        XCTAssertEqual(refusal, .dispatchAlreadyActive(taskID: taskID))
        XCTAssertEqual(session.cancelCount, 1, "Stop must cancel the one started run exactly once")
        guard case .report(let firstReport) = firstResult else {
            XCTFail("The first dispatch must settle once stopped, got \(firstResult)")
            return
        }
        XCTAssertEqual(firstReport.completion.disposition, .stale)
    }

    func testStopDuringRuntimeStartInFlightCancelsJustStartedRun() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = TestTaskSchedulerClock(start: startDate)
        let workspace = Self.dispatchWorkspace(workspaceID: UUID(), repositoryPath: Self.dispatchRepositoryPath)
        let gate = AsyncGate()
        let session = DispatchTestSession()
        let port = GatedStartTaskRunningPort(session: session, gate: gate)
        let (scheduler, fixture) = try await makeDispatchFixture(
            store: store, clock: clock,
            providers: DispatchTestRegistry(results: [.eligible(runtimeID: "runtime", modelID: "model")]),
            workspaces: DispatchTestPreflight(result: .owned(workspace)),
            verifier: DispatchCountingVerifier(passed: true), port: port,
            budget: ExecutionBudget(), schedulerID: "scheduler-dispatch-start-in-flight")
        let taskID = fixture.task.id
        let attemptID = fixture.attemptID
        let generation = fixture.generation
        let fingerprint = "fingerprint-start-in-flight"
        try await recordExecuteApproval(store: store, taskID: taskID, attemptID: attemptID, fingerprint: fingerprint)

        async let dispatchCall = dispatchTestOutcome(
            scheduler,
            taskID: taskID,
            attemptID: attemptID,
            generation: generation,
            fingerprint: fingerprint
        )
        await gate.waitUntilEntered()

        try await scheduler.stop(taskID: taskID)
        await gate.release()

        let outcome = await dispatchCall
        XCTAssertEqual(port.startCount, 1)
        XCTAssertEqual(session.cancelCount, 1, "A run whose reservation was retired during start must be cancelled")
        guard case .report(let report) = outcome else {
            XCTFail("The dispatch must settle as stale after its run was cancelled, got \(outcome)")
            return
        }
        XCTAssertEqual(report.completion.disposition, .stale)
        let stored = try await store.task(id: taskID)
        XCTAssertEqual(stored?.status, .blocked)
        XCTAssertEqual(stored?.blockReason, .custom("stopped"))
    }
}

// MARK: - Live dispatch race observation

/// One dispatch outcome kept as a value so race tests can interleave tasks without
/// awaiting a call that may still be parked inside the scheduler.
private enum DispatchTestOutcome: Sendable {
    case report(TaskRunDispatchReport)
    case refusal(TaskDispatchRefusal)
    case otherFailure(String)
}

/// Actor box for one asynchronously observed dispatch outcome.
private actor DispatchTestOutcomeBox {
    private(set) var outcome: DispatchTestOutcome?

    func set(_ outcome: DispatchTestOutcome) {
        self.outcome = outcome
    }
}

/// Awaits one dispatch and keeps its typed refusal instead of throwing it.
private func dispatchTestOutcome(
    _ scheduler: TaskScheduler,
    taskID: UUID,
    attemptID: UUID,
    generation: Int,
    fingerprint: String
) async -> DispatchTestOutcome {
    do {
        return .report(
            try await scheduler.dispatch(
                taskID: taskID,
                attemptID: attemptID,
                generation: generation,
                fingerprint: fingerprint
            )
        )
    } catch let refusal as TaskDispatchRefusal {
        return .refusal(refusal)
    } catch {
        return .otherFailure(String(describing: error))
    }
}
