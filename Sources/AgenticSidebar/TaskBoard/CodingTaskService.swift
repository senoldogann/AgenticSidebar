import Foundation

/// Typed failures raised by the app-facing task service.
///
/// The board UI never sees a raw repository, scheduler or provider error: every mutation
/// either returns a value or one of these cases, and a rejected backend call can never be
/// mistaken for success.
enum CodingTaskServiceError: LocalizedError, Equatable, Sendable {
    case projectNotFound(UUID)
    case taskNotFound(UUID)
    case invalidProjectInput(field: String, reason: String)
    case invalidTaskInput(field: String, reason: String)
    case staleVersion(taskID: UUID, expected: Int, actual: Int)
    case staleAttempt(taskID: UUID, expectedAttemptID: UUID?, actualAttemptID: UUID?)
    case actionAlreadyInFlight(taskID: UUID)
    case actionNotAvailable(taskID: UUID, status: TaskStatus)
    case noActiveAttempt(taskID: UUID)
    case budgetExhausted(taskID: UUID, reason: String)
    case acceptanceDenied(taskID: UUID, reasons: [AcceptanceBlockReason])
    case acceptanceInputUnavailable(taskID: UUID, reason: String)
    case dependencyRejected(projectID: UUID, reason: String)
    case transitionRejected(TaskTransitionError)
    case persistence(TaskRepositoryError)
    case schedulerRejected(reason: String)

    var errorDescription: String? {
        switch self {
        case .projectNotFound(let id):
            return "Project not found: \(id)"
        case .taskNotFound(let id):
            return "Task not found: \(id)"
        case .invalidProjectInput(let field, let reason):
            return "Invalid project \(field): \(reason)"
        case .invalidTaskInput(let field, let reason):
            return "Invalid task \(field): \(reason)"
        case .staleVersion(let taskID, let expected, let actual):
            return "Task \(taskID) changed since this view loaded: expected version \(expected), actual \(actual)"
        case .staleAttempt(let taskID, let expected, let actual):
            return
                "Task \(taskID) active attempt changed: expected \(expected?.uuidString ?? "none"), actual \(actual?.uuidString ?? "none")"
        case .actionAlreadyInFlight(let taskID):
            return "Task \(taskID) already has an action in flight"
        case .actionNotAvailable(let taskID, let status):
            return "Action is not available for task \(taskID) in status \(status.rawValue)"
        case .noActiveAttempt(let taskID):
            return "Task \(taskID) has no active attempt"
        case .budgetExhausted(let taskID, let reason):
            return "Task \(taskID) exhausted its execution budget: \(reason)"
        case .acceptanceDenied(let taskID, let reasons):
            return "Task \(taskID) cannot be accepted: \(reasons.count) blocking gate reason(s)"
        case .acceptanceInputUnavailable(let taskID, let reason):
            return "Acceptance inputs for task \(taskID) are unavailable: \(reason)"
        case .dependencyRejected(let projectID, let reason):
            return "Dependency for project \(projectID) rejected: \(reason)"
        case .transitionRejected(let error):
            return "Transition rejected: \(error)"
        case .persistence(let error):
            return "Task store rejected the operation: \(error.localizedDescription)"
        case .schedulerRejected(let reason):
            return "Scheduler rejected the operation: \(reason)"
        }
    }
}

/// Why a start request could not reach a runtime, with the missing capability when known.
enum CodingTaskRuntimeUnavailability: Sendable, Equatable {
    case unsupported(missingCapabilities: [String])
    case providerUnavailable(reason: String)

    var message: String {
        switch self {
        case .unsupported(let missingCapabilities):
            guard !missingCapabilities.isEmpty else {
                return "No eligible runtime supports this task"
            }
            return "No eligible runtime provides: \(missingCapabilities.joined(separator: ", "))"
        case .providerUnavailable(let reason):
            return reason
        }
    }
}

/// Honest outcome of a start pass: claimed, blocked, refused for a missing runtime or deferred.
enum CodingTaskStartResult: Sendable, Equatable {
    case claimed(attemptID: UUID, generation: Int)
    case blocked(TaskBlockReason)
    case unavailable(CodingTaskRuntimeUnavailability)
    case deferred(reason: String)
}

