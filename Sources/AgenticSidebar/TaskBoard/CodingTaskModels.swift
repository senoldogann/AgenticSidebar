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
