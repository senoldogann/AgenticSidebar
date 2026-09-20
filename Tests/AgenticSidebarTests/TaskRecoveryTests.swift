import Foundation
import XCTest

@testable import AgenticSidebar

final class TaskRecoveryTests: XCTestCase {

    // MARK: - Test doubles

    private final class RecoveryTestClock: TaskSchedulerClock, @unchecked Sendable {
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

    private final class ScriptedProviderSessions: TaskProviderSessionInspecting, @unchecked Sendable {
        private let lock = NSLock()
        private let status: TaskProviderSessionStatus
        private var inspected: [TaskAttempt] = []

        init(status: TaskProviderSessionStatus) {
            self.status = status
        }

        func providerStatus(for attempt: TaskAttempt) async -> TaskProviderSessionStatus {
            record(attempt)
            return status
        }

        private func record(_ attempt: TaskAttempt) {
            lock.lock()
            inspected.append(attempt)
            lock.unlock()
        }

        var inspectedAttempts: [TaskAttempt] {
            lock.lock()
            defer { lock.unlock() }
            return inspected
        }
    }

    private final class ScriptedWorkspaces: TaskWorkspaceOwnershipInspecting, @unchecked Sendable {
        private let lock = NSLock()
        private let status: TaskWorkspaceOwnershipStatus
        private var inspected: [TaskAttempt] = []

        init(status: TaskWorkspaceOwnershipStatus) {
            self.status = status
        }

        func workspaceStatus(for attempt: TaskAttempt) async -> TaskWorkspaceOwnershipStatus {
            record(attempt)
            return status
        }

        private func record(_ attempt: TaskAttempt) {
            lock.lock()
            inspected.append(attempt)
            lock.unlock()
        }

        var inspectedAttempts: [TaskAttempt] {
            lock.lock()
            defer { lock.unlock() }
            return inspected
        }
    }

    private final class ScriptedProcesses: TaskProcessOwnershipInspecting, @unchecked Sendable {
        private let lock = NSLock()
        private let status: TaskProcessOwnershipStatus
        private var inspected: [TaskAttempt] = []

        init(status: TaskProcessOwnershipStatus) {
            self.status = status
        }

        func processStatus(for attempt: TaskAttempt) async -> TaskProcessOwnershipStatus {
            record(attempt)
            return status
        }

        private func record(_ attempt: TaskAttempt) {
            lock.lock()
            inspected.append(attempt)
            lock.unlock()
        }

        var inspectedAttempts: [TaskAttempt] {
            lock.lock()
            defer { lock.unlock() }
            return inspected
        }
    }

    /// Provider port that parks the first inspection until the test releases it.
    ///
    /// Later inspections answer immediately with `.active` so a concurrent reconcile can
    /// never block on the gate. This lets a test hold one pass mid-flight while another
    /// actor mutates the store, without the second pass hanging.
    private final class GatedProviderSessions: TaskProviderSessionInspecting, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: CheckedContinuation<TaskProviderSessionStatus, Never>?
        private var inspectedOnce = false

        func providerStatus(for attempt: TaskAttempt) async -> TaskProviderSessionStatus {
            let shouldSuspend = lock.withLock { () -> Bool in
                let firstInspection = !inspectedOnce
                inspectedOnce = true
                return firstInspection
            }
            guard shouldSuspend else { return .active }
            return await withCheckedContinuation { continuation in
                lock.withLock {
                    pending = continuation
                }
            }
        }

        var isSuspended: Bool {
            lock.withLock { pending != nil }
        }

