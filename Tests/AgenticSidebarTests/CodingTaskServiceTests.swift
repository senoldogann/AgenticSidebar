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

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}

actor ScriptedProviderRegistry: TaskProviderRegistryPort {
    private var result: TaskProviderCandidate
    private var gatedCandidates: AsyncGate?
    private var gatedCandidatesFromCall = 1
    private(set) var callCount = 0

    init(result: TaskProviderCandidate) {
        self.result = result
    }

    func setResult(_ result: TaskProviderCandidate) {
        self.result = result
    }

    func gateCandidates(_ gate: AsyncGate) {
        gateCandidates(gate, fromCall: 1)
    }

    /// Talepten sonraki uygunluk sorularını kapıya alır; ilk çağrı (talep öncesi)
    /// serbest kalır, böylece gönderim anındaki ret deterministik olur.
    func gateCandidates(_ gate: AsyncGate, fromCall: Int) {
        gatedCandidates = gate
        gatedCandidatesFromCall = fromCall
    }

    func candidate(for task: CodingTask, stage: TaskStage) async -> TaskProviderCandidate {
        callCount += 1
        if let gate = gatedCandidates, callCount >= gatedCandidatesFromCall {
            await gate.enter()
        }
        return result
    }
}

/// Sıralı sahiplik yanıtları: talep anı ile gönderim anı farklı sonuç görebilsin.
actor ScriptedWorkspacePreflight: TaskWorkspacePreflightPort {
    private var results: [TaskWorkspacePreflightResult]
    private(set) var callCount = 0

    init(results: [TaskWorkspacePreflightResult]) {
        self.results = results
    }

    func preflight(projectID: UUID, taskID: UUID) async -> TaskWorkspacePreflightResult {
        callCount += 1
        guard !results.isEmpty else {
            return .unavailable(reason: "script exhausted after \(callCount) calls")
        }
        if results.count == 1 {
            return results[0]
        }
        return results.removeFirst()
    }
}

/// Parmak izi sorgusunu kapıya alan sahte artık `FixedExecutionFingerprints`
/// üzerinden `gate` ile kurulur; ek bir türe gerek yoktur.

/// Kapanış bariyeri testi için gönderim portu: olay akışını test serbest
/// bırakana kadar açık tutar, böylece gönderim görevi uçuşta kalır.
actor HoldingDispatchPort: TaskRunningPort {
    private struct HeldRun {
        let taskID: UUID
        let attemptID: UUID
        let generation: Int
        let continuation: AsyncStream<CodingAgentEvent>.Continuation
    }

    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private var heldRuns: [UUID: HeldRun] = [:]

    func start(
        _ request: TaskRunRequest,
        approvalResolver: @escaping TaskRunApprovalResolver
    ) async throws -> TaskRunSession {
        startCount += 1
        let (stream, continuation) = AsyncStream<CodingAgentEvent>.makeStream()
        continuation.yield(
            CodingAgentEvent(
                taskID: request.task.id,
                attemptID: request.attempt.id,
                generation: request.attempt.generation,
                kind: .started
            )
        )
        heldRuns[request.attempt.id] = HeldRun(
            taskID: request.task.id,
            attemptID: request.attempt.id,
            generation: request.attempt.generation,
            continuation: continuation
        )
        return HoldingRunSession(events: stream) { [weak self] in
            await self?.recordCancel(attemptID: request.attempt.id)
        }
    }

    private func recordCancel(attemptID: UUID) {
        cancelCount += 1
    }

    /// Açık akışları terminal iptal olayıyla kapatır: gönderim görevi ancak
    /// bundan sonra bitebilir.
    func finishAll() {
        for held in heldRuns.values {
            held.continuation.yield(
                CodingAgentEvent(
                    taskID: held.taskID,
                    attemptID: held.attemptID,
                    generation: held.generation,
                    kind: .interrupted("held dispatch released")
                )
            )
            held.continuation.finish()
        }
        heldRuns = [:]
    }
}

struct HoldingRunSession: TaskRunSession {
    let events: AsyncStream<CodingAgentEvent>
    let cancelHandler: @Sendable () async -> Void

    func cancel() async {
        await cancelHandler()
    }
}

/// Provizyonu devrede tutan basit sahte: talep edilen çalışma alanı kaydını
/// olduğu gibi teslim eder, gönderim kapısının gördüğü kimlikle birebir aynıdır.
struct FixedProvisioning: TaskWorkspaceProvisioningPort {
    let workspace: TaskWorkspaceDescriptor

    func resolveBase(for task: CodingTask) async throws -> WorkspaceBase {
        WorkspaceBase(commitSHA: "test-base")
    }

