import Foundation

// MARK: - Recovery ports

/// Live provider work observed for a recovering attempt.
enum TaskProviderSessionStatus: Sendable, Equatable {
    /// A provider session bound to this exact attempt identity is still live.
    case active
    /// No provider session bound to this attempt identity remains.
    case stopped
    /// Liveness could not be determined.
    case unknown(reason: String)
}

/// Port answering whether live provider work owns a recovering attempt.
///
/// The implementation must bind its answer to the attempt identity (task, attempt,
/// generation and lease nonce); a session from another attempt or another app is not ownership.
protocol TaskProviderSessionInspecting: Sendable {
    func providerStatus(for attempt: TaskAttempt) async -> TaskProviderSessionStatus
}

/// Workspace binding observed for a recovering attempt.
enum TaskWorkspaceOwnershipStatus: Sendable, Equatable {
    /// A workspace record is still actively bound to this attempt: owned identity plus a live holder.
    case activelyOwned(TaskWorkspaceDescriptor)
    /// No active binding remains; the repository path is known so its lease can be released.
    case notActivelyOwned(repositoryPath: String)
    /// Ownership could not be inspected.
    case unknown(reason: String)
}

/// Port answering workspace ownership for a recovering attempt.
protocol TaskWorkspaceOwnershipInspecting: Sendable {
    func workspaceStatus(for attempt: TaskAttempt) async -> TaskWorkspaceOwnershipStatus
}

/// Proof that a live process belongs to one exact attempt generation.
struct TaskProcessOwnershipProof: Sendable, Equatable {
    let pid: Int32
    let attemptID: UUID
    let ownerNonce: String
    let executablePath: String
    let workspacePath: String
}

/// Process ownership observed for a recovering attempt.
enum TaskProcessOwnershipStatus: Sendable, Equatable {
    /// A live process proved to own this exact attempt (identity, nonce, executable and workspace all match).
    case owned(TaskProcessOwnershipProof)
    /// A live process exists but is not provably this attempt's.
    case foreign(pid: Int32, reason: String)
    /// No candidate process remains.
    case absent
    /// A process may exist but ownership cannot be proven; a PID alone is never ownership.
    case unknown(pid: Int32?, reason: String)
}

/// Port answering process ownership for a recovering attempt.
protocol TaskProcessOwnershipInspecting: Sendable {
    func processStatus(for attempt: TaskAttempt) async -> TaskProcessOwnershipStatus
}

// MARK: - Recovery report

/// Explicit recovery actions a human may take; recovery itself never executes them.
enum TaskRecoveryChoice: Sendable, Equatable {
    /// Retry the task after the user accepts the uncertainty.
    case retryTask(taskID: UUID)
    /// End the uncertain attempt and release its repository lease by hand.
    case abandonAttempt(attemptID: UUID)
    /// Terminate a foreign or unprovable process after human inspection.
    case terminateProcess(pid: Int32)
}

/// Per-task reconciliation outcome.
enum TaskRecoveryDisposition: Sendable, Equatable {
    /// No dangling in-flight attempt existed, or it was already settled.
    case noAction
    /// The attempt could not be proven stopped; the task is blocked for uncertain execution.
    case blockedUncertain(attemptID: UUID)
    /// The dangling attempt was ended and its repository lease released by exact identity.
    case reconciledAndReleased(attemptID: UUID, generation: Int, repositoryPath: String)
    /// A foreign or unprovable process exists; no destructive action was taken.
    case requiresUserChoice(attemptID: UUID, processID: Int32?, reason: String)
    /// Reconciliation could not complete for this task; the reason is explicit.
    case failed(reason: String)
}

/// One task's recovery reconciliation result.
struct TaskRecoveryEntry: Sendable, Equatable {
    let taskID: UUID
    let disposition: TaskRecoveryDisposition
    /// Choices offered to a human; never executed by recovery.
    let userChoices: [TaskRecoveryChoice]
}

/// Project-wide reconciliation report produced at launch.
struct RecoveryReport: Sendable, Equatable {
    let projectID: UUID
    let reconciledAt: Date
    let entries: [TaskRecoveryEntry]
    /// Set when the project snapshot could not be read at all; entries stay empty in that case.
    let failure: String?

    init(projectID: UUID, reconciledAt: Date, entries: [TaskRecoveryEntry], failure: String?) {
        self.projectID = projectID
        self.reconciledAt = reconciledAt
        self.entries = entries
        self.failure = failure
    }

    func entry(for taskID: UUID) -> TaskRecoveryEntry? {
        entries.first { $0.taskID == taskID }
    }

    var blockedUncertainTaskIDs: [UUID] {
        entries.compactMap { entry in
            if case .blockedUncertain = entry.disposition {
                return entry.taskID
            }
            return nil
        }
    }

    var reconciledTaskIDs: [UUID] {
        entries.compactMap { entry in
            if case .reconciledAndReleased = entry.disposition {
                return entry.taskID
            }
            return nil
        }
    }

