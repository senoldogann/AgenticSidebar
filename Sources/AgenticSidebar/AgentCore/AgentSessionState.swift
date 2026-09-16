import Foundation

enum AgentSessionStatus: Equatable, Sendable {
    case idle
    case streaming
    case runningTool(String)
    case waiting
    case cancelling
    case completed
    case cancelled
    case failed
}

enum AgentSessionError: Error, Equatable, Sendable {
    case missingCredential
    case backendExecutableUnavailable
    case backendStartupFailure
    case authenticationFailure
    case providerUnavailable
    case rateLimited
    case unsupportedCapability
    case transportFailure
    case streamInterrupted
    case contextLimitExceeded
    case unexpectedBackendResponse
}

/// Non-fatal conditions worth telling the user about, such as a transcript that
/// had to be trimmed to fit the model context window.
enum AgentSessionNotice: Equatable, Sendable {
    case transcriptTrimmed(droppedMessageCount: Int)
}

struct AgentSessionState: Equatable, Sendable {
    let id: UUID
    var configuration: SessionConfiguration?
    var messages: [ChatMessage]
    var status: AgentSessionStatus
    var error: AgentSessionError?
    var notice: AgentSessionNotice?
    var startedAt: Date?
    var completedAt: Date?
    var activityGroups: [AgentTurnActivityGroup] = []

    init(
        id: UUID = UUID(),
        configuration: SessionConfiguration? = nil,
        messages: [ChatMessage] = [],
        status: AgentSessionStatus = .idle,
        error: AgentSessionError? = nil,
        notice: AgentSessionNotice? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.configuration = configuration
        self.messages = messages
        self.status = status
        self.error = error
        self.notice = notice
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}