        func waitUntilSuspended() async {
            for _ in 0..<5_000 {
                if isSuspended {
                    return
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }

        func release(with status: TaskProviderSessionStatus) {
            let continuation = lock.withLock { () -> CheckedContinuation<TaskProviderSessionStatus, Never>? in
                let parked = pending
                pending = nil
                return parked
            }
            continuation?.resume(returning: status)
        }
    }

    private struct RecoveryTestProviderRegistry: TaskProviderRegistryPort {
        func candidate(for task: CodingTask, stage: TaskStage) async -> TaskProviderCandidate {
            .eligible(runtimeID: "recovery-test-runtime", modelID: "recovery-test-model")
        }
    }

    private struct RecoveryTestWorkspacePreflight: TaskWorkspacePreflightPort {
        let descriptor: TaskWorkspaceDescriptor

        func preflight(projectID: UUID, taskID: UUID) async -> TaskWorkspacePreflightResult {
            .owned(descriptor)
        }
    }

    private struct RecoveryTestVerifier: TaskVerifying {
        func verify(
            task: CodingTask,
            attempt: TaskAttempt,
            workspace: TaskWorkspaceDescriptor
        ) async -> TaskVerificationReport {
            TaskVerificationReport(passed: true, recipeName: "recovery-test", detailsRedacted: "recovery-test")
        }
    }

    private actor RecoveryHookingRepository: CodingTaskRepository {
        private let base: CodingTaskRepository
        private var snapshotError: TaskRepositoryError?
        private var endAttemptError: TaskRepositoryError?
        private var releaseLeaseError: TaskRepositoryError?
        private var transitionError: TaskRepositoryError?

        init(base: CodingTaskRepository) {
            self.base = base
        }

        func setSnapshotError(_ error: TaskRepositoryError?) {
            snapshotError = error
        }

        func setEndAttemptError(_ error: TaskRepositoryError?) {
            endAttemptError = error
        }

        func setReleaseLeaseError(_ error: TaskRepositoryError?) {
            releaseLeaseError = error
        }

        func setTransitionError(_ error: TaskRepositoryError?) {
            transitionError = error
        }

        func snapshot(projectID: UUID) async throws -> CodingBoardSnapshot {
            if let snapshotError {
                throw snapshotError
            }
            return try await base.snapshot(projectID: projectID)
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
            if let transitionError {
                throw transitionError
            }
            return try await base.transition(taskID: taskID, expectedVersion: expectedVersion, action: action, context: context)
        }

        func claimAttempt(taskID: UUID, expectedVersion: Int, attempt: TaskAttempt) async throws -> TaskAttempt {
            try await base.claimAttempt(taskID: taskID, expectedVersion: expectedVersion, attempt: attempt)
        }

        func endAttempt(
            taskID: UUID,
            attemptID: UUID,
            expectedVersion: Int,
            outcome: AttemptOutcome,
            toolCallCount: Int?,
            durationSeconds: Int?
        ) async throws -> CodingTask {
            if let endAttemptError {
                throw endAttemptError
            }
            return try await base.endAttempt(
                taskID: taskID,
                attemptID: attemptID,
                expectedVersion: expectedVersion,
                outcome: outcome,
                toolCallCount: toolCallCount,
                durationSeconds: durationSeconds
            )
        }

        func acquireRepositoryLease(
            repositoryPath: String,
            taskID: UUID,
            attemptID: UUID,
            leaseTimeoutSeconds: TimeInterval
        ) async throws {
            try await base.acquireRepositoryLease(
                repositoryPath: repositoryPath,
                taskID: taskID,
                attemptID: attemptID,
                leaseTimeoutSeconds: leaseTimeoutSeconds
            )
        }

        func releaseRepositoryLease(repositoryPath: String, taskID: UUID, attemptID: UUID) async throws {
            if let releaseLeaseError {
                throw releaseLeaseError
            }
            try await base.releaseRepositoryLease(repositoryPath: repositoryPath, taskID: taskID, attemptID: attemptID)
        }

        func appendEvent(_ event: CodingTaskEvent) async throws {
            try await base.appendEvent(event)
        }

        func recordEvidence(_ evidence: VerificationEvidence) async throws {
            try await base.recordEvidence(evidence)
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

        func loadAgentProfile(id: UUID) async throws -> AgentProfile? {
            try await base.loadAgentProfile(id: id)
        }
    }

    // MARK: - Fixtures

    private let startDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTask(projectID: UUID, status: TaskStatus, title: String) -> CodingTask {
        CodingTask(
            id: UUID(),
            projectID: projectID,
            title: title,
            objective: title,
            status: status,
            createdAt: startDate,
            updatedAt: startDate
        )
    }

    private func makeAttempt(
        taskID: UUID,
        sequence: Int,
        generation: Int,
        workspaceID: UUID,
        leaseToken: String,
        leaseExpiry: Date,
        startedAt: Date
    ) -> TaskAttempt {
        TaskAttempt(
            taskID: taskID,
            attemptSequence: sequence,
            role: .developer,
            providerID: "recovery-provider",
            modelID: "recovery-model",
            workspaceID: workspaceID,
            generation: generation,
            leaseOwner: "recovery-scheduler",
            leaseToken: leaseToken,
            leaseExpiry: leaseExpiry,
            startedAt: startedAt,
            endedAt: nil,
            outcome: .inProgress,
            toolCallCount: nil,
            durationSeconds: nil
        )
    }

    private func seedInFlightAttempt(
        store: SQLiteTaskStore,
        task: CodingTask,
        attempt: TaskAttempt,
        repositoryPath: String,
        leaseTimeoutSeconds: TimeInterval
    ) async throws -> CodingTask {
        try await store.acquireRepositoryLease(
            repositoryPath: repositoryPath,
            taskID: task.id,
            attemptID: attempt.id,
            leaseTimeoutSeconds: leaseTimeoutSeconds
        )
        _ = try await store.claimAttempt(taskID: task.id, expectedVersion: task.version, attempt: attempt)
        let claimedTask = try await store.task(id: task.id)
        return try XCTUnwrap(claimedTask)
    }

    private func makeRecovery(
        repository: CodingTaskRepository,
        clock: RecoveryTestClock,
        providers: TaskProviderSessionInspecting,
        workspaces: TaskWorkspaceOwnershipInspecting,
        processes: TaskProcessOwnershipInspecting,
        recoveryID: String
    ) -> TaskRecovery {
        TaskRecovery(
            repository: repository,
            providers: providers,
            workspaces: workspaces,
            processes: processes,
            clock: clock,
            recoveryID: recoveryID
        )
    }

    private func entry(for taskID: UUID, in report: RecoveryReport) throws -> TaskRecoveryEntry {
        try XCTUnwrap(report.entry(for: taskID))
    }

    private func makeChallengerTask(store: SQLiteTaskStore, projectID: UUID) async throws -> CodingTask {
        let challenger = makeTask(projectID: projectID, status: .ready, title: "Challenger")
        try await store.createTask(challenger)
        return challenger
    }

    private func assertRepositoryLeaseHeld(
        store: SQLiteTaskStore,
        repositoryPath: String,
        challengerTaskID: UUID
    ) async throws {
        do {
            try await store.acquireRepositoryLease(
                repositoryPath: repositoryPath,
                taskID: challengerTaskID,
                attemptID: UUID(),
                leaseTimeoutSeconds: 3600
            )
            XCTFail("Repository lease must still be held")
        } catch let error as TaskRepositoryError {
            guard case .repositoryLeaseConflict = error else {
                XCTFail("Expected repositoryLeaseConflict, got \(error)")
                return
            }
        }
    }

    // MARK: - Crash after claim

    func testCrashAfterClaimReapsOrphanAttemptAndBlocksForUncertainExecution() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = RecoveryTestClock(start: startDate)
        let projectID = UUID()
        let repositoryPath = "/tmp/task-recovery-tests/claim-repo-\(UUID().uuidString)"
        let task = makeTask(projectID: projectID, status: .ready, title: "Crash after claim")
        try await store.createTask(task)
        let attempt = makeAttempt(
            taskID: task.id,
            sequence: 1,
            generation: 1,
            workspaceID: UUID(),
            leaseToken: "nonce-claim",
            leaseExpiry: startDate.addingTimeInterval(600),
            startedAt: startDate
        )
        let runningTask = try await seedInFlightAttempt(
            store: store,
            task: task,
            attempt: attempt,
            repositoryPath: repositoryPath,
            leaseTimeoutSeconds: 3600
        )
        XCTAssertEqual(runningTask.status, .running)

        let recovery = makeRecovery(
            repository: store,
            clock: clock,
            providers: ScriptedProviderSessions(status: .stopped),
            workspaces: ScriptedWorkspaces(status: .notActivelyOwned(repositoryPath: repositoryPath)),
            processes: ScriptedProcesses(status: .absent),
            recoveryID: "recovery-claim"
        )
        let report = await recovery.reconcile(projectID: projectID)

        let recovered = try entry(for: task.id, in: report)
        XCTAssertEqual(
            recovered.disposition,
            .reconciledAndReleased(attemptID: attempt.id, generation: 1, repositoryPath: repositoryPath)
        )
        XCTAssertEqual(recovered.userChoices, [.retryTask(taskID: task.id)])
        XCTAssertEqual(report.reconciledTaskIDs, [task.id])
        XCTAssertTrue(report.blockedUncertainTaskIDs.isEmpty)
        XCTAssertTrue(report.requiresUserChoiceTaskIDs.isEmpty)
        XCTAssertNil(report.failure)

        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.outcome, .cancelled)
        XCTAssertNotNil(history.first?.endedAt)

        let stored = try await store.task(id: task.id)
        XCTAssertEqual(stored?.status, .blocked)
        XCTAssertEqual(stored?.blockReason, TaskRecovery.uncertainBlockReason(for: attempt))
        XCTAssertEqual(stored?.currentAttemptID, attempt.id, "The reconciled generation stays recorded for audit")

        let snapshot = try await store.snapshot(projectID: projectID)
        XCTAssertTrue(snapshot.activeAttempts.isEmpty)

        let challenger = try await makeChallengerTask(store: store, projectID: projectID)
        try await store.acquireRepositoryLease(
            repositoryPath: repositoryPath,
            taskID: challenger.id,
            attemptID: UUID(),
            leaseTimeoutSeconds: 3600
        )
    }

