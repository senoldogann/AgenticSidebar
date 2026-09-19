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

/// Lease validation outcome for a completion callback.
enum TaskCompletionDisposition: Sendable, Equatable {
    case accepted
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
        activeAttempts[taskID] = nil
        await releaseLease(for: record.workspace.repositoryPath, taskID: taskID)

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
            activeAttempts[taskID] = nil
            await releaseLease(for: record.workspace.repositoryPath, taskID: taskID)
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
            activeAttempts[taskID] = nil
            await releaseLease(for: record.workspace.repositoryPath, taskID: taskID)
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
    @discardableResult
    func attemptDidComplete(
        taskID: UUID,
        attemptID: UUID,
        generation: Int,
        ownerNonce: String,
        outcome: AttemptOutcome,
        usage: TaskAttemptUsage
    ) async throws -> TaskAttemptCompletionReport {
        let now = clock.now()
        guard let record = activeAttempts[taskID],
            record.attempt.id == attemptID,
            record.lease.isHeld(by: ownerNonce, attemptID: attemptID, generation: generation, at: now)
        else {
            return TaskAttemptCompletionReport(taskID: taskID, attemptID: attemptID, disposition: .stale)
        }
        guard outcome != .inProgress else {
            throw TaskSchedulerError.invalidCompletionOutcome(outcome)
        }
        guard let task = try await repository.task(id: taskID) else {
            throw TaskSchedulerError.taskNotFound(taskID)
        }

        let previousDurations = try await repository.attemptHistory(taskID: taskID)
            .filter { $0.id != attemptID }
            .compactMap(\.durationSeconds)
        let duration = usage.durationSeconds ?? max(0, Int(now.timeIntervalSince(record.startedAt)))
        let endedTask = try await repository.endAttempt(
            taskID: taskID,
            attemptID: attemptID,
            expectedVersion: task.version,
            outcome: outcome,
            toolCallCount: usage.toolCallCount,
            durationSeconds: duration
        )

        activeAttempts[taskID] = nil
        await releaseLease(for: record.workspace.repositoryPath, taskID: taskID)

        if let toolCallCount = usage.toolCallCount, toolCallCount > task.budget.maxToolCallsPerAttempt {
            try await block(endedTask, reason: .custom("toolCallBudgetExceeded"))
            return TaskAttemptCompletionReport(taskID: taskID, attemptID: attemptID, disposition: .accepted)
        }
        let accumulatedSeconds = previousDurations.reduce(0, +) + duration
        if accumulatedSeconds >= task.budget.maxTaskDurationSeconds {
            try await block(endedTask, reason: .custom("timeBudgetExhausted"))
            return TaskAttemptCompletionReport(taskID: taskID, attemptID: attemptID, disposition: .accepted)
        }

        switch outcome {
        case .succeeded:
            let report = await verifier.verify(task: task, attempt: record.attempt, workspace: record.workspace)
            if report.passed {
                let evidence = VerificationEvidence(
                    taskID: taskID,
                    attemptID: attemptID,
                    recipeName: report.recipeName,
                    passed: true,
                    detailsRedacted: report.detailsRedacted,
                    recordedAt: now
                )
                try await repository.recordEvidence(evidence)
                _ = try await repository.transition(
                    taskID: taskID,
                    expectedVersion: endedTask.version,
                    action: .submitForReview,
                    context: TaskTransitionContext(
                        fingerprint: attemptID.uuidString,
                        actor: schedulerID,
                        evidenceIDs: [evidence.id]
                    )
                )
            } else {
                try await block(endedTask, reason: .verificationFailed(report.detailsRedacted))
            }
        case .failed:
            try await block(endedTask, reason: .custom("attemptFailed"))
        case .timedOut:
            try await block(endedTask, reason: .custom("attemptTimedOut"))
        case .cancelled:
            try await block(endedTask, reason: .custom("attemptCancelled"))
        case .inProgress:
            break
        }

        return TaskAttemptCompletionReport(taskID: taskID, attemptID: attemptID, disposition: .accepted)
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

            do {
                try await repository.acquireRepositoryLease(
                    repositoryPath: workspace.repositoryPath,
                    taskID: task.id,
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
                    history: history
                )
                return TaskScheduleEntry(
                    taskID: task.id,
                    disposition: .claimed(attemptID: attempt.id, generation: attempt.generation)
                )
            } catch let error as TaskRepositoryError where Self.isContention(error) {
                await releaseLease(for: workspace.repositoryPath, taskID: task.id)
                return TaskScheduleEntry(taskID: task.id, disposition: .deferred(reason: "claimRejected"))
            }
        }
    }

    private func claimAttempt(
        task: CodingTask,
        workspace: TaskWorkspaceDescriptor,
        runtimeID: String,
        modelID: String,
        history: [TaskAttempt]
    ) async throws -> TaskAttempt {
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
        let attempt = TaskAttempt(
            id: attemptID,
            taskID: task.id,
            attemptSequence: history.count + 1,
            role: Self.role(for: task.stage),
            providerID: runtimeID,
            modelID: modelID,
            workspaceID: workspace.workspaceID,
            generation: generation,
            leaseOwner: schedulerID,
            leaseToken: ownerNonce,
            leaseExpiry: lease.expiration,
            startedAt: now,
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
            lease: lease,
            workspace: workspace,
            startedAt: now
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

    private func releaseLease(for repositoryPath: String, taskID: UUID) async {
        try? await repository.releaseRepositoryLease(repositoryPath: repositoryPath, taskID: taskID)
    }

    private static func isContention(_ error: TaskRepositoryError) -> Bool {
        switch error {
        case .staleVersion, .activeAttemptConflict, .repositoryLeaseConflict, .nonMonotonicGeneration:
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
