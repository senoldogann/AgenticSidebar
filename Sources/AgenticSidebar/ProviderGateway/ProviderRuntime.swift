import Foundation

enum ProviderRuntimeError: Error, Equatable, Sendable {
    case missingCredential
    case executableUnavailable
    case startupFailure
    case authenticationFailure
    case unavailable
    case transport
    case unexpectedResponse
}

enum ProviderEvent: Equatable, Sendable {
    case assistantTextDelta(String)
    case activityStarted(ProviderActivityDescriptor)
    case activityFinished(
        ProviderActivityID,
        outcome: ProviderActivityOutcome
    )
    case waiting
    case completed
}

struct ProviderRequest: Equatable, Sendable {
    let sessionID: UUID
    let configuration: SessionConfiguration
    let messages: [ChatMessage]
}

struct ProviderStream: Sendable {
    let events: AsyncThrowingStream<ProviderEvent, Error>
    private let cancellation: @Sendable () async -> Void

    init(
        events: AsyncThrowingStream<ProviderEvent, Error>,
        cancellation: @escaping @Sendable () async -> Void = {}
    ) {
        self.events = events
        self.cancellation = cancellation
    }

    func cancel() async {
        await cancellation()
    }
}

protocol ProviderRuntime: Sendable {
    var id: ProviderID { get }

    func capabilities() async throws -> ProviderCapabilities
    func startStream(for request: ProviderRequest) async throws -> ProviderStream
}
