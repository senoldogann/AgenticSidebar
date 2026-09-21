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

/// Port that provisions the owned workspace an attempt is claimed against.
///
/// The workspace must exist and be bound *before* the attempt row is claimed: `create`
/// runs with the already-minted attempt identity, and the record it returns is what the
/// claim binds. `discardUnclaimed` removes a workspace whose attempt never claimed,
/// strictly by the exact `(workspaceID, attemptID)` identity pair that created it.
///
/// `resolveBase` keeps the base commit explicit instead of guessed: the scheduler never
/// resolves a moving reference itself, and only a full commit object name may reach `create`.
protocol TaskWorkspaceProvisioningPort: Sendable {
    /// Resolves the immutable base commit a fresh workspace for this task is created from.
    func resolveBase(for task: CodingTask) async throws -> WorkspaceBase

    /// Creates the owned workspace for the exact attempt identity.
    func create(task: CodingTask, attempt: TaskAttempt, base: WorkspaceBase) async throws -> WorkspaceRecord

    /// Discards a created workspace whose attempt never claimed, by exact identity only.
    func discardUnclaimed(workspaceID: UUID, attemptID: UUID) async throws
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
    case staleAttempt(
        taskID: UUID,
        expectedAttemptID: UUID?,
        expectedGeneration: Int?,
        actualAttemptID: UUID?,
        actualGeneration: Int?
    )

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
        case .staleAttempt(let taskID, let expectedAttemptID, let expectedGeneration, let actualAttemptID, let actualGeneration):
            return
                "Task \(taskID) active attempt changed: expected \(expectedAttemptID?.uuidString ?? "none")/gen \(expectedGeneration.map(String.init) ?? "none"), actual \(actualAttemptID?.uuidString ?? "none")/gen \(actualGeneration.map(String.init) ?? "none")"
        }
    }
}

