import Foundation

/// Sunum katmanın oturum servisiyle konuştuğu arayüz.
///
/// Somut `AgentSessionService` bu protokolü uygular; `RootChatView` ve
/// `ConversationDetailView` somut sınıfa değil bu arayüze dayanır, böylece
/// sunum katmanı taklit bir oturum servisine karşı test edilebilir.
@MainActor
protocol AgentSessionServiceProtocol: AnyObject, Observable {
    var providers: [ProviderCapabilities] { get }
    var sessions: [AgentSession] { get }
    var activeSessionID: UUID { get }
    var activeSession: AgentSession { get }
    var state: AgentSessionState { get }
    var isBusy: Bool { get }
    var canSubmit: Bool { get }
    var canAcceptPrompt: Bool { get }
    var availableModels: [ProviderModelCapability] { get }
    var availableVariants: [ProviderVariant] { get }
    var activeSessionTitle: String { get }
    var activeTurnID: UUID? { get }
    var queuedPrompts: [QueuedPrompt] { get }
    var sessionList: [SessionSummary] { get }
    var todos: [AgentTodo] { get }

    @discardableResult
    func createSession() -> UUID
    func selectSession(_ id: UUID)
    func deleteSession(_ id: UUID)
    func deleteSessions(_ ids: Set<UUID>)
    func renameSession(_ id: UUID, to newTitle: String)
    func setSessionPinned(_ id: UUID, pinned: Bool)
    func toggleSessionPin(_ id: UUID)
    func selectProvider(_ providerID: ProviderID) throws
    func selectModel(_ modelID: ProviderModelID) throws
    func selectVariant(_ variantID: ProviderVariantID?) throws
    func refreshCapabilities() async
    @discardableResult
    func submit(_ prompt: String) -> Task<Void, Never>?
    @discardableResult
    func submit(_ prompt: String, attachmentPaths: [String]) -> Task<Void, Never>?
    @discardableResult
    func submit(
        _ prompt: String,
        attachmentPaths: [String],
        speedMode: ResponseSpeedMode
    ) -> Task<Void, Never>?
    @discardableResult
    func send(
        _ prompt: String,
        attachmentPaths: [String],
        speedMode: ResponseSpeedMode,
        mode: AgentMode,
        tags: [ExtensionTag]
    ) -> PromptAcceptance
    func answerActiveQuestion(_ answer: AgentQuestionAnswer)
    func dismissActiveQuestion()
    func removeQueuedPrompt(_ id: UUID)
    @discardableResult
    func updateQueuedPrompt(_ id: UUID, text: String) -> Bool
    @discardableResult
    func moveQueuedPrompt(_ id: UUID, to destinationIndex: Int) -> Bool
    func clearQueuedPrompts()
    func drainQueuedPrompts()
    func cancel() async
    func flushPendingSave() async
    func saveNow() async
}

extension AgentSessionService: AgentSessionServiceProtocol {}
