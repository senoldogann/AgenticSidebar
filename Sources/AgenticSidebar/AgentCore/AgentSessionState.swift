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
    case unsupportedCapability
    case transportFailure
    case streamInterrupted
    case unexpectedBackendResponse
}

struct AgentSessionState: Equatable, Sendable {
    let id: UUID
    var configuration: SessionConfiguration?
    var messages: [ChatMessage]
    var status: AgentSessionStatus
    var error: AgentSessionError?
    var startedAt: Date?
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        configuration: SessionConfiguration? = nil,
        messages: [ChatMessage] = [],
        status: AgentSessionStatus = .idle,
        error: AgentSessionError? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.configuration = configuration
        self.messages = messages
        self.status = status
        self.error = error
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}
