import Foundation

/// Actions that trigger a state transition on a CodingTask.
public enum TaskAction: Sendable, Codable, Equatable {
    case markReady
    case startAttempt(attemptID: UUID, role: AgentRole)
    case block(reason: TaskBlockReason)
    case unblock
    case submitForReview
    case requestChanges(feedback: String)
    case accept
    case cancel
}

/// Context accompanying a transition request.
public struct TaskTransitionContext: Sendable, Equatable {
    public let fingerprint: String
    public let actor: String
    public let evidenceIDs: [UUID]
    public let humanApproval: TaskApproval?

    public init(
        fingerprint: String,
        actor: String,
        evidenceIDs: [UUID] = [],
        humanApproval: TaskApproval? = nil
    ) {
        self.fingerprint = fingerprint
        self.actor = actor
        self.evidenceIDs = evidenceIDs
        self.humanApproval = humanApproval
    }
}

/// Errors raised when a task transition is invalid or lacks required evidence.
public enum TaskTransitionError: Error, Sendable, Equatable {
    case illegalTransition(from: TaskStatus, to: TaskStatus, reason: String)
    case taskTerminal(status: TaskStatus)
    case missingHumanAcceptance
    case missingVerificationEvidence
    case fingerprintMismatch(expected: String, actual: String)
    case staleVersion(expected: Int, actual: Int)
    case unmetCriteria([UUID])
}

/// Guarded, deterministic state machine for task lifecycle management.
public enum TaskStateMachine {

    /// Executes a guarded transition returning a newly updated task.
    public static func transition(
        _ task: CodingTask,
        action: TaskAction,
        context: TaskTransitionContext
    ) throws -> CodingTask {
        // Invariant: Terminal tasks (done, cancelled) cannot be mutated.
        guard !task.status.isTerminal else {
            throw TaskTransitionError.taskTerminal(status: task.status)
        }

        var updated = task

        switch action {
        case .markReady:
            guard task.status == .backlog || task.status == .blocked else {
                throw TaskTransitionError.illegalTransition(
                    from: task.status,
                    to: .ready,
                    reason: "markReady is only legal from backlog or blocked"
                )
            }
            updated.status = .ready
            updated.stage = .plan
            updated.blockReason = nil
            updated.previousStageBeforeBlock = nil

        case .startAttempt(let attemptID, _):
            guard task.status == .ready else {
                throw TaskTransitionError.illegalTransition(
                    from: task.status,
                    to: .running,
                    reason: "startAttempt is only legal from ready"
                )
            }
            updated.status = .running
            updated.stage = .implementation
            updated.currentAttemptID = attemptID

        case .block(let reason):
            guard task.status == .ready || task.status == .running || task.status == .review else {
                throw TaskTransitionError.illegalTransition(
                    from: task.status,
                    to: .blocked,
                    reason: "block is only legal from ready, running, or review"
                )
            }
            updated.previousStageBeforeBlock = task.stage
            updated.status = .blocked
            updated.blockReason = reason

        case .unblock:
            guard task.status == .blocked else {
                throw TaskTransitionError.illegalTransition(
                    from: task.status,
                    to: .ready,
                    reason: "unblock is only legal from blocked"
                )
            }
            updated.status = .ready
            updated.stage = task.previousStageBeforeBlock ?? .plan
            updated.blockReason = nil
            updated.previousStageBeforeBlock = nil

        case .submitForReview:
            guard task.status == .running else {
                throw TaskTransitionError.illegalTransition(
                    from: task.status,
                    to: .review,
                    reason: "submitForReview is only legal from running"
                )
            }
            guard !context.evidenceIDs.isEmpty else {
                throw TaskTransitionError.missingVerificationEvidence
            }
            updated.status = .review
            updated.stage = .acceptance

        case .requestChanges:
            guard task.status == .review else {
                throw TaskTransitionError.illegalTransition(
                    from: task.status,
                    to: .ready,
                    reason: "requestChanges is only legal from review"
                )
            }
            updated.status = .ready
            updated.stage = .plan

        case .accept:
            guard task.status == .review else {
                throw TaskTransitionError.illegalTransition(
                    from: task.status,
                    to: .done,
                    reason: "accept is only legal from review state"
                )
            }

            // Invariant: Verification evidence is required.
            guard !context.evidenceIDs.isEmpty else {
                throw TaskTransitionError.missingVerificationEvidence
            }

            // Invariant: All acceptance criteria must be satisfied.
            let unmet = task.criteria.filter { !$0.isCompleted }.map(\.id)
            guard unmet.isEmpty else {
                throw TaskTransitionError.unmetCriteria(unmet)
            }

            // Invariant: Human acceptance approval must match task and exact fingerprint.
            guard let approval = context.humanApproval, approval.action == .accept else {
                throw TaskTransitionError.missingHumanAcceptance
            }
            guard approval.taskID == task.id else {
                throw TaskTransitionError.missingHumanAcceptance
            }
            guard approval.fingerprint == context.fingerprint else {
                throw TaskTransitionError.fingerprintMismatch(
                    expected: context.fingerprint,
                    actual: approval.fingerprint
                )
            }

            updated.status = .done
            updated.stage = .acceptance

        case .cancel:
            updated.status = .cancelled
        }

        updated.version = task.version + 1
        updated.updatedAt = Date()
        return updated
    }
}
