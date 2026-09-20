import Foundation

/// Unique project registered in the Task Board.
public struct CodingProject: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var repositoryPath: String
    public var gitIdentity: String
    public var protectedRefs: [String]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        repositoryPath: String,
        gitIdentity: String,
        protectedRefs: [String] = ["main", "master"],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.repositoryPath = repositoryPath
        self.gitIdentity = gitIdentity
        self.protectedRefs = protectedRefs
        self.createdAt = createdAt
    }
}

/// Status of a task on the task board.
public enum TaskStatus: String, Sendable, Codable, Equatable, CaseIterable {
    case backlog
    case ready
    case running
    case blocked
    case review
    case done
    case cancelled

    public var isTerminal: Bool {
        self == .done || self == .cancelled
    }
}

/// Workflow stage of a task.
public enum TaskStage: String, Sendable, Codable, Equatable, CaseIterable {
    case analysis
    case plan
    case implementation
    case verification
    case codeReview
    case qa
    case acceptance
}

/// Actionable reason why a task is blocked.
public enum TaskBlockReason: Sendable, Codable, Equatable {
    case prerequisitesNotSatisfied
    case unsupportedCapability(String)
    case rateLimited
    case approvalRequired
    case verificationFailed(String)
    case uncertainExecution(String)
    case custom(String)
}

/// Logical role assigned to an agent for an attempt.
public enum AgentRole: String, Sendable, Codable, Equatable, CaseIterable {
    case architect
    case developer
    case reviewer
    case qa
}

/// Acceptance criterion required for task completion.
public struct CodingAcceptanceCriterion: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public let taskID: UUID
    public var description: String
    public var isCompleted: Bool
    public var evidenceID: UUID?

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        description: String,
        isCompleted: Bool = false,
        evidenceID: UUID? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.description = description
        self.isCompleted = isCompleted
        self.evidenceID = evidenceID
    }
}

/// Dependency edge between two tasks within a project.
public struct TaskDependency: Sendable, Identifiable, Codable, Equatable {
    public var id: String { "\(prerequisiteTaskID.uuidString)->\(dependentTaskID.uuidString)" }
    public let projectID: UUID
    public let prerequisiteTaskID: UUID
    public let dependentTaskID: UUID

    public init(projectID: UUID, prerequisiteTaskID: UUID, dependentTaskID: UUID) {
        self.projectID = projectID
        self.prerequisiteTaskID = prerequisiteTaskID
        self.dependentTaskID = dependentTaskID
    }
}

/// Budget constraints for executing attempts.
public struct ExecutionBudget: Sendable, Codable, Equatable {
    public var maxAttempts: Int
    public var maxTaskDurationSeconds: Int
    public var maxToolCallsPerAttempt: Int

    public init(
        maxAttempts: Int = 3,
        maxTaskDurationSeconds: Int = 3600,
        maxToolCallsPerAttempt: Int = 300
    ) {
        self.maxAttempts = maxAttempts
        self.maxTaskDurationSeconds = maxTaskDurationSeconds
        self.maxToolCallsPerAttempt = maxToolCallsPerAttempt
    }
}

/// Outcome of an agent attempt.
public enum AttemptOutcome: String, Sendable, Codable, Equatable {
    case inProgress
    case succeeded
    case failed
    case cancelled
    case timedOut
}

/// Single execution attempt for a task.
public struct TaskAttempt: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public let taskID: UUID
    public let attemptSequence: Int
    public let role: AgentRole
    public let providerID: String
    public let modelID: String
    public let variantSnapshot: String?
    public let workspaceID: UUID?
    public let generation: Int
    public let leaseOwner: String?
    public let leaseToken: String?
    public let leaseExpiry: Date?
    public let startedAt: Date
    public var endedAt: Date?
    public var outcome: AttemptOutcome
    public var toolCallCount: Int?
    public var durationSeconds: Int?

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        attemptSequence: Int,
        role: AgentRole,
        providerID: String,
        modelID: String,
        variantSnapshot: String? = nil,
        workspaceID: UUID? = nil,
        generation: Int = 1,
        leaseOwner: String? = nil,
        leaseToken: String? = nil,
        leaseExpiry: Date? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        outcome: AttemptOutcome = .inProgress,
        toolCallCount: Int? = nil,
        durationSeconds: Int? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.attemptSequence = attemptSequence
        self.role = role
        self.providerID = providerID
        self.modelID = modelID
        self.variantSnapshot = variantSnapshot
        self.workspaceID = workspaceID
        self.generation = generation
        self.leaseOwner = leaseOwner
        self.leaseToken = leaseToken
        self.leaseExpiry = leaseExpiry
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.toolCallCount = toolCallCount
        self.durationSeconds = durationSeconds
    }
}