    func create(task: CodingTask, attempt: TaskAttempt, base: WorkspaceBase) async throws -> WorkspaceRecord {
        WorkspaceRecord(
            workspaceID: workspace.workspaceID,
            projectID: task.projectID,
            taskID: task.id,
            attemptID: attempt.id,
            repositoryPath: workspace.repositoryPath,
            workspacePath: workspace.workspacePath,
            commonDirIdentity: "test-common-dir",
            baseSHA: base.commitSHA,
            nonce: UUID().uuidString,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    func discardUnclaimed(workspaceID: UUID, attemptID: UUID) async throws {}
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

struct FixedExecutionFingerprints: TaskExecutionFingerprintProviding {
    let fingerprint: String
    let failure: Error?
    let gate: AsyncGate?

    init(fingerprint: String, failure: Error? = nil) {
        self.init(fingerprint: fingerprint, failure: failure, gate: nil)
    }

    init(fingerprint: String, failure: Error?, gate: AsyncGate?) {
        self.fingerprint = fingerprint
        self.failure = failure
        self.gate = gate
    }

    func executionFingerprint(projectID: UUID, taskID: UUID) async throws -> String {
        if let gate {
            await gate.enter()
        }
        if let failure {
            throw failure
        }
        return fingerprint
    }
}

/// Canlı gönderim portu sahtesi: kaç kez başlatıldığını ve hangi isteğin
/// geldiğini kaydeder; terminal olayları senaryoya göre yayar.
actor ServiceScriptedDispatchPort: TaskRunningPort {
    private(set) var startCount = 0
    private(set) var requests: [TaskRunRequest] = []
    private var hangingContinuations: [UUID: AsyncStream<CodingAgentEvent>.Continuation] = [:]
    private let hangAfterStart: Bool
    private var startGate: AsyncGate?
    private var startFailure: Error?

    init(hangAfterStart: Bool = false) {
        self.hangAfterStart = hangAfterStart
    }

    /// `start` çağrısını kapıya alır: gönderim, çalıştırıcı başlamadan bekletilir.
    func gateStart(_ gate: AsyncGate) {
        startGate = gate
    }

    /// Bir sonraki `start` çağrısını verilen hatayla düşürür; zamanlayıcı bunu
    /// `runtimeStartFailed` reddine çevirir.
    func failNextStart(with error: Error) {
        startFailure = error
    }

    func start(
        _ request: TaskRunRequest,
        approvalResolver: @escaping TaskRunApprovalResolver
    ) async throws -> TaskRunSession {
        startCount += 1
        requests.append(request)
        if let gate = startGate {
            await gate.enter()
        }
        if let failure = startFailure {
            startFailure = nil
            throw failure
        }
        let (stream, continuation) = AsyncStream<CodingAgentEvent>.makeStream()
        continuation.yield(
            CodingAgentEvent(
                taskID: request.task.id,
                attemptID: request.attempt.id,
                generation: request.attempt.generation,
                kind: .started
            )
        )
        if hangAfterStart {
            hangingContinuations[request.attempt.id] = continuation
        } else {
            continuation.yield(
                CodingAgentEvent(
                    taskID: request.task.id,
                    attemptID: request.attempt.id,
                    generation: request.attempt.generation,
                    kind: .terminalSuccess
                )
            )
            continuation.finish()
        }
        return TestScriptedRunSession(events: stream) { [weak self] in
            await self?.cancel(attemptID: request.attempt.id)
        }
    }

    private func cancel(attemptID: UUID) {
        guard let continuation = hangingContinuations.removeValue(forKey: attemptID) else { return }
        continuation.yield(
            CodingAgentEvent(
                taskID: UUID(),
                attemptID: attemptID,
                generation: 0,
                kind: .interrupted("cancelled")
            )
        )
        continuation.finish()
    }

    /// Asılı kalan koşuların akışını kapatır (test temizliği): gönderim döngüsü
    /// terminal durumla biter, süreçte askıda görev kalmaz.
    func finishHangingRuns() {
        for continuation in hangingContinuations.values {
            continuation.finish()
        }
        hangingContinuations = [:]
    }
}

struct TestScriptedRunSession: TaskRunSession {
    let events: AsyncStream<CodingAgentEvent>
    let cancelHandler: @Sendable () async -> Void

    func cancel() async {
        await cancelHandler()
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
    private var nextRecordApprovalFailure: TaskRepositoryError?
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

    func failNextRecordApproval(with error: TaskRepositoryError) {
        nextRecordApprovalFailure = error
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

    func updateTaskDetails(
        taskID: UUID,
        expectedVersion: Int,
        title: String,
        objective: String,
        priority: Int
    ) async throws -> CodingTask {
        try await base.updateTaskDetails(
            taskID: taskID,
            expectedVersion: expectedVersion,
            title: title,
            objective: objective,
            priority: priority
        )
    }

    func deleteTask(taskID: UUID) async throws {
        try await base.deleteTask(taskID: taskID)
    }

    func addDependency(_ dependency: TaskDependency) async throws {
        addDependencyCount += 1
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
        if let failure = nextRecordApprovalFailure {
            nextRecordApprovalFailure = nil
            throw failure
        }
        try await base.recordApproval(approval)
    }

    func approvals(taskID: UUID) async throws -> [TaskApproval] {
        try await base.approvals(taskID: taskID)
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
            executionFingerprints: FixedExecutionFingerprints(fingerprint: currentFingerprint, failure: nil, gate: nil),
            clock: clock,
            requiredSteps: requiredSteps,
            liveDispatchAvailable: false
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

    func testCreateProjectPersistsToStoreAndSurvivesFreshService() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)

        let stored = try await harness.store.loadProject(id: project.id)
        XCTAssertEqual(stored, project)
        let listed = await service.listProjects()
        XCTAssertEqual(listed, [project])

        let freshService = harness.makeService()
        let cachedBeforeRestore = await freshService.project(id: project.id)
        XCTAssertNil(cachedBeforeRestore)
        let restored = await freshService.projectFromStore(id: project.id)
        XCTAssertEqual(restored, project)
        let relisted = await freshService.listProjects()
        XCTAssertEqual(relisted, [project])
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

    // MARK: - Canlı koşu gönderimi (executeRecipe onayı)

    private func makeDispatchService(
        port: ServiceScriptedDispatchPort,
        providers: ScriptedProviderRegistry,
        workspaces: any TaskWorkspacePreflightPort,
        clock: ServiceTestClock,
        fingerprint: String,
        fingerprintFailure: Error?,
        fingerprintGate: AsyncGate?,
        verificationPreflight: (any TaskVerificationPreflightProviding)? = nil
    ) async throws -> (
        store: SQLiteTaskStore,
        repository: ServiceHookingRepository,
        scheduler: TaskScheduler,
        service: CodingTaskService,
        project: CodingProject
    ) {
        let store = try SQLiteTaskStore.inMemory()
        let repository = ServiceHookingRepository(base: store)
        let scheduler = TaskScheduler(
            repository: repository,
            providers: providers,
            workspaces: workspaces,
            verifier: FixedVerifier(passed: true),
            clock: clock,
            schedulerID: "scheduler-dispatch-service",
            provisioning: nil,
            dispatchPort: port
        )
        let recovery = TaskRecovery(
            repository: repository,
            providers: NoProviderSessions(),
            workspaces: NoWorkspaceOwnership(),
            processes: NoProcesses(),
            clock: clock,
            recoveryID: "recovery-dispatch-service"
        )
        let service = CodingTaskService(
            repository: repository,
            scheduler: scheduler,
            recovery: recovery,
            providers: providers,
            acceptanceEvidence: FixedAcceptanceEvidence(evidence: [], currentFingerprint: fingerprint),
            executionFingerprints: FixedExecutionFingerprints(
                fingerprint: fingerprint,
                failure: fingerprintFailure,
                gate: fingerprintGate
            ),
            clock: clock,
            requiredSteps: [],
            liveDispatchAvailable: true,
            verificationPreflight: verificationPreflight
        )
        let project = try await service.createProject(
            name: "Dispatch",
            repositoryPath: TaskBoardServiceFixtures.ownedWorkspace.repositoryPath,
            gitIdentity: "dev@example.com",
            protectedRefs: ["main"]
        )
        return (store, repository, scheduler, service, project)
    }

    private func makeEligibleProviders() -> ScriptedProviderRegistry {
        ScriptedProviderRegistry(result: .eligible(runtimeID: "runtime-1", modelID: "model-1"))
    }

    private func makeOwnedPreflight() -> FixedWorkspacePreflight {
        FixedWorkspacePreflight(result: .owned(TaskBoardServiceFixtures.ownedWorkspace))
    }

    func testStartRunRequiresAHumanActorBeforeAnyClaim() async throws {
        let port = ServiceScriptedDispatchPort()
        let fixture = try await makeDispatchService(
            port: port,
            providers: makeEligibleProviders(),
            workspaces: makeOwnedPreflight(),
            clock: ServiceTestClock(start: TaskBoardServiceFixtures.startDate),
            fingerprint: "fingerprint-live",
            fingerprintFailure: nil,
            fingerprintGate: nil
        )
        _ = try await fixture.service.createTask(
            projectID: fixture.project.id,
            title: "Live",
            objective: "Run live",
            priority: 1,
            criteria: ["done"]
        )
        let snapshotForActor = try await fixture.service.snapshot(projectID: fixture.project.id)
        let actorTask = try XCTUnwrap(snapshotForActor.tasks.first)

        do {
            _ = try await fixture.service.startRun(taskID: actorTask.id, expectedVersion: actorTask.version, actor: "   ")
            XCTFail("A blank human actor must be refused before any claim")
        } catch {
            XCTAssertEqual(error as? CodingTaskServiceError, .invalidTaskInput(field: "actor", reason: "must not be blank"))
        }
        let startCount = await port.startCount
        XCTAssertEqual(startCount, 0)
        let reloaded = try await fixture.store.task(id: actorTask.id)
        XCTAssertEqual(reloaded?.status, .backlog)
    }

    func testStartRunWithoutInjectedPortIsRefusedBeforeClaim() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await service.createTask(projectID: project.id, title: "Task", objective: "Objective", priority: 1, criteria: [])

        do {
            _ = try await service.startRun(taskID: task.id, expectedVersion: 1, actor: "human@example.com")
            XCTFail("A composition without a running port must refuse startRun")
        } catch {
            XCTAssertEqual(error as? CodingTaskServiceError, .liveDispatchUnavailable(taskID: task.id))
        }
        let counts = await harness.repository.mutationCounts()
        XCTAssertEqual(counts.claimAttempts, 0)
    }

    // MARK: - Doğrulama ön kontrolü (H1)

    private struct ScriptedVerificationPreflight: TaskVerificationPreflightProviding {
        let reason: String?
        func unresolvableReason(projectID: UUID, taskID: UUID) async -> String? { reason }
    }

    /// H1: çözülemeyen çalışma alanı ajanı yakmadan ertelenir; talep geri
    /// çekilir, onay uydurulmaz, gönderim doğmaz.
    func testStartRunRefusesUnresolvableWorkspaceBeforeDispatch() async throws {
        let port = ServiceScriptedDispatchPort()
        let fixture = try await makeDispatchService(
            port: port,
            providers: makeEligibleProviders(),
            workspaces: makeOwnedPreflight(),
            clock: ServiceTestClock(start: TaskBoardServiceFixtures.startDate),
            fingerprint: "fingerprint-live",
            fingerprintFailure: nil,
            fingerprintGate: nil,
            verificationPreflight: ScriptedVerificationPreflight(
                reason: "VERIFICATION_UNRECOGNIZED_PROJECT: çalışma alanında Package.swift yok"
            )
        )
        _ = try await fixture.service.createTask(
            projectID: fixture.project.id,
            title: "Live",
            objective: "Run live",
            priority: 1,
            criteria: ["done"]
        )
        let snapshotForPreflight = try await fixture.service.snapshot(projectID: fixture.project.id)
        let preflightTask = try XCTUnwrap(snapshotForPreflight.tasks.first)

        let result = try await fixture.service.startRun(
            taskID: preflightTask.id,
            expectedVersion: preflightTask.version,
            actor: "human@example.com"
        )
        guard case .deferred(let reason) = result else {
            return XCTFail("An unresolvable workspace must defer the run, got \(result)")
        }
        XCTAssertTrue(reason.contains("VERIFICATION_UNRECOGNIZED_PROJECT"))
        let approvals = try await fixture.store.approvals(taskID: preflightTask.id)
        XCTAssertTrue(approvals.isEmpty, "No approval may be invented for an unresolvable workspace")
        try await assertClaimRetired(
            taskID: preflightTask.id,
            store: fixture.store,
            port: port,
            expectedStartCount: 0
        )
    }

    /// Çözülebilen çalışma alanı kapıdan geçer ve koşu doğar.
    func testStartRunDispatchesWhenWorkspaceResolves() async throws {
        let port = ServiceScriptedDispatchPort()
        let fixture = try await makeDispatchService(
            port: port,
            providers: makeEligibleProviders(),
            workspaces: makeOwnedPreflight(),
            clock: ServiceTestClock(start: TaskBoardServiceFixtures.startDate),
            fingerprint: "fingerprint-live",
            fingerprintFailure: nil,
            fingerprintGate: nil,
            verificationPreflight: ScriptedVerificationPreflight(reason: nil)
        )
        _ = try await fixture.service.createTask(
            projectID: fixture.project.id,
            title: "Live",
            objective: "Run live",
            priority: 1,
            criteria: ["done"]
        )
        let snapshotForRun = try await fixture.service.snapshot(projectID: fixture.project.id)
        let runTask = try XCTUnwrap(snapshotForRun.tasks.first)

        let result = try await fixture.service.startRun(
            taskID: runTask.id,
            expectedVersion: runTask.version,
            actor: "human@example.com"
        )
        guard case .claimed = result else {
            return XCTFail("A resolvable workspace must claim the run, got \(result)")
        }
        try await waitForDispatchStart(port, count: 1)
    }

    func testStartRunRecordsExecuteApprovalBoundToAttemptAndFingerprint() async throws {
        let port = ServiceScriptedDispatchPort()
        let fixture = try await makeDispatchService(
            port: port,
            providers: makeEligibleProviders(),
            workspaces: makeOwnedPreflight(),
            clock: ServiceTestClock(start: TaskBoardServiceFixtures.startDate),
            fingerprint: "fingerprint-live",
            fingerprintFailure: nil,
            fingerprintGate: nil
        )
        _ = try await fixture.service.createTask(
            projectID: fixture.project.id,
            title: "Live",
            objective: "Run live",
            priority: 1,
            criteria: ["done"]
        )
        let snapshotForRun = try await fixture.service.snapshot(projectID: fixture.project.id)
        let runTask = try XCTUnwrap(snapshotForRun.tasks.first)

        let result = try await fixture.service.startRun(
            taskID: runTask.id,
            expectedVersion: runTask.version,
            actor: "human@example.com"
        )
        guard case .claimed(let attemptID, let generation) = result else {
            return XCTFail("Expected a claim, got \(result)")
        }
        try await waitForDispatchStart(port, count: 1)

        let approvals = try await fixture.store.approvals(taskID: runTask.id)
        XCTAssertEqual(approvals.count, 1)
        let approval = try XCTUnwrap(approvals.first)
        XCTAssertEqual(approval.action, .executeRecipe)
        XCTAssertEqual(approval.actor, "human@example.com")
        XCTAssertEqual(approval.attemptID, attemptID)
        XCTAssertEqual(approval.fingerprint, "fingerprint-live")
        XCTAssertTrue(
            approval.authorizes(
                action: .executeRecipe,
                taskID: runTask.id,
                attemptID: attemptID,
                fingerprint: "fingerprint-live"
            )
        )

        let capturedRequests = await port.requests
        let request = try XCTUnwrap(capturedRequests.first)
        XCTAssertEqual(request.attempt.id, attemptID)
        XCTAssertEqual(request.attempt.generation, generation)
        // Koşu terminal olaylarla bittiğinde görev incelemeye ilerler.
        try await waitUntil {
            let reloaded = try? await fixture.store.task(id: runTask.id)
            return reloaded?.status == .review
        }
    }

    func testStartRunRefusesWhenFingerprintIsUnavailableAndRetiresTheClaim() async throws {
        let port = ServiceScriptedDispatchPort()
        let fixture = try await makeDispatchService(
            port: port,
            providers: makeEligibleProviders(),
            workspaces: makeOwnedPreflight(),
            clock: ServiceTestClock(start: TaskBoardServiceFixtures.startDate),
            fingerprint: "unused",
            fingerprintFailure: TaskExecutionFingerprintError.fingerprintUnavailable(
                taskID: UUID(),
                workspacePath: "/tmp/workspace"
            ),
            fingerprintGate: nil
        )
        _ = try await fixture.service.createTask(
            projectID: fixture.project.id,
            title: "Live",
            objective: "Run live",
            priority: 1,
            criteria: []
        )
        let snapshotForFingerprint = try await fixture.service.snapshot(projectID: fixture.project.id)
        let fingerprintTask = try XCTUnwrap(snapshotForFingerprint.tasks.first)

        do {
            _ = try await fixture.service.startRun(
                taskID: fingerprintTask.id,
                expectedVersion: fingerprintTask.version,
                actor: "human@example.com"
            )
            XCTFail("A missing fingerprint must refuse the run")
        } catch let error as CodingTaskServiceError {
            guard case .executionFingerprintUnavailable(let refusedTaskID, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(refusedTaskID, fingerprintTask.id)
        }

        let startCount = await port.startCount
        XCTAssertEqual(startCount, 0, "No runtime may start without a bound approval")
        let approvals = try await fixture.store.approvals(taskID: fingerprintTask.id)
        XCTAssertTrue(approvals.isEmpty, "No approval may be invented when the fingerprint is unavailable")
        let reloaded = try await fixture.store.task(id: fingerprintTask.id)
        XCTAssertEqual(reloaded?.status, .blocked)
        XCTAssertEqual(reloaded?.blockReason, .custom(TaskScheduler.stoppedBlockReason))
    }

    // MARK: - Talep sonrası gönderim redleri (fenced geri çekme)

    /// Talep alındıktan sonra gönderim reddedilirse deneme `.running` olarak
    /// asılı kalamaz: tam kimliğiyle emekliye ayrılır ve görev bloke olur.
    private func assertClaimRetired(
        taskID: UUID,
        store: SQLiteTaskStore,
        port: ServiceScriptedDispatchPort,
        expectedStartCount: Int
    ) async throws {
        let history = try await store.attemptHistory(taskID: taskID)
        XCTAssertEqual(
            history.map(\.outcome),
            [.cancelled],
            "The refused claim must end cancelled instead of stranding in progress"
        )
        let reloaded = try await store.task(id: taskID)
        XCTAssertEqual(reloaded?.status, .blocked)
        XCTAssertEqual(reloaded?.blockReason, .custom(TaskScheduler.stoppedBlockReason))
        let startCount = await port.startCount
        XCTAssertEqual(startCount, expectedStartCount, "Only the expected runtime starts may occur")
    }

    func testDispatchWorkspaceNotOwnedRefusalRetiresTheClaim() async throws {
        let port = ServiceScriptedDispatchPort()
        let owned = TaskBoardServiceFixtures.ownedWorkspace
        let fixture = try await makeDispatchService(
            port: port,
            providers: makeEligibleProviders(),
            workspaces: ScriptedWorkspacePreflight(results: [
                .owned(owned),
                .notOwned(reason: "workspace disappeared"),
            ]),
            clock: ServiceTestClock(start: TaskBoardServiceFixtures.startDate),
            fingerprint: "fingerprint-live",
            fingerprintFailure: nil,
            fingerprintGate: nil
        )
        let task = try await fixture.service.createTask(
            projectID: fixture.project.id,
            title: "Live",
            objective: "Run live",
            priority: 1,
            criteria: []
        )

        let result = try await fixture.service.startRun(taskID: task.id, expectedVersion: task.version, actor: "human@example.com")
        guard case .claimed = result else {
            return XCTFail("Expected a claim, got \(result)")
        }
        await fixture.service.awaitDispatchedRuns()
        try await assertClaimRetired(taskID: task.id, store: fixture.store, port: port, expectedStartCount: 0)
    }

    func testDispatchWorkspaceIdentityMismatchRefusalRetiresTheClaim() async throws {
        let port = ServiceScriptedDispatchPort()
        let owned = TaskBoardServiceFixtures.ownedWorkspace
        let foreignWorkspace = TaskWorkspaceDescriptor(
            workspaceID: UUID(),
            workspacePath: owned.workspacePath,
            repositoryPath: owned.repositoryPath
        )
        let fixture = try await makeDispatchService(
            port: port,
            providers: makeEligibleProviders(),
            workspaces: ScriptedWorkspacePreflight(results: [
                .owned(owned),
                .owned(foreignWorkspace),
            ]),
            clock: ServiceTestClock(start: TaskBoardServiceFixtures.startDate),
            fingerprint: "fingerprint-live",
            fingerprintFailure: nil,
            fingerprintGate: nil
        )
        let task = try await fixture.service.createTask(
            projectID: fixture.project.id,
            title: "Live",
            objective: "Run live",
            priority: 1,
            criteria: []
        )

        let result = try await fixture.service.startRun(taskID: task.id, expectedVersion: task.version, actor: "human@example.com")
        guard case .claimed = result else {
            return XCTFail("Expected a claim, got \(result)")
        }
        await fixture.service.awaitDispatchedRuns()
        try await assertClaimRetired(taskID: task.id, store: fixture.store, port: port, expectedStartCount: 0)
    }

    func testDispatchProviderNotEligibleRefusalRetiresTheClaim() async throws {
        let port = ServiceScriptedDispatchPort()
        let providers = makeEligibleProviders()
        let gate = AsyncGate()
        await providers.gateCandidates(gate, fromCall: 3)
        let fixture = try await makeDispatchService(
            port: port,
            providers: providers,
            workspaces: makeOwnedPreflight(),
            clock: ServiceTestClock(start: TaskBoardServiceFixtures.startDate),
            fingerprint: "fingerprint-live",
            fingerprintFailure: nil,
            fingerprintGate: nil
        )
        let task = try await fixture.service.createTask(
            projectID: fixture.project.id,
            title: "Live",
            objective: "Run live",
            priority: 1,
            criteria: []
        )

        let result = try await fixture.service.startRun(taskID: task.id, expectedVersion: task.version, actor: "human@example.com")
        guard case .claimed = result else {
            return XCTFail("Expected a claim, got \(result)")
        }
        await gate.waitUntilEntered()
        await providers.setResult(.unsupported(missingCapabilities: ["tools"]))
        await gate.release()
        await fixture.service.awaitDispatchedRuns()
        try await assertClaimRetired(taskID: task.id, store: fixture.store, port: port, expectedStartCount: 0)
    }

    func testDispatchBudgetRefusalRetiresTheClaim() async throws {
        let port = ServiceScriptedDispatchPort()
        let providers = makeEligibleProviders()
        let gate = AsyncGate()
        await providers.gateCandidates(gate, fromCall: 3)
        let clock = ServiceTestClock(start: TaskBoardServiceFixtures.startDate)
        let fixture = try await makeDispatchService(
            port: port,
            providers: providers,
            workspaces: makeOwnedPreflight(),
            clock: clock,
            fingerprint: "fingerprint-live",
            fingerprintFailure: nil,
            fingerprintGate: nil
        )
        let task = try await fixture.service.createTask(
            projectID: fixture.project.id,
            title: "Live",
            objective: "Run live",
            priority: 1,
            criteria: []
        )

        let result = try await fixture.service.startRun(taskID: task.id, expectedVersion: task.version, actor: "human@example.com")
        guard case .claimed = result else {
            return XCTFail("Expected a claim, got \(result)")
        }
        await gate.waitUntilEntered()
        clock.advance(by: TimeInterval(task.budget.maxTaskDurationSeconds + 60))
        await gate.release()
        await fixture.service.awaitDispatchedRuns()
        try await assertClaimRetired(taskID: task.id, store: fixture.store, port: port, expectedStartCount: 0)
    }

    /// Koşu yuvasını başka bir gönderim tutarken gelen `dispatchAlreadyActive`
    /// reddi de denemeyi emekliye ayırır; gönderim çağrısı başlamış olsa bile
    /// görev asılı kalmaz.
    func testDispatchAlreadyActiveRefusalRetiresTheClaim() async throws {
        let port = ServiceScriptedDispatchPort(hangAfterStart: true)
        let fingerprintGate = AsyncGate()
        let fixture = try await makeDispatchService(
            port: port,
            providers: makeEligibleProviders(),
            workspaces: makeOwnedPreflight(),
            clock: ServiceTestClock(start: TaskBoardServiceFixtures.startDate),
            fingerprint: "fingerprint-live",
            fingerprintFailure: nil,
            fingerprintGate: fingerprintGate
        )
        let task = try await fixture.service.createTask(
            projectID: fixture.project.id,
            title: "Live",
            objective: "Run live",
            priority: 1,
            criteria: []
        )

        let start = Task { try await fixture.service.startRun(taskID: task.id, expectedVersion: task.version, actor: "human@example.com") }
        await fingerprintGate.waitUntilEntered()

        // Talep alındı; aynı deneme için koşu yuvasını yabancı bir gönderim tutuyor.
        let claimedHistory = try await fixture.store.attemptHistory(taskID: task.id)
        let claimed = try XCTUnwrap(claimedHistory.first)
        try await fixture.store.recordApproval(
            TaskApproval(
                id: UUID(),
                taskID: task.id,
                attemptID: claimed.id,
                fingerprint: "fingerprint-live",
                actor: "foreign@example.com",
                timestamp: TaskBoardServiceFixtures.startDate,
                action: .executeRecipe
            )
        )
        let occupyingRun = Task {
            _ = try? await fixture.scheduler.dispatch(
                taskID: task.id,
                attemptID: claimed.id,
                generation: claimed.generation,
                fingerprint: "fingerprint-live"
            )
        }
        try await waitForDispatchStart(port, count: 1)

        await fingerprintGate.release()
        guard case .claimed = try await start.value else {
            return XCTFail("Expected the fenced startRun to still claim its attempt")
        }
        await fixture.service.awaitDispatchedRuns()
        try await assertClaimRetired(taskID: task.id, store: fixture.store, port: port, expectedStartCount: 1)
        // Temizlik: yabancı gönderimi kapat, askıda görev bırakma.
        await port.finishHangingRuns()
        await occupyingRun.value
    }

    /// Bayat bir çalıştırıcı-başlatma hatası, kendisinden sonra talep edilmiş
    /// daha yeni bir denemeyi asla iptal etmemeli: geri çekme kimlikle çitlenir.
    func testStaleRuntimeStartFailureDoesNotCancelANewerAttempt() async throws {
        struct DispatchStartFailure: Error {}

        let port = ServiceScriptedDispatchPort()
        let startGate = AsyncGate()
        await port.gateStart(startGate)
        await port.failNextStart(with: DispatchStartFailure())
        let fixture = try await makeDispatchService(
            port: port,
            providers: makeEligibleProviders(),
            workspaces: makeOwnedPreflight(),
            clock: ServiceTestClock(start: TaskBoardServiceFixtures.startDate),
            fingerprint: "fingerprint-live",
            fingerprintFailure: nil,
            fingerprintGate: nil
        )
        let task = try await fixture.service.createTask(
            projectID: fixture.project.id,
            title: "Live",
            objective: "Run live",
            priority: 1,
            criteria: []
        )

        let first = try await fixture.service.startRun(taskID: task.id, expectedVersion: task.version, actor: "human@example.com")
        guard case .claimed(let firstAttemptID, let firstGeneration) = first else {
            return XCTFail("Expected the first claim, got \(first)")
        }
        await startGate.waitUntilEntered()

        let second = try await fixture.service.retry(
            taskID: task.id,
            expectedActiveAttemptID: firstAttemptID,
            expectedActiveGeneration: firstGeneration
        )
        guard case .claimed(let secondAttemptID, _) = second.disposition else {
            return XCTFail("Expected a newer claim, got \(second)")
        }

        await startGate.release()
        await fixture.service.awaitDispatchedRuns()

        let history = try await fixture.store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.map(\.id), [firstAttemptID, secondAttemptID])
        XCTAssertEqual(history.map(\.outcome), [.cancelled, .inProgress])
        let reloaded = try await fixture.store.task(id: task.id)
        XCTAssertEqual(reloaded?.status, .running, "The stale runtime-start failure must not stop the newer attempt")
        XCTAssertEqual(reloaded?.currentAttemptID, secondAttemptID)
        let startCount = await port.startCount
        XCTAssertEqual(startCount, 1, "The runtime start was attempted exactly once")
    }

    /// Onay kaydı düşerse talep edilmiş deneme yine de tam kimliğiyle geri
    /// çekilir; hata çağırana açıkça döner.
    func testStartRunRetiresTheClaimWhenApprovalCannotBeRecorded() async throws {
        let port = ServiceScriptedDispatchPort()
        let fixture = try await makeDispatchService(
            port: port,
            providers: makeEligibleProviders(),
            workspaces: makeOwnedPreflight(),
            clock: ServiceTestClock(start: TaskBoardServiceFixtures.startDate),
            fingerprint: "fingerprint-live",
            fingerprintFailure: nil,
            fingerprintGate: nil
        )
        let task = try await fixture.service.createTask(
            projectID: fixture.project.id,
            title: "Live",
            objective: "Run live",
            priority: 1,
            criteria: []
        )
        await fixture.repository.failNextRecordApproval(with: .underlying("disk full"))

        do {
            _ = try await fixture.service.startRun(taskID: task.id, expectedVersion: task.version, actor: "human@example.com")
            XCTFail("A failed approval record must refuse the run")
        } catch let error as CodingTaskServiceError {
            XCTAssertEqual(error, .persistence(.underlying("disk full")))
        }
        try await assertClaimRetired(taskID: task.id, store: fixture.store, port: port, expectedStartCount: 0)
    }

    /// Kapanış bariyeri: uçuştaki gönderim görevi bitmeden mağaza kapanmaz.
    ///
    /// Gönderim portu olay akışını test serbest bırakana kadar açık tutar;
    /// `shutdown` bu sırada mağazayı kapatırsa okuma `readOnly("Store is closed")`
    /// ile düşerdi. Bariyer çalışırken mağaza açık kalır, akış kapatılınca
    /// `shutdown` tamamlanır ve mağaza kapanır.
    @MainActor
    func testShutdownAwaitsInFlightDispatchBeforeClosingTheStore() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let clock = ServiceTestClock(start: TaskBoardServiceFixtures.startDate)
        let workspace = TaskBoardServiceFixtures.ownedWorkspace
        let port = HoldingDispatchPort()
        let composition = TaskBoardComposition.make(
            repository: store,
            providers: makeEligibleProviders(),
            workspacePreflight: FixedWorkspacePreflight(result: .owned(workspace)),
            provisioning: FixedProvisioning(workspace: workspace),
            dispatchPort: port,
            recoveryProviders: NoProviderSessions(),
            recoveryWorkspaces: NoWorkspaceOwnership(),
            recoveryProcesses: NoProcesses(),
            verifier: FixedVerifier(passed: true),
            acceptanceEvidence: FixedAcceptanceEvidence(evidence: [], currentFingerprint: "fingerprint-live"),
            executionFingerprints: FixedExecutionFingerprints(fingerprint: "fingerprint-live", failure: nil, gate: nil),
            clock: clock,
            schedulerID: "scheduler-shutdown-barrier",
            recoveryID: "recovery-shutdown-barrier",
            requiredSteps: []
        )
        let project = try await composition.service.createProject(
            name: "Shutdown",
            repositoryPath: workspace.repositoryPath,
            gitIdentity: "dev@example.com",
            protectedRefs: ["main"]
        )
        composition.register(projectID: project.id)
        let task = try await composition.service.createTask(
            projectID: project.id,
            title: "Live",
            objective: "Run live",
            priority: 1,
            criteria: []
        )
        let result = try await composition.service.startRun(
            taskID: task.id,
            expectedVersion: task.version,
            actor: "human@example.com"
        )
        guard case .claimed = result else {
            return XCTFail("Expected a claim, got \(result)")
        }
        try await waitUntilMainActor { await port.startCount >= 1 }

        let shutdown = Task { await composition.shutdown() }
        try await waitUntilMainActor { await port.cancelCount >= 1 }
        try await Task.sleep(for: .milliseconds(250))

        // Bariyer olmasaydı `shutdown` bu noktada mağazayı çoktan kapatmış olurdu.
        var storeOpenWhileRunIsHeld = false
        do {
            _ = try await store.task(id: task.id)
            storeOpenWhileRunIsHeld = true
        } catch {
            storeOpenWhileRunIsHeld = false
        }
        XCTAssertTrue(
            storeOpenWhileRunIsHeld,
            "shutdown must await the in-flight dispatch task before closing the store"
        )

        await port.finishAll()
        await shutdown.value

        var storeClosedAfterShutdown = false
        do {
            _ = try await store.task(id: task.id)
        } catch {
            storeClosedAfterShutdown = true
        }
        XCTAssertTrue(storeClosedAfterShutdown, "shutdown must close the store once the barrier completes")
    }

    // MARK: - Kabul ölçütü tamamlama

    func testSetCriterionCompletionMarksAndUnmarksWithVersionFence() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await service.createTask(
            projectID: project.id,
            title: "Criteria",
            objective: "Complete criteria",
            priority: 1,
            criteria: ["first", "second"]
        )
        let firstCriterion = try XCTUnwrap(task.criteria.first)

        let completed = try await service.setCriterionCompletion(
            taskID: task.id,
            criterionID: firstCriterion.id,
            isCompleted: true,
            expectedVersion: task.version
        )
        XCTAssertEqual(completed.version, task.version + 1)
        XCTAssertEqual(completed.criteria.first?.isCompleted, true)
        XCTAssertEqual(completed.criteria.last?.isCompleted, false)

        let uncompleted = try await service.setCriterionCompletion(
            taskID: task.id,
            criterionID: firstCriterion.id,
            isCompleted: false,
            expectedVersion: completed.version
        )
        XCTAssertEqual(uncompleted.criteria.first?.isCompleted, false)

        do {
            _ = try await service.setCriterionCompletion(
                taskID: task.id,
                criterionID: firstCriterion.id,
                isCompleted: true,
                expectedVersion: task.version
            )
            XCTFail("A stale version must be refused")
        } catch {
            XCTAssertEqual(
                error as? CodingTaskServiceError,
                .staleVersion(taskID: task.id, expected: task.version, actual: uncompleted.version)
            )
        }
    }

    func testSetCriterionCompletionRejectsUnknownCriterion() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await service.createTask(
            projectID: project.id,
            title: "Criteria",
            objective: "Objective",
            priority: 1,
            criteria: ["first"]
        )
        let unknownID = UUID()

        do {
            _ = try await service.setCriterionCompletion(
                taskID: task.id,
                criterionID: unknownID,
                isCompleted: true,
                expectedVersion: task.version
            )
            XCTFail("An unknown criterion must be refused")
        } catch {
            XCTAssertEqual(
                error as? CodingTaskServiceError,
                .criterionNotFound(taskID: task.id, criterionID: unknownID)
            )
        }
    }

    func testCriterionCompletionUnblocksHumanAcceptance() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let seeded = try await harness.seedReviewTask(
            projectID: UUID(),
            criteriaCompleted: false,
            evidence: []
        )
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
        let criterion = try XCTUnwrap(seeded.task.criteria.first)

        do {
            _ = try await service.accept(taskID: seeded.task.id, expectedVersion: seeded.task.version, actor: "human@example.com")
            XCTFail("Acceptance must stay blocked while a criterion is unmet")
        } catch let error as CodingTaskServiceError {
            guard case .acceptanceDenied(_, let reasons) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reasons.contains { if case .unmetCriteria = $0 { return true } else { return false } })
        }

        let completed = try await service.setCriterionCompletion(
            taskID: seeded.task.id,
            criterionID: criterion.id,
            isCompleted: true,
            expectedVersion: seeded.task.version
        )
        let accepted = try await service.accept(
            taskID: seeded.task.id,
            expectedVersion: completed.version,
            actor: "human@example.com"
        )
        XCTAssertEqual(accepted.status, .done)
    }

    private func waitForDispatchStart(_ port: ServiceScriptedDispatchPort, count: Int) async throws {
        try await waitUntil {
            await port.startCount >= count
        }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met before timeout")
    }

    /// MainActor testleri için bekçi: koşul kapanışı da MainActor'a izole kalır.
    @MainActor
    private func waitUntilMainActor(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met before timeout")
    }
}
