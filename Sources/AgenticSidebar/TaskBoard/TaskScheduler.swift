import Foundation

/// Deterministic time source injected into the scheduler.
protocol TaskSchedulerClock: Sendable {
    func now() -> Date
}

/// Production clock backed by the system wall clock.
struct SystemTaskSchedulerClock: TaskSchedulerClock {
    func now() -> Date {
        Date()
    }
}

/// Owned workspace handle returned by the workspace preflight port.
struct TaskWorkspaceDescriptor: Sendable, Equatable {
    let workspaceID: UUID
    let workspacePath: String
    let repositoryPath: String
}

/// Result of a workspace ownership preflight for a task.
enum TaskWorkspacePreflightResult: Sendable, Equatable {
    case owned(TaskWorkspaceDescriptor)
    case notOwned(reason: String)
    case unavailable(reason: String)
}

/// Preflight port answering whether an owned workspace exists for a task.
protocol TaskWorkspacePreflightPort: Sendable {
    func preflight(projectID: UUID, taskID: UUID) async -> TaskWorkspacePreflightResult
}

/// Runtime candidate selected for a task stage.
enum TaskProviderCandidate: Sendable, Equatable {
    case eligible(runtimeID: String, modelID: String)
    case unsupported(missingCapabilities: [String])
    case unavailable(reason: String)
}

/// Provider registry port resolving an eligible runtime for a task.
protocol TaskProviderRegistryPort: Sendable {
    func candidate(for task: CodingTask, stage: TaskStage) async -> TaskProviderCandidate
}

/// Verification report produced for a completed attempt.
struct TaskVerificationReport: Sendable, Equatable {
    let passed: Bool
    let recipeName: String
    let detailsRedacted: String
}

/// Verifier port invoked for succeeded attempts.
protocol TaskVerifying: Sendable {
    func verify(
        task: CodingTask,
        attempt: TaskAttempt,
        workspace: TaskWorkspaceDescriptor
    ) async -> TaskVerificationReport
}

/// Usage reported by a runner for a finished attempt. Missing values stay unknown.
struct TaskAttemptUsage: Sendable, Equatable {
    let toolCallCount: Int?
    let durationSeconds: Int?
}

/// Disposition of a single task during a schedule pass.
enum TaskScheduleDisposition: Sendable, Equatable {
    case claimed(attemptID: UUID, generation: Int)
    case blocked(TaskBlockReason)
    case deferred(reason: String)
}

/// Per-task schedule decision.
struct TaskScheduleEntry: Sendable, Equatable {
    let taskID: UUID
    let disposition: TaskScheduleDisposition
}

/// Deterministic schedule pass result for one project.
struct TaskScheduleReport: Sendable, Equatable {
    let projectID: UUID
    let entries: [TaskScheduleEntry]

    init(projectID: UUID, entries: [TaskScheduleEntry]) {
        self.projectID = projectID
        self.entries = entries
    }

    var claimedTaskIDs: [UUID] {
        entries.compactMap { entry in
            if case .claimed = entry.disposition {
                return entry.taskID
            }
            return nil
        }
    }

    var blockedTaskIDs: [UUID] {
        entries.compactMap { entry in
            if case .blocked = entry.disposition {
                return entry.taskID
            }
            return nil
        }
    }

    var deferredTaskIDs: [UUID] {
        entries.compactMap { entry in
            if case .deferred = entry.disposition {
                return entry.taskID
            }
            return nil
        }
    }
}

/// Bookkeeping concern recorded after an attempt already reached a terminal outcome.
enum TaskCompletionConcern: Sendable, Equatable {
    case supersededByConcurrentActivity
    case bookkeepingRejected
}

/// Lease validation outcome for a completion callback.
enum TaskCompletionDisposition: Sendable, Equatable {
    case accepted
    case acceptedWithBookkeepingConcern(TaskCompletionConcern)
    case stale
}

/// Result of a validated attempt completion.
struct TaskAttemptCompletionReport: Sendable, Equatable {
    let taskID: UUID
    let attemptID: UUID
    let disposition: TaskCompletionDisposition
}