/// Exclusive ownership lease for a single attempt generation.
public struct TaskLease: Sendable, Codable, Equatable {
    public let attemptID: UUID
    public let generation: Int
    public let ownerNonce: String
    public let expiration: Date

    public init(
        attemptID: UUID,
        generation: Int,
        ownerNonce: String,
        expiration: Date
    ) {
        self.attemptID = attemptID
        self.generation = generation
        self.ownerNonce = ownerNonce
        self.expiration = expiration
    }

    /// Returns true when the lease is bound to the given attempt owner and has not expired.
    public func isHeld(by ownerNonce: String, attemptID: UUID, generation: Int, at date: Date) -> Bool {
        self.ownerNonce == ownerNonce
            && self.attemptID == attemptID
            && self.generation == generation
            && !hasExpired(at: date)
    }

    /// Returns true when the lease has reached its expiration instant.
    public func hasExpired(at date: Date) -> Bool {
        date >= expiration
    }
}

/// Scoped action in a human or system approval.
public enum ApprovalAction: String, Sendable, Codable, Equatable {
    case executeRecipe
    case accept
    case merge
    case push
    case discardWorkspace
}

/// Formal approval record binding an exact content fingerprint.
public struct TaskApproval: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public let taskID: UUID
    public let attemptID: UUID
    public let fingerprint: String
    public let actor: String
    public let timestamp: Date
    public let action: ApprovalAction

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        attemptID: UUID,
        fingerprint: String,
        actor: String,
        timestamp: Date = Date(),
        action: ApprovalAction
    ) {
        self.id = id
        self.taskID = taskID
        self.attemptID = attemptID
        self.fingerprint = fingerprint
        self.actor = actor
        self.timestamp = timestamp
        self.action = action
    }

    /// True when this approval authorizes exactly the given action on the given task,
    /// attempt and content fingerprint; any other content revokes its validity.
    public func authorizes(action: ApprovalAction, taskID: UUID, attemptID: UUID, fingerprint: String) -> Bool {
        self.action == action
            && self.taskID == taskID
            && self.attemptID == attemptID
            && self.fingerprint == fingerprint
    }
}

/// Severity of a review finding.
public enum ReviewFindingSeverity: String, Sendable, Codable, Equatable, CaseIterable {
    case low
    case medium
    case high
    case critical

    /// The blocking band: an open finding at or above this severity denies completion.
    public var blocksAcceptance: Bool {
        self == .high || self == .critical
    }
}

/// Lifecycle status of a review finding.
public enum ReviewFindingStatus: String, Sendable, Codable, Equatable {
    case open
    case dismissed
}

/// Errors raised when a finding dismissal lacks the human record it must carry.
public enum ReviewFindingError: Error, Sendable, Equatable {
    case missingDismissalActor(findingID: UUID)
    case missingDismissalReason(findingID: UUID)
}

