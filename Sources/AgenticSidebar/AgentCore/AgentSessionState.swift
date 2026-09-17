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
    /// Aktivite içeriği her değiştiğinde artan sayaç.
    ///
    /// `TranscriptIndexCache` anahtarı yalnız sayı ve fazlara baktığı için akan
    /// bir aracın çıktısı güncellendiğinde anahtar değişmiyor ve satır
    /// önbellekteki eski kopyayla çiziliyordu; sayaç o boşluğu kapatır.
    /// Arşive yazılmaz, yalnız bellekte yaşar.
    var activityRevision: Int = 0
    /// The agent's own task list for this session, as the backend reports it.
    var todos: [AgentTodo] = []
    /// The currently active question waiting for user input, if any.
    var activeQuestion: AgentQuestion? = nil
    /// A backend question stays visible until the server accepts the response.
    var isQuestionSubmitting = false
    /// The response failed; the existing card can be retried or rejected.
    var questionSubmissionFailed = false
    /// History of questions asked and answered in this session.
    var questionHistory: [AgentQuestion] = []

    init(
        id: UUID = UUID(),
        configuration: SessionConfiguration? = nil,
        messages: [ChatMessage] = [],
        status: AgentSessionStatus = .idle,
        error: AgentSessionError? = nil,
        notice: AgentSessionNotice? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        activeQuestion: AgentQuestion? = nil,
        questionHistory: [AgentQuestion] = []
    ) {
        self.id = id
        self.configuration = configuration
        self.messages = messages
        self.status = status
        self.error = error
        self.notice = notice
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.activeQuestion = activeQuestion
        self.questionHistory = questionHistory
    }
}
