import Foundation

enum CodingAgentAdapterError: Error, LocalizedError, Equatable {
    case invalidProvider
    case serverUnavailable
    case invalidModel
    case unsupportedCapability(String)
    case unsupportedStage(TaskStage)
    case workspaceNotContained(expected: String, actual: String?)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidProvider:
            return "Invalid provider for coding agent adapter."
        case .serverUnavailable:
            return "Backend server is unavailable."
        case .invalidModel:
            return "Invalid model specified for coding agent adapter."
        case .unsupportedCapability(let cap):
            return "Unsupported capability: \(cap)"
        case .unsupportedStage(let stage):
            return "Unsupported task stage for adapter: \(stage.rawValue)"
        case .workspaceNotContained(let expected, let actual):
            return "Backend working directory (\(actual ?? "none")) does not match task workspace (\(expected))."
        case .executionFailed(let message):
            return "Execution failed: \(message)"
        }
    }
}

struct CodingAgentExecutionRequest: Sendable, Equatable {
    let taskID: UUID
    let attemptID: UUID
    let generation: Int
    let role: AgentRole
    let configuration: SessionConfiguration
    let objective: String
    let acceptanceCriteria: [CodingAcceptanceCriterion]
    let workspacePath: String
    let relevantFiles: [String]
    let stage: TaskStage
    let deadline: Date?
    let policySnapshot: [String: String]

    init(
        taskID: UUID,
        attemptID: UUID,
        generation: Int,
        role: AgentRole,
        configuration: SessionConfiguration,
        objective: String,
        acceptanceCriteria: [CodingAcceptanceCriterion],
        workspacePath: String,
        relevantFiles: [String] = [],
        stage: TaskStage = .plan,
        deadline: Date? = nil,
        policySnapshot: [String: String] = [:]
    ) {
        self.taskID = taskID
        self.attemptID = attemptID
        self.generation = generation
        self.role = role
        self.configuration = configuration
        self.objective = objective
        self.acceptanceCriteria = acceptanceCriteria
        self.workspacePath = workspacePath
        self.relevantFiles = relevantFiles
        self.stage = stage
        self.deadline = deadline
        self.policySnapshot = policySnapshot
    }
}

struct CodingAgentEvent: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case started
        case textDelta(String)
        case activityStarted(id: String, title: String)
        case activityUpdated(id: String, detail: String)
        case activityFinished(id: String)
        case approvalRequested(id: String, tool: String, params: [String: String])
        case questionAsked(id: String, prompt: String)
        case usage(inputTokens: Int, outputTokens: Int)
        case terminalSuccess
        case terminalError(String)
        case interrupted(String)
    }

    let taskID: UUID
    let attemptID: UUID
    let generation: Int
    let timestamp: Date
    let kind: Kind

    init(
        taskID: UUID,
        attemptID: UUID,
        generation: Int,
        timestamp: Date = Date(),
        kind: Kind
    ) {
        self.taskID = taskID
        self.attemptID = attemptID
        self.generation = generation
        self.timestamp = timestamp
        self.kind = kind
    }

    func matches(taskID: UUID, attemptID: UUID, generation: Int) -> Bool {
        self.taskID == taskID && self.attemptID == attemptID && self.generation == generation
    }
}

struct CodingAgentRun: Sendable {
    let events: AsyncStream<CodingAgentEvent>
    let cancelHandler: @Sendable () async -> Void

    init(
        events: AsyncStream<CodingAgentEvent>,
        cancel: @escaping @Sendable () async -> Void
    ) {
        self.events = events
        self.cancelHandler = cancel
    }

    func cancel() async {
        await cancelHandler()
    }

    func isTerminatedSuccessfully(events: [CodingAgentEvent]) -> Bool {
        Self.isTerminatedSuccessfully(events: events)
    }

    static func isTerminatedSuccessfully(events: [CodingAgentEvent]) -> Bool {
        guard
            let lastTerminal = events.last(where: {
                switch $0.kind {
                case .terminalSuccess, .terminalError, .interrupted:
                    return true
                default:
                    return false
                }
            })
        else {
            return false
        }

        switch lastTerminal.kind {
        case .terminalSuccess:
            return true
        default:
            return false
        }
    }
}

protocol CodingAgentRuntime: Sendable {
    var runtimeID: String { get }
    func capabilities(configuration: SessionConfiguration) async -> CodingAgentCapabilities
    func start(request: CodingAgentExecutionRequest) async throws -> CodingAgentRun
    func release(attemptID: UUID) async
}