/// Review finding raised against a task attempt.
///
/// A finding only leaves the open state through an explicit dismissal that records a
/// non-empty human actor and reason. A persisted row that claims `dismissed` without both
/// fields is treated as open by every consumer: dismissal can never happen implicitly.
/// `attemptID` identifies the reviewed attempt; nil means the finding is task-scoped.
public struct ReviewFinding: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public let taskID: UUID
    public let attemptID: UUID?
    public let severity: ReviewFindingSeverity
    public let summary: String
    public let status: ReviewFindingStatus
    public let dismissalActor: String?
    public let dismissalReason: String?
    public let dismissedAt: Date?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        attemptID: UUID? = nil,
        severity: ReviewFindingSeverity,
        summary: String,
        status: ReviewFindingStatus = .open,
        dismissalActor: String? = nil,
        dismissalReason: String? = nil,
        dismissedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.attemptID = attemptID
        self.severity = severity
        self.summary = summary
        self.status = status
        self.dismissalActor = dismissalActor
        self.dismissalReason = dismissalReason
        self.dismissedAt = dismissedAt
        self.createdAt = createdAt
    }

    /// True only when the dismissal recorded a non-empty human actor and reason.
    public var isDismissed: Bool {
        status == .dismissed && Self.hasHumanText(dismissalActor) && Self.hasHumanText(dismissalReason)
    }

    /// True while the finding still denies completion; an invalid dismissal never counts.
    public var isOpen: Bool { !isDismissed }

    /// Returns a dismissed copy, refusing to record a dismissal without actor and reason.
    public func dismissed(by actor: String, reason: String, at date: Date) throws -> ReviewFinding {
        let trimmedActor = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedActor.isEmpty else {
            throw ReviewFindingError.missingDismissalActor(findingID: id)
        }
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReason.isEmpty else {
            throw ReviewFindingError.missingDismissalReason(findingID: id)
        }
        return ReviewFinding(
            id: id,
            taskID: taskID,
            attemptID: attemptID,
            severity: severity,
            summary: summary,
            status: .dismissed,
            dismissalActor: trimmedActor,
            dismissalReason: trimmedReason,
            dismissedAt: date,
            createdAt: createdAt
        )
    }

    /// Whether the finding applies to the given attempt; task-scoped findings apply to all.
    public func applies(toAttempt attemptID: UUID) -> Bool {
        self.attemptID == nil || self.attemptID == attemptID
    }

    private static func hasHumanText(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Disposition of one verification step.
public enum VerificationEvidenceStatus: String, Sendable, Codable, Equatable {
    /// The command ran and exited zero, and the workspace revision stayed unchanged
    /// through the end of the run (including the post-final recomputation).
    case passed
    /// The command ran and failed, timed out, was cancelled, could not run at all, or the
    /// workspace revision changed after it ran.
    case failed
    /// The step did not run: an earlier required step failed, the caller cancelled, the
    /// workspace revision changed between steps, or the step is explicitly unavailable.
    case skipped
}

/// Redacted verification evidence for one recipe step.
///
/// `taskID`/`attemptID` are optional so the verification runner can record standalone
/// evidence before a task attaches it. `passed` is derived from `status`: only an actual
/// zero exit code on an unchanged workspace revision may report a pass.
/// `recipeVersion` records which recipe semantics produced the entry; nil means the row
/// was written before recipe versions were tracked and no version may be assumed.
public struct VerificationEvidence: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public let taskID: UUID?
    public let attemptID: UUID?
    public let recipeName: String
    public let stepName: String?
    public let status: VerificationEvidenceStatus
    public let exitCode: Int32?
    public let timedOut: Bool
    public let detailsRedacted: String
    public let workspaceFingerprint: String?
    public let blockedBy: String?
    public let recordedAt: Date
    public let recipeVersion: Int?

    public var passed: Bool { status == .passed }

    /// Task-scoped evidence without step detail; kept for callers that only record pass/fail.
    public init(
        id: UUID = UUID(),
        taskID: UUID,
        attemptID: UUID,
        recipeName: String,
        passed: Bool,
        detailsRedacted: String,
        recordedAt: Date = Date(),
        recipeVersion: Int? = nil
    ) {
        self.init(
            id: id,
            taskID: taskID,
            attemptID: attemptID,
            recipeName: recipeName,
            stepName: nil,
            status: passed ? .passed : .failed,
            exitCode: nil,
            timedOut: false,
            detailsRedacted: detailsRedacted,
            workspaceFingerprint: nil,
            blockedBy: nil,
            recordedAt: recordedAt,
            recipeVersion: recipeVersion
        )
    }

    public init(
        id: UUID = UUID(),
        taskID: UUID? = nil,
        attemptID: UUID? = nil,
        recipeName: String,
        stepName: String? = nil,
        status: VerificationEvidenceStatus,
        exitCode: Int32? = nil,
        timedOut: Bool = false,
        detailsRedacted: String,
        workspaceFingerprint: String? = nil,
        blockedBy: String? = nil,
        recordedAt: Date = Date(),
        recipeVersion: Int? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.attemptID = attemptID
        self.recipeName = recipeName
        self.stepName = stepName
        self.status = status
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.detailsRedacted = detailsRedacted
        self.workspaceFingerprint = workspaceFingerprint
        self.blockedBy = blockedBy
        self.recordedAt = recordedAt
        self.recipeVersion = recipeVersion
    }
}

/// Immutable coding task entity.
public struct CodingTask: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public let projectID: UUID
    public var title: String
    public var objective: String
    public var priority: Int
    public var status: TaskStatus
    public var stage: TaskStage
    public var blockReason: TaskBlockReason?
    public var previousStageBeforeBlock: TaskStage?
    public var version: Int
    public var criteria: [CodingAcceptanceCriterion]
    public var budget: ExecutionBudget
    public var currentAttemptID: UUID?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        title: String,
        objective: String,
        priority: Int = 1,
        status: TaskStatus = .backlog,
        stage: TaskStage = .analysis,
        blockReason: TaskBlockReason? = nil,
        previousStageBeforeBlock: TaskStage? = nil,
        version: Int = 1,
        criteria: [CodingAcceptanceCriterion] = [],
        budget: ExecutionBudget = ExecutionBudget(),
        currentAttemptID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.objective = objective
        self.priority = priority
        self.status = status
        self.stage = stage
        self.blockReason = blockReason
        self.previousStageBeforeBlock = previousStageBeforeBlock
        self.version = version
        self.criteria = criteria
        self.budget = budget
        self.currentAttemptID = currentAttemptID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