    var requiresUserChoiceTaskIDs: [UUID] {
        entries.compactMap { entry in
            if case .requiresUserChoice = entry.disposition {
                return entry.taskID
            }
            return nil
        }
    }
}

// MARK: - Recovery actor

/// Conservative launch-time reconciliation for crash-orphaned task attempts.
///
/// Recovery inspects persisted in-flight attempts through injected provider-session,
/// workspace-ownership and process-ownership ports. It never dispatches work, never
/// retries and never terminates a process: anything it cannot prove stopped is blocked
/// with `uncertainExecution` and surfaced in the report for an explicit human choice.
actor TaskRecovery {
    private let repository: CodingTaskRepository
    private let providers: TaskProviderSessionInspecting
    private let workspaces: TaskWorkspaceOwnershipInspecting
    private let processes: TaskProcessOwnershipInspecting
    private let clock: TaskSchedulerClock
    private let recoveryID: String

    init(
        repository: CodingTaskRepository,
        providers: TaskProviderSessionInspecting,
        workspaces: TaskWorkspaceOwnershipInspecting,
        processes: TaskProcessOwnershipInspecting,
        clock: TaskSchedulerClock,
        recoveryID: String
    ) {
        self.repository = repository
        self.providers = providers
        self.workspaces = workspaces
        self.processes = processes
        self.clock = clock
        self.recoveryID = recoveryID
    }

    /// Stable block reason recorded for an in-flight attempt that recovery could not verify.
    nonisolated static func uncertainBlockReason(for attempt: TaskAttempt) -> TaskBlockReason {
        .uncertainExecution("attempt \(attempt.id.uuidString) generation \(attempt.generation) is unverified after recovery")
    }

    /// Reconciles every persisted in-flight attempt of a project.
    ///
    /// The pass never dispatches, retries or terminates: a dangling attempt is only ended
    /// and its repository lease only released when no live provider session, actively owned
    /// workspace or proved process owns it. Anything else is blocked for uncertain execution
    /// and surfaced for an explicit human choice.
    func reconcile(projectID: UUID) async -> RecoveryReport {
        let reconciledAt = clock.now()
        let snapshot: CodingBoardSnapshot
        do {
            snapshot = try await repository.snapshot(projectID: projectID)
        } catch {
            return RecoveryReport(
                projectID: projectID,
                reconciledAt: reconciledAt,
                entries: [],
                failure: "project snapshot failed: \(error)"
            )
        }

        var entries: [TaskRecoveryEntry] = []
        for task in snapshot.tasks {
            guard let attempt = snapshot.activeAttempts.first(where: { $0.taskID == task.id }) else {
                entries.append(TaskRecoveryEntry(taskID: task.id, disposition: .noAction, userChoices: []))
                continue
            }
            entries.append(await reconcileAttempt(attempt, task: task))
        }
        return RecoveryReport(projectID: projectID, reconciledAt: reconciledAt, entries: entries, failure: nil)
    }

    // MARK: - Per-attempt reconciliation

    private func reconcileAttempt(_ attempt: TaskAttempt, task: CodingTask) async -> TaskRecoveryEntry {
        let providerStatus = await providers.providerStatus(for: attempt)
        let workspaceStatus = await workspaces.workspaceStatus(for: attempt)
        let processStatus = await processes.processStatus(for: attempt)

        let expectedWorkspacePath: String?
        switch workspaceStatus {
        case .activelyOwned(let descriptor):
            expectedWorkspacePath = descriptor.workspacePath
        case .notActivelyOwned, .unknown:
            expectedWorkspacePath = nil
        }

        // A foreign or unprovable process is never settled by recovery: only a human decides.
        switch processStatus {
        case .foreign(let pid, let reason):
            return await requiresUserChoice(attempt: attempt, pid: pid, reason: reason)
        case .unknown(let pid, let reason):
            return await requiresUserChoice(attempt: attempt, pid: pid, reason: reason)
        case .owned(let proof):
            guard Self.isOwnershipProofValid(proof, attempt: attempt, expectedWorkspacePath: expectedWorkspacePath) else {
                return await requiresUserChoice(
                    attempt: attempt,
                    pid: proof.pid,
                    reason: "process ownership cannot be proven against the attempt identity"
                )
            }
            return await blockUncertain(attempt: attempt, pid: proof.pid)
        case .absent:
            break
        }

        switch providerStatus {
        case .active:
            return await blockUncertain(attempt: attempt, pid: nil)
        case .unknown:
            return await blockUncertain(attempt: attempt, pid: nil)
        case .stopped:
            break
        }

        switch workspaceStatus {
        case .activelyOwned, .unknown:
            return await blockUncertain(attempt: attempt, pid: nil)
        case .notActivelyOwned(let repositoryPath):
            return await reap(attempt: attempt, task: task, repositoryPath: repositoryPath)
        }
    }

    /// Validates a port-provided ownership proof against the exact persisted attempt identity.
    ///
    /// A PID alone is never ownership: the proof must bind the attempt ID and lease nonce,
    /// carry a non-empty executable path and match the workspace the attempt was bound to.
    private static func isOwnershipProofValid(
        _ proof: TaskProcessOwnershipProof,
        attempt: TaskAttempt,
        expectedWorkspacePath: String?
    ) -> Bool {
        guard proof.attemptID == attempt.id else { return false }
        guard let attemptNonce = attempt.leaseToken, !attemptNonce.isEmpty, proof.ownerNonce == attemptNonce else {
            return false
        }
        guard !proof.executablePath.isEmpty, !proof.workspacePath.isEmpty else { return false }
        guard let expectedWorkspacePath, proof.workspacePath == expectedWorkspacePath else { return false }
        return true
    }

    /// Ends a dangling attempt that is provably not owned and releases its lease by exact identity.
    private func reap(attempt: TaskAttempt, task: CodingTask, repositoryPath: String) async -> TaskRecoveryEntry {
        do {
            _ = try await repository.endAttempt(
                taskID: attempt.taskID,
                attemptID: attempt.id,
                expectedVersion: task.version,
                outcome: .cancelled,
                toolCallCount: nil,
                durationSeconds: max(0, Int(clock.now().timeIntervalSince(attempt.startedAt)))
            )
        } catch {
            return TaskRecoveryEntry(
                taskID: attempt.taskID,
                disposition: .failed(reason: "ending attempt \(attempt.id.uuidString) failed: \(error)"),
                userChoices: []
            )
        }

        var leaseReleaseFailure: String?
        do {
            try await repository.releaseRepositoryLease(
                repositoryPath: repositoryPath,
                taskID: attempt.taskID,
                attemptID: attempt.id
            )
        } catch {
            leaseReleaseFailure = "\(error)"
        }

        do {
            try await blockTaskForUncertainExecution(taskID: attempt.taskID, reason: Self.uncertainBlockReason(for: attempt))
        } catch {
            return TaskRecoveryEntry(
                taskID: attempt.taskID,
                disposition: .failed(reason: "attempt \(attempt.id.uuidString) was ended but blocking failed: \(error)"),
                userChoices: []
            )
        }

        if let leaseReleaseFailure {
            return TaskRecoveryEntry(
                taskID: attempt.taskID,
                disposition: .failed(
                    reason: "attempt \(attempt.id.uuidString) was ended but repository lease release failed: \(leaseReleaseFailure)"
                ),
                userChoices: []
            )
        }

        return TaskRecoveryEntry(
            taskID: attempt.taskID,
            disposition: .reconciledAndReleased(
                attemptID: attempt.id,
                generation: attempt.generation,
                repositoryPath: repositoryPath
            ),
            userChoices: [.retryTask(taskID: attempt.taskID)]
        )
    }

    private func blockUncertain(attempt: TaskAttempt, pid: Int32?) async -> TaskRecoveryEntry {
        do {
            try await blockTaskForUncertainExecution(taskID: attempt.taskID, reason: Self.uncertainBlockReason(for: attempt))
        } catch {
            return TaskRecoveryEntry(
                taskID: attempt.taskID,
                disposition: .failed(reason: "blocking task \(attempt.taskID.uuidString) failed: \(error)"),
                userChoices: []
            )
        }
        let choices: [TaskRecoveryChoice] = pid.map { [.terminateProcess(pid: $0)] } ?? []
        return TaskRecoveryEntry(
            taskID: attempt.taskID,
            disposition: .blockedUncertain(attemptID: attempt.id),
            userChoices: choices
        )
    }

    private func requiresUserChoice(attempt: TaskAttempt, pid: Int32?, reason: String) async -> TaskRecoveryEntry {
        do {
            try await blockTaskForUncertainExecution(taskID: attempt.taskID, reason: Self.uncertainBlockReason(for: attempt))
        } catch {
            return TaskRecoveryEntry(
                taskID: attempt.taskID,
                disposition: .failed(reason: "blocking task \(attempt.taskID.uuidString) failed: \(error)"),
                userChoices: []
            )
        }
        var choices: [TaskRecoveryChoice] = [.abandonAttempt(attemptID: attempt.id)]
        if let pid {
            choices.insert(.terminateProcess(pid: pid), at: 0)
        }
        return TaskRecoveryEntry(
            taskID: attempt.taskID,
            disposition: .requiresUserChoice(attemptID: attempt.id, processID: pid, reason: reason),
            userChoices: choices
        )
    }

    /// Blocks a task for uncertain execution when the state machine still allows it.
    ///
    /// Already blocked or terminal tasks are left untouched; recovery never unblocks or reopens work.
    private func blockTaskForUncertainExecution(taskID: UUID, reason: TaskBlockReason) async throws {
        guard let task = try await repository.task(id: taskID) else {
            throw TaskRepositoryError.taskNotFound(taskID)
        }
        guard task.status == .ready || task.status == .running || task.status == .review else {
            return
        }
        _ = try await repository.transition(
            taskID: taskID,
            expectedVersion: task.version,
            action: .block(reason: reason),
            context: TaskTransitionContext(fingerprint: recoveryID, actor: recoveryID)
        )
    }
}
