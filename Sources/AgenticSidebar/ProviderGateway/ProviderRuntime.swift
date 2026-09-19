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
    /// Sağlayıcı yan soruyu (`/btw`) desteklemiyor. Yeni providerlar
    /// `answerSideQuestion` override edene kadar bu döner.
    case unsupported

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
    /// Düşünme içeriği: akıl yürüten modellerin ara adımları. Asistan
    /// metninden ayrı kanaldır — transkripte ve geçmişe asla karışmaz,
    /// yalnız turdaki `.thinking` aktivitesinde birikir ve kartta gösterilir.
    /// OpenCode `reasoning` parçası, OpenAI reasoning-summary deltasıdır.
    case thinkingDelta(String)
    /// Sağlayıcının bildirdiği tur jeton kullanımı: OpenAI `response.completed`
    /// içindeki `response.usage`, OpenCode `message.updated` içindeki asistan
    /// mesajı `tokens` alanıdır. Her iki kaynak da toleranslı okunur; alan
    /// yoksa olay üretilmez, akış aynen sürer.
    case turnUsage(TurnTokenUsage)
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
    /// One backend request can contain several ordered questions.
    case questionAsked(OpenCodeQuestionRequest)
    case waiting
    case completed
}

/// Tek turun sağlayıcı-tarafı jeton sayımı. `inputTokens` o adımdaki bağlam
/// boyutuna denktir (OpenCode durumlu oturumda sunucu tarafındaki birikim,
/// OpenAI durumsuz istekte gönderilen girdidir).
struct TurnTokenUsage: Equatable, Sendable {
    /// Bağlamda taşınan girdi jetonu.
    let inputTokens: Int
    /// Üretilen çıktı jetonu (akıl yürütme dahil).
    let outputTokens: Int
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
    /// Yuvarlanan bağlam özeti (`/compact`): pencere dışına düşen ön ekin
    /// yoğunlaştırılmışı. Boşken maliyet yoktur; doluyken istek başına eklenir.
    let contextSummary: String

    init(
        sessionID: UUID,
        configuration: SessionConfiguration,
        messages: [ChatMessage],
        speedMode: ResponseSpeedMode,
        mode: AgentMode = .build,
        extensionContext: String? = nil,
        activityGroups: [AgentTurnActivityGroup] = [],
        contextSummary: String = ""
    ) {
        self.sessionID = sessionID
        self.configuration = configuration
        self.messages = messages
        self.speedMode = speedMode
        self.mode = mode
        self.extensionContext = extensionContext
        self.activityGroups = activityGroups
        self.contextSummary = contextSummary
    }
}

struct ProviderStream: Sendable {
    /// Olay akışı. Geri-baskı sınırı imzada görünmez: akışı kuran
    /// `BoundedChannel` taşır (iki çalışma zamanında da kapasite 128).
    /// Tüketici akışın sınırlı olduğunu varsayar, sınır değerini değil.
    let events: AsyncThrowingStream<ProviderEvent, Error>
    private let cancellation: @Sendable () async -> Void
    private let questionReply: @Sendable (String, [[String]]) async throws -> Void
    private let questionRejection: @Sendable (String) async throws -> Void

    init(
        events: AsyncThrowingStream<ProviderEvent, Error>,
        cancellation: @escaping @Sendable () async -> Void = {},
        questionReply: @escaping @Sendable (String, [[String]]) async throws -> Void = { _, _ in
            throw ProviderRuntimeError.unavailable
        },
        questionRejection: @escaping @Sendable (String) async throws -> Void = { _ in
            throw ProviderRuntimeError.unavailable
        }
    ) {
        self.events = events
        self.cancellation = cancellation
        self.questionReply = questionReply
        self.questionRejection = questionRejection
    }

    func cancel() async {
        await cancellation()
    }

    /// A question is an in-turn tool response, not a new user prompt.
    func replyQuestion(requestID: String, answers: [[String]]) async throws {
        try await questionReply(requestID, answers)
    }

    func rejectQuestion(requestID: String) async throws {
        try await questionRejection(requestID)
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

    /// Yan soru (`/btw`): oturum bağlamıyla tek-atımlık, araçsız yanıt.
    ///
    /// Turn makinesine girmez, transkripte yazmaz, çalışan turu kesmez.
    /// Her runtime kendi izolasyonuyla implemente eder (OpenCode: geçici uzak
    /// oturum; durumsuzlar: tek completion). Desteklemeyenler varsayılanı
    /// kullanır (`.unsupported`).
    func answerSideQuestion(_ query: SideQuestionQuery) async throws -> ProviderStream
}

extension ProviderRuntime {
    func releaseSession(_ sessionID: UUID) async {}

    func sessionTodos(sessionID: UUID) async -> [AgentTodo]? { nil }

    func answerSideQuestion(_ query: SideQuestionQuery) async throws -> ProviderStream {
        throw ProviderRuntimeError.unsupported
    }
}
