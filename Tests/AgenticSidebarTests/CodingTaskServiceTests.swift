import Foundation
import XCTest

@testable import AgenticSidebar

// MARK: - Shared clocks and ports

final class ServiceTestClock: TaskSchedulerClock, @unchecked Sendable {
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
}

actor ScriptedProviderRegistry: TaskProviderRegistryPort {
    private var result: TaskProviderCandidate
    private var gatedCandidates: AsyncGate?
    private(set) var callCount = 0

    init(result: TaskProviderCandidate) {
        self.result = result
    }

    func setResult(_ result: TaskProviderCandidate) {
        self.result = result
    }

    func gateCandidates(_ gate: AsyncGate) {
        gatedCandidates = gate
    }

    func candidate(for task: CodingTask, stage: TaskStage) async -> TaskProviderCandidate {
        callCount += 1
        if let gate = gatedCandidates {
            await gate.enter()
        }
        return result
    }
}

struct FixedWorkspacePreflight: TaskWorkspacePreflightPort {
    let result: TaskWorkspacePreflightResult

    func preflight(projectID: UUID, taskID: UUID) async -> TaskWorkspacePreflightResult {
        result
    }
}

struct FixedVerifier: TaskVerifying {
    let passed: Bool

    func verify(
        task: CodingTask,
        attempt: TaskAttempt,
        workspace: TaskWorkspaceDescriptor
    ) async -> TaskVerificationReport {
        TaskVerificationReport(passed: passed, recipeName: "test-recipe", detailsRedacted: "redacted")
    }
}

struct FixedAcceptanceEvidence: TaskAcceptanceEvidenceProviding {
    let evidence: [VerificationEvidence]
    let currentFingerprint: String

    func acceptanceEvidence(taskID: UUID) async throws -> TaskAcceptanceEvidence {
        TaskAcceptanceEvidence(evidence: evidence, currentFingerprint: currentFingerprint)
    }
}

struct NoProviderSessions: TaskProviderSessionInspecting {
    func providerStatus(for attempt: TaskAttempt) async -> TaskProviderSessionStatus {
        .stopped
    }
}

struct NoWorkspaceOwnership: TaskWorkspaceOwnershipInspecting {
    func workspaceStatus(for attempt: TaskAttempt) async -> TaskWorkspaceOwnershipStatus {
        .unknown(reason: "ownership is not inspected by this test double")
    }
}

struct NoProcesses: TaskProcessOwnershipInspecting {
    func processStatus(for attempt: TaskAttempt) async -> TaskProcessOwnershipStatus {
        .absent
    }
}

// MARK: - Async gate