/// Evidence and current content fingerprint used by the acceptance gate.
struct TaskAcceptanceEvidence: Sendable, Equatable {
    let evidence: [VerificationEvidence]
    let currentFingerprint: String
}

/// Supplies gate inputs the repository protocol cannot list yet (evidence and fingerprint).
///
/// The composition root wires this to the verification runner and the owned workspace; Task 13
/// only defines the boundary so the service never inspects Git or SQLite itself.
protocol TaskAcceptanceEvidenceProviding: Sendable {
    func acceptanceEvidence(taskID: UUID) async throws -> TaskAcceptanceEvidence
}

/// App-facing task service: the only surface the board UI is allowed to mutate through.
///
/// Every mutating call is single-flight per task, takes the caller's expected version or
/// attempt identity where the layer supports it, and reports an explicit typed refusal instead
/// of an optimistic success. The service never dispatches work its injected runtime cannot run.
actor CodingTaskService {
    private let repository: CodingTaskRepository
    private let scheduler: TaskScheduler
    private let recovery: TaskRecovery
    private let providers: TaskProviderRegistryPort
    private let acceptanceEvidence: TaskAcceptanceEvidenceProviding
    private let clock: TaskSchedulerClock
    private let requiredSteps: [String]

    /// Process-lifetime project registry. Persistence arrives with the project repository port
    /// in the composition task; nothing here writes SQL or guesses Git state.
    private var registeredProjects: [UUID: CodingProject] = [:]

    /// Tasks with an action currently suspended at a port; a second action is refused, not raced.
    private var inFlightTaskIDs: Set<UUID> = []

    init(
        repository: CodingTaskRepository,
        scheduler: TaskScheduler,
        recovery: TaskRecovery,
        providers: TaskProviderRegistryPort,
        acceptanceEvidence: TaskAcceptanceEvidenceProviding,
        clock: TaskSchedulerClock,
        requiredSteps: [String]
    ) {
        self.repository = repository
        self.scheduler = scheduler
        self.recovery = recovery
        self.providers = providers
        self.acceptanceEvidence = acceptanceEvidence
        self.clock = clock
        self.requiredSteps = requiredSteps
    }

    // MARK: - Projects and tasks

    /// Registers a project for this process after validating its display and repository identity.
    func createProject(
        name: String,
        repositoryPath: String,
        gitIdentity: String,
        protectedRefs: [String]
    ) async throws -> CodingProject {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw CodingTaskServiceError.invalidProjectInput(field: "name", reason: "must not be blank")
        }
        let trimmedPath = repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw CodingTaskServiceError.invalidProjectInput(field: "repositoryPath", reason: "must not be blank")
        }
        let trimmedIdentity = gitIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIdentity.isEmpty else {
            throw CodingTaskServiceError.invalidProjectInput(field: "gitIdentity", reason: "must not be blank")
        }

        let project = CodingProject(
            id: UUID(),
            name: trimmedName,
            repositoryPath: trimmedPath,
            gitIdentity: trimmedIdentity,
            protectedRefs: protectedRefs,
            createdAt: clock.now()
        )
        registeredProjects[project.id] = project
        return project
    }

    func project(id: UUID) -> CodingProject? {
        registeredProjects[id]
    }

    /// Creates a backlog task with ordered criteria; a repository rejection is surfaced, never absorbed.
    func createTask(
        projectID: UUID,
        title: String,
        objective: String,
        priority: Int,
        criteria: [String]
    ) async throws -> CodingTask {
        guard registeredProjects[projectID] != nil else {
            throw CodingTaskServiceError.projectNotFound(projectID)
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw CodingTaskServiceError.invalidTaskInput(field: "title", reason: "must not be blank")
        }
        let trimmedObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedObjective.isEmpty else {
            throw CodingTaskServiceError.invalidTaskInput(field: "objective", reason: "must not be blank")
        }
        guard priority >= 0 else {
            throw CodingTaskServiceError.invalidTaskInput(field: "priority", reason: "must not be negative")
        }
        let trimmedCriteria = criteria.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard trimmedCriteria.allSatisfy({ !$0.isEmpty }) else {
            throw CodingTaskServiceError.invalidTaskInput(field: "criteria", reason: "must not contain blank descriptions")
        }

        let taskID = UUID()
        let now = clock.now()
        let acceptanceCriteria = trimmedCriteria.map { description in
            CodingAcceptanceCriterion(taskID: taskID, description: description)
        }
        let task = CodingTask(
            id: taskID,
            projectID: projectID,
            title: trimmedTitle,
            objective: trimmedObjective,
            priority: priority,
            status: .backlog,
            stage: .analysis,
            version: 1,
            criteria: acceptanceCriteria,
            createdAt: now,
            updatedAt: now
        )
        try await mapped { try await self.repository.createTask(task) }
        return task
    }

    /// Adds a dependency edge after a pure cycle/self/duplicate test; a rejected edge never persists.
    func addDependency(
        projectID: UUID,
        prerequisiteTaskID: UUID,
        dependentTaskID: UUID
    ) async throws -> TaskDependency {
        let edge = TaskDependency(
            projectID: projectID,
            prerequisiteTaskID: prerequisiteTaskID,
            dependentTaskID: dependentTaskID
        )
        let snapshot = try await snapshot(projectID: projectID)
        do {
            _ = try TaskDependencyGraph.add(edge, to: snapshot.dependencies, tasks: snapshot.tasks)
        } catch let error as DependencyGraphError {
            throw CodingTaskServiceError.dependencyRejected(projectID: projectID, reason: error.localizedDescription)
        }
        try await mapped { try await self.repository.addDependency(edge) }
        return edge
    }

    // MARK: - Reads

    func snapshot(projectID: UUID) async throws -> CodingBoardSnapshot {
        try await mapped { try await self.repository.snapshot(projectID: projectID) }
    }

    func attemptHistory(taskID: UUID) async throws -> [TaskAttempt] {
        try await mapped { try await self.repository.attemptHistory(taskID: taskID) }
    }

    /// Evaluates the completion gate without mutating anything; reasons are always explicit.
    func evaluateAcceptance(taskID: UUID) async throws -> AcceptanceDecision {
        let task = try await requireTask(taskID)
        let context = try await acceptanceContext(task: task)
        return context.decision
    }

    /// Conservative launch-time reconciliation through the recovery actor.
    func reconcile(projectID: UUID) async -> RecoveryReport {
        await recovery.reconcile(projectID: projectID)
    }

    // MARK: - Execution control

    /// Starts a backlog or ready task: pre-checks the runtime, then arms and claims one attempt.
    ///
    /// An unsupported or unavailable runtime is refused before any scheduler call, so no claim,
    /// lease or transition is written for work this machine cannot run. Workspace readiness is
    /// surfaced exactly as the scheduler reports it (for example `.deferred(reason:)`).
    func start(taskID: UUID, expectedVersion: Int) async throws -> CodingTaskStartResult {
        try await withExclusiveTaskAction(taskID: taskID) {
            let task = try await self.requireTask(taskID)
            try Self.requireVersion(task: task, expectedVersion: expectedVersion)
            guard task.status == .backlog || task.status == .ready else {
                throw CodingTaskServiceError.actionNotAvailable(taskID: taskID, status: task.status)
            }
            guard task.currentAttemptID == nil else {
                return .deferred(reason: "activeAttempt")
            }

            let stage: TaskStage = task.status == .backlog ? .plan : task.stage
            switch await self.providers.candidate(for: task, stage: stage) {
            case .unsupported(let missingCapabilities):
                return .unavailable(.unsupported(missingCapabilities: missingCapabilities))
            case .unavailable(let reason):
                return .unavailable(.providerUnavailable(reason: reason))
            case .eligible:
                break
            }

            let entry = try await self.mapped { try await self.scheduler.retry(taskID: taskID) }
            return Self.startResult(from: entry)
        }
    }

    /// Suspends scheduling for the exact active attempt the caller saw.
    func pause(taskID: UUID, expectedAttemptID: UUID) async throws {
        try await withExclusiveTaskAction(taskID: taskID) {
            _ = try await self.requireTask(taskID)
            guard let active = try await self.activeAttempt(taskID: taskID) else {
                throw CodingTaskServiceError.noActiveAttempt(taskID: taskID)
            }
            guard active.id == expectedAttemptID else {
                throw CodingTaskServiceError.staleAttempt(
                    taskID: taskID,
                    expectedAttemptID: expectedAttemptID,
                    actualAttemptID: active.id
                )
            }
            try await self.mapped { try await self.scheduler.pause(taskID: taskID) }
        }
    }

    /// Resumes a paused or stopped task by re-arming it; the scheduler has no non-destructive resume.
    ///
    /// Resume replaces the suspended attempt with a fresh generation, so the caller must name the
    /// attempt it saw. A mismatch is a typed stale refusal, never a silent cancellation.
    @discardableResult
    func resume(taskID: UUID, expectedVersion: Int, expectedAttemptID: UUID?) async throws -> TaskScheduleEntry {
        try await withExclusiveTaskAction(taskID: taskID) {
            let task = try await self.requireTask(taskID)
            try Self.requireVersion(task: task, expectedVersion: expectedVersion)
            guard task.status == .blocked else {
                throw CodingTaskServiceError.actionNotAvailable(taskID: taskID, status: task.status)
            }
            let active = try await self.activeAttempt(taskID: taskID)
            guard active?.id == expectedAttemptID else {
                throw CodingTaskServiceError.staleAttempt(
                    taskID: taskID,
                    expectedAttemptID: expectedAttemptID,
                    actualAttemptID: active?.id
                )
            }
            return try await self.mapped { try await self.scheduler.retry(taskID: taskID) }
        }
    }

    /// Stops the task the caller saw; the expected attempt may be nil only when none is current.
    func stop(taskID: UUID, expectedAttemptID: UUID?) async throws {
        try await withExclusiveTaskAction(taskID: taskID) {
            let task = try await self.requireTask(taskID)
            guard task.currentAttemptID == expectedAttemptID else {
                throw CodingTaskServiceError.staleAttempt(
                    taskID: taskID,
                    expectedAttemptID: expectedAttemptID,
                    actualAttemptID: task.currentAttemptID
                )
            }
            try await self.mapped { try await self.scheduler.stop(taskID: taskID) }
        }
    }

    /// Re-arms a task and claims a new attempt, fenced to the exact active generation.
    ///
    /// The scheduler's `retry` cancels whichever attempt is active, so the service refuses to
    /// call it unless the caller's expected attempt identity and generation match the persisted
    /// active attempt; the review finding M5 gap is closed here.
    @discardableResult
    func retry(
        taskID: UUID,
        expectedActiveAttemptID: UUID?,
        expectedActiveGeneration: Int?
    ) async throws -> TaskScheduleEntry {
        try await withExclusiveTaskAction(taskID: taskID) {
            let task = try await self.requireTask(taskID)
            guard !task.status.isTerminal else {
                throw CodingTaskServiceError.actionNotAvailable(taskID: taskID, status: task.status)
            }
            let active = try await self.activeAttempt(taskID: taskID)
            guard active?.id == expectedActiveAttemptID, active?.generation == expectedActiveGeneration else {
                throw CodingTaskServiceError.staleAttempt(
                    taskID: taskID,
                    expectedAttemptID: expectedActiveAttemptID,
                    actualAttemptID: active?.id
                )
            }
            return try await self.mapped { try await self.scheduler.retry(taskID: taskID) }
        }
    }

    // MARK: - Review and acceptance

    /// Sends a reviewed task back to ready with the reviewer's feedback.
    func requestChanges(
        taskID: UUID,
        expectedVersion: Int,
        actor: String,
        feedback: String
    ) async throws -> CodingTask {
        try await withExclusiveTaskAction(taskID: taskID) {
            let trimmedActor = try Self.requireHumanText(actor, field: "actor")
            let trimmedFeedback = try Self.requireHumanText(feedback, field: "feedback")
            let task = try await self.requireTask(taskID)
            try Self.requireVersion(task: task, expectedVersion: expectedVersion)
            guard task.status == .review else {
                throw CodingTaskServiceError.actionNotAvailable(taskID: taskID, status: task.status)
            }
            return try await self.mapped {
                try await self.repository.transition(
                    taskID: taskID,
                    expectedVersion: expectedVersion,
                    action: .requestChanges(feedback: trimmedFeedback),
                    context: TaskTransitionContext(
                        fingerprint: task.currentAttemptID?.uuidString ?? "",
                        actor: trimmedActor
                    )
                )
            }
        }
    }

    /// Accepts a task only when the completion gate passes; the approval binds actor, attempt and content.
    func accept(taskID: UUID, expectedVersion: Int, actor: String) async throws -> CodingTask {
        try await withExclusiveTaskAction(taskID: taskID) {
            let trimmedActor = try Self.requireHumanText(actor, field: "actor")
            let task = try await self.requireTask(taskID)
            try Self.requireVersion(task: task, expectedVersion: expectedVersion)
            guard task.status == .review else {
                throw CodingTaskServiceError.actionNotAvailable(taskID: taskID, status: task.status)
            }

            let context = try await self.acceptanceContext(task: task)
            if case .blocked(let reasons) = context.decision {
                throw CodingTaskServiceError.acceptanceDenied(taskID: taskID, reasons: reasons)
            }

            let approval = try await self.matchingOrRecordedApproval(for: context, actor: trimmedActor)
            let evidenceIDs = context.evidence
                .filter { entry in
                    entry.taskID == task.id
                        && entry.status == .passed
                        && entry.workspaceFingerprint == context.currentFingerprint
                }
                .map(\.id)
            return try await self.mapped {
                try await self.repository.transition(
                    taskID: taskID,
                    expectedVersion: expectedVersion,
                    action: .accept,
                    context: TaskTransitionContext(
                        fingerprint: context.currentFingerprint,
                        actor: trimmedActor,
                        evidenceIDs: evidenceIDs,
                        humanApproval: approval
                    )
                )
            }
        }
    }

    // MARK: - Acceptance context

    private struct AcceptanceContext {
        let task: CodingTask
        let attempt: TaskAttempt
        let evidence: [VerificationEvidence]
        let findings: [ReviewFinding]
        let approvals: [TaskApproval]
        let currentFingerprint: String
        let decision: AcceptanceDecision
    }

    private func acceptanceContext(task: CodingTask) async throws -> AcceptanceContext {
        guard let attemptID = task.currentAttemptID else {
            throw CodingTaskServiceError.noActiveAttempt(taskID: task.id)
        }
        let history = try await attemptHistory(taskID: task.id)
        guard let attempt = history.first(where: { $0.id == attemptID }) else {
            throw CodingTaskServiceError.noActiveAttempt(taskID: task.id)
        }
        let inputs: TaskAcceptanceEvidence
        do {
            inputs = try await acceptanceEvidence.acceptanceEvidence(taskID: task.id)
        } catch {
            throw CodingTaskServiceError.acceptanceInputUnavailable(taskID: task.id, reason: String(describing: error))
        }
        let findings = try await mapped { try await self.repository.findings(taskID: task.id) }
        let approvals = try await mapped { try await self.repository.approvals(taskID: task.id) }
        let decision = AcceptanceGate.evaluate(
            task: task,
            attempt: attempt,
            evidence: inputs.evidence,
            findings: findings,
            approvals: approvals,
            currentFingerprint: inputs.currentFingerprint,
            requiredSteps: requiredSteps
        )
        return AcceptanceContext(
            task: task,
            attempt: attempt,
            evidence: inputs.evidence,
            findings: findings,
            approvals: approvals,
            currentFingerprint: inputs.currentFingerprint,
            decision: decision
        )
    }

    /// Returns an approval that already authorizes this exact attempt and content, or records one.
    private func matchingOrRecordedApproval(for context: AcceptanceContext, actor: String) async throws -> TaskApproval {
        let existing = context.approvals.first { approval in
            approval.authorizes(
                action: .accept,
                taskID: context.task.id,
                attemptID: context.attempt.id,
                fingerprint: context.currentFingerprint
            )
                && !approval.actor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let existing {
            return existing
        }
        let approval = TaskApproval(
            id: UUID(),
            taskID: context.task.id,
            attemptID: context.attempt.id,
            fingerprint: context.currentFingerprint,
            actor: actor,
            timestamp: clock.now(),
            action: .accept
        )
        try await mapped { try await self.repository.recordApproval(approval) }
        return approval
    }

    // MARK: - Guards and mapping

    private func withExclusiveTaskAction<T>(taskID: UUID, _ operation: () async throws -> T) async throws -> T {
        guard inFlightTaskIDs.insert(taskID).inserted else {
            throw CodingTaskServiceError.actionAlreadyInFlight(taskID: taskID)
        }
        defer { inFlightTaskIDs.remove(taskID) }
        return try await operation()
    }

    private func requireTask(_ taskID: UUID) async throws -> CodingTask {
        let task = try await mapped { try await self.repository.task(id: taskID) }
        guard let task else {
            throw CodingTaskServiceError.taskNotFound(taskID)
        }
        return task
    }

    private func activeAttempt(taskID: UUID) async throws -> TaskAttempt? {
        let history = try await attemptHistory(taskID: taskID)
        return history.first { $0.outcome == .inProgress && $0.endedAt == nil }
    }

    private func mapped<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            throw Self.mapError(error)
        }
    }

    private static func mapError(_ error: Error) -> CodingTaskServiceError {
        if let serviceError = error as? CodingTaskServiceError {
            return serviceError
        }
        if let repositoryError = error as? TaskRepositoryError {
            switch repositoryError {
            case .staleVersion(let taskID, let expected, let actual):
                return .staleVersion(taskID: taskID, expected: expected, actual: actual)
            case .taskNotFound(let id):
                return .taskNotFound(id)
            default:
                return .persistence(repositoryError)
            }
        }
        if let transitionError = error as? TaskTransitionError {
            return .transitionRejected(transitionError)
        }
        if let schedulerError = error as? TaskSchedulerError {
            switch schedulerError {
            case .taskNotFound(let id):
                return .taskNotFound(id)
            case .noActiveAttempt(let id):
                return .noActiveAttempt(taskID: id)
            case .retryNotAvailable(let taskID, let status):
                return .actionNotAvailable(taskID: taskID, status: status)
            case .attemptBudgetExhausted(let taskID, let used, let maximum):
                return .budgetExhausted(taskID: taskID, reason: "attempt budget exhausted (\(used)/\(maximum))")
            case .timeBudgetExhausted(let taskID, let used, let maximum):
                return .budgetExhausted(taskID: taskID, reason: "time budget exhausted (\(used)s/\(maximum)s)")
            case .toolCallBudgetExhausted(let taskID, let used, let maximum):
                return .budgetExhausted(taskID: taskID, reason: "tool-call budget exhausted (\(used)/\(maximum))")
            case .invalidCompletionOutcome(let outcome):
                return .schedulerRejected(reason: "invalid completion outcome \(outcome.rawValue)")
            }
        }
        return .schedulerRejected(reason: String(describing: error))
    }

    private static func requireVersion(task: CodingTask, expectedVersion: Int) throws {
        guard task.version == expectedVersion else {
            throw CodingTaskServiceError.staleVersion(
                taskID: task.id,
                expected: expectedVersion,
                actual: task.version
            )
        }
    }

    private static func requireHumanText(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CodingTaskServiceError.invalidTaskInput(field: field, reason: "must not be blank")
        }
        return trimmed
    }

    private static func startResult(from entry: TaskScheduleEntry) -> CodingTaskStartResult {
        switch entry.disposition {
        case .claimed(let attemptID, let generation):
            return .claimed(attemptID: attemptID, generation: generation)
        case .blocked(let reason):
            return .blocked(reason)
        case .deferred(let reason):
            return .deferred(reason: reason)
        }
    }
}