/// Deterministic, lease-owning scheduler for coding tasks.
///
/// The scheduler owns one active writing attempt per repository, enforces
/// attempt/time/tool-call budgets and keeps missing usage unknown. It performs
/// repository bookkeeping only; an attempt is only claimed against an owned
/// workspace — created for the minted attempt identity through the provisioning
/// port before the claim, or already owned per the preflight port when no
/// provisioner is injected.
actor TaskScheduler {
    static let attemptLeaseGraceSeconds: TimeInterval = 300
    static let repositoryLeaseGraceSeconds: TimeInterval = 600

    /// Block reason values that mean a user suspension; only these may be resumed.
    static let pausedBlockReason = "paused"
    static let stoppedBlockReason = "stopped"

    /// True when the block reason is a user suspension rather than a system block.
    static func isUserSuspension(_ reason: TaskBlockReason?) -> Bool {
        guard case .custom(let value) = reason else { return false }
        return value == pausedBlockReason || value == stoppedBlockReason
    }

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

    private struct ActiveRunRecord: Sendable {
        let runID: UUID
        var session: (any TaskRunSession)?
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

    /// Optional workspace-before-claim provisioner.
    ///
    /// When present, the claim path creates the owned workspace for the minted attempt
    /// identity first and binds its `workspaceID` into the claim; when absent, the
    /// scheduler keeps the preflight-only behavior for already-owned workspaces.
    private let provisioning: (any TaskWorkspaceProvisioningPort)?

    /// Optional live dispatch port.
    ///
    /// When present, `dispatch` may start one run for the exact accepted attempt;
    /// when absent, live writing stays disabled and no run is ever started.
    private let dispatchPort: (any TaskRunningPort)?

    private var activeAttempts: [UUID: ActiveAttemptRecord] = [:]
    private var activeRuns: [UUID: ActiveRunRecord] = [:]
    private var pausedTaskIDs: Set<UUID> = []
    private var stoppedTaskIDs: Set<UUID> = []

    init(
        repository: CodingTaskRepository,
        providers: TaskProviderRegistryPort,
        workspaces: TaskWorkspacePreflightPort,
        verifier: TaskVerifying,
        clock: TaskSchedulerClock,
        schedulerID: String,
        provisioning: (any TaskWorkspaceProvisioningPort)?
    ) {
        self.init(
            repository: repository,
            providers: providers,
            workspaces: workspaces,
            verifier: verifier,
            clock: clock,
            schedulerID: schedulerID,
            provisioning: provisioning,
            dispatchPort: nil
        )
    }

    init(
        repository: CodingTaskRepository,
        providers: TaskProviderRegistryPort,
        workspaces: TaskWorkspacePreflightPort,
        verifier: TaskVerifying,
        clock: TaskSchedulerClock,
        schedulerID: String,
        provisioning: (any TaskWorkspaceProvisioningPort)?,
        dispatchPort: (any TaskRunningPort)?
    ) {
        self.repository = repository
        self.providers = providers
        self.workspaces = workspaces
        self.verifier = verifier
        self.clock = clock
        self.schedulerID = schedulerID
        self.provisioning = provisioning
        self.dispatchPort = dispatchPort
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

    /// Dispatches the exact claimed attempt to the injected running port.
    ///
    /// Every gate fails closed before any runtime call: an injected port, a single
    /// live run per task, the exact active attempt identity, the owned workspace
    /// identity, registry eligibility, accepted budgets and a human
    /// `executeRecipe` approval bound to the exact task, attempt and fingerprint.
    ///
    /// Events are consumed serially (a bounded stream therefore applies backpressure),
    /// only events matching the exact `(taskID, attemptID, generation)` identity may
    /// mutate state, and the terminal outcome is recorded through `attemptDidComplete`
    /// so the verification and acceptance flow continues unchanged. A stream that ends
    /// without a terminal event is an interruption, never a success.
    @discardableResult
    func dispatch(
        taskID: UUID,
        attemptID: UUID,
        generation: Int,
        fingerprint: String
    ) async throws -> TaskRunDispatchReport {
        guard let dispatchPort else {
            throw TaskDispatchRefusal.dispatchDisabled(taskID: taskID)
        }
        guard activeRuns[taskID] == nil else {
            throw TaskDispatchRefusal.dispatchAlreadyActive(taskID: taskID)
        }
        guard
            let record = activeAttempts[taskID],
            record.attempt.id == attemptID,
            record.attempt.generation == generation
        else {
            throw TaskDispatchRefusal.staleAttempt(
                taskID: taskID,
                expectedAttemptID: attemptID,
                expectedGeneration: generation,
                actualAttemptID: activeAttempts[taskID]?.attempt.id,
                actualGeneration: activeAttempts[taskID]?.attempt.generation
            )
        }

        // Reserve the single-flight slot before the first suspension point: a concurrent
        // duplicate dispatch loses here instead of overwriting this run token, and
        // stop/pause/retry can retire exactly this reservation while the gates below await.
        // Every exit path clears the reservation through the defer.
        let runID = UUID()
        activeRuns[taskID] = ActiveRunRecord(runID: runID, session: nil)
        defer { clearRunIfOwned(taskID: taskID, runID: runID) }

        guard let task = try await repository.task(id: taskID) else {
            throw TaskSchedulerError.taskNotFound(taskID)
        }
        guard task.status == .running else {
            throw TaskDispatchRefusal.taskNotRunning(taskID: taskID, status: task.status)
        }

        switch await workspaces.preflight(projectID: record.projectID, taskID: taskID) {
        case .owned(let current):
            guard current.workspaceID == record.workspace.workspaceID else {
                throw TaskDispatchRefusal.workspaceIdentityMismatch(
                    taskID: taskID,
                    expectedWorkspaceID: record.workspace.workspaceID,
                    actualWorkspaceID: current.workspaceID
                )
            }
        case .notOwned(let reason):
            throw TaskDispatchRefusal.workspaceNotOwned(taskID: taskID, reason: reason)
        case .unavailable(let reason):
            throw TaskDispatchRefusal.workspaceNotOwned(taskID: taskID, reason: reason)
        }

        switch await providers.candidate(for: task, stage: task.stage) {
        case .eligible:
            break
        case .unsupported(let missingCapabilities):
            throw TaskDispatchRefusal.providerNotEligible(taskID: taskID, missingCapabilities: missingCapabilities)
        case .unavailable(let reason):
            throw TaskDispatchRefusal.providerUnavailable(taskID: taskID, reason: reason)
        }

        let history = try await repository.attemptHistory(taskID: taskID)
        switch dispatchBudgetState(for: task, record: record, history: history) {
        case .available:
            break
        case .attemptsExhausted:
            throw TaskDispatchRefusal.budgetExhausted(taskID: taskID, reason: "attemptBudgetExhausted")
        case .toolCallsExhausted:
            throw TaskDispatchRefusal.budgetExhausted(taskID: taskID, reason: "toolCallBudgetExceeded")
        case .timeExhausted:
            throw TaskDispatchRefusal.budgetExhausted(taskID: taskID, reason: "timeBudgetExhausted")
        }

        let approvals = try await repository.approvals(taskID: taskID)
        let approved = approvals.contains { approval in
            approval.authorizes(
                action: .executeRecipe,
                taskID: taskID,
                attemptID: attemptID,
                fingerprint: fingerprint
            )
                && !approval.actor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard approved else {
            throw TaskDispatchRefusal.executeApprovalMissing(
                taskID: taskID,
                attemptID: attemptID,
                fingerprint: fingerprint
            )
        }

        // Re-validate after every gate await: stop/pause/retry may have retired this
        // reservation, replaced the attempt, suspended the task or blocked it while the
        // gates were in flight. The post-start runID check below stays as the last resort
        // for a retirement while the port is starting.
        guard let liveTask = try await repository.task(id: taskID) else {
            throw TaskSchedulerError.taskNotFound(taskID)
        }
        try requireDispatchReservation(
            taskID: taskID,
            attemptID: attemptID,
            generation: generation,
            runID: runID,
            task: liveTask
        )

        let request = TaskRunRequest(
            task: task,
            attempt: record.attempt,
            workspace: record.workspace,
            approvalPolicy: .approveSafe,
            deadline: record.startedAt.addingTimeInterval(TimeInterval(task.budget.maxTaskDurationSeconds))
        )
        let workspacePath = record.workspace.workspacePath
        let resolver: TaskRunApprovalResolver = { approvalRequest in
            TaskRunApprovalPolicy.resolve(
                toolName: approvalRequest.toolName,
                patterns: approvalRequest.patterns,
                workspacePath: workspacePath,
                delegationTarget: approvalRequest.delegationTarget
            )
        }

        // Between the revalidation above and the start call there is no suspension
        // point, so only a retirement that lands while `start` itself is in flight can
        // still race; the post-start runID check below is the last resort for that case.
        let session: any TaskRunSession
        do {
            session = try await dispatchPort.start(request, approvalResolver: resolver)
        } catch {
            throw TaskDispatchRefusal.runtimeStartFailed(taskID: taskID, reason: String(describing: error))
        }
        if activeRuns[taskID]?.runID == runID {
            activeRuns[taskID]?.session = session
        } else {
            // A concurrent stop/pause/retry retired this reservation while the port
            // was starting; the just-started run is cancelled and never consumed.
            await session.cancel()
        }

        var activityIDs: Set<String> = []
        var approvalDecisions: [TaskRunApprovalDecision] = []
        var outcome: AttemptOutcome = .cancelled
        var fencedByScheduler = false

        eventLoop: for await event in session.events {
            guard event.matches(taskID: taskID, attemptID: attemptID, generation: generation) else {
                continue
            }
            switch event.kind {
            case .activityStarted(let id, _):
                activityIDs.insert(id)
                if activityIDs.count > task.budget.maxToolCallsPerAttempt, !fencedByScheduler {
                    fencedByScheduler = true
                    await session.cancel()
                }
            case .approvalRequested(let id, let tool, let params):
                let approvalRequest = TaskRunApprovalRequest(
                    id: id,
                    toolName: tool,
                    patterns: Self.approvalPatterns(from: params),
                    delegationTarget: params["delegationTarget"]
                )
                let reply = await resolver(approvalRequest)
                approvalDecisions.append(TaskRunApprovalDecision(requestID: id, toolName: tool, reply: reply))
                if case .deny = reply, !fencedByScheduler {
                    fencedByScheduler = true
                    await session.cancel()
                }
            case .terminalSuccess:
                outcome = fencedByScheduler ? .cancelled : .succeeded
                break eventLoop
            case .terminalError:
                outcome = .failed
                break eventLoop
            case .interrupted:
                outcome = .cancelled
                break eventLoop
            default:
                break
            }
        }

        let toolCallCount = activityIDs.isEmpty ? nil : activityIDs.count
        let completion = try await attemptDidComplete(
            taskID: taskID,
            attemptID: attemptID,
            generation: generation,
            ownerNonce: record.lease.ownerNonce,
            outcome: outcome,
            usage: TaskAttemptUsage(toolCallCount: toolCallCount, durationSeconds: nil)
        )
        return TaskRunDispatchReport(
            taskID: taskID,
            attemptID: attemptID,
            outcome: outcome,
            toolCallCount: toolCallCount,
            approvalDecisions: approvalDecisions,
            completion: completion
        )
    }

    /// Cancels the live run bound to a task and awaits its cleanup.
    ///
    /// Only the exact run record is cleared, so cancelling a retired run can never
    /// touch a newer attempt's run. `cancel()` must finish the run's event stream.
    private func cancelActiveRun(taskID: UUID) async {
        guard let record = activeRuns[taskID] else { return }
        activeRuns[taskID] = nil
        guard let session = record.session else { return }
        await session.cancel()
    }

    private func clearRunIfOwned(taskID: UUID, runID: UUID) {
        guard activeRuns[taskID]?.runID == runID else { return }
        activeRuns[taskID] = nil
    }

    /// Fails closed unless the dispatch reservation still owns the exact attempt.
    ///
    /// Stop/pause/retry may retire the run token, replace the attempt, suspend the task
    /// or block it while the dispatch gates are in flight, so the exact reservation, the
    /// exact attempt identity, the suspension sets and the live task status must all
    /// still agree before a runtime may start.
    private func requireDispatchReservation(
        taskID: UUID,
        attemptID: UUID,
        generation: Int,
        runID: UUID,
        task: CodingTask
    ) throws {
        guard activeRuns[taskID]?.runID == runID else {
            throw TaskDispatchRefusal.staleAttempt(
                taskID: taskID,
                expectedAttemptID: attemptID,
                expectedGeneration: generation,
                actualAttemptID: activeAttempts[taskID]?.attempt.id,
                actualGeneration: activeAttempts[taskID]?.attempt.generation
            )
        }
        guard
            let liveRecord = activeAttempts[taskID],
            liveRecord.attempt.id == attemptID,
            liveRecord.attempt.generation == generation
        else {
            throw TaskDispatchRefusal.staleAttempt(
                taskID: taskID,
                expectedAttemptID: attemptID,
                expectedGeneration: generation,
                actualAttemptID: activeAttempts[taskID]?.attempt.id,
                actualGeneration: activeAttempts[taskID]?.attempt.generation
            )
        }
        guard !pausedTaskIDs.contains(taskID), !stoppedTaskIDs.contains(taskID), task.status == .running else {
            throw TaskDispatchRefusal.taskNotRunning(taskID: taskID, status: task.status)
        }
    }

    /// Splits the adapter's comma-joined `patterns` parameter back into entries.
    private static func approvalPatterns(from params: [String: String]) -> [String] {
        guard let joined = params["patterns"] else { return [] }
        return
            joined
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Budget acceptance for a claimed attempt.
    ///
    /// Prior attempts are measured exactly like the claim pipeline measures them; the
    /// active attempt's own elapsed time counts against the task duration because a
    /// dispatch after its deadline must not start a live run.
    private func dispatchBudgetState(
        for task: CodingTask,
        record: ActiveAttemptRecord,
        history: [TaskAttempt]
    ) -> TaskBudgetState {
        let prior = history.filter { $0.id != record.attempt.id }
        if prior.count >= task.budget.maxAttempts {
            return .attemptsExhausted(used: prior.count)
        }
        if let worstToolCalls = prior.compactMap(\.toolCallCount).max(),
            worstToolCalls > task.budget.maxToolCallsPerAttempt
        {
            return .toolCallsExhausted(used: worstToolCalls)
        }
        let elapsedSeconds = max(0, Int(clock.now().timeIntervalSince(record.startedAt)))
        let knownSeconds = prior.compactMap(\.durationSeconds).reduce(0, +) + elapsedSeconds
        if knownSeconds >= task.budget.maxTaskDurationSeconds {
            return .timeExhausted(usedSeconds: knownSeconds)
        }
        return .available
    }

    /// Suspends scheduling for a task without ending its attempt.
    ///
    /// A live run is cancelled and awaited before the task is blocked: a suspended
    /// task must not keep writing. The attempt row stays in progress until an
    /// explicit retry or reconciliation replaces it, exactly as before.
    func pause(taskID: UUID) async throws {
        guard activeAttempts[taskID] != nil else {
            throw TaskSchedulerError.noActiveAttempt(taskID)
        }
        pausedTaskIDs.insert(taskID)
        await cancelActiveRun(taskID: taskID)

        guard let task = try await repository.task(id: taskID) else {
            throw TaskSchedulerError.taskNotFound(taskID)
        }
        if task.status == .running {
            try await block(task, reason: .custom(Self.pausedBlockReason))
        }
    }

    /// Terminates the active attempt of a task and requires an explicit retry.
    ///
    /// A live run is cleared from the attempt record and cancelled before the lease
    /// is released, so the run's own completion can no longer mutate the task and a
    /// newer attempt's run is never touched.
    func stop(taskID: UUID) async throws {
        stoppedTaskIDs.insert(taskID)
        pausedTaskIDs.remove(taskID)

        if let record = activeAttempts[taskID] {
            clearActiveAttemptIfOwned(taskID: taskID, attemptID: record.attempt.id)
            await cancelActiveRun(taskID: taskID)
            await releaseLease(for: record.workspace.repositoryPath, taskID: taskID, attemptID: record.attempt.id)
            try await cancelAttempt(taskID: taskID, attemptID: record.attempt.id)
        } else if let task = try await repository.task(id: taskID) {
            let history = try await repository.attemptHistory(taskID: taskID)
            if let dangling = history.first(where: { $0.outcome == .inProgress }) {
                try await cancelAttempt(taskID: taskID, attemptID: dangling.id)
                await releaseLeaseOfTerminalAttempt(taskID: taskID, projectID: task.projectID, attemptID: dangling.id)
            }
        }

        guard let task = try await repository.task(id: taskID) else {
            throw TaskSchedulerError.taskNotFound(taskID)
        }
        if task.status == .ready || task.status == .running || task.status == .review {
            try await block(task, reason: .custom(Self.stoppedBlockReason))
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
            await cancelActiveRun(taskID: taskID)
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

    /// Fenced re-arm: the caller's expected attempt identity is revalidated before any
    /// cancellation, so a stale action can never cancel newer work.
    ///
    /// The unfenced `retry(taskID:)` stays for existing callers; every service path that
    /// replaces an attempt uses this fence.
    @discardableResult
    func retry(taskID: UUID, expectedAttemptID: UUID?, expectedGeneration: Int?) async throws -> TaskScheduleEntry {
        let actual = try await fencedActiveAttempt(taskID: taskID)
        guard actual?.id == expectedAttemptID, actual?.generation == expectedGeneration else {
            throw TaskSchedulerError.staleAttempt(
                taskID: taskID,
                expectedAttemptID: expectedAttemptID,
                expectedGeneration: expectedGeneration,
                actualAttemptID: actual?.id,
                actualGeneration: actual?.generation
            )
        }
        return try await retry(taskID: taskID)
    }

    /// Active attempt as this scheduler will cancel it: its owned record first, then any
    /// dangling in-progress row the repository still reports.
    private func fencedActiveAttempt(taskID: UUID) async throws -> TaskAttempt? {
        if let record = activeAttempts[taskID] {
            return record.attempt
        }
        let history = try await repository.attemptHistory(taskID: taskID)
        return history.first { $0.outcome == .inProgress && $0.endedAt == nil }
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
            if let provisioning {
                return try await provisionedClaimEntry(
                    for: task,
                    runtimeID: runtimeID,
                    modelID: modelID,
                    history: history,
                    provisioning: provisioning
                )
            }
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

    /// Workspace-before-claim path used when a provisioning port is injected.
    ///
    /// Order: mint attempt identity → resolve the immutable base → create the owned
    /// workspace for that exact identity → acquire the repository lease → claim the
    /// attempt bound to the created `workspaceID`. Any failure after creation discards
    /// the workspace by exact identity, so a rejected lease, a rejected claim or a
    /// thrown repository failure never leaves an orphan workspace behind. Claim
    /// failures are reported deferred; a discard failure is raised because leaving an
    /// orphan would be worse than a visibly failed schedule pass.
    private func provisionedClaimEntry(
        for task: CodingTask,
        runtimeID: String,
        modelID: String,
        history: [TaskAttempt],
        provisioning: any TaskWorkspaceProvisioningPort
    ) async throws -> TaskScheduleEntry {
        let identity = makePendingIdentity(for: task, history: history)
        let record: WorkspaceRecord
        do {
            let base = try await provisioning.resolveBase(for: task)
            let provisionalAttempt = makeAttempt(
                task: task,
                runtimeID: runtimeID,
                modelID: modelID,
                history: history,
                identity: identity,
                workspaceID: nil
            )
            record = try await provisioning.create(task: task, attempt: provisionalAttempt, base: base)
        } catch {
            return TaskScheduleEntry(
                taskID: task.id,
                disposition: .deferred(reason: "workspaceProvisioningFailed:\(error.localizedDescription)")
            )
        }
        let workspace = TaskWorkspaceDescriptor(
            workspaceID: record.workspaceID,
            workspacePath: record.workspacePath,
            repositoryPath: record.repositoryPath
        )

        do {
            try await repository.acquireRepositoryLease(
                repositoryPath: workspace.repositoryPath,
                taskID: task.id,
                attemptID: identity.attemptID,
                leaseTimeoutSeconds: TimeInterval(task.budget.maxTaskDurationSeconds) + Self.repositoryLeaseGraceSeconds
            )
        } catch {
            try await provisioning.discardUnclaimed(workspaceID: workspace.workspaceID, attemptID: identity.attemptID)
            if let repositoryError = error as? TaskRepositoryError, Self.isContention(repositoryError) {
                return TaskScheduleEntry(taskID: task.id, disposition: .deferred(reason: "repositoryBusy"))
            }
            throw error
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
            try await provisioning.discardUnclaimed(workspaceID: workspace.workspaceID, attemptID: identity.attemptID)
            if let repositoryError = error as? TaskRepositoryError, Self.isContention(repositoryError) {
                return TaskScheduleEntry(taskID: task.id, disposition: .deferred(reason: "claimRejected"))
            }
            return TaskScheduleEntry(
                taskID: task.id,
                disposition: .deferred(reason: "claimFailed:\(error.localizedDescription)")
            )
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
        let attempt = makeAttempt(
            task: task,
            runtimeID: runtimeID,
            modelID: modelID,
            history: history,
            identity: identity,
            workspaceID: workspace.workspaceID
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

    /// Builds the attempt row for a minted identity.
    ///
    /// The provisioning path passes `workspaceID: nil` for the pre-claim provisional
    /// attempt (the workspace does not exist yet); the claimed attempt always carries
    /// the exact workspace identity the claim is bound to.
    private func makeAttempt(
        task: CodingTask,
        runtimeID: String,
        modelID: String,
        history: [TaskAttempt],
        identity: PendingAttemptIdentity,
        workspaceID: UUID?
    ) -> TaskAttempt {
        TaskAttempt(
            id: identity.attemptID,
            taskID: task.id,
            attemptSequence: history.count + 1,
            role: Self.role(for: task.stage),
            providerID: runtimeID,
            modelID: modelID,
            workspaceID: workspaceID,
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

    /// Releases the repository lease of a dangling attempt once it is provably terminal.
    ///
    /// The dangling path has no in-memory workspace record, so the repository path is resolved
    /// through the workspace preflight port and the lease is released by the exact attempt
    /// identity that held it. Release stays best-effort: `stop` must not fail after the attempt
    /// is already cancelled.
    private func releaseLeaseOfTerminalAttempt(taskID: UUID, projectID: UUID, attemptID: UUID) async {
        guard let history = try? await repository.attemptHistory(taskID: taskID),
            let attempt = history.first(where: { $0.id == attemptID }),
            attempt.outcome != .inProgress
        else {
            return
        }
        guard case .owned(let workspace) = await workspaces.preflight(projectID: projectID, taskID: taskID) else {
            return
        }
        await releaseLease(for: workspace.repositoryPath, taskID: taskID, attemptID: attemptID)
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