    // MARK: - Crash after provider submission

    func testCrashAfterProviderSubmissionBlocksWithoutReapingLiveSession() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = RecoveryTestClock(start: startDate)
        let projectID = UUID()
        let repositoryPath = "/tmp/task-recovery-tests/provider-repo-\(UUID().uuidString)"
        let task = makeTask(projectID: projectID, status: .ready, title: "Crash after provider submission")
        try await store.createTask(task)
        let attempt = makeAttempt(
            taskID: task.id,
            sequence: 1,
            generation: 1,
            workspaceID: UUID(),
            leaseToken: "nonce-provider",
            leaseExpiry: startDate.addingTimeInterval(600),
            startedAt: startDate
        )
        _ = try await seedInFlightAttempt(
            store: store,
            task: task,
            attempt: attempt,
            repositoryPath: repositoryPath,
            leaseTimeoutSeconds: 3600
        )

        let recovery = makeRecovery(
            repository: store,
            clock: clock,
            providers: ScriptedProviderSessions(status: .active),
            workspaces: ScriptedWorkspaces(status: .notActivelyOwned(repositoryPath: repositoryPath)),
            processes: ScriptedProcesses(status: .absent),
            recoveryID: "recovery-provider"
        )
        let report = await recovery.reconcile(projectID: projectID)

        let recovered = try entry(for: task.id, in: report)
        XCTAssertEqual(recovered.disposition, .blockedUncertain(attemptID: attempt.id))
        XCTAssertTrue(recovered.userChoices.isEmpty)
        XCTAssertEqual(report.blockedUncertainTaskIDs, [task.id])
        XCTAssertTrue(report.reconciledTaskIDs.isEmpty)

        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.first?.outcome, .inProgress)
        XCTAssertNil(history.first?.endedAt)

        let stored = try await store.task(id: task.id)
        XCTAssertEqual(stored?.status, .blocked)
        XCTAssertEqual(stored?.blockReason, TaskRecovery.uncertainBlockReason(for: attempt))