/// Holds repository calls open so tests can observe in-flight state before releasing them.
///
/// The gate is multi-waiter: every caller that enters before `release()` is parked and every
/// parked caller is woken by `release()`, so cross-task concurrency tests cannot deadlock on
/// an overwritten continuation.
actor AsyncGate {
    private var isReleased = false
    private var enteredCount = 0
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []

    func currentEnteredCount() -> Int {
        enteredCount
    }

    func enter() async {
        enteredCount += 1
        let waiters = enteredContinuations
        enteredContinuations = []
        for waiter in waiters {
            waiter.resume()
        }
        if isReleased {
            return
        }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    /// Suspends until at least `count` callers have entered the gate.
    func waitUntilEntered(count: Int) async {
        while enteredCount < count {
            await withCheckedContinuation { continuation in
                enteredContinuations.append(continuation)
            }
        }
    }

    func waitUntilEntered() async {
        await waitUntilEntered(count: 1)
    }

    func release() {
        isReleased = true
        let waiters = releaseContinuations
        releaseContinuations = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}

// MARK: - Hooking repository

struct RepositoryMutationCounts: Equatable, Sendable {
    let snapshots: Int
    let taskReads: Int
    let createTask: Int
    let addDependency: Int
    let transitions: Int
    let claimAttempts: Int
    let endAttempts: Int
    let recordedEvidence: Int
    let recordedApprovals: Int
}

/// Wraps a real in-memory store, counts every call and can hold or fail selected calls.
actor ServiceHookingRepository: CodingTaskRepository {
    private let base: SQLiteTaskStore
    private var gatedTaskReads: AsyncGate?
    private var gatedSnapshots: AsyncGate?
    private var nextClaimAttemptFailure: TaskRepositoryError?
    private var nextSnapshotFailure: TaskRepositoryError?
    private var nextTransitionFailure: TaskRepositoryError?
    private var nextTaskReadFailure: Error?
    private var nextAttemptHistoryFailure: Error?
    private var nextRepositoryLeaseFailure: TaskRepositoryError?
    private var snapshotCount = 0
    private var taskReadCount = 0
    private var createTaskCount = 0
    private var addDependencyCount = 0
    private var transitionCount = 0
    private var claimAttemptCount = 0
    private var endAttemptCount = 0
    private var recordEvidenceCount = 0
    private var recordApprovalCount = 0

    init(base: SQLiteTaskStore) {
        self.base = base
    }

    func gateTaskReads(_ gate: AsyncGate) {
        gatedTaskReads = gate
    }

    func gateSnapshots(_ gate: AsyncGate) {
        gatedSnapshots = gate
    }

    func failNextClaimAttempt(with error: TaskRepositoryError) {
        nextClaimAttemptFailure = error
    }

    func failNextSnapshot(with error: TaskRepositoryError) {
        nextSnapshotFailure = error
    }

    func failNextTransition(with error: TaskRepositoryError) {
        nextTransitionFailure = error
    }

    func failNextTaskRead(with error: Error) {
        nextTaskReadFailure = error
    }

    func failNextAttemptHistory(with error: TaskRepositoryError) {
        nextAttemptHistoryFailure = error
    }

    func failNextRepositoryLease(with error: TaskRepositoryError) {
        nextRepositoryLeaseFailure = error
    }

    func mutationCounts() -> RepositoryMutationCounts {
        RepositoryMutationCounts(
            snapshots: snapshotCount,
            taskReads: taskReadCount,
            createTask: createTaskCount,
            addDependency: addDependencyCount,
            transitions: transitionCount,
            claimAttempts: claimAttemptCount,
            endAttempts: endAttemptCount,
            recordedEvidence: recordEvidenceCount,
            recordedApprovals: recordApprovalCount
        )
    }

    func snapshot(projectID: UUID) async throws -> CodingBoardSnapshot {
        snapshotCount += 1
        if let gate = gatedSnapshots {
            await gate.enter()
        }
        if let failure = nextSnapshotFailure {
            nextSnapshotFailure = nil
            throw failure
        }
        return try await base.snapshot(projectID: projectID)
    }

    func createTask(_ task: CodingTask) async throws {
        createTaskCount += 1
        try await base.createTask(task)
    }

    func addDependency(_ dependency: TaskDependency) async throws {
        addDependencyCount += 1
        try await base.addDependency(dependency)
    }

    func task(id: UUID) async throws -> CodingTask? {
        taskReadCount += 1
        if let gate = gatedTaskReads {
            await gate.enter()
        }
        if let failure = nextTaskReadFailure {
            nextTaskReadFailure = nil
            throw failure
        }
        return try await base.task(id: id)
    }

    func attemptHistory(taskID: UUID) async throws -> [TaskAttempt] {
        if let failure = nextAttemptHistoryFailure {
            nextAttemptHistoryFailure = nil
            throw failure
        }
        return try await base.attemptHistory(taskID: taskID)
    }

    func transition(
        taskID: UUID,
        expectedVersion: Int,
        action: TaskAction,
        context: TaskTransitionContext
    ) async throws -> CodingTask {
        transitionCount += 1
        if let failure = nextTransitionFailure {
            nextTransitionFailure = nil
            throw failure
        }
        return try await base.transition(taskID: taskID, expectedVersion: expectedVersion, action: action, context: context)
    }

    func claimAttempt(
        taskID: UUID,
        expectedVersion: Int,
        attempt: TaskAttempt
    ) async throws -> TaskAttempt {
        claimAttemptCount += 1
        if let failure = nextClaimAttemptFailure {
            nextClaimAttemptFailure = nil
            throw failure
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
        endAttemptCount += 1
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
        if let failure = nextRepositoryLeaseFailure {
            nextRepositoryLeaseFailure = nil
            throw failure
        }
        try await base.acquireRepositoryLease(
            repositoryPath: repositoryPath,
            taskID: taskID,
            attemptID: attemptID,
            leaseTimeoutSeconds: leaseTimeoutSeconds
        )
    }

    func releaseRepositoryLease(repositoryPath: String, taskID: UUID, attemptID: UUID) async throws {
        try await base.releaseRepositoryLease(repositoryPath: repositoryPath, taskID: taskID, attemptID: attemptID)
    }

    func appendEvent(_ event: CodingTaskEvent) async throws {
        try await base.appendEvent(event)
    }

    func recordEvidence(_ evidence: VerificationEvidence) async throws {
        recordEvidenceCount += 1
        try await base.recordEvidence(evidence)
    }

    func recordFinding(_ finding: ReviewFinding) async throws {
        try await base.recordFinding(finding)
    }

    func findings(taskID: UUID) async throws -> [ReviewFinding] {
        try await base.findings(taskID: taskID)
    }

    func dismissFinding(
        findingID: UUID,
        actor: String,
        reason: String,
        at date: Date
    ) async throws -> ReviewFinding {
        try await base.dismissFinding(findingID: findingID, actor: actor, reason: reason, at: date)
    }

    func recordApproval(_ approval: TaskApproval) async throws {
        recordApprovalCount += 1
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

// MARK: - Fixtures and harness

enum TaskBoardServiceFixtures {
    static let startDate = Date(timeIntervalSince1970: 1_700_000_000)

    static let ownedWorkspace = TaskWorkspaceDescriptor(
        workspaceID: UUID(),
        workspacePath: "/tmp/agentic-sidebar-service-tests/workspace",
        repositoryPath: "/tmp/agentic-sidebar-service-tests/repo"
    )
}

final class ServiceTestHarness {
    let store: SQLiteTaskStore
    let repository: ServiceHookingRepository
    let clock: ServiceTestClock
    let providers: ScriptedProviderRegistry
    let scheduler: TaskScheduler
    var workspaceResult: TaskWorkspacePreflightResult
    var verifierPassed = true
    var acceptanceEvidence: [VerificationEvidence] = []
    var currentFingerprint = "fingerprint-1"
    var requiredSteps = ["build"]

    init(workspace: TaskWorkspacePreflightResult) throws {
        let store = try SQLiteTaskStore.inMemory()
        let repository = ServiceHookingRepository(base: store)
        let clock = ServiceTestClock(start: TaskBoardServiceFixtures.startDate)
        let providers = ScriptedProviderRegistry(result: .eligible(runtimeID: "runtime-1", modelID: "model-1"))
        self.store = store
        self.repository = repository
        self.clock = clock
        self.providers = providers
        self.workspaceResult = workspace
        self.scheduler = TaskScheduler(
            repository: repository,
            providers: providers,
            workspaces: FixedWorkspacePreflight(result: workspace),
            verifier: FixedVerifier(passed: true),
            clock: clock,
            schedulerID: "scheduler-test",
            provisioning: nil
        )
    }

    func makeService() -> CodingTaskService {
        let recovery = TaskRecovery(
            repository: repository,
            providers: NoProviderSessions(),
            workspaces: NoWorkspaceOwnership(),
            processes: NoProcesses(),
            clock: clock,
            recoveryID: "recovery-test"
        )
        return CodingTaskService(
            repository: repository,
            scheduler: scheduler,
            recovery: recovery,
            providers: providers,
            acceptanceEvidence: FixedAcceptanceEvidence(
                evidence: acceptanceEvidence,
                currentFingerprint: currentFingerprint
            ),
            clock: clock,
            requiredSteps: requiredSteps
        )
    }

    /// Seeds a running task with one in-progress attempt and moves it into review.
    func seedReviewTask(
        projectID: UUID,
        criteriaCompleted: Bool,
        evidence: [VerificationEvidence]
    ) async throws -> (task: CodingTask, attempt: TaskAttempt) {
        let taskID = UUID()
        let attemptID = UUID()
        let now = clock.now()
        let task = CodingTask(
            id: taskID,
            projectID: projectID,
            title: "Review task",
            objective: "Review task objective",
            priority: 1,
            status: .running,
            stage: .implementation,
            version: 1,
            criteria: [
                CodingAcceptanceCriterion(taskID: taskID, description: "criterion", isCompleted: criteriaCompleted)
            ],
            currentAttemptID: attemptID,
            createdAt: now,
            updatedAt: now
        )
        try await store.createTask(task)
        let attempt = TaskAttempt(
            id: attemptID,
            taskID: taskID,
            attemptSequence: 1,
            role: .developer,
            providerID: "runtime-1",
            modelID: "model-1",
            generation: 1,
            startedAt: now
        )
        _ = try await store.claimAttempt(taskID: taskID, expectedVersion: 1, attempt: attempt)
        for entry in evidence {
            try await store.recordEvidence(entry)
        }
        let submittedEvidenceIDs = evidence.isEmpty ? [UUID()] : evidence.map(\.id)
        _ = try await store.transition(
            taskID: taskID,
            expectedVersion: 2,
            action: .submitForReview,
            context: TaskTransitionContext(
                fingerprint: attemptID.uuidString,
                actor: "agent",
                evidenceIDs: submittedEvidenceIDs
            )
        )
        let fetched = try await store.task(id: taskID)
        let reloaded = try XCTUnwrap(fetched)
        return (reloaded, attempt)
    }
}

// MARK: - Service tests

final class CodingTaskServiceTests: XCTestCase {

    private func makeProject(service: CodingTaskService) async throws -> CodingProject {
        try await service.createProject(
            name: "Board",
            repositoryPath: "/tmp/agentic-sidebar-service-tests/repo",
            gitIdentity: "dev@example.com",
            protectedRefs: ["main"]
        )
    }

    func testCreateProjectRejectsBlankInputAndRegistersProject() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()

        do {
            _ = try await service.createProject(
                name: "   ",
                repositoryPath: "/tmp/repo",
                gitIdentity: "dev@example.com",
                protectedRefs: ["main"]
            )
            XCTFail("A blank project name must be rejected")
        } catch {
            XCTAssertEqual(error as? CodingTaskServiceError, .invalidProjectInput(field: "name", reason: "must not be blank"))
        }

        let project = try await makeProject(service: service)
        let reloaded = await service.project(id: project.id)
        XCTAssertEqual(reloaded, project)
    }

    func testCreateTaskRejectsBlankObjectiveAndUnknownProject() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)

        do {
            _ = try await service.createTask(projectID: project.id, title: "Title", objective: "  ", priority: 1, criteria: [])
            XCTFail("A blank objective must be rejected")
        } catch {
            XCTAssertEqual(error as? CodingTaskServiceError, .invalidTaskInput(field: "objective", reason: "must not be blank"))
        }

        let unknownProjectID = UUID()
        do {
            _ = try await service.createTask(
                projectID: unknownProjectID,
                title: "Title",
                objective: "Objective",
                priority: 1,
                criteria: []
            )
            XCTFail("An unknown project must be rejected")
        } catch {
            XCTAssertEqual(error as? CodingTaskServiceError, .projectNotFound(unknownProjectID))
        }

        let counts = await harness.repository.mutationCounts()
        XCTAssertEqual(counts.createTask, 0)
    }

    func testCreateTaskPersistsCriteriaAndReloadsWithFidelity() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)

        let task = try await service.createTask(
            projectID: project.id,
            title: "Ship board",
            objective: "Expose the board",
            priority: 7,
            criteria: ["first", "second"]
        )
        XCTAssertEqual(task.status, .backlog)
        XCTAssertEqual(task.stage, .analysis)
        XCTAssertEqual(task.version, 1)
        XCTAssertEqual(task.criteria.map(\.description), ["first", "second"])

        let snapshot = try await service.snapshot(projectID: project.id)
        let reloaded = try XCTUnwrap(snapshot.tasks.first)
        XCTAssertEqual(reloaded.id, task.id)
        XCTAssertEqual(reloaded.title, "Ship board")
        XCTAssertEqual(reloaded.objective, "Expose the board")
        XCTAssertEqual(reloaded.priority, 7)
        XCTAssertEqual(reloaded.status, .backlog)
        XCTAssertEqual(reloaded.stage, .analysis)
        XCTAssertEqual(reloaded.version, 1)
        XCTAssertEqual(reloaded.criteria.map(\.description), ["first", "second"])
    }

    func testAddDependencyRejectsSelfEdgesCyclesAndDuplicates() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let first = try await service.createTask(projectID: project.id, title: "First", objective: "A", priority: 1, criteria: [])
        let second = try await service.createTask(projectID: project.id, title: "Second", objective: "B", priority: 1, criteria: [])

        do {
            _ = try await service.addDependency(
                projectID: project.id,
                prerequisiteTaskID: first.id,
                dependentTaskID: first.id
            )
            XCTFail("A self edge must be rejected")
        } catch let error as CodingTaskServiceError {
            guard case .dependencyRejected = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }

        _ = try await service.addDependency(projectID: project.id, prerequisiteTaskID: first.id, dependentTaskID: second.id)

        do {
            _ = try await service.addDependency(
                projectID: project.id,
                prerequisiteTaskID: second.id,
                dependentTaskID: first.id
            )
            XCTFail("A cycle must be rejected")
        } catch let error as CodingTaskServiceError {
            guard case .dependencyRejected = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }

        do {
            _ = try await service.addDependency(
                projectID: project.id,
                prerequisiteTaskID: first.id,
                dependentTaskID: second.id
            )
            XCTFail("A duplicate edge must be rejected")
        } catch let error as CodingTaskServiceError {
            guard case .dependencyRejected = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }

        let snapshot = try await service.snapshot(projectID: project.id)
        XCTAssertEqual(snapshot.dependencies.count, 1)
        XCTAssertEqual(snapshot.dependencies.first?.prerequisiteTaskID, first.id)
    }

    func testStartRejectsStaleVersionWithoutMutating() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await service.createTask(projectID: project.id, title: "Task", objective: "Objective", priority: 1, criteria: [])

        do {
            _ = try await service.start(taskID: task.id, expectedVersion: 0)
            XCTFail("A stale expected version must be rejected")
        } catch {
            XCTAssertEqual(
                error as? CodingTaskServiceError,
                .staleVersion(taskID: task.id, expected: 0, actual: 1)
            )
        }

        let counts = await harness.repository.mutationCounts()
        XCTAssertEqual(counts.claimAttempts, 0)
        XCTAssertEqual(counts.transitions, 0)
        let reloaded = try await service.snapshot(projectID: project.id).tasks.first
        XCTAssertEqual(reloaded?.status, .backlog)
        XCTAssertEqual(reloaded?.version, 1)
    }

    func testStartWithoutEligibleRuntimeDoesNotDispatch() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await service.createTask(projectID: project.id, title: "Task", objective: "Objective", priority: 1, criteria: [])

        await harness.providers.setResult(.unavailable(reason: "no eligible runtime"))
        let unavailableResult = try await service.start(taskID: task.id, expectedVersion: 1)
        XCTAssertEqual(unavailableResult, .unavailable(.providerUnavailable(reason: "no eligible runtime")))

        await harness.providers.setResult(.unsupported(missingCapabilities: ["toolUse"]))
        let unsupportedResult = try await service.start(taskID: task.id, expectedVersion: 1)
        XCTAssertEqual(unsupportedResult, .unavailable(.unsupported(missingCapabilities: ["toolUse"])))

        let counts = await harness.repository.mutationCounts()
        XCTAssertEqual(counts.claimAttempts, 0)
        XCTAssertEqual(counts.transitions, 0)
        let reloaded = try await service.snapshot(projectID: project.id).tasks.first
        XCTAssertEqual(reloaded?.status, .backlog)
        XCTAssertEqual(reloaded?.version, 1)
    }

    func testStartDefersHonestlyWhenWorkspaceIsNotOwned() async throws {
        let harness = try ServiceTestHarness(workspace: .notOwned(reason: "no manifest"))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await service.createTask(projectID: project.id, title: "Task", objective: "Objective", priority: 1, criteria: [])

        let result = try await service.start(taskID: task.id, expectedVersion: 1)
        XCTAssertEqual(result, .deferred(reason: "workspaceNotOwned"))

        let counts = await harness.repository.mutationCounts()
        XCTAssertEqual(counts.claimAttempts, 0)
        let reloaded = try await service.snapshot(projectID: project.id).tasks.first
        XCTAssertEqual(reloaded?.status, .ready)
    }

    func testStartClaimsAttemptWhenRuntimeAndWorkspaceAreEligible() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await service.createTask(projectID: project.id, title: "Task", objective: "Objective", priority: 1, criteria: [])

        let result = try await service.start(taskID: task.id, expectedVersion: 1)
        guard case .claimed(let attemptID, let generation) = result else {
            XCTFail("Expected a claim, got \(result)")
            return
        }
        XCTAssertEqual(generation, 1)

        let reloadedSnapshot = try await service.snapshot(projectID: project.id)
        let reloaded = try XCTUnwrap(reloadedSnapshot.tasks.first)
        XCTAssertEqual(reloaded.status, .running)
        XCTAssertEqual(reloaded.currentAttemptID, attemptID)
        let history = try await harness.store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.map(\.outcome), [.inProgress])
        XCTAssertEqual(history.first?.generation, 1)
    }

    func testConcurrentActionsForSameTaskAreDeduplicated() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await service.createTask(projectID: project.id, title: "Task", objective: "Objective", priority: 1, criteria: [])

        let gate = AsyncGate()
        await harness.repository.gateTaskReads(gate)
        let first = Task { try await service.start(taskID: task.id, expectedVersion: 1) }
        await gate.waitUntilEntered()

        do {
            _ = try await service.start(taskID: task.id, expectedVersion: 1)
            XCTFail("A duplicate action for the same task must be rejected")
        } catch {
            XCTAssertEqual(error as? CodingTaskServiceError, .actionAlreadyInFlight(taskID: task.id))
        }

        await gate.release()
        let result = try await first.value
        guard case .claimed = result else {
            XCTFail("Expected the first action to claim, got \(result)")
            return
        }
        let counts = await harness.repository.mutationCounts()
        XCTAssertEqual(counts.claimAttempts, 1)
    }

    func testRetryRejectsMismatchedActiveAttemptWithoutCancellingIt() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await service.createTask(projectID: project.id, title: "Task", objective: "Objective", priority: 1, criteria: [])

        let startResult = try await service.start(taskID: task.id, expectedVersion: 1)
        guard case .claimed(let activeAttemptID, let activeGeneration) = startResult else {
            XCTFail("Expected a claim, got \(startResult)")
            return
        }

        do {
            _ = try await service.retry(
                taskID: task.id,
                expectedActiveAttemptID: UUID(),
                expectedActiveGeneration: activeGeneration
            )
            XCTFail("A mismatched active attempt must be rejected")
        } catch let error as CodingTaskServiceError {
            guard case .staleAttempt(let taskID, let expected, let actual) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(taskID, task.id)
            XCTAssertNotEqual(expected, activeAttemptID)
            XCTAssertEqual(actual, activeAttemptID)
        }

        do {
            _ = try await service.retry(
                taskID: task.id,
                expectedActiveAttemptID: nil,
                expectedActiveGeneration: nil
            )
            XCTFail("Omitting the active attempt while one exists must be rejected")
        } catch let error as CodingTaskServiceError {
            guard case .staleAttempt = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }

        let untouched = try await harness.store.attemptHistory(taskID: task.id)
        XCTAssertEqual(untouched.count, 1)
        XCTAssertEqual(untouched.first?.outcome, .inProgress)
        XCTAssertEqual(untouched.first?.id, activeAttemptID)

        let retryResult = try await service.retry(
            taskID: task.id,
            expectedActiveAttemptID: activeAttemptID,
            expectedActiveGeneration: activeGeneration
        )
        guard case .claimed(_, let retriedGeneration) = retryResult.disposition else {
            XCTFail("Expected a retried claim, got \(retryResult)")
            return
        }
        XCTAssertEqual(retriedGeneration, 2)
        let history = try await harness.store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.map(\.outcome), [.cancelled, .inProgress])
    }

    func testSchedulerFencedRetryRefusesMismatchedActiveAttemptWithoutCancelling() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await service.createTask(projectID: project.id, title: "Task", objective: "Objective", priority: 1, criteria: [])

        let startResult = try await service.start(taskID: task.id, expectedVersion: 1)
        guard case .claimed(let activeAttemptID, let activeGeneration) = startResult else {
            XCTFail("Expected a claim, got \(startResult)")
            return
        }

        do {
            _ = try await harness.scheduler.retry(
                taskID: task.id,
                expectedAttemptID: UUID(),
                expectedGeneration: activeGeneration
            )
            XCTFail("A mismatched active attempt must be refused inside the scheduler")
        } catch let error as TaskSchedulerError {
            guard
                case .staleAttempt(let taskID, let expected, let expectedGeneration, let actual, let actualGeneration) = error
            else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(taskID, task.id)
            XCTAssertNotEqual(expected, activeAttemptID)
            XCTAssertEqual(expectedGeneration, activeGeneration)
            XCTAssertEqual(actual, activeAttemptID)
            XCTAssertEqual(actualGeneration, activeGeneration)
        }

        do {
            _ = try await harness.scheduler.retry(taskID: task.id, expectedAttemptID: activeAttemptID, expectedGeneration: nil)
            XCTFail("Omitting the active generation while one exists must be refused inside the scheduler")
        } catch let error as TaskSchedulerError {
            guard case .staleAttempt = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }

        let untouched = try await harness.store.attemptHistory(taskID: task.id)
        XCTAssertEqual(untouched.map(\.outcome), [.inProgress])
        XCTAssertEqual(untouched.first?.id, activeAttemptID)

        let retried = try await harness.scheduler.retry(
            taskID: task.id,
            expectedAttemptID: activeAttemptID,
            expectedGeneration: activeGeneration
        )
        guard case .claimed(_, let retriedGeneration) = retried.disposition else {
            XCTFail("Expected a fenced retried claim, got \(retried)")
            return
        }
        XCTAssertEqual(retriedGeneration, activeGeneration + 1)
        let history = try await harness.store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.map(\.outcome), [.cancelled, .inProgress])
    }

    /// A concurrent claim that lands after `start` read the task must never be cancelled:
    /// the fenced no-active-attempt expectation refuses with a typed stale error instead.
    func testStartDoesNotCancelAttemptClaimedAfterGuard() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await service.createTask(projectID: project.id, title: "Task", objective: "Objective", priority: 1, criteria: [])
        _ = try await harness.store.transition(
            taskID: task.id,
            expectedVersion: 1,
            action: .markReady,
            context: TaskTransitionContext(fingerprint: "agent", actor: "agent")
        )

        let gate = AsyncGate()
        await harness.providers.gateCandidates(gate)
        let start = Task { try await service.start(taskID: task.id, expectedVersion: 2) }
        await gate.waitUntilEntered()

        let foreignAttemptID = UUID()
        let foreignAttempt = TaskAttempt(
            id: foreignAttemptID,
            taskID: task.id,
            attemptSequence: 1,
            role: .developer,
            providerID: "runtime-1",
            modelID: "model-1",
            generation: 1,
            startedAt: harness.clock.now()
        )
        _ = try await harness.store.claimAttempt(taskID: task.id, expectedVersion: 2, attempt: foreignAttempt)

        await gate.release()
        do {
            _ = try await start.value
            XCTFail("A start that lost the race to another claim must be refused")
        } catch let error as CodingTaskServiceError {
            guard case .staleAttempt(let taskID, let expected, let actual) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(taskID, task.id)
            XCTAssertNil(expected)
            XCTAssertEqual(actual, foreignAttemptID)
        }

        let history = try await harness.store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.map(\.outcome), [.inProgress], "The concurrent claim must survive the stale start")
        XCTAssertEqual(history.first?.id, foreignAttemptID)
        let reloaded = try await harness.store.task(id: task.id)
        XCTAssertEqual(reloaded?.currentAttemptID, foreignAttemptID)
    }

    func testBackendClaimRejectionIsNotReportedAsSuccess() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await service.createTask(projectID: project.id, title: "Task", objective: "Objective", priority: 1, criteria: [])

        await harness.repository.failNextClaimAttempt(with: .taskNotClaimable(taskID: task.id, status: .ready))
        let result = try await service.start(taskID: task.id, expectedVersion: 1)
        XCTAssertEqual(result, .deferred(reason: "claimRejected"))

        let history = try await harness.store.attemptHistory(taskID: task.id)
        XCTAssertTrue(history.isEmpty)
    }

    func testAcceptDeniedWhenGateBlocksWithoutMutation() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let seeded = try await harness.seedReviewTask(projectID: project.id, criteriaCompleted: false, evidence: [])

        do {
            _ = try await service.accept(taskID: seeded.task.id, expectedVersion: seeded.task.version, actor: "reviewer")
            XCTFail("A blocked acceptance must be denied")
        } catch let error as CodingTaskServiceError {
            guard case .acceptanceDenied(let taskID, let reasons) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(taskID, seeded.task.id)
            XCTAssertFalse(reasons.isEmpty)
        }

        let counts = await harness.repository.mutationCounts()
        XCTAssertEqual(counts.recordedApprovals, 0)
        let reloaded = try await harness.store.task(id: seeded.task.id)
        XCTAssertEqual(reloaded?.status, .review)
        XCTAssertEqual(reloaded?.version, seeded.task.version)
    }

    func testAcceptRecordsHumanApprovalAndCompletes() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let projectID = UUID()
        let seeded = try await harness.seedReviewTask(projectID: projectID, criteriaCompleted: true, evidence: [])
        let evidence = VerificationEvidence(
            taskID: seeded.task.id,
            attemptID: seeded.attempt.id,
            recipeName: "test-recipe",
            stepName: "build",
            status: .passed,
            detailsRedacted: "redacted",
            workspaceFingerprint: harness.currentFingerprint,
            recordedAt: harness.clock.now(),
            recipeVersion: VerificationRecipe.currentVersion
        )
        harness.acceptanceEvidence = [evidence]
        let service = harness.makeService()

        let decision = try await service.evaluateAcceptance(taskID: seeded.task.id)
        XCTAssertEqual(decision, .readyForHumanReview)

        let accepted = try await service.accept(taskID: seeded.task.id, expectedVersion: seeded.task.version, actor: "reviewer")
        XCTAssertEqual(accepted.status, .done)

        let approvals = try await harness.store.approvals(taskID: seeded.task.id)
        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(approvals.first?.actor, "reviewer")
        XCTAssertEqual(approvals.first?.action, .accept)
        XCTAssertEqual(approvals.first?.attemptID, seeded.attempt.id)
        XCTAssertEqual(approvals.first?.fingerprint, harness.currentFingerprint)
    }

    func testAcceptRejectsBlankActor() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let seeded = try await harness.seedReviewTask(projectID: project.id, criteriaCompleted: true, evidence: [])

        do {
            _ = try await service.accept(taskID: seeded.task.id, expectedVersion: seeded.task.version, actor: "   ")
            XCTFail("A blank actor must be rejected")
        } catch {
            XCTAssertEqual(error as? CodingTaskServiceError, .invalidTaskInput(field: "actor", reason: "must not be blank"))
        }

        let counts = await harness.repository.mutationCounts()
        XCTAssertEqual(counts.recordedApprovals, 0)
    }

    func testStopAfterTaskAdvancedToReviewIsRefusedWithoutMutatingState() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await service.createTask(projectID: project.id, title: "Task", objective: "Objective", priority: 1, criteria: [])

        let startResult = try await service.start(taskID: task.id, expectedVersion: 1)
        guard case .claimed(let attemptID, _) = startResult else {
            XCTFail("Expected a claim, got \(startResult)")
            return
        }
        let fetchedRunning = try await harness.store.task(id: task.id)
        let running = try XCTUnwrap(fetchedRunning)
        XCTAssertEqual(running.status, .running)

        _ = try await harness.store.transition(
            taskID: task.id,
            expectedVersion: running.version,
            action: .submitForReview,
            context: TaskTransitionContext(fingerprint: attemptID.uuidString, actor: "agent", evidenceIDs: [UUID()])
        )

        do {
            try await service.stop(taskID: task.id, expectedVersion: running.version, expectedAttemptID: attemptID)
            XCTFail("A stop based on a stale running view must be refused")
        } catch {
            XCTAssertEqual(
                error as? CodingTaskServiceError,
                .staleVersion(taskID: task.id, expected: running.version, actual: running.version + 1)
            )
        }

        do {
            try await service.stop(taskID: task.id, expectedVersion: running.version + 1, expectedAttemptID: attemptID)
            XCTFail("Stop must not be available for a review task")
        } catch {
            XCTAssertEqual(error as? CodingTaskServiceError, .actionNotAvailable(taskID: task.id, status: .review))
        }

        let fetchedAfter = try await harness.store.task(id: task.id)
        let after = try XCTUnwrap(fetchedAfter)
        XCTAssertEqual(after.status, .review)
        XCTAssertEqual(after.version, running.version + 1)
        XCTAssertNil(after.blockReason)
        let history = try await harness.store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.map(\.outcome), [.inProgress])
        XCTAssertEqual(history.first?.id, attemptID)
    }

    func testPauseSuspendsRunningTaskAndRejectsStaleAttempt() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await service.createTask(projectID: project.id, title: "Task", objective: "Objective", priority: 1, criteria: [])

        let startResult = try await service.start(taskID: task.id, expectedVersion: 1)
        guard case .claimed(let attemptID, _) = startResult else {
            XCTFail("Expected a claim, got \(startResult)")
            return
        }

        let wrongAttemptID = UUID()
        do {
            try await service.pause(taskID: task.id, expectedAttemptID: wrongAttemptID)
            XCTFail("A mismatched attempt must be refused")
        } catch {
            XCTAssertEqual(
                error as? CodingTaskServiceError,
                .staleAttempt(taskID: task.id, expectedAttemptID: wrongAttemptID, actualAttemptID: attemptID)
            )
        }

        try await service.pause(taskID: task.id, expectedAttemptID: attemptID)
        let fetched = try await harness.store.task(id: task.id)
        let paused = try XCTUnwrap(fetched)
        XCTAssertEqual(paused.status, .blocked)
        XCTAssertEqual(paused.blockReason, .custom(TaskScheduler.pausedBlockReason))
        let history = try await harness.store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.map(\.outcome), [.inProgress])
    }

    func testStopCancelsActiveAttemptAndRejectsMismatchedAttempt() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await service.createTask(projectID: project.id, title: "Task", objective: "Objective", priority: 1, criteria: [])

        let startResult = try await service.start(taskID: task.id, expectedVersion: 1)
        guard case .claimed(let attemptID, _) = startResult else {
            XCTFail("Expected a claim, got \(startResult)")
            return
        }
        let fetchedRunning = try await harness.store.task(id: task.id)
        let running = try XCTUnwrap(fetchedRunning)

        let wrongAttemptID = UUID()
        do {
            try await service.stop(taskID: task.id, expectedVersion: running.version, expectedAttemptID: wrongAttemptID)
            XCTFail("A mismatched attempt must be refused")
        } catch {
            XCTAssertEqual(
                error as? CodingTaskServiceError,
                .staleAttempt(taskID: task.id, expectedAttemptID: wrongAttemptID, actualAttemptID: attemptID)
            )
        }
        let untouched = try await harness.store.attemptHistory(taskID: task.id)
        XCTAssertEqual(untouched.map(\.outcome), [.inProgress])

        try await service.stop(taskID: task.id, expectedVersion: running.version, expectedAttemptID: attemptID)
        let fetchedStopped = try await harness.store.task(id: task.id)
        let stopped = try XCTUnwrap(fetchedStopped)
        XCTAssertEqual(stopped.status, .blocked)
        XCTAssertEqual(stopped.blockReason, .custom(TaskScheduler.stoppedBlockReason))
        let history = try await harness.store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.map(\.outcome), [.cancelled])
    }

    func testResumeReArmsPausedAndStoppedTasks() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await service.createTask(projectID: project.id, title: "Task", objective: "Objective", priority: 1, criteria: [])

        let startResult = try await service.start(taskID: task.id, expectedVersion: 1)
        guard case .claimed(let firstAttemptID, let firstGeneration) = startResult else {
            XCTFail("Expected a claim, got \(startResult)")
            return
        }
        try await service.pause(taskID: task.id, expectedAttemptID: firstAttemptID)
        let fetchedPaused = try await harness.store.task(id: task.id)
        let paused = try XCTUnwrap(fetchedPaused)

        let resumedEntry = try await service.resume(
            taskID: task.id,
            expectedVersion: paused.version,
            expectedAttemptID: firstAttemptID
        )
        guard case .claimed(let resumedAttemptID, let resumedGeneration) = resumedEntry.disposition else {
            XCTFail("Expected a resumed claim, got \(resumedEntry)")
            return
        }
        XCTAssertEqual(resumedGeneration, firstGeneration + 1)
        let resumedHistory = try await harness.store.attemptHistory(taskID: task.id)
        XCTAssertEqual(resumedHistory.map(\.outcome), [.cancelled, .inProgress])
        XCTAssertEqual(resumedHistory.last?.id, resumedAttemptID)

        let fetchedRunning = try await harness.store.task(id: task.id)
        let running = try XCTUnwrap(fetchedRunning)
        XCTAssertEqual(running.status, .running)
        try await service.stop(taskID: task.id, expectedVersion: running.version, expectedAttemptID: resumedAttemptID)
        let fetchedStopped = try await harness.store.task(id: task.id)
        let stopped = try XCTUnwrap(fetchedStopped)
        XCTAssertEqual(stopped.blockReason, .custom(TaskScheduler.stoppedBlockReason))

        let stoppedEntry = try await service.resume(
            taskID: task.id,
            expectedVersion: stopped.version,
            expectedAttemptID: nil
        )
        guard case .claimed = stoppedEntry.disposition else {
            XCTFail("A stopped task must be resumable, got \(stoppedEntry)")
            return
        }
        let finalHistory = try await harness.store.attemptHistory(taskID: task.id)
        XCTAssertEqual(finalHistory.map(\.outcome), [.cancelled, .cancelled, .inProgress])
    }

    func testResumeRefusesSystemBlocksWithoutMutating() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)

        let blockReasons: [TaskBlockReason] = [
            .uncertainExecution("agent vanished"),
            .verificationFailed("build failed"),
            .custom("attemptBudgetExhausted"),
        ]
        for reason in blockReasons {
            let taskID = UUID()
            let now = harness.clock.now()
            let blocked = CodingTask(
                id: taskID,
                projectID: project.id,
                title: "Blocked",
                objective: "Objective",
                priority: 1,
                status: .blocked,
                stage: .implementation,
                blockReason: reason,
                previousStageBeforeBlock: .implementation,
                version: 1,
                createdAt: now,
                updatedAt: now
            )
            try await harness.store.createTask(blocked)

            do {
                _ = try await service.resume(taskID: taskID, expectedVersion: 1, expectedAttemptID: nil)
                XCTFail("Resume must be refused for block reason \(reason)")
            } catch {
                XCTAssertEqual(error as? CodingTaskServiceError, .actionNotAvailable(taskID: taskID, status: .blocked))
            }

            let fetched = try await harness.store.task(id: taskID)
            let reloaded = try XCTUnwrap(fetched)
            XCTAssertEqual(reloaded.status, .blocked)
            XCTAssertEqual(reloaded.blockReason, reason)
            XCTAssertEqual(reloaded.version, 1)
        }

        let counts = await harness.repository.mutationCounts()
        XCTAssertEqual(counts.claimAttempts, 0)
        XCTAssertEqual(counts.transitions, 0)
    }

    func testRequestChangesSendsReviewBackToReadyAndRejectsWrongStatusAndBlankInput() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let seeded = try await harness.seedReviewTask(projectID: project.id, criteriaCompleted: false, evidence: [])

        let changed = try await service.requestChanges(
            taskID: seeded.task.id,
            expectedVersion: seeded.task.version,
            actor: "reviewer",
            feedback: "please fix the build"
        )
        XCTAssertEqual(changed.status, .ready)
        XCTAssertEqual(changed.stage, .plan)
        XCTAssertEqual(changed.version, seeded.task.version + 1)

        do {
            _ = try await service.requestChanges(
                taskID: seeded.task.id,
                expectedVersion: changed.version,
                actor: "reviewer",
                feedback: "again"
            )
            XCTFail("Request changes must not be available outside review")
        } catch {
            XCTAssertEqual(error as? CodingTaskServiceError, .actionNotAvailable(taskID: seeded.task.id, status: .ready))
        }

        do {
            _ = try await service.requestChanges(
                taskID: seeded.task.id,
                expectedVersion: changed.version,
                actor: "reviewer",
                feedback: "   "
            )
            XCTFail("Blank feedback must be rejected")
        } catch {
            XCTAssertEqual(error as? CodingTaskServiceError, .invalidTaskInput(field: "feedback", reason: "must not be blank"))
        }
    }

    func testAcceptDoesNotReuseApprovalRecordedByAnotherActor() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let projectID = UUID()
        let seeded = try await harness.seedReviewTask(projectID: projectID, criteriaCompleted: true, evidence: [])
        harness.acceptanceEvidence = [
            VerificationEvidence(
                taskID: seeded.task.id,
                attemptID: seeded.attempt.id,
                recipeName: "test-recipe",
                stepName: "build",
                status: .passed,
                detailsRedacted: "redacted",
                workspaceFingerprint: harness.currentFingerprint,
                recordedAt: harness.clock.now(),
                recipeVersion: VerificationRecipe.currentVersion
            )
        ]
        try await harness.store.recordApproval(
            TaskApproval(
                taskID: seeded.task.id,
                attemptID: seeded.attempt.id,
                fingerprint: harness.currentFingerprint,
                actor: "someone-else",
                timestamp: harness.clock.now(),
                action: .accept
            )
        )
        let service = harness.makeService()

        let accepted = try await service.accept(taskID: seeded.task.id, expectedVersion: seeded.task.version, actor: "reviewer")
        XCTAssertEqual(accepted.status, .done)

        let approvals = try await harness.store.approvals(taskID: seeded.task.id)
        XCTAssertEqual(approvals.count, 2)
        XCTAssertTrue(approvals.contains { $0.actor == "reviewer" && $0.action == .accept && $0.attemptID == seeded.attempt.id })
        XCTAssertTrue(approvals.contains { $0.actor == "someone-else" })
    }

    func testAcceptReusesExistingSameActorApprovalWithoutDuplicateRow() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let projectID = UUID()
        let seeded = try await harness.seedReviewTask(projectID: projectID, criteriaCompleted: true, evidence: [])
        harness.acceptanceEvidence = [
            VerificationEvidence(
                taskID: seeded.task.id,
                attemptID: seeded.attempt.id,
                recipeName: "test-recipe",
                stepName: "build",
                status: .passed,
                detailsRedacted: "redacted",
                workspaceFingerprint: harness.currentFingerprint,
                recordedAt: harness.clock.now(),
                recipeVersion: VerificationRecipe.currentVersion
            )
        ]
        let existing = TaskApproval(
            taskID: seeded.task.id,
            attemptID: seeded.attempt.id,
            fingerprint: harness.currentFingerprint,
            actor: "reviewer",
            timestamp: harness.clock.now(),
            action: .accept
        )
        try await harness.store.recordApproval(existing)
        let service = harness.makeService()

        let accepted = try await service.accept(taskID: seeded.task.id, expectedVersion: seeded.task.version, actor: "reviewer")
        XCTAssertEqual(accepted.status, .done)

        let approvals = try await harness.store.approvals(taskID: seeded.task.id)
        XCTAssertEqual(approvals, [existing], "A reused approval must not be persisted twice")
        let counts = await harness.repository.mutationCounts()
        XCTAssertEqual(counts.recordedApprovals, 0, "The accept path records its approval inside the transition")
    }

    func testFailedAcceptTransitionLeavesNoOrphanApproval() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let projectID = UUID()
        let seeded = try await harness.seedReviewTask(projectID: projectID, criteriaCompleted: true, evidence: [])
        harness.acceptanceEvidence = [
            VerificationEvidence(
                taskID: seeded.task.id,
                attemptID: seeded.attempt.id,
                recipeName: "test-recipe",
                stepName: "build",
                status: .passed,
                detailsRedacted: "redacted",
                workspaceFingerprint: harness.currentFingerprint,
                recordedAt: harness.clock.now(),
                recipeVersion: VerificationRecipe.currentVersion
            )
        ]
        let service = harness.makeService()
        await harness.repository.failNextTransition(
            with: .staleVersion(taskID: seeded.task.id, expected: seeded.task.version, actual: seeded.task.version + 1)
        )

        do {
            _ = try await service.accept(taskID: seeded.task.id, expectedVersion: seeded.task.version, actor: "reviewer")
            XCTFail("A rejected transition must not accept the task")
        } catch {
            XCTAssertEqual(
                error as? CodingTaskServiceError,
                .staleVersion(taskID: seeded.task.id, expected: seeded.task.version, actual: seeded.task.version + 1)
            )
        }

        let approvals = try await harness.store.approvals(taskID: seeded.task.id)
        XCTAssertTrue(approvals.isEmpty)
        let counts = await harness.repository.mutationCounts()
        XCTAssertEqual(counts.recordedApprovals, 0)
        let fetched = try await harness.store.task(id: seeded.task.id)
        let reloaded = try XCTUnwrap(fetched)
        XCTAssertEqual(reloaded.status, .review)
        XCTAssertEqual(reloaded.version, seeded.task.version)
    }

    func testStaleFingerprintAcceptanceRefusalDoesNotRecordApproval() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        harness.requiredSteps = []
        let projectID = UUID()
        let seeded = try await harness.seedReviewTask(projectID: projectID, criteriaCompleted: true, evidence: [])
        try await harness.store.recordApproval(
            TaskApproval(
                taskID: seeded.task.id,
                attemptID: seeded.attempt.id,
                fingerprint: "fingerprint-0",
                actor: "reviewer",
                timestamp: harness.clock.now(),
                action: .accept
            )
        )
        let service = harness.makeService()

        do {
            _ = try await service.accept(taskID: seeded.task.id, expectedVersion: seeded.task.version, actor: "reviewer")
            XCTFail("An approval bound to stale content must not authorize acceptance")
        } catch let error as CodingTaskServiceError {
            guard case .acceptanceDenied(let taskID, let reasons) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(taskID, seeded.task.id)
            XCTAssertTrue(
                reasons.contains(
                    .acceptanceApprovalFingerprintMismatch(expected: harness.currentFingerprint, actual: "fingerprint-0")
                )
            )
        }

        let approvals = try await harness.store.approvals(taskID: seeded.task.id)
        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(approvals.first?.fingerprint, "fingerprint-0")
        let counts = await harness.repository.mutationCounts()
        XCTAssertEqual(counts.recordedApprovals, 0)
        let fetched = try await harness.store.task(id: seeded.task.id)
        let reloaded = try XCTUnwrap(fetched)
        XCTAssertEqual(reloaded.status, .review)
    }

    func testUnexpectedErrorMapsToUnexpectedServiceError() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await service.createTask(projectID: project.id, title: "Task", objective: "Objective", priority: 1, criteria: [])

        await harness.repository.failNextTaskRead(with: CancellationError())
        do {
            _ = try await service.start(taskID: task.id, expectedVersion: 1)
            XCTFail("An unexpected port error must surface as a typed service error")
        } catch {
            XCTAssertEqual(error as? CodingTaskServiceError, .unexpected(String(describing: CancellationError())))
        }

        let counts = await harness.repository.mutationCounts()
        XCTAssertEqual(counts.claimAttempts, 0)
        XCTAssertEqual(counts.transitions, 0)
    }

    func testErrorMappingDistinguishesSchedulerStaleAndUnexpectedErrors() {
        let taskID = UUID()
        let expectedAttemptID = UUID()
        let actualAttemptID = UUID()
        XCTAssertEqual(
            CodingTaskService.mapError(
                TaskSchedulerError.staleAttempt(
                    taskID: taskID,
                    expectedAttemptID: expectedAttemptID,
                    expectedGeneration: 1,
                    actualAttemptID: actualAttemptID,
                    actualGeneration: 2
                )
            ),
            .staleAttempt(taskID: taskID, expectedAttemptID: expectedAttemptID, actualAttemptID: actualAttemptID)
        )
        XCTAssertEqual(
            CodingTaskService.mapError(TaskSchedulerError.invalidCompletionOutcome(.inProgress)),
            .schedulerRejected(reason: "invalid completion outcome inProgress")
        )
        XCTAssertEqual(
            CodingTaskService.mapError(TaskRepositoryError.underlying("db down")),
            .persistence(.underlying("db down"))
        )
    }

    func testReconcileReturnsReportForProject() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        _ = try await service.createTask(projectID: project.id, title: "Task", objective: "Objective", priority: 1, criteria: [])

        let report = await service.reconcile(projectID: project.id)
        XCTAssertNil(report.failure)
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries.first?.disposition, .noAction)
    }
}