/// Errors raised by deterministic scheduling and lease ownership.
enum TaskSchedulerError: LocalizedError, Equatable, Sendable {
    case taskNotFound(UUID)
    case noActiveAttempt(UUID)
    case attemptBudgetExhausted(taskID: UUID, used: Int, maximum: Int)
    case timeBudgetExhausted(taskID: UUID, usedSeconds: Int, maximumSeconds: Int)
    case toolCallBudgetExhausted(taskID: UUID, used: Int, maximum: Int)
    case retryNotAvailable(taskID: UUID, status: TaskStatus)
    case invalidCompletionOutcome(AttemptOutcome)

    var errorDescription: String? {
        switch self {
        case .taskNotFound(let id):
            return "Task not found: \(id)"
        case .noActiveAttempt(let id):
            return "Task \(id) has no active attempt to control"
        case .attemptBudgetExhausted(let taskID, let used, let maximum):
            return "Task \(taskID) exhausted its attempt budget (\(used)/\(maximum))"
        case .timeBudgetExhausted(let taskID, let used, let maximum):
            return "Task \(taskID) exhausted its active time budget (\(used)s/\(maximum)s)"
        case .toolCallBudgetExhausted(let taskID, let used, let maximum):
            return "Task \(taskID) exhausted its tool-call budget (\(used)/\(maximum))"
        case .retryNotAvailable(let taskID, let status):
            return "Task \(taskID) cannot be retried from status \(status.rawValue)"
        case .invalidCompletionOutcome(let outcome):
            return "Completion outcome \(outcome.rawValue) is not terminal"
        }
    }
}

