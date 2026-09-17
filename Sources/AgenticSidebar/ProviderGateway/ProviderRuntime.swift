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

    /// Taşıma katmanındaki üç dallı `catch` zincirinin tek karşılığı:
    /// bilinen sağlayıcı hatası aynen, iptal aynen, diğer her şey `.transport`.
    /// Davranış değişmeden tekrarı kaldırır.
    static func mapTransportError(_ error: Error) -> Error {
        if let runtimeError = error as? ProviderRuntimeError {
            return runtimeError
        }
        if error is CancellationError {
            return error
        }
        return ProviderRuntimeError.transport
    }
}

enum ProviderEvent: Equatable, Sendable {
    case assistantTextDelta(String)
    case activityStarted(ProviderActivityDescriptor)
    /// An in-progress activity (such as a subagent) received an update (e.g. inner tool calls or intermediate output).
    case activityUpdated(ProviderActivityDescriptor)
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
    /// Activities that ran in prior turns of this session, for restoring full context.
    let activityGroups: [AgentTurnActivityGroup]

    init(
        sessionID: UUID,
        configuration: SessionConfiguration,
        messages: [ChatMessage],
        speedMode: ResponseSpeedMode,
        mode: AgentMode = .build,
        extensionContext: String? = nil,
        activityGroups: [AgentTurnActivityGroup] = []
    ) {
        self.sessionID = sessionID
        self.configuration = configuration
        self.messages = messages
        self.speedMode = speedMode
        self.mode = mode
        self.extensionContext = extensionContext
        self.activityGroups = activityGroups
    }
}

struct ProviderStream: Sendable {
    /// Olay akışı. Geri-baskı sınırı imzada görünmez: akışı kuran
    /// `BoundedChannel` taşır (iki çalışma zamanında da kapasite 128).
    /// Tüketici akışın sınırlı olduğunu varsayar, sınır değerini değil.
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

    /// The tasks the agent is tracking for a session, when the provider keeps such
    /// a list.
    ///
    /// `nil` — not an empty list — means the provider has no such notion, which is
    /// why that is the default: an empty list would say "this turn has no tasks"
    /// and wipe a checklist the provider simply does not report.
    func sessionTodos(sessionID: UUID) async -> [AgentTodo]?
}

extension ProviderRuntime {
    func releaseSession(_ sessionID: UUID) async {}

    func sessionTodos(sessionID: UUID) async -> [AgentTodo]? { nil }
}