        let challenger = try await makeChallengerTask(store: store, projectID: projectID)
        try await assertRepositoryLeaseHeld(store: store, repositoryPath: repositoryPath, challengerTaskID: challenger.id)
    }

    // MARK: - Crash after edit before evidence

    func testCrashAfterEditBeforeEvidenceWithActivelyOwnedWorkspaceBlocks() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = RecoveryTestClock(start: startDate)
        let projectID = UUID()
        let repositoryPath = "/tmp/task-recovery-tests/edit-repo-\(UUID().uuidString)"
        let workspaceID = UUID()
        let task = makeTask(projectID: projectID, status: .ready, title: "Crash after edit")
        try await store.createTask(task)
        let attempt = makeAttempt(
            taskID: task.id,
            sequence: 1,
            generation: 1,
            workspaceID: workspaceID,
            leaseToken: "nonce-edit",
            leaseExpiry: startDate.addingTimeInterval(600),
            startedAt: startDate
        )
        _ = try await seedInFlightAttempt(
            store: store,
            task: task,
            attempt: attempt,
            repositoryPath: repositoryPath,
            leaseTimeoutSeconds: 3600
        )
        let descriptor = TaskWorkspaceDescriptor(
            workspaceID: workspaceID,
            workspacePath: repositoryPath + "/workspace",
            repositoryPath: repositoryPath
        )

        let recovery = makeRecovery(
            repository: store,
            clock: clock,
            providers: ScriptedProviderSessions(status: .stopped),
            workspaces: ScriptedWorkspaces(status: .activelyOwned(descriptor)),
            processes: ScriptedProcesses(status: .absent),
            recoveryID: "recovery-edit"
        )
        let report = await recovery.reconcile(projectID: projectID)

        let recovered = try entry(for: task.id, in: report)
        XCTAssertEqual(recovered.disposition, .blockedUncertain(attemptID: attempt.id))

        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.first?.outcome, .inProgress)

        let stored = try await store.task(id: task.id)
        XCTAssertEqual(stored?.status, .blocked)
        XCTAssertEqual(stored?.blockReason, TaskRecovery.uncertainBlockReason(for: attempt))

        let challenger = try await makeChallengerTask(store: store, projectID: projectID)
        try await assertRepositoryLeaseHeld(store: store, repositoryPath: repositoryPath, challengerTaskID: challenger.id)
    }

    // MARK: - Orphan process ownership

    func testOrphanProcessWithForeignOwnerRequiresUserChoiceWithoutDestructiveAction() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = RecoveryTestClock(start: startDate)
        let projectID = UUID()
        let repositoryPath = "/tmp/task-recovery-tests/foreign-repo-\(UUID().uuidString)"
        let task = makeTask(projectID: projectID, status: .ready, title: "Foreign orphan process")
        try await store.createTask(task)
        let attempt = makeAttempt(
            taskID: task.id,
            sequence: 1,
            generation: 1,
            workspaceID: UUID(),
            leaseToken: "nonce-foreign",
            leaseExpiry: startDate.addingTimeInterval(600),
            startedAt: startDate
        )
        _ = try await seedInFlightAttempt(
            store: store,
            task: task,
            attempt: attempt,
            repositoryPath: repositoryPath,
            leaseTimeoutSeconds: 3600
        )

        let recovery = makeRecovery(
            repository: store,
            clock: clock,
            providers: ScriptedProviderSessions(status: .stopped),
            workspaces: ScriptedWorkspaces(status: .notActivelyOwned(repositoryPath: repositoryPath)),
            processes: ScriptedProcesses(status: .foreign(pid: 4242, reason: "executable path belongs to another owner")),
            recoveryID: "recovery-foreign"
        )
        let report = await recovery.reconcile(projectID: projectID)

        let recovered = try entry(for: task.id, in: report)
        XCTAssertEqual(
            recovered.disposition,
            .requiresUserChoice(
                attemptID: attempt.id,
                processID: 4242,
                reason: "executable path belongs to another owner"
            )
        )
        XCTAssertEqual(recovered.userChoices, [.terminateProcess(pid: 4242), .abandonAttempt(attemptID: attempt.id)])
        XCTAssertEqual(report.requiresUserChoiceTaskIDs, [task.id])
        XCTAssertTrue(report.blockedUncertainTaskIDs.isEmpty)

        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.first?.outcome, .inProgress)
        XCTAssertNil(history.first?.endedAt)
        let stored = try await store.task(id: task.id)
        XCTAssertEqual(stored?.status, .blocked)

        let challenger = try await makeChallengerTask(store: store, projectID: projectID)
        try await assertRepositoryLeaseHeld(store: store, repositoryPath: repositoryPath, challengerTaskID: challenger.id)
    }

    func testUnknownProcessOwnershipNeverTerminatesAndRequiresUserChoice() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = RecoveryTestClock(start: startDate)
        let projectID = UUID()
        let repositoryPath = "/tmp/task-recovery-tests/unknown-pid-repo-\(UUID().uuidString)"
        let task = makeTask(projectID: projectID, status: .ready, title: "Unknown orphan process")
        try await store.createTask(task)
        let attempt = makeAttempt(
            taskID: task.id,
            sequence: 1,
            generation: 1,
            workspaceID: UUID(),
            leaseToken: "nonce-unknown",
            leaseExpiry: startDate.addingTimeInterval(600),
            startedAt: startDate
        )
        _ = try await seedInFlightAttempt(
            store: store,
            task: task,
            attempt: attempt,
            repositoryPath: repositoryPath,
            leaseTimeoutSeconds: 3600
        )
        let providerSessions = ScriptedProviderSessions(status: .stopped)
        let processes = ScriptedProcesses(status: .unknown(pid: 777, reason: "pid exists but ownership is unprovable"))

        let recovery = makeRecovery(
            repository: store,
            clock: clock,
            providers: providerSessions,
            workspaces: ScriptedWorkspaces(status: .notActivelyOwned(repositoryPath: repositoryPath)),
            processes: processes,
            recoveryID: "recovery-unknown-pid"
        )
        let report = await recovery.reconcile(projectID: projectID)

        let recovered = try entry(for: task.id, in: report)
        guard case .requiresUserChoice(let choiceAttemptID, let processID, let reason) = recovered.disposition else {
            XCTFail("A PID without ownership proof must never authorize automatic termination")
            return
        }
        XCTAssertEqual(choiceAttemptID, attempt.id)
        XCTAssertEqual(processID, 777)
        XCTAssertEqual(reason, "pid exists but ownership is unprovable")
        XCTAssertEqual(recovered.userChoices, [.terminateProcess(pid: 777), .abandonAttempt(attemptID: attempt.id)])
        XCTAssertEqual(providerSessions.inspectedAttempts.first?.leaseToken, "nonce-unknown")
        XCTAssertEqual(processes.inspectedAttempts.first?.id, attempt.id)

        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.first?.outcome, .inProgress)
        let challenger = try await makeChallengerTask(store: store, projectID: projectID)
        try await assertRepositoryLeaseHeld(store: store, repositoryPath: repositoryPath, challengerTaskID: challenger.id)
    }

    func testMatchingProcessOwnershipProofBlocksWithoutReaping() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = RecoveryTestClock(start: startDate)
        let projectID = UUID()
        let repositoryPath = "/tmp/task-recovery-tests/owned-process-repo-\(UUID().uuidString)"
        let workspaceID = UUID()
        let task = makeTask(projectID: projectID, status: .ready, title: "Matching process ownership")
        try await store.createTask(task)
        let attempt = makeAttempt(
            taskID: task.id,
            sequence: 1,
            generation: 1,
            workspaceID: workspaceID,
            leaseToken: "nonce-owned",
            leaseExpiry: startDate.addingTimeInterval(600),
            startedAt: startDate
        )
        _ = try await seedInFlightAttempt(
            store: store,
            task: task,
            attempt: attempt,
            repositoryPath: repositoryPath,
            leaseTimeoutSeconds: 3600
        )
        let descriptor = TaskWorkspaceDescriptor(
            workspaceID: workspaceID,
            workspacePath: repositoryPath + "/workspace",
            repositoryPath: repositoryPath
        )
        let proof = TaskProcessOwnershipProof(
            pid: 5150,
            attemptID: attempt.id,
            ownerNonce: "nonce-owned",
            executablePath: "/usr/local/bin/recovery-agent",
            workspacePath: descriptor.workspacePath
        )

        let recovery = makeRecovery(
            repository: store,
            clock: clock,
            providers: ScriptedProviderSessions(status: .stopped),
            workspaces: ScriptedWorkspaces(status: .activelyOwned(descriptor)),
            processes: ScriptedProcesses(status: .owned(proof)),
            recoveryID: "recovery-owned-process"
        )
        let report = await recovery.reconcile(projectID: projectID)

        let recovered = try entry(for: task.id, in: report)
        XCTAssertEqual(recovered.disposition, .blockedUncertain(attemptID: attempt.id))
        XCTAssertEqual(recovered.userChoices, [.terminateProcess(pid: 5150)])

        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.first?.outcome, .inProgress)
        let challenger = try await makeChallengerTask(store: store, projectID: projectID)
        try await assertRepositoryLeaseHeld(store: store, repositoryPath: repositoryPath, challengerTaskID: challenger.id)
    }

    func testMismatchedProcessOwnershipProofRequiresUserChoice() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = RecoveryTestClock(start: startDate)
        let projectID = UUID()
        let repositoryPath = "/tmp/task-recovery-tests/mismatched-process-repo-\(UUID().uuidString)"
        let workspaceID = UUID()
        let task = makeTask(projectID: projectID, status: .ready, title: "Mismatched process ownership")
        try await store.createTask(task)
        let attempt = makeAttempt(
            taskID: task.id,
            sequence: 1,
            generation: 1,
            workspaceID: workspaceID,
            leaseToken: "nonce-expected",
            leaseExpiry: startDate.addingTimeInterval(600),
            startedAt: startDate
        )
        _ = try await seedInFlightAttempt(
            store: store,
            task: task,
            attempt: attempt,
            repositoryPath: repositoryPath,
            leaseTimeoutSeconds: 3600
        )
        let descriptor = TaskWorkspaceDescriptor(
            workspaceID: workspaceID,
            workspacePath: repositoryPath + "/workspace",
            repositoryPath: repositoryPath
        )
        let mismatchedProof = TaskProcessOwnershipProof(
            pid: 6161,
            attemptID: attempt.id,
            ownerNonce: "nonce-foreign",
            executablePath: "/usr/local/bin/recovery-agent",
            workspacePath: descriptor.workspacePath
        )

        let recovery = makeRecovery(
            repository: store,
            clock: clock,
            providers: ScriptedProviderSessions(status: .stopped),
            workspaces: ScriptedWorkspaces(status: .activelyOwned(descriptor)),
            processes: ScriptedProcesses(status: .owned(mismatchedProof)),
            recoveryID: "recovery-mismatched-process"
        )
        let report = await recovery.reconcile(projectID: projectID)

        let recovered = try entry(for: task.id, in: report)
        guard case .requiresUserChoice(_, let processID, _) = recovered.disposition else {
            XCTFail("A process whose nonce does not match the attempt must not be treated as owned")
            return
        }
        XCTAssertEqual(processID, 6161)

        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.first?.outcome, .inProgress)
        let challenger = try await makeChallengerTask(store: store, projectID: projectID)
        try await assertRepositoryLeaseHeld(store: store, repositoryPath: repositoryPath, challengerTaskID: challenger.id)
    }

    // MARK: - Expired lease

    func testExpiredLeaseDoesNotAuthorizeTakeoverUntilAttemptIsTerminal() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = RecoveryTestClock(start: startDate)
        let projectID = UUID()
        let repositoryPath = "/tmp/task-recovery-tests/expired-lease-repo-\(UUID().uuidString)"
        let task = makeTask(projectID: projectID, status: .ready, title: "Expired lease")
        try await store.createTask(task)
        let attempt = makeAttempt(
            taskID: task.id,
            sequence: 1,
            generation: 1,
            workspaceID: UUID(),
            leaseToken: "nonce-expired",
            leaseExpiry: startDate.addingTimeInterval(30),
            startedAt: startDate.addingTimeInterval(-600)
        )
        _ = try await seedInFlightAttempt(
            store: store,
            task: task,
            attempt: attempt,
            repositoryPath: repositoryPath,
            leaseTimeoutSeconds: -10
        )
        clock.advance(seconds: 120)

        let challenger = try await makeChallengerTask(store: store, projectID: projectID)
        try await assertRepositoryLeaseHeld(store: store, repositoryPath: repositoryPath, challengerTaskID: challenger.id)

        let recovery = makeRecovery(
            repository: store,
            clock: clock,
            providers: ScriptedProviderSessions(status: .stopped),
            workspaces: ScriptedWorkspaces(status: .notActivelyOwned(repositoryPath: repositoryPath)),
            processes: ScriptedProcesses(status: .absent),
            recoveryID: "recovery-expired-lease"
        )
        let report = await recovery.reconcile(projectID: projectID)

        let recovered = try entry(for: task.id, in: report)
        XCTAssertEqual(
            recovered.disposition,
            .reconciledAndReleased(attemptID: attempt.id, generation: 1, repositoryPath: repositoryPath)
        )
        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.first?.outcome, .cancelled)
        try await store.acquireRepositoryLease(
            repositoryPath: repositoryPath,
            taskID: challenger.id,
            attemptID: UUID(),
            leaseTimeoutSeconds: 3600
        )
    }

    // MARK: - Delayed callback after retry

    func testDelayedCompletionAfterReconcileAndRetryIsRejectedAsStale() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = RecoveryTestClock(start: startDate)
        let projectID = UUID()
        let repositoryPath = "/tmp/task-recovery-tests/delayed-callback-repo-\(UUID().uuidString)"
        let workspaceID = UUID()
        let task = makeTask(projectID: projectID, status: .ready, title: "Delayed callback")
        try await store.createTask(task)
        let firstAttempt = makeAttempt(
            taskID: task.id,
            sequence: 1,
            generation: 1,
            workspaceID: workspaceID,
            leaseToken: "nonce-first",
            leaseExpiry: startDate.addingTimeInterval(600),
            startedAt: startDate
        )
        _ = try await seedInFlightAttempt(
            store: store,
            task: task,
            attempt: firstAttempt,
            repositoryPath: repositoryPath,
            leaseTimeoutSeconds: 3600
        )

        let recovery = makeRecovery(
            repository: store,
            clock: clock,
            providers: ScriptedProviderSessions(status: .stopped),
            workspaces: ScriptedWorkspaces(status: .notActivelyOwned(repositoryPath: repositoryPath)),
            processes: ScriptedProcesses(status: .absent),
            recoveryID: "recovery-delayed"
        )
        let report = await recovery.reconcile(projectID: projectID)
        XCTAssertEqual(
            try entry(for: task.id, in: report).disposition,
            .reconciledAndReleased(
                attemptID: firstAttempt.id, generation: 1, repositoryPath: repositoryPath
            ))

        let blockedTask = try await store.task(id: task.id)
        let blocked = try XCTUnwrap(blockedTask)
        let unblocked = try await store.transition(
            taskID: task.id,
            expectedVersion: blocked.version,
            action: .unblock,
            context: TaskTransitionContext(fingerprint: "explicit-retry", actor: "test")
        )
        let secondAttempt = makeAttempt(
            taskID: task.id,
            sequence: 2,
            generation: 2,
            workspaceID: UUID(),
            leaseToken: "nonce-second",
            leaseExpiry: startDate.addingTimeInterval(600),
            startedAt: startDate
        )
        try await store.acquireRepositoryLease(
            repositoryPath: repositoryPath,
            taskID: task.id,
            attemptID: secondAttempt.id,
            leaseTimeoutSeconds: 3600
        )
        _ = try await store.claimAttempt(taskID: task.id, expectedVersion: unblocked.version, attempt: secondAttempt)
        let claimedTask = try await store.task(id: task.id)
        let claimed = try XCTUnwrap(claimedTask)

        do {
            _ = try await store.endAttempt(
                taskID: task.id,
                attemptID: firstAttempt.id,
                expectedVersion: claimed.version,
                outcome: .succeeded,
                toolCallCount: nil,
                durationSeconds: nil
            )
            XCTFail("A late completion for a reconciled generation must be rejected")
        } catch let error as TaskRepositoryError {
            XCTAssertEqual(error, .attemptNotActive(taskID: task.id, attemptID: firstAttempt.id))
        }

        let descriptor = TaskWorkspaceDescriptor(
            workspaceID: UUID(),
            workspacePath: repositoryPath + "/workspace",
            repositoryPath: repositoryPath
        )
        let scheduler = TaskScheduler(
            repository: store,
            providers: RecoveryTestProviderRegistry(),
            workspaces: RecoveryTestWorkspacePreflight(descriptor: descriptor),
            verifier: RecoveryTestVerifier(),
            clock: clock,
            schedulerID: "recovery-late-callback",
            provisioning: nil
        )
        let lateCompletion = try await scheduler.attemptDidComplete(
            taskID: task.id,
            attemptID: firstAttempt.id,
            generation: 1,
            ownerNonce: "nonce-first",
            outcome: .succeeded,
            usage: TaskAttemptUsage(toolCallCount: nil, durationSeconds: nil)
        )
        XCTAssertEqual(lateCompletion.disposition, .stale)

        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.first { $0.id == firstAttempt.id }?.outcome, .cancelled)
        XCTAssertEqual(history.first { $0.id == secondAttempt.id }?.outcome, .inProgress)
        let stored = try await store.task(id: task.id)
        XCTAssertEqual(stored?.status, .running)
    }

    // MARK: - Close and reopen

    func testReconcileAfterCloseAndReopenNeverAutoRetries() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let dbURL = tempDirectory.appendingPathComponent("task-recovery.sqlite")
        let projectID = UUID()
        let repositoryPath = tempDirectory.appendingPathComponent("repo").path
        let taskID: UUID
        let attemptID: UUID
        do {
            let store = try SQLiteTaskStore.open(at: dbURL)
            let task = makeTask(projectID: projectID, status: .ready, title: "Close and reopen")
            taskID = task.id
            try await store.createTask(task)
            let attempt = makeAttempt(
                taskID: task.id,
                sequence: 1,
                generation: 1,
                workspaceID: UUID(),
                leaseToken: "nonce-reopen",
                leaseExpiry: startDate.addingTimeInterval(600),
                startedAt: startDate
            )
            attemptID = attempt.id
            _ = try await seedInFlightAttempt(
                store: store,
                task: task,
                attempt: attempt,
                repositoryPath: repositoryPath,
                leaseTimeoutSeconds: 3600
            )
            await store.close()
        }

        let reopened = try SQLiteTaskStore.open(at: dbURL)
        let clock = RecoveryTestClock(start: startDate)
        let recovery = makeRecovery(
            repository: reopened,
            clock: clock,
            providers: ScriptedProviderSessions(status: .stopped),
            workspaces: ScriptedWorkspaces(status: .notActivelyOwned(repositoryPath: repositoryPath)),
            processes: ScriptedProcesses(status: .absent),
            recoveryID: "recovery-reopen"
        )
        let report = await recovery.reconcile(projectID: projectID)
        XCTAssertEqual(
            try entry(for: taskID, in: report).disposition,
            .reconciledAndReleased(
                attemptID: attemptID, generation: 1, repositoryPath: repositoryPath
            ))

        let descriptor = TaskWorkspaceDescriptor(
            workspaceID: UUID(),
            workspacePath: repositoryPath + "/workspace",
            repositoryPath: repositoryPath
        )
        let scheduler = TaskScheduler(
            repository: reopened,
            providers: RecoveryTestProviderRegistry(),
            workspaces: RecoveryTestWorkspacePreflight(descriptor: descriptor),
            verifier: RecoveryTestVerifier(),
            clock: clock,
            schedulerID: "recovery-launch",
            provisioning: nil
        )
        let scheduleReport = try await scheduler.schedule(projectID: projectID)
        XCTAssertTrue(scheduleReport.claimedTaskIDs.isEmpty, "Recovery must never dispatch a replacement attempt")
        XCTAssertTrue(scheduleReport.entries.isEmpty, "A task blocked for uncertain execution is not eligible")
        await reopened.close()

        let finalStore = try SQLiteTaskStore.open(at: dbURL)
        let persisted = try await finalStore.task(id: taskID)
        XCTAssertEqual(persisted?.status, .blocked)
        XCTAssertEqual(persisted?.blockReason?.uncertainExecutionDetail != nil, true)
        let history = try await finalStore.attemptHistory(taskID: taskID)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.outcome, .cancelled)
        let snapshot = try await finalStore.snapshot(projectID: projectID)
        XCTAssertTrue(snapshot.activeAttempts.isEmpty)
        let challenger = try await makeChallengerTask(store: finalStore, projectID: projectID)
        try await finalStore.acquireRepositoryLease(
            repositoryPath: repositoryPath,
            taskID: challenger.id,
            attemptID: UUID(),
            leaseTimeoutSeconds: 3600
        )
        await finalStore.close()
    }

    // MARK: - Idempotency and error reporting

    func testSecondReconcileReportsNoActionAndDoesNotRetry() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = RecoveryTestClock(start: startDate)
        let projectID = UUID()
        let repositoryPath = "/tmp/task-recovery-tests/idempotent-repo-\(UUID().uuidString)"
        let task = makeTask(projectID: projectID, status: .ready, title: "Idempotent recovery")
        let cleanTask = makeTask(projectID: projectID, status: .ready, title: "Clean task")
        try await store.createTask(task)
        try await store.createTask(cleanTask)
        let attempt = makeAttempt(
            taskID: task.id,
            sequence: 1,
            generation: 1,
            workspaceID: UUID(),
            leaseToken: "nonce-idempotent",
            leaseExpiry: startDate.addingTimeInterval(600),
            startedAt: startDate
        )
        _ = try await seedInFlightAttempt(
            store: store,
            task: task,
            attempt: attempt,
            repositoryPath: repositoryPath,
            leaseTimeoutSeconds: 3600
        )

        let recovery = makeRecovery(
            repository: store,
            clock: clock,
            providers: ScriptedProviderSessions(status: .stopped),
            workspaces: ScriptedWorkspaces(status: .notActivelyOwned(repositoryPath: repositoryPath)),
            processes: ScriptedProcesses(status: .absent),
            recoveryID: "recovery-idempotent"
        )
        let firstReport = await recovery.reconcile(projectID: projectID)
        XCTAssertEqual(
            try entry(for: task.id, in: firstReport).disposition,
            .reconciledAndReleased(attemptID: attempt.id, generation: 1, repositoryPath: repositoryPath)
        )
        XCTAssertEqual(try entry(for: cleanTask.id, in: firstReport).disposition, .noAction)
        let settledTask = try await store.task(id: task.id)
        let settledVersion = try XCTUnwrap(settledTask).version

        let secondReport = await recovery.reconcile(projectID: projectID)
        XCTAssertEqual(try entry(for: task.id, in: secondReport).disposition, .noAction)
        XCTAssertEqual(try entry(for: cleanTask.id, in: secondReport).disposition, .noAction)
        let afterSecondTask = try await store.task(id: task.id)
        let afterSecond = try XCTUnwrap(afterSecondTask)
        XCTAssertEqual(afterSecond.version, settledVersion, "A settled task must not be transitioned again")
        XCTAssertEqual(afterSecond.status, .blocked)
        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.outcome, .cancelled)
    }

    func testSnapshotFailureIsReportedExplicitly() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let hooking = RecoveryHookingRepository(base: store)
        await hooking.setSnapshotError(.storeCorrupt("snapshot unavailable"))
        let clock = RecoveryTestClock(start: startDate)
        let recovery = makeRecovery(
            repository: hooking,
            clock: clock,
            providers: ScriptedProviderSessions(status: .stopped),
            workspaces: ScriptedWorkspaces(status: .notActivelyOwned(repositoryPath: "/tmp/never-used")),
            processes: ScriptedProcesses(status: .absent),
            recoveryID: "recovery-snapshot-failure"
        )

        let report = await recovery.reconcile(projectID: UUID())

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.failure?.contains("snapshot unavailable"), true)
    }

    func testEndAttemptFailureIsReportedExplicitly() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = RecoveryTestClock(start: startDate)
        let projectID = UUID()
        let repositoryPath = "/tmp/task-recovery-tests/end-failure-repo-\(UUID().uuidString)"
        let task = makeTask(projectID: projectID, status: .ready, title: "End attempt failure")
        try await store.createTask(task)
        let attempt = makeAttempt(
            taskID: task.id,
            sequence: 1,
            generation: 1,
            workspaceID: UUID(),
            leaseToken: "nonce-end-failure",
            leaseExpiry: startDate.addingTimeInterval(600),
            startedAt: startDate
        )
        _ = try await seedInFlightAttempt(
            store: store,
            task: task,
            attempt: attempt,
            repositoryPath: repositoryPath,
            leaseTimeoutSeconds: 3600
        )
        let hooking = RecoveryHookingRepository(base: store)
        await hooking.setEndAttemptError(.underlying("end attempt unavailable"))

        let recovery = makeRecovery(
            repository: hooking,
            clock: clock,
            providers: ScriptedProviderSessions(status: .stopped),
            workspaces: ScriptedWorkspaces(status: .notActivelyOwned(repositoryPath: repositoryPath)),
            processes: ScriptedProcesses(status: .absent),
            recoveryID: "recovery-end-failure"
        )
        let report = await recovery.reconcile(projectID: projectID)

        let recovered = try entry(for: task.id, in: report)
        guard case .failed(let reason) = recovered.disposition else {
            XCTFail("An endAttempt failure must surface as an explicit failed disposition")
            return
        }
        XCTAssertTrue(reason.contains("end attempt unavailable"))
        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.first?.outcome, .inProgress)
        let stored = try await store.task(id: task.id)
        XCTAssertEqual(stored?.status, .running)
        let challenger = try await makeChallengerTask(store: store, projectID: projectID)
        try await assertRepositoryLeaseHeld(store: store, repositoryPath: repositoryPath, challengerTaskID: challenger.id)
    }

    func testLeaseReleaseFailureIsReportedExplicitly() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = RecoveryTestClock(start: startDate)
        let projectID = UUID()
        let repositoryPath = "/tmp/task-recovery-tests/release-failure-repo-\(UUID().uuidString)"
        let task = makeTask(projectID: projectID, status: .ready, title: "Lease release failure")
        try await store.createTask(task)
        let attempt = makeAttempt(
            taskID: task.id,
            sequence: 1,
            generation: 1,
            workspaceID: UUID(),
            leaseToken: "nonce-release-failure",
            leaseExpiry: startDate.addingTimeInterval(600),
            startedAt: startDate
        )
        _ = try await seedInFlightAttempt(
            store: store,
            task: task,
            attempt: attempt,
            repositoryPath: repositoryPath,
            leaseTimeoutSeconds: 3600
        )
        let hooking = RecoveryHookingRepository(base: store)
        await hooking.setReleaseLeaseError(.underlying("lease release unavailable"))

        let recovery = makeRecovery(
            repository: hooking,
            clock: clock,
            providers: ScriptedProviderSessions(status: .stopped),
            workspaces: ScriptedWorkspaces(status: .notActivelyOwned(repositoryPath: repositoryPath)),
            processes: ScriptedProcesses(status: .absent),
            recoveryID: "recovery-release-failure"
        )
        let report = await recovery.reconcile(projectID: projectID)

        let recovered = try entry(for: task.id, in: report)
        guard case .failed(let reason) = recovered.disposition else {
            XCTFail("A lease release failure must surface as an explicit failed disposition")
            return
        }
        XCTAssertTrue(reason.contains("lease release unavailable"))
        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.first?.outcome, .cancelled)
        let stored = try await store.task(id: task.id)
        XCTAssertEqual(stored?.status, .blocked)
        let challenger = try await makeChallengerTask(store: store, projectID: projectID)
        try await assertRepositoryLeaseHeld(store: store, repositoryPath: repositoryPath, challengerTaskID: challenger.id)
    }

    // MARK: - Generation fencing, single-flight and stalled-run healing

    func testStaleReconcilePassDoesNotBlockNewerGeneration() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = RecoveryTestClock(start: startDate)
        let projectID = UUID()
        let repositoryPath = "/tmp/task-recovery-tests/stale-pass-repo-\(UUID().uuidString)"
        let task = makeTask(projectID: projectID, status: .ready, title: "Stale reconcile pass")
        try await store.createTask(task)
        let firstAttempt = makeAttempt(
            taskID: task.id,
            sequence: 1,
            generation: 1,
            workspaceID: UUID(),
            leaseToken: "nonce-generation-one",
            leaseExpiry: startDate.addingTimeInterval(600),
            startedAt: startDate
        )
        let claimed = try await seedInFlightAttempt(
            store: store,
            task: task,
            attempt: firstAttempt,
            repositoryPath: repositoryPath,
            leaseTimeoutSeconds: 3600
        )
        let gated = GatedProviderSessions()
        let recovery = makeRecovery(
            repository: store,
            clock: clock,
            providers: gated,
            workspaces: ScriptedWorkspaces(status: .notActivelyOwned(repositoryPath: repositoryPath)),
            processes: ScriptedProcesses(status: .absent),
            recoveryID: "recovery-stale-pass"
        )

        let stalePass = Task { await recovery.reconcile(projectID: projectID) }
        await gated.waitUntilSuspended()
        XCTAssertTrue(gated.isSuspended, "The first reconcile pass must park at the provider port")

        // Another actor reaps generation 1 and claims generation 2 while pass A is suspended.
        let ended = try await store.endAttempt(
            taskID: task.id,
            attemptID: firstAttempt.id,
            expectedVersion: claimed.version,
            outcome: .cancelled,
            toolCallCount: nil,
            durationSeconds: nil
        )
        try await store.releaseRepositoryLease(
            repositoryPath: repositoryPath,
            taskID: task.id,
            attemptID: firstAttempt.id
        )
        let secondAttempt = makeAttempt(
            taskID: task.id,
            sequence: 2,
            generation: 2,
            workspaceID: UUID(),
            leaseToken: "nonce-generation-two",
            leaseExpiry: startDate.addingTimeInterval(600),
            startedAt: startDate
        )
        try await store.acquireRepositoryLease(
            repositoryPath: repositoryPath,
            taskID: task.id,
            attemptID: secondAttempt.id,
            leaseTimeoutSeconds: 3600
        )
        _ = try await store.claimAttempt(taskID: task.id, expectedVersion: ended.version, attempt: secondAttempt)

        gated.release(with: .active)
        let report = await stalePass.value

        let recovered = try entry(for: task.id, in: report)
        XCTAssertEqual(
            recovered.disposition,
            .noAction,
            "A pass reconciled against generation 1 must not act on the newer generation"
        )
        XCTAssertTrue(recovered.userChoices.isEmpty)

        let stored = try await store.task(id: task.id)
        XCTAssertEqual(stored?.status, .running)
        XCTAssertEqual(stored?.currentAttemptID, secondAttempt.id)
        let history = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.first { $0.id == firstAttempt.id }?.outcome, .cancelled)
        XCTAssertEqual(history.first { $0.id == secondAttempt.id }?.outcome, .inProgress)
        XCTAssertNil(history.first { $0.id == secondAttempt.id }?.endedAt)
    }

    func testBlockFailureAfterReapIsHealedOnNextReconcile() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = RecoveryTestClock(start: startDate)
        let projectID = UUID()
        let repositoryPath = "/tmp/task-recovery-tests/heal-repo-\(UUID().uuidString)"
        let task = makeTask(projectID: projectID, status: .ready, title: "Heal stalled run")
        try await store.createTask(task)
        let attempt = makeAttempt(
            taskID: task.id,
            sequence: 1,
            generation: 1,
            workspaceID: UUID(),
            leaseToken: "nonce-heal",
            leaseExpiry: startDate.addingTimeInterval(600),
            startedAt: startDate
        )
        _ = try await seedInFlightAttempt(
            store: store,
            task: task,
            attempt: attempt,
            repositoryPath: repositoryPath,
            leaseTimeoutSeconds: 3600
        )
        let hooking = RecoveryHookingRepository(base: store)
        await hooking.setTransitionError(.underlying("transition unavailable"))

        let recovery = makeRecovery(
            repository: hooking,
            clock: clock,
            providers: ScriptedProviderSessions(status: .stopped),
            workspaces: ScriptedWorkspaces(status: .notActivelyOwned(repositoryPath: repositoryPath)),
            processes: ScriptedProcesses(status: .absent),
            recoveryID: "recovery-heal"
        )
        let firstReport = await recovery.reconcile(projectID: projectID)

        let firstEntry = try entry(for: task.id, in: firstReport)
        guard case .failed(let blockFailureReason) = firstEntry.disposition else {
            XCTFail("A block failure after a successful reap must surface explicitly")
            return
        }
        XCTAssertTrue(blockFailureReason.contains("blocking failed"))

        let stranded = try await store.task(id: task.id)
        XCTAssertEqual(stranded?.status, .running, "A failed block strands the task in running")
        XCTAssertEqual(stranded?.currentAttemptID, attempt.id)
        let strandedHistory = try await store.attemptHistory(taskID: task.id)
        XCTAssertEqual(strandedHistory.first?.outcome, .cancelled)
        let strandedSnapshot = try await store.snapshot(projectID: projectID)
        XCTAssertTrue(strandedSnapshot.activeAttempts.isEmpty)

        await hooking.setTransitionError(nil)
        let secondReport = await recovery.reconcile(projectID: projectID)

        XCTAssertEqual(
            try entry(for: task.id, in: secondReport).disposition,
            .blockedUncertain(attemptID: attempt.id),
            "The second pass must heal the stranded run"
        )
        XCTAssertEqual(secondReport.blockedUncertainTaskIDs, [task.id])
        let healed = try await store.task(id: task.id)
        XCTAssertEqual(healed?.status, .blocked)
        XCTAssertEqual(healed?.blockReason, TaskRecovery.uncertainBlockReason(for: attempt))
        XCTAssertEqual(healed?.currentAttemptID, attempt.id)
    }

    func testOverlappingReconcileIsSingleFlight() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = RecoveryTestClock(start: startDate)
        let projectID = UUID()
        let repositoryPath = "/tmp/task-recovery-tests/single-flight-repo-\(UUID().uuidString)"
        let task = makeTask(projectID: projectID, status: .ready, title: "Single flight reconcile")
        try await store.createTask(task)
        let attempt = makeAttempt(
            taskID: task.id,
            sequence: 1,
            generation: 1,
            workspaceID: UUID(),
            leaseToken: "nonce-single-flight",
            leaseExpiry: startDate.addingTimeInterval(600),
            startedAt: startDate
        )
        let claimed = try await seedInFlightAttempt(
            store: store,
            task: task,
            attempt: attempt,
            repositoryPath: repositoryPath,
            leaseTimeoutSeconds: 3600
        )
        let gated = GatedProviderSessions()
        let recovery = makeRecovery(
            repository: store,
            clock: clock,
            providers: gated,
            workspaces: ScriptedWorkspaces(status: .notActivelyOwned(repositoryPath: repositoryPath)),
            processes: ScriptedProcesses(status: .absent),
            recoveryID: "recovery-single-flight"
        )

        let firstPass = Task { await recovery.reconcile(projectID: projectID) }
        await gated.waitUntilSuspended()
        XCTAssertTrue(gated.isSuspended, "The first reconcile pass must park at the provider port")

        let busyReport = await recovery.reconcile(projectID: projectID)
        XCTAssertEqual(busyReport.failure?.contains("reconciliation already in progress"), true)

        let recovered = try entry(for: task.id, in: busyReport)
        XCTAssertEqual(recovered.disposition, .noAction)
        XCTAssertTrue(recovered.userChoices.isEmpty)
        let untouched = try await store.task(id: task.id)
        XCTAssertEqual(untouched?.status, .running)
        XCTAssertEqual(untouched?.version, claimed.version)

        gated.release(with: .active)
        let firstReport = await firstPass.value
        XCTAssertEqual(try entry(for: task.id, in: firstReport).disposition, .blockedUncertain(attemptID: attempt.id))
        let blocked = try await store.task(id: task.id)
        XCTAssertEqual(blocked?.status, .blocked)
    }

    func testLeaseReleaseFailureOffersAbandonAttemptChoice() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = RecoveryTestClock(start: startDate)
        let projectID = UUID()
        let repositoryPath = "/tmp/task-recovery-tests/release-choice-repo-\(UUID().uuidString)"
        let task = makeTask(projectID: projectID, status: .ready, title: "Lease release choice")
        try await store.createTask(task)
        let attempt = makeAttempt(
            taskID: task.id,
            sequence: 1,
            generation: 1,
            workspaceID: UUID(),
            leaseToken: "nonce-release-choice",
            leaseExpiry: startDate.addingTimeInterval(600),
            startedAt: startDate
        )
        _ = try await seedInFlightAttempt(
            store: store,
            task: task,
            attempt: attempt,
            repositoryPath: repositoryPath,
            leaseTimeoutSeconds: 3600
        )
        let hooking = RecoveryHookingRepository(base: store)
        await hooking.setReleaseLeaseError(.underlying("lease release unavailable"))

        let recovery = makeRecovery(
            repository: hooking,
            clock: clock,
            providers: ScriptedProviderSessions(status: .stopped),
            workspaces: ScriptedWorkspaces(status: .notActivelyOwned(repositoryPath: repositoryPath)),
            processes: ScriptedProcesses(status: .absent),
            recoveryID: "recovery-release-choice"
        )
        let report = await recovery.reconcile(projectID: projectID)

        let recovered = try entry(for: task.id, in: report)
        guard case .failed(let reason) = recovered.disposition else {
            XCTFail("A lease release failure must surface as an explicit failed disposition")
            return
        }
        XCTAssertTrue(reason.contains("lease release unavailable"))
        XCTAssertEqual(
            recovered.userChoices,
            [.abandonAttempt(attemptID: attempt.id)],
            "A held lease after a failed release must be actionable by hand"
        )
    }
}

extension TaskBlockReason {
    fileprivate var uncertainExecutionDetail: String? {
        guard case .uncertainExecution(let detail) = self else { return nil }
        return detail
    }
}