/// Deterministic, lease-owning scheduler for coding tasks.
///
/// The scheduler owns one active writing attempt per repository, enforces
/// attempt/time/tool-call budgets and keeps missing usage unknown. It performs
/// repository bookkeeping only; live execution stays inert until the workspace
/// preflight port returns an owned workspace.
actor TaskScheduler {
    static let attemptLeaseGraceSeconds: TimeInterval = 300
    static let repositoryLeaseGraceSeconds: TimeInterval = 600

    private struct ActiveAttemptRecord: Sendable {
        let taskID: UUID
        let projectID: UUID
        let attempt: TaskAttempt
        let lease: TaskLease
        let workspace: TaskWorkspaceDescriptor
        let startedAt: Date
    }

    private struct PendingAttemptIdentity: Sendable {
        let attemptID: UUID
        let generation: Int
        let ownerNonce: String
        let startedAt: Date
        let lease: TaskLease
    }

    private enum TaskBudgetState: Equatable {
        case available
        case attemptsExhausted(used: Int)
        case toolCallsExhausted(used: Int)
        case timeExhausted(usedSeconds: Int)
    }

    private let repository: CodingTaskRepository
    private let providers: TaskProviderRegistryPort
    private let workspaces: TaskWorkspacePreflightPort
    private let verifier: TaskVerifying
    private let clock: TaskSchedulerClock
    private let schedulerID: String

    private var activeAttempts: [UUID: ActiveAttemptRecord] = [:]
    private var pausedTaskIDs: Set<UUID> = []
    private var stoppedTaskIDs: Set<UUID> = []

    init(
        repository: CodingTaskRepository,
        providers: TaskProviderRegistryPort,
        workspaces: TaskWorkspacePreflightPort,
        verifier: TaskVerifying,
        clock: TaskSchedulerClock,
        schedulerID: String
    ) {
        self.repository = repository
        self.providers = providers
        self.workspaces = workspaces
        self.verifier = verifier
        self.clock = clock
        self.schedulerID = schedulerID
    }

    /// Lease currently owned by this scheduler instance for a task.
    func activeLease(taskID: UUID) -> TaskLease? {
        activeAttempts[taskID]?.lease
    }

    /// Runs one deterministic schedule pass for a project.
    @discardableResult
    func schedule(projectID: UUID) async throws -> TaskScheduleReport {
        let snapshot = try await repository.snapshot(projectID: projectID)
        var entries: [TaskScheduleEntry] = []

        for taskID in TaskDependencyGraph.readyIDs(tasks: snapshot.tasks, dependencies: snapshot.dependencies) {
            guard let task = snapshot.tasks.first(where: { $0.id == taskID }) else { continue }

            if pausedTaskIDs.contains(taskID) || stoppedTaskIDs.contains(taskID) {
                entries.append(TaskScheduleEntry(taskID: taskID, disposition: .deferred(reason: "schedulerSuspended")))
                continue
            }

            let history = try await repository.attemptHistory(taskID: taskID)
            switch budgetState(for: task, history: history) {
            case .available:
                break
            case .attemptsExhausted:
                await blockIfPossible(task, reason: .custom("attemptBudgetExhausted"))
                entries.append(TaskScheduleEntry(taskID: taskID, disposition: .blocked(.custom("attemptBudgetExhausted"))))
                continue
            case .toolCallsExhausted:
                await blockIfPossible(task, reason: .custom("toolCallBudgetExceeded"))
                entries.append(TaskScheduleEntry(taskID: taskID, disposition: .blocked(.custom("toolCallBudgetExceeded"))))
                continue
            case .timeExhausted:
                await blockIfPossible(task, reason: .custom("timeBudgetExhausted"))
                entries.append(TaskScheduleEntry(taskID: taskID, disposition: .blocked(.custom("timeBudgetExhausted"))))
                continue
            }

            if activeAttempts[taskID] != nil || history.contains(where: { $0.outcome == .inProgress }) {
                entries.append(TaskScheduleEntry(taskID: taskID, disposition: .deferred(reason: "activeAttempt")))
                continue
            }

            entries.append(try await claimEntry(for: task, projectID: projectID, history: history))
        }

        return TaskScheduleReport(projectID: projectID, entries: entries)
    }

    /// Suspends scheduling for a task without ending its attempt.
    func pause(taskID: UUID) async throws {
        guard let record = activeAttempts[taskID] else {
            throw TaskSchedulerError.noActiveAttempt(taskID)
        }
        pausedTaskIDs.insert(taskID)
        clearActiveAttemptIfOwned(taskID: taskID, attemptID: record.attempt.id)
        await releaseLease(for: record.workspace.repositoryPath, taskID: taskID, attemptID: record.attempt.id)

        guard let task = try await repository.task(id: taskID) else {
            throw TaskSchedulerError.taskNotFound(taskID)
        }
        if task.status == .running {
            try await block(task, reason: .custom("paused"))
        }
    }

    /// Terminates the active attempt of a task and requires an explicit retry.
    func stop(taskID: UUID) async throws {
        stoppedTaskIDs.insert(taskID)
        pausedTaskIDs.remove(taskID)

        if let record = activeAttempts[taskID] {
            clearActiveAttemptIfOwned(taskID: taskID, attemptID: record.attempt.id)
            await releaseLease(for: record.workspace.repositoryPath, taskID: taskID, attemptID: record.attempt.id)
            try await cancelAttempt(taskID: taskID, attemptID: record.attempt.id)
        } else if try await repository.task(id: taskID) != nil {
            let history = try await repository.attemptHistory(taskID: taskID)
            if let dangling = history.first(where: { $0.outcome == .inProgress }) {
                try await cancelAttempt(taskID: taskID, attemptID: dangling.id)
            }
        }

        guard let task = try await repository.task(id: taskID) else {
            throw TaskSchedulerError.taskNotFound(taskID)
        }
        if task.status == .ready || task.status == .running || task.status == .review {
            try await block(task, reason: .custom("stopped"))
        }
    }

    /// Re-arms a task and claims a new attempt within its remaining budgets.
    @discardableResult
    func retry(taskID: UUID) async throws -> TaskScheduleEntry {
        guard let task = try await repository.task(id: taskID) else {
            throw TaskSchedulerError.taskNotFound(taskID)
        }
        if task.status.isTerminal {
            throw TaskSchedulerError.retryNotAvailable(taskID: taskID, status: task.status)
        }

        pausedTaskIDs.remove(taskID)
        stoppedTaskIDs.remove(taskID)

        if let record = activeAttempts[taskID] {
            clearActiveAttemptIfOwned(taskID: taskID, attemptID: record.attempt.id)
            await releaseLease(for: record.workspace.repositoryPath, taskID: taskID, attemptID: record.attempt.id)
            try await cancelAttempt(taskID: taskID, attemptID: record.attempt.id)
        }

        var history = try await repository.attemptHistory(taskID: taskID)
        if let dangling = history.first(where: { $0.outcome == .inProgress }) {
            try await cancelAttempt(taskID: taskID, attemptID: dangling.id)
            history = try await repository.attemptHistory(taskID: taskID)
        }

        switch budgetState(for: task, history: history) {
        case .available:
            break
        case .attemptsExhausted(let used):
            await blockIfPossible(task, reason: .custom("attemptBudgetExhausted"))
            throw TaskSchedulerError.attemptBudgetExhausted(taskID: taskID, used: used, maximum: task.budget.maxAttempts)
        case .toolCallsExhausted(let used):
            await blockIfPossible(task, reason: .custom("toolCallBudgetExceeded"))
            throw TaskSchedulerError.toolCallBudgetExhausted(taskID: taskID, used: used, maximum: task.budget.maxToolCallsPerAttempt)
        case .timeExhausted(let used):
            await blockIfPossible(task, reason: .custom("timeBudgetExhausted"))
            throw TaskSchedulerError.timeBudgetExhausted(
                taskID: taskID,
                usedSeconds: used,
                maximumSeconds: task.budget.maxTaskDurationSeconds
            )
        }

        let armedTask = try await armForClaim(taskID: taskID)
        return try await claimEntry(for: armedTask, projectID: armedTask.projectID, history: history)
    }

    /// Validates lease ownership and records the terminal outcome of an attempt.
    ///
    /// The attempt record is only cleared and its repository lease only released while the
    /// stored record still belongs to this attempt, so concurrent retry/stop/pause activity
    /// can never lose the newer attempt nor delete its lease.
    @discardableResult
    func attemptDidComplete(
        taskID: UUID,
        attemptID: UUID,
        generation: Int,
        ownerNonce: String,
        outcome: AttemptOutcome,
        usage: TaskAttemptUsage
    ) async throws -> TaskAttemptCompletionReport {
        guard
            let record = ownedAttemptRecord(
                taskID: taskID,
                attemptID: attemptID,
                generation: generation,
                ownerNonce: ownerNonce
            )
        else {
            return TaskAttemptCompletionReport(taskID: taskID, attemptID: attemptID, disposition: .stale)
        }
        guard outcome != .inProgress else {
            throw TaskSchedulerError.invalidCompletionOutcome(outcome)
        }
        guard let task = try await repository.task(id: taskID) else {
            throw TaskSchedulerError.taskNotFound(taskID)
        }
        guard
            ownedAttemptRecord(taskID: taskID, attemptID: attemptID, generation: generation, ownerNonce: ownerNonce) != nil
        else {
            return TaskAttemptCompletionReport(taskID: taskID, attemptID: attemptID, disposition: .stale)
        }

        let previousDurations = try await repository.attemptHistory(taskID: taskID)
            .filter { $0.id != attemptID }
            .compactMap(\.durationSeconds)
        let duration = usage.durationSeconds ?? max(0, Int(clock.now().timeIntervalSince(record.startedAt)))

        let endedTask: CodingTask
        do {
            endedTask = try await repository.endAttempt(
                taskID: taskID,
                attemptID: attemptID,
                expectedVersion: task.version,
                outcome: outcome,
                toolCallCount: usage.toolCallCount,
                durationSeconds: duration
            )
        } catch let error as TaskRepositoryError where Self.isTerminalEndRejection(error) {
            return TaskAttemptCompletionReport(taskID: taskID, attemptID: attemptID, disposition: .stale)
        }

        let supersededByConcurrentActivity = hasNewerActivity(taskID: taskID, attemptID: attemptID)
        clearActiveAttemptIfOwned(taskID: taskID, attemptID: attemptID)
        await releaseLease(for: record.workspace.repositoryPath, taskID: taskID, attemptID: attemptID)

        if supersededByConcurrentActivity {
            return TaskAttemptCompletionReport(
                taskID: taskID,
                attemptID: attemptID,
                disposition: .acceptedWithBookkeepingConcern(.supersededByConcurrentActivity)
            )
        }

        if let toolCallCount = usage.toolCallCount, toolCallCount > task.budget.maxToolCallsPerAttempt {
            return try await performBookkeeping(taskID: taskID, attemptID: attemptID) {
                try await self.block(endedTask, reason: .custom("toolCallBudgetExceeded"))
            }
        }
        let accumulatedSeconds = previousDurations.reduce(0, +) + duration
        if accumulatedSeconds >= task.budget.maxTaskDurationSeconds {
            return try await performBookkeeping(taskID: taskID, attemptID: attemptID) {
                try await self.block(endedTask, reason: .custom("timeBudgetExhausted"))
            }
        }

        switch outcome {
        case .succeeded:
            let report = await verifier.verify(task: task, attempt: record.attempt, workspace: record.workspace)
            guard !hasNewerActivity(taskID: taskID, attemptID: attemptID) else {
                return TaskAttemptCompletionReport(
                    taskID: taskID,
                    attemptID: attemptID,
                    disposition: .acceptedWithBookkeepingConcern(.supersededByConcurrentActivity)
                )
            }
            if report.passed {
                let evidence = VerificationEvidence(
                    taskID: taskID,
                    attemptID: attemptID,
                    recipeName: report.recipeName,
                    passed: true,
                    detailsRedacted: report.detailsRedacted,
                    recordedAt: clock.now()
                )
                return try await performBookkeeping(taskID: taskID, attemptID: attemptID) {
                    try await self.repository.recordEvidence(evidence)
                    _ = try await self.repository.transition(
                        taskID: taskID,
                        expectedVersion: endedTask.version,
                        action: .submitForReview,
                        context: TaskTransitionContext(
                            fingerprint: attemptID.uuidString,
                            actor: self.schedulerID,
                            evidenceIDs: [evidence.id]
                        )
                    )
                }
            }
            return try await performBookkeeping(taskID: taskID, attemptID: attemptID) {
                try await self.block(endedTask, reason: .verificationFailed(report.detailsRedacted))
            }
        case .failed:
            return try await performBookkeeping(taskID: taskID, attemptID: attemptID) {
                try await self.block(endedTask, reason: .custom("attemptFailed"))
            }
        case .timedOut:
            return try await performBookkeeping(taskID: taskID, attemptID: attemptID) {
                try await self.block(endedTask, reason: .custom("attemptTimedOut"))
            }
        case .cancelled:
            return try await performBookkeeping(taskID: taskID, attemptID: attemptID) {
                try await self.block(endedTask, reason: .custom("attemptCancelled"))
            }
        case .inProgress:
            return TaskAttemptCompletionReport(taskID: taskID, attemptID: attemptID, disposition: .accepted)
        }
    }

    /// Runs post-terminal bookkeeping; a rejected transition yields a defined concern, never a stale failure.
    private func performBookkeeping(
        taskID: UUID,
        attemptID: UUID,
        _ work: () async throws -> Void
    ) async throws -> TaskAttemptCompletionReport {
        do {
            try await work()
            return TaskAttemptCompletionReport(taskID: taskID, attemptID: attemptID, disposition: .accepted)
        } catch let error as TaskRepositoryError where Self.isContention(error) {
            return TaskAttemptCompletionReport(
                taskID: taskID,
                attemptID: attemptID,
                disposition: .acceptedWithBookkeepingConcern(.bookkeepingRejected)
            )
        }
    }

    private func ownedAttemptRecord(
        taskID: UUID,
        attemptID: UUID,
        generation: Int,
        ownerNonce: String
    ) -> ActiveAttemptRecord? {
        guard !pausedTaskIDs.contains(taskID),
            let record = activeAttempts[taskID],
            record.attempt.id == attemptID,
            record.lease.isHeld(by: ownerNonce, attemptID: attemptID, generation: generation, at: clock.now())
        else {
            return nil
        }
        return record
    }

    private func hasNewerActivity(taskID: UUID, attemptID: UUID) -> Bool {
        if pausedTaskIDs.contains(taskID) || stoppedTaskIDs.contains(taskID) {
            return true
        }
        guard let record = activeAttempts[taskID] else { return false }
        return record.attempt.id != attemptID
    }

    private func clearActiveAttemptIfOwned(taskID: UUID, attemptID: UUID) {
        guard activeAttempts[taskID]?.attempt.id == attemptID else { return }
        activeAttempts[taskID] = nil
    }

    // MARK: - Eligibility and budgeting

    private func budgetState(for task: CodingTask, history: [TaskAttempt]) -> TaskBudgetState {
        if history.count >= task.budget.maxAttempts {
            return .attemptsExhausted(used: history.count)
        }
        if let worstToolCalls = history.compactMap(\.toolCallCount).max(),
            worstToolCalls > task.budget.maxToolCallsPerAttempt
        {
            return .toolCallsExhausted(used: worstToolCalls)
        }
        let knownSeconds = history.compactMap(\.durationSeconds).reduce(0, +)
        if knownSeconds >= task.budget.maxTaskDurationSeconds {
            return .timeExhausted(usedSeconds: knownSeconds)
        }
        return .available
    }

    // MARK: - Claim pipeline

    private func claimEntry(for task: CodingTask, projectID: UUID, history: [TaskAttempt]) async throws -> TaskScheduleEntry {
        let candidate = await providers.candidate(for: task, stage: task.stage)
        switch candidate {
        case .unsupported(let missingCapabilities):
            let reason = TaskBlockReason.unsupportedCapability(missingCapabilities.joined(separator: ","))
            await blockIfPossible(task, reason: reason)
            return TaskScheduleEntry(taskID: task.id, disposition: .blocked(reason))

        case .unavailable(let reason):
            return TaskScheduleEntry(taskID: task.id, disposition: .deferred(reason: "providerUnavailable:\(reason)"))

        case .eligible(let runtimeID, let modelID):
            let preflight = await workspaces.preflight(projectID: projectID, taskID: task.id)
            guard case .owned(let workspace) = preflight else {
                return TaskScheduleEntry(taskID: task.id, disposition: .deferred(reason: "workspaceNotOwned"))
            }

            let identity = makePendingIdentity(for: task, history: history)
            do {
                try await repository.acquireRepositoryLease(
                    repositoryPath: workspace.repositoryPath,
                    taskID: task.id,
                    attemptID: identity.attemptID,
                    leaseTimeoutSeconds: TimeInterval(task.budget.maxTaskDurationSeconds) + Self.repositoryLeaseGraceSeconds
                )
            } catch let error as TaskRepositoryError where Self.isContention(error) {
                return TaskScheduleEntry(taskID: task.id, disposition: .deferred(reason: "repositoryBusy"))
            }

            do {
                let attempt = try await claimAttempt(
                    task: task,
                    workspace: workspace,
                    runtimeID: runtimeID,
                    modelID: modelID,
                    history: history,
                    identity: identity
                )
                return TaskScheduleEntry(
                    taskID: task.id,
                    disposition: .claimed(attemptID: attempt.id, generation: attempt.generation)
                )
            } catch {
                await releaseLease(for: workspace.repositoryPath, taskID: task.id, attemptID: identity.attemptID)
                if let repositoryError = error as? TaskRepositoryError, Self.isContention(repositoryError) {
                    return TaskScheduleEntry(taskID: task.id, disposition: .deferred(reason: "claimRejected"))
                }
                throw error
            }
        }
    }

    private func makePendingIdentity(for task: CodingTask, history: [TaskAttempt]) -> PendingAttemptIdentity {
        let attemptID = UUID()
        let generation = (history.map(\.generation).max() ?? 0) + 1
        let now = clock.now()
        let ownerNonce = UUID().uuidString
        let leaseDuration = TimeInterval(task.budget.maxTaskDurationSeconds) + Self.attemptLeaseGraceSeconds
        let lease = TaskLease(
            attemptID: attemptID,
            generation: generation,
            ownerNonce: ownerNonce,
            expiration: now.addingTimeInterval(leaseDuration)
        )
        return PendingAttemptIdentity(
            attemptID: attemptID,
            generation: generation,
            ownerNonce: ownerNonce,
            startedAt: now,
            lease: lease
        )
    }

    private func claimAttempt(
        task: CodingTask,
        workspace: TaskWorkspaceDescriptor,
        runtimeID: String,
        modelID: String,
        history: [TaskAttempt],
        identity: PendingAttemptIdentity
    ) async throws -> TaskAttempt {
        let attempt = TaskAttempt(
            id: identity.attemptID,
            taskID: task.id,
            attemptSequence: history.count + 1,
            role: Self.role(for: task.stage),
            providerID: runtimeID,
            modelID: modelID,
            workspaceID: workspace.workspaceID,
            generation: identity.generation,
            leaseOwner: schedulerID,
            leaseToken: identity.ownerNonce,
            leaseExpiry: identity.lease.expiration,
            startedAt: identity.startedAt,
            endedAt: nil,
            outcome: .inProgress,
            toolCallCount: nil,
            durationSeconds: nil
        )
        let claimed = try await repository.claimAttempt(taskID: task.id, expectedVersion: task.version, attempt: attempt)
        activeAttempts[task.id] = ActiveAttemptRecord(
            taskID: task.id,
            projectID: task.projectID,
            attempt: claimed,
            lease: identity.lease,
            workspace: workspace,
            startedAt: identity.startedAt
        )
        return claimed
    }

    // MARK: - Task lifecycle helpers

    private func armForClaim(taskID: UUID) async throws -> CodingTask {
        guard var task = try await repository.task(id: taskID) else {
            throw TaskSchedulerError.taskNotFound(taskID)
        }
        let context = transitionContext()
        switch task.status {
        case .backlog:
            task = try await repository.transition(taskID: taskID, expectedVersion: task.version, action: .markReady, context: context)
        case .blocked:
            task = try await repository.transition(taskID: taskID, expectedVersion: task.version, action: .unblock, context: context)
        case .ready:
            break
        case .running:
            let blocked = try await repository.transition(
                taskID: taskID,
                expectedVersion: task.version,
                action: .block(reason: .custom("retry")),
                context: context
            )
            task = try await repository.transition(
                taskID: taskID,
                expectedVersion: blocked.version,
                action: .unblock,
                context: context
            )
        case .review, .done, .cancelled:
            throw TaskSchedulerError.retryNotAvailable(taskID: taskID, status: task.status)
        }
        return task
    }

    private func cancelAttempt(taskID: UUID, attemptID: UUID) async throws {
        guard let task = try await repository.task(id: taskID) else {
            throw TaskSchedulerError.taskNotFound(taskID)
        }
        let history = try await repository.attemptHistory(taskID: taskID)
        guard let attempt = history.first(where: { $0.id == attemptID && $0.outcome == .inProgress }) else {
            return
        }
        let duration = max(0, Int(clock.now().timeIntervalSince(attempt.startedAt)))
        _ = try await repository.endAttempt(
            taskID: taskID,
            attemptID: attemptID,
            expectedVersion: task.version,
            outcome: .cancelled,
            toolCallCount: nil,
            durationSeconds: duration
        )
    }

    private func blockIfPossible(_ task: CodingTask, reason: TaskBlockReason) async {
        guard task.status == .ready || task.status == .running || task.status == .review else {
            return
        }
        _ = try? await block(task, reason: reason)
    }

    @discardableResult
    private func block(_ task: CodingTask, reason: TaskBlockReason) async throws -> CodingTask {
        try await repository.transition(
            taskID: task.id,
            expectedVersion: task.version,
            action: .block(reason: reason),
            context: transitionContext()
        )
    }

    private func transitionContext() -> TaskTransitionContext {
        TaskTransitionContext(fingerprint: schedulerID, actor: schedulerID)
    }

    private func releaseLease(for repositoryPath: String, taskID: UUID, attemptID: UUID) async {
        try? await repository.releaseRepositoryLease(repositoryPath: repositoryPath, taskID: taskID, attemptID: attemptID)
    }

    private static func isContention(_ error: TaskRepositoryError) -> Bool {
        switch error {
        case .staleVersion, .activeAttemptConflict, .repositoryLeaseConflict, .nonMonotonicGeneration, .taskNotClaimable:
            return true
        default:
            return false
        }
    }

    private static func isTerminalEndRejection(_ error: TaskRepositoryError) -> Bool {
        switch error {
        case .staleVersion, .attemptNotActive:
            return true
        default:
            return false
        }
    }

    private static func role(for stage: TaskStage) -> AgentRole {
        switch stage {
        case .analysis, .plan:
            return .architect
        case .implementation, .verification:
            return .developer
        case .codeReview, .acceptance:
            return .reviewer
        case .qa:
            return .qa
        }
    }
}
