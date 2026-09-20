import Foundation

/// Errors produced by repository persistence and optimistic concurrency controls.
public enum TaskRepositoryError: LocalizedError, Equatable, Sendable {
    case taskNotFound(UUID)
    case findingNotFound(UUID)
    case findingAlreadyDismissed(findingID: UUID)
    case staleVersion(taskID: UUID, expected: Int, actual: Int)
    case activeAttemptConflict(taskID: UUID, existingAttemptID: UUID)
    case repositoryLeaseConflict(repositoryPath: String, heldByTaskID: UUID)
    case attemptNotActive(taskID: UUID, attemptID: UUID)
    case nonMonotonicGeneration(taskID: UUID, minimumExclusive: Int, actual: Int)
    case taskNotClaimable(taskID: UUID, status: TaskStatus)
    case invalidApprovalActor(approvalID: UUID)
    case duplicateRecord(String)
    case foreignKeyViolation(String)
    case storeCorrupt(String)
    case readOnly(String)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .taskNotFound(let id):
            return "Task not found: \(id)"
        case .findingNotFound(let id):
            return "Review finding not found: \(id)"
        case .findingAlreadyDismissed(let findingID):
            return "Review finding \(findingID) is already dismissed"
        case .staleVersion(let id, let expected, let actual):
            return "Task \(id) version conflict: expected \(expected), actual \(actual)"
        case .activeAttemptConflict(let taskID, let existingAttemptID):
            return "Task \(taskID) already has an active attempt: \(existingAttemptID)"
        case .repositoryLeaseConflict(let path, let heldBy):
            return "Repository lease for \(path) is currently held by task \(heldBy)"
        case .attemptNotActive(let taskID, let attemptID):
            return "Attempt \(attemptID) is not active for task \(taskID)"
        case .nonMonotonicGeneration(let taskID, let minimumExclusive, let actual):
            return "Attempt generation for task \(taskID) must exceed \(minimumExclusive), got \(actual)"
        case .taskNotClaimable(let taskID, let status):
            return "Task \(taskID) cannot claim an attempt from status \(status.rawValue)"
        case .invalidApprovalActor(let approvalID):
            return "Approval \(approvalID) must record a non-blank human actor"
        case .duplicateRecord(let message):
            return "Duplicate record: \(message)"
        case .foreignKeyViolation(let message):
            return "Foreign key constraint violation: \(message)"
        case .storeCorrupt(let message):
            return "Database store is corrupted or invalid: \(message)"
        case .readOnly(let message):
            return "Store is in read-only mode: \(message)"
        case .underlying(let message):
            return "Database error: \(message)"
        }
    }
}

/// Project-scoped snapshot of tasks, dependencies, and active attempts.
public struct CodingBoardSnapshot: Sendable, Codable, Equatable {
    public let projectID: UUID
    public var tasks: [CodingTask]
    public var dependencies: [TaskDependency]
    public var activeAttempts: [TaskAttempt]

    public init(
        projectID: UUID,
        tasks: [CodingTask] = [],
        dependencies: [TaskDependency] = [],
        activeAttempts: [TaskAttempt] = []
    ) {
        self.projectID = projectID
        self.tasks = tasks
        self.dependencies = dependencies
        self.activeAttempts = activeAttempts
    }
}

/// Persistent definition of an agent profile and its authorized capabilities.
public struct AgentProfile: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var role: AgentRole
    public var capabilities: [String]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        role: AgentRole,
        capabilities: [String],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.capabilities = capabilities
        self.createdAt = createdAt
    }
}

/// Redacted typed event recorded during task execution.
public struct CodingTaskEvent: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public let taskID: UUID
    public let attemptID: UUID?
    public let timestamp: Date
    public let kind: String
    public let redactedPayload: String

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        attemptID: UUID? = nil,
        timestamp: Date = Date(),
        kind: String,
        redactedPayload: String
    ) {
        self.id = id
        self.taskID = taskID
        self.attemptID = attemptID
        self.timestamp = timestamp
        self.kind = kind
        self.redactedPayload = redactedPayload
    }
}

/// Protocol defining transactional persistence operations for coding tasks and attempts.
public protocol CodingTaskRepository: Sendable {
    func snapshot(projectID: UUID) async throws -> CodingBoardSnapshot
    func createTask(_ task: CodingTask) async throws
    func addDependency(_ dependency: TaskDependency) async throws
    func task(id: UUID) async throws -> CodingTask?
    func attemptHistory(taskID: UUID) async throws -> [TaskAttempt]
    func transition(
        taskID: UUID,
        expectedVersion: Int,
        action: TaskAction,
        context: TaskTransitionContext
    ) async throws -> CodingTask
    func claimAttempt(
        taskID: UUID,
        expectedVersion: Int,
        attempt: TaskAttempt
    ) async throws -> TaskAttempt
    func endAttempt(
        taskID: UUID,
        attemptID: UUID,
        expectedVersion: Int,
        outcome: AttemptOutcome,
        toolCallCount: Int?,
        durationSeconds: Int?
    ) async throws -> CodingTask
    func acquireRepositoryLease(
        repositoryPath: String,
        taskID: UUID,
        attemptID: UUID,
        leaseTimeoutSeconds: TimeInterval
    ) async throws
    func releaseRepositoryLease(
        repositoryPath: String,
        taskID: UUID,
        attemptID: UUID
    ) async throws
    func appendEvent(_ event: CodingTaskEvent) async throws
    func recordEvidence(_ evidence: VerificationEvidence) async throws
    func recordFinding(_ finding: ReviewFinding) async throws
    func findings(taskID: UUID) async throws -> [ReviewFinding]
    func dismissFinding(
        findingID: UUID,
        actor: String,
        reason: String,
        at date: Date
    ) async throws -> ReviewFinding
    func recordApproval(_ approval: TaskApproval) async throws
    func approvals(taskID: UUID) async throws -> [TaskApproval]
    func saveAgentProfile(_ profile: AgentProfile) async throws
    func loadAgentProfile(id: UUID) async throws -> AgentProfile?
}
