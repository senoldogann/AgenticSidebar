import Foundation

enum ProviderRuntimeError: Error, Equatable, Sendable {
    case missingCredential
    case executableUnavailable
    case startupFailure
    case authenticationFailure
    case unavailable
    case rateLimited
    /// The request outgrew the model context window; the transcript has to be
    /// trimmed before another attempt can succeed.
    case contextLimitExceeded
    case transport
    case unexpectedResponse
}

enum ProviderEvent: Equatable, Sendable {
    case assistantTextDelta(String)
    case activityStarted(ProviderActivityDescriptor)
    /// The activity ended. The result travels with it: a tool's output and the
    /// file-change preview only exist on the backend's *final* part update, so
    /// without them the timeline had nothing to show for a finished tool.
    case activityFinished(
        ProviderActivityID,
        outcome: ProviderActivityOutcome,
        output: String? = nil,
        diff: String? = nil
    )
    case waiting
    case completed
}

struct ProviderRequest: Equatable, Sendable {
    let sessionID: UUID
    let configuration: SessionConfiguration
    let messages: [ChatMessage]
    let speedMode: ResponseSpeedMode
    let mode: AgentMode
    /// What the extensions tagged on this turn should add to the instructions.
    /// `nil` for an untagged turn, which is the common case and costs nothing.
    let extensionContext: String?

    init(
        sessionID: UUID,
        configuration: SessionConfiguration,
        messages: [ChatMessage],
        speedMode: ResponseSpeedMode,
        mode: AgentMode = .build,
        extensionContext: String? = nil
    ) {
        self.sessionID = sessionID
        self.configuration = configuration
        self.messages = messages
        self.speedMode = speedMode
        self.mode = mode
        self.extensionContext = extensionContext
    }
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

    /// Bir sohbet silindiğinde sağlayıcının o oturum için tuttuğu her şeyi
    /// bırakmasını ister.
    ///
    /// Durumsuz sağlayıcıların bırakacağı bir şey yoktur; durumlu olanlar
    /// (OpenCode) burada sunucu tarafındaki oturumu da kapatır, aksi halde her
    /// silinen sohbet arkasında ölü bir uzak oturum bırakır.
    func releaseSession(_ sessionID: UUID) async
}

extension ProviderRuntime {
    func releaseSession(_ sessionID: UUID) async {}
}
