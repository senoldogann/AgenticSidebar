import Foundation
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
            schedulerID: schedulerID
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

        init(base: CodingTaskRepository) {
            self.base = base
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

        func addDependency(_ dependency: TaskDependency) async throws {
            try await base.addDependency(dependency)
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

        func saveAgentProfile(_ profile: AgentProfile) async throws {
            try await base.saveAgentProfile(profile)
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
            schedulerID: "scheduler-reentrancy"
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
            schedulerID: "scheduler-claim-failure"
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
            schedulerID: "scheduler-verifier-failure"
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
            schedulerID: "scheduler-swallowed-release"
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
}
