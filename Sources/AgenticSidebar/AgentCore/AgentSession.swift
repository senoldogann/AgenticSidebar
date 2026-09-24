import Foundation
import Observation

/// One conversation: transcript, configuration and its own streaming turn.
///
/// Streaming state lives here rather than in `AgentSessionService` so a
/// background conversation keeps running while the user works in another one.
@MainActor
@Observable
final class AgentSession {
    let id: UUID
    let createdAt: Date

    @ObservationIgnored
    private let runtimes: [any ProviderRuntime]

    /// Eşleşmezlik kuralı: `activeTask`/`activeStream` doluysa `activeTurnID`
    /// de doludur ve üçü aynı tura aittir; üçü birlikte kurulur, birlikte
    /// düşürülür (`startTurn`, `cancel`, `consume` sonu, `recoverOrphanedTurn`).
    /// `cancel` bu sayede elindeki tutamacın koşan tura ait olduğunu bilir.
    @ObservationIgnored
    private var activeTask: Task<Void, Never>?

    @ObservationIgnored
    private var activeStream: ProviderStream?

    /// Answers for a single OpenCode request must be sent together, in order.
    /// Keep the user-facing questions pending until the server accepts the batch.
    private struct PendingBackendQuestion {
        let request: OpenCodeQuestionRequest
        let turnID: UUID
        var index = 0
        var answers: [[String]] = []
        var resolvedQuestions: [AgentQuestion] = []
    }

    @ObservationIgnored private var pendingBackendQuestion: PendingBackendQuestion?
    @ObservationIgnored private var queuedBackendQuestions: [(request: OpenCodeQuestionRequest, turnID: UUID)] = []

    private(set) var activeTurnID: UUID?

    @ObservationIgnored
    private var activeTurnSpeedMode: ResponseSpeedMode = .normal

    @ObservationIgnored
    private var activeTurnMode: AgentMode = .build

    @ObservationIgnored
    private var activeAssistantMessageID: UUID?

    @ObservationIgnored
    private var currentTurnAnchorMessageID: UUID?

    /// Bu turda akış hedefine hiç asistan metni düştü mü.
    ///
    /// Sessiz bir tamamlanmayı ayırt etmek için: model hiç yanıt üretmezse
    /// transkripte hiçbir şey eklenmez ve kullanıcı "ajan başlamadı" der.
    @ObservationIgnored
    private var turnProducedAssistantText = false

    /// Invalidates older asynchronous todo reads, including reads from previous turns.
    @ObservationIgnored
    private var todoRefreshGeneration = 0

    @ObservationIgnored
    private var streamingTextAccumulator = StreamingTextAccumulator.empty

    @ObservationIgnored
    private var streamingTextFlushTask: Task<Void, Never>?

    /// Henüz düşünme kartına yazılmamış thinking deltası. Asistan metni gibi
    /// her SSE satırında `state`'e dokunmak gözlem fırtınası çıkarır, o yüzden
    /// aynı debounce deseniyle birikir ve boşaltılır.
    @ObservationIgnored
    private var pendingThinkingText = ""

    @ObservationIgnored
    private var thinkingFlushTask: Task<Void, Never>?

    @ObservationIgnored
    private var pendingActivityUpdates: [ProviderActivityID: (descriptor: ProviderActivityDescriptor, turnID: UUID)] = [:]

    @ObservationIgnored
    private var activityUpdateFlushTask: Task<Void, Never>?

    @ObservationIgnored
    private var noticeAutoDismissTask: Task<Void, Never>?

    /// Called after every transcript/status change so the owner can debounce a
    /// persistence write. Streaming flushes fire often, hence the debounce.
    @ObservationIgnored
    var onPersistentChange: (@MainActor () -> Void)?
    var onImmediatePersistentChange: (@MainActor () -> Void)?
    /// Notifies the session service when summary-relevant fields change (title, status, pin, message count),
    /// strictly avoiding updates on intermediate streaming text chunks to prevent sidebar re-render storms.
    @ObservationIgnored
    var onSummaryChange: (@MainActor () -> Void)?
    var onTurnFinished:
        (@MainActor (_ sessionID: UUID, _ sessionTitle: String, _ status: AgentSessionStatus, _ lastMessageSnippet: String?) -> Void)?
    /// Tur sınırları: izin seviyesi tur başında anlık görüntülenir, tur
    /// bitene kadar koşan tur eski kuralla devam eder. Başlangıç ve bitiş
    /// aynı `turnID` ile eşleşir; üstüne binen turda eski turun geç bitişi
    /// yeni turun kaydını düşürmez (merkez `turnID` korur).
    var onTurnStarted: (@MainActor (_ sessionID: UUID, _ turnID: UUID) -> Void)?
    var onTurnEnded: (@MainActor (_ sessionID: UUID, _ turnID: UUID) -> Void)?

    @ObservationIgnored
    private let budget: TranscriptBudget

    /// Determines the streaming UI flush interval. Fast mode floors at 40ms:
    /// 60fps (16ms) full-transcript `@Observable` invalidation starved the
    /// main thread during display-cycle layout (22:46 SIGABRT family); 25fps
    /// keeps the typewriter feel without the storm.
    /// Background sessions flush at 750ms to save CPU without losing responsiveness on switch.
    static func streamingTextInterval(
        forMessageLength length: Int,
        speedMode: ResponseSpeedMode,
        isVisibleInUI: Bool
    ) -> Duration {
        guard isVisibleInUI else {
            return .milliseconds(750)
        }
        return switch speedMode {
        case .fast:
            switch length {
            case ..<30_000: .milliseconds(40)
            case ..<80_000: .milliseconds(40)
            default: .milliseconds(80)
            }
        case .normal:
            switch length {
            case ..<20_000: .milliseconds(40)
            case ..<80_000: .milliseconds(90)
            default: .milliseconds(180)
            }
        }
    }

    static func streamingTextInterval(
        forMessageLength length: Int,
        speedMode: ResponseSpeedMode
    ) -> Duration {
        streamingTextInterval(
            forMessageLength: length,
            speedMode: speedMode,
            isVisibleInUI: true
        )
    }

    /// Bellekte tutulan aktivite sayısı, arşivdekiyle aynı sınıra budanır.
    /// Budanmazsa uzun bir sohbette bütün tur geçmişi RAM'de birikir.
    private static let maximumInMemoryActivities = SessionArchiveStore.maximumActivitiesPerSession

    /// Tur sürerken budamanın seyrek çalışması için pay: sınır aşıldıktan
    /// sonra her yeni aktivitede değil, bu kadar fazlası birikince budanır.
    private static let activityPruneHeadroom = 40

    /// Bellekte bir aktivite için saklanan en fazla karakter.
    ///
    /// Arşiv sınırından yüksek tutulur — kullanıcı açtığı kartta hâlâ anlamlı
    /// bir çıktı görür — ama bir dosyanın tamamının süresiz durmasını engeller.
    private static let maximumInMemoryOutputLength = 64_000

    /// Tur başına düşünme kartında tutulan en fazla karakter. Araç çıktısından
    /// (64k) küçüktür: düşünme gösterim metnidir. Taşan sessizce düşer, turu
    /// ve arşivi bozmaz (`output` alanı arşiv sınırına da tabidir).
    private static let maximumThinkingCharacters = 8_000

    /// Kuyrukta bekleyebilecek en fazla mesaj.
    ///
    /// Sınırsız bir kuyruk, uzun süre yanıtlanmayan bir turun arkasında hem
    /// belleği hem de kullanıcının ne göndereceği üzerindeki kontrolünü
    /// kaybettiriyordu.
    static let maximumQueuedPrompts = 20

    /// Bellekte tutulan en fazla mesaj: arşiv tam kalır, RAM büyümez.
    private static let maximumInMemoryMessages = 1000

    private(set) var providers: [ProviderCapabilities] = []

    /// Prompts that arrived while a turn was running, oldest first.
    ///
    /// The transcript only shows a message once its turn starts, so a queued
    /// prompt is held here (and surfaced next to the composer) rather than being
    /// written to the conversation ahead of the turn that will answer it.
    private(set) var queuedPrompts: [QueuedPrompt] = []

    /// Whether this session is currently rendered in an active UI pane.
    /// Background sessions throttle their flush timer to 750ms, drastically reducing MainActor pressure.
    @ObservationIgnored
    var isVisibleInUI: Bool = true {
        didSet {
            if isVisibleInUI && !oldValue {
                if let activeTurnID {
                    flushPendingAssistantText(turnID: activeTurnID)
                }
            }
        }
    }

    /// Fast O(1) guard preventing wasteful O(N) array traversals across all historical turns on every token delta.
    @ObservationIgnored
    private var hasRunningThinkingActivity: Bool = false

    /// Discretely tracked properties avoiding broad observation storms when `state` mutates on streaming tokens.
    private(set) var status: AgentSessionStatus = .idle
    private(set) var configuration: SessionConfiguration?
    private(set) var todos: [AgentTodo] = []
    private(set) var activeQuestion: AgentQuestion?
    /// Yuvarlanan bağlam özeti (`/compact`): pencere dışına düşen ön ekin
    /// yoğunlaştırılmışı. Ekrandaki transkripti değiştirmez; istek başına
    /// eklenir. Arşivde yaşar, yeniden başlatmada geri gelir.
    private(set) var contextSummary = ""
    /// Özetin kapsadığı en yeni mesaj: bu kimlik ve öncesini tekrar
    /// özetleme; aynı kaybı her turda yeniden işlemek hem tur hem fatura yakar.
    private var summarizedThroughMessageID: UUID?
    /// Nag kilidi: kırpma bildirimi yalnız kayıp sayısı ARTTIĞINDA kurulur.
    /// Aynı kayıp her turda yeniden sunulmaz.
    private var lastTrimNoticeDroppedCount = 0
    /// Sağlayıcının bildirdiği son tur sayımı (`.turnUsage`): OpenAI
    /// `response.usage`, OpenCode asistan `tokens`. Sunucu oturumu dönünce
    /// (özet rotasyonu) ya da model değişince bayatlar, sıfırlanır.
    private(set) var lastTurnUsage: TurnTokenUsage?
    /// Oturum ömrünce işlenen toplam jeton (halka açılır penceresindeki
    /// "Total processed" satırı). Tur bildirimleri geldikçe birikir; model
    /// değişiminde sıfırlanmaz (ömür boyu sayaçtır), yalnız bellekte yaşar.
    private(set) var totalInputTokens = 0
    private(set) var totalOutputTokens = 0

    /// Giren + çıkan toplamı: açılır pencerenin alt satırı.
    var totalProcessedTokens: Int {
        totalInputTokens + totalOutputTokens
    }
    /// Bestecideki bağlam halkasının girdisi: yalnız sağlayıcı verisi.
    /// Pay son turun bildirilen girdisi, payda seçili modelin penceresi;
    /// ikisinden biri yoksa halka bilinmeyen gösterir, tahmin uydurulmaz.
    var contextUsage: SessionContextUsage {
        SessionContextUsage(
            usedTokens: lastTurnUsage?.inputTokens,
            limitTokens: selectedModelCapability?.contextLimit,
            lastInputTokens: lastTurnUsage?.inputTokens,
            lastOutputTokens: lastTurnUsage?.outputTokens
        )
    }
    /// Seçili modelin yetenek kaydı (pencere boyu buradan okunur).
    private var selectedModelCapability: ProviderModelCapability? {
        guard
            let configuration,
            let provider = providers.first(where: { $0.id == configuration.providerID })
        else {
            return nil
        }
        return provider.model(id: configuration.modelID)
    }
    /// Sürmekte olan özet turu: tek uçuşludur, iptal edilebilir.
    @ObservationIgnored
    private var compactionTask: Task<Void, Never>?
    var isCompacting: Bool { compactionTask != nil }

    /// Compact düğmesinin engeli (`nil` = basılabilir). `requestCompaction`
    /// içindeki koruma sırasının okunur izdüşümüdür; düğme ile eylem aynı
    /// kararı verir, ikisi ayrışamaz.
    var compactionBlocker: CompactionFailureReason? {
        if isBusy {
            return .busy
        }
        if isCompacting {
            return .compacting
        }
        guard
            let configuration,
            runtime(for: configuration.providerID) != nil
        else {
            return .unavailable
        }
        guard
            ContextCompactor.plan(
                messages: state.messages,
                budget: budget,
                summarizedThroughMessageID: summarizedThroughMessageID
            ) != nil
        else {
            return .nothingToCompact
        }
        return nil
    }

    @ObservationIgnored
    private var lastCompletedAt: Date?
    @ObservationIgnored
    private var lastObservedMessageCount: Int = 0

    /// The session state, directly tracked through the Observation framework.
    var state: AgentSessionState {
        didSet {
            var summaryChanged = false
            if state.status != status {
                status = state.status
                summaryChanged = true
            }
            if state.configuration != configuration {
                configuration = state.configuration
            }
            if state.todos != todos {
                todos = state.todos
            }
            if state.activeQuestion != activeQuestion {
                activeQuestion = state.activeQuestion
            }
            if state.completedAt != lastCompletedAt {
                lastCompletedAt = state.completedAt
                summaryChanged = true
            }
            if state.messages.count != lastObservedMessageCount {
                lastObservedMessageCount = state.messages.count
                summaryChanged = true
            }
            if state.notice != oldValue.notice {
                if state.notice != nil {
                    scheduleNoticeAutoDismiss(after: .seconds(6))
                } else {
                    noticeAutoDismissTask?.cancel()
                    noticeAutoDismissTask = nil
                }
            }
            if summaryChanged {
                noteSummaryChange()
            }
            onPersistentChange?()
        }
    }

    /// Kullanıcının verdiği başlık; `nil` ise otomatik başlık gösterilir.
    /// `state` dışında tutulduğu için değişimde kalıcılık elle tetiklenir.
    var customTitle: String? {
        didSet {
            noteSummaryChange()
            onPersistentChange?()
        }
    }

    /// Sabitli oturumlar listede üstte durur, arşiv budamada en son düşer.
    var isPinned: Bool {
        didSet {
            noteSummaryChange()
            onPersistentChange?()
        }
    }

    /// Oturumun bağlı olduğu klasörün dosya yolu; `nil` = klasörsüz oturum.
    /// `state` dışında tutulur, değişimde kalıcılık ve özet elle tetiklenir.
    /// Yazma tek kaynaktan (`setWorkingDirectory`) yapılır; doğrudan atama
    /// normalleştirmeyi atlayıp `"  "` gibi boş-biçimli yollar saklardı.
    private(set) var workingDirectoryPath: String? {
        didSet {
            noteSummaryChange()
            onPersistentChange?()
        }
    }

    init(
        runtimes: [any ProviderRuntime],
        state: AgentSessionState = AgentSessionState(),
        budget: TranscriptBudget = TranscriptBudget(),
        customTitle: String? = nil,
        isPinned: Bool = false,
        workingDirectoryPath: String? = nil
    ) {
        self.runtimes = runtimes
        self.state = state
        self.id = state.id
        self.createdAt = Date()
        self.budget = budget
        self.customTitle = customTitle
        self.isPinned = isPinned
        self.workingDirectoryPath = Self.normalizedDirectoryPath(workingDirectoryPath)
        self.status = state.status
        self.configuration = state.configuration
        self.todos = state.todos
        self.activeQuestion = state.activeQuestion
        self.lastCompletedAt = state.completedAt
        self.lastObservedMessageCount = state.messages.count
    }

    init(
        runtimes: [any ProviderRuntime],
        snapshot: SessionSnapshot,
        budget: TranscriptBudget = TranscriptBudget()
    ) {
        self.runtimes = runtimes
        self.id = snapshot.id
        self.createdAt = snapshot.createdAt
        self.budget = budget
        self.customTitle = snapshot.customTitle
        self.isPinned = snapshot.isPinned
        self.workingDirectoryPath = Self.normalizedDirectoryPath(snapshot.workingDirectoryPath)
        self.contextSummary = snapshot.contextSummary
        self.summarizedThroughMessageID = snapshot.summarizedThroughMessageID
        // Kuyruk, kesintiden sağ çıkar: kapanışta tur ortasında bekleyen mesaj,
        // açılışta yine bekliyor olur — kullanıcı gönderdiği işi geri yazar.
        self.queuedPrompts = Array(snapshot.queuedPrompts.prefix(Self.maximumQueuedPrompts))
        let restoredState = AgentSessionState(
            id: snapshot.id,
            configuration: snapshot.configuration,
            messages: snapshot.messages,
            status: .idle
        )
        self.state = restoredState
        self.status = .idle
        self.configuration = snapshot.configuration
        self.todos = restoredState.todos
        self.activeQuestion = restoredState.activeQuestion
        self.lastCompletedAt = restoredState.completedAt
        self.lastObservedMessageCount = restoredState.messages.count
        // The timeline is restored collapsed and closed: a turn that was still
        // running when the app quit never finished, and its thinking row would
        // otherwise count up from a stale start date forever.
        self.state.activityGroups = snapshot.activityGroups.map {
            $0.normalizedForRestore()
        }
    }

    /// A running turn cannot survive a relaunch, so a snapshot never carries one;
    /// the activity timeline it does carry comes back collapsed.
    func snapshot() -> SessionSnapshot {
        SessionSnapshot(
            id: id,
            createdAt: createdAt,
            configuration: state.configuration,
            messages: state.messages,
            activityGroups: state.activityGroups,
            customTitle: customTitle,
            isPinned: isPinned,
            queuedPrompts: queuedPrompts,
            contextSummary: contextSummary,
            summarizedThroughMessageID: summarizedThroughMessageID,
            workingDirectoryPath: workingDirectoryPath
        )
    }

    /// Klasör yolunu tek kaynaktan normalleştirir: boş/boşluk yol `nil` olur.
    static func normalizedDirectoryPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    /// Bağlı klasörü değiştirir; boş yol klasörü kaldırır.
    func setWorkingDirectory(path: String?) {
        let normalized = Self.normalizedDirectoryPath(path)
        guard workingDirectoryPath != normalized else { return }
        workingDirectoryPath = normalized
    }

    /// İlk kullanıcı mesajından türetilen otomatik başlık.
    var automaticTitle: String {
        guard let firstUserMessage = state.messages.first(where: { $0.role == .user }) else {
            return "New session"
        }

        let firstLine =
            firstUserMessage.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? firstUserMessage.text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.count > 60 else {
            return trimmed.isEmpty ? "New session" : trimmed
        }

        return String(trimmed.prefix(60)) + "…"
    }

    /// Ekranda ve listede gösterilen başlık: özel başlık varsa o.
    var effectiveTitle: String {
        guard let customTitle else {
            return automaticTitle
        }
        let trimmed = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? automaticTitle : trimmed
    }

    var title: String {
        effectiveTitle
    }

    /// Proje önekli başlık; klasörsüzde `title` ile aynı.
    /// Örnek: `AgenticSidebar > Merhaba`.
    var qualifiedTitle: String {
        WorkingDirectoryDisplay.qualifiedTitle(title: title, directoryPath: workingDirectoryPath)
    }

    /// Kullanıcı başlığını günceller; boş ya da yalnızca boşluk ise `nil` olur.
    /// Başlık en fazla 120 karakter saklanır, fazlası kırpılır.
    func rename(to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if customTitle != nil {
                customTitle = nil
                noteSummaryChange()
            }
            return
        }
        let updated = String(trimmed.prefix(120))
        if customTitle != updated {
            customTitle = updated
            noteSummaryChange()
        }
    }

    /// Sabitleme durumunu ayarlar.
    func setPinned(_ pinned: Bool) {
        guard isPinned != pinned else { return }
        isPinned = pinned
        noteSummaryChange()
    }

    /// Sabitleme durumunu tersine çevirir.
    func togglePin() {
        isPinned.toggle()
        noteSummaryChange()
    }

    private func noteSummaryChange() {
        onSummaryChange?()
    }

    var isBusy: Bool {
        switch status {
        case .streaming, .runningTool, .waiting, .cancelling:
            true
        case .idle, .completed, .cancelled, .failed:
            false
        }
    }

    var canSubmit: Bool {
        guard let configuration else {
            return false
        }

        return runtime(for: configuration.providerID) != nil && !isBusy
    }

    /// Oturumun şu anda bir mesajı ya hemen başlatabileceği ya da kuyruğa
    /// alabileceği durum.
    ///
    /// `send`'i çağırmadan önce sorulur: kuyruğu dolu bir oturuma saniyede
    /// birkaç kez mesaj denemek, her denemede bir hata kaydı üretirdi.
    var canAcceptPrompt: Bool {
        if canSubmit {
            return true
        }

        guard
            isBusy,
            let configuration,
            runtime(for: configuration.providerID) != nil
        else {
            return false
        }

        return queuedPrompts.count < Self.maximumQueuedPrompts
    }

    var availableModels: [ProviderModelCapability] {
        guard
            let configuration,
            let provider = providers.first(where: { $0.id == configuration.providerID })
        else {
            return []
        }

        return provider.models
    }

    var availableVariants: [ProviderVariant] {
        guard
            let configuration,
            let provider = providers.first(where: { $0.id == configuration.providerID }),
            let model = provider.model(id: configuration.modelID)
        else {
            return []
        }

        return model.variants
    }

    func applyCapabilities(
        _ providers: [ProviderCapabilities],
        normalizeConfiguration: Bool
    ) {
        self.providers = providers

        if normalizeConfiguration {
            normalizeConfigurationState()
        }
    }

    func markIdle() {
        state.status = .idle
        state.error = nil
    }

    func clearConfiguration() {
        state.configuration = nil
        // The checklist belongs to a provider that can report one; without a
        // configuration no refresh can arrive to replace it, so a stale list
        // would sit on screen until the next turn clears it at start.
        invalidateTodoReads()
        state.todos = []
        state.status = .idle
        state.error = nil
        // Pencere yokken eski sayım paydaya vurulmaz.
        lastTurnUsage = nil
    }

    func failCapabilityDiscovery(with error: AgentSessionError) {
        state.configuration = nil
        invalidateTodoReads()
        state.todos = []
        state.status = .failed
        state.error = error
        lastTurnUsage = nil
    }

    func selectProvider(_ providerID: ProviderID) throws {
        guard !isBusy else {
            return
        }

        guard
            let provider = providers.first(where: { $0.id == providerID }),
            let model = provider.models.first
        else {
            throw AgentSessionError.unsupportedCapability
        }

        state.configuration = SessionConfiguration(
            providerID: provider.id,
            modelID: model.id,
            variantID: nil
        )
        // Another provider's checklist must not survive the switch: a provider
        // with no such notion answers `nil` and leaves the last list in place.
        invalidateTodoReads()
        state.todos = []
        state.error = nil
        // Pencere de değişmiş olabilir: eski sayım yeni paydaya vurulmaz.
        lastTurnUsage = nil
    }

    func selectModel(_ modelID: ProviderModelID) throws {
        // Tur ortasında değişim güvenlidir: koşan tur yapılandırmayı tur
        // başında kopyalamıştır, bu yazım yalnız sonraki turu belirler.
        guard
            var configuration = state.configuration,
            let provider = providers.first(where: { $0.id == configuration.providerID }),
            let model = provider.model(id: modelID)
        else {
            throw AgentSessionError.unsupportedCapability
        }

        configuration.modelID = model.id
        if !provider.supports(
            variantID: configuration.variantID,
            for: model.id
        ) {
            configuration.variantID = nil
        }
        state.configuration = configuration
        state.error = nil
        // Pencere değişti: eski turun sayımı yeni paydaya vurulmaz.
        lastTurnUsage = nil
    }

    func selectVariant(_ variantID: ProviderVariantID?) throws {
        // Gerekçe `selectModel` ile aynı: yazım sonraki turu belirler.
        guard
            var configuration = state.configuration,
            let provider = providers.first(where: { $0.id == configuration.providerID }),
            provider.supports(
                variantID: variantID,
                for: configuration.modelID
            )
        else {
            throw AgentSessionError.unsupportedCapability
        }

        configuration.variantID = variantID
        state.configuration = configuration
        state.error = nil
    }

    @discardableResult
    func submit(_ prompt: String) -> Task<Void, Never>? {
        submit(prompt, attachmentPaths: [], speedMode: .normal)
    }

    @discardableResult
    func submit(
        _ prompt: String,
        attachmentPaths: [String]
    ) -> Task<Void, Never>? {
        submit(prompt, attachmentPaths: attachmentPaths, speedMode: .normal)
    }

    @discardableResult
    func submit(
        _ prompt: String,
        attachmentPaths: [String],
        speedMode: ResponseSpeedMode,
        mode: AgentMode = .build,
        tags: [ExtensionTag] = []
    ) -> Task<Void, Never>? {
        let queuedPrompt = QueuedPrompt(
            text: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            attachmentPaths: attachmentPaths,
            extensionTags: tags,
            speedMode: speedMode,
            mode: mode
        )

        guard !queuedPrompt.text.isEmpty, canSubmit else {
            return nil
        }

        return startTurn(for: queuedPrompt)
    }

    /// Starts the turn, or queues the prompt when one is already running.
    ///
    /// This is what the composer uses: a message that arrives mid-turn waits its
    /// turn in order instead of being refused or interleaved with the answer that
    /// is still streaming.
    @discardableResult
    func send(
        _ prompt: String,
        attachmentPaths: [String] = [],
        speedMode: ResponseSpeedMode = .normal,
        mode: AgentMode = .build,
        tags: [ExtensionTag] = []
    ) -> PromptAcceptance {
        let queuedPrompt = QueuedPrompt(
            text: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            attachmentPaths: attachmentPaths,
            extensionTags: tags,
            speedMode: speedMode,
            mode: mode
        )

        guard !queuedPrompt.text.isEmpty else {
            return .rejected
        }

        guard queuedPrompts.count < Self.maximumQueuedPrompts else {
            AppLog.agentSession.error(
                "The prompt queue already holds \(Self.maximumQueuedPrompts, privacy: .public) messages; the new one was refused"
            )
            return .rejected
        }

        if canSubmit, queuedPrompts.isEmpty {
            return startTurn(for: queuedPrompt) == nil ? .rejected : .started
        }

        // A session with no usable configuration could never run the prompt
        // later, so only a session that can run or is genuinely busy accepts a queued message.
        guard
            canSubmit || (isBusy && state.configuration.flatMap { runtime(for: $0.providerID) } != nil)
        else {
            return .rejected
        }

        queuedPrompts.append(queuedPrompt)
        noteQueueChange()

        if canSubmit {
            startNextQueuedTurn()
            return .started
        }
        return .queued
    }

    /// Runs the oldest queued prompt if the session is free.
    func drainQueueIfPossible() {
        guard canSubmit, !queuedPrompts.isEmpty else {
            return
        }
        startNextQueuedTurn()
    }

    /// Kuyruktaki bir mesajı öne alıp hemen çalıştırır: tur dönüyorsa o tur
    /// durdurulur, boşta ise mesaj sıradaki iş olarak başlar. İptalin sonundaki
    /// `startNextQueuedTurn` en öndekini aldığı için öne almak yeterlidir.
    func sendQueuedPromptImmediately(_ id: UUID) {
        guard let index = queuedPrompts.firstIndex(where: { $0.id == id }) else {
            return
        }
        let prompt = queuedPrompts.remove(at: index)
        queuedPrompts.insert(prompt, at: 0)
        noteQueueChange()
        if isBusy {
            Task { @MainActor [weak self] in
                await self?.cancel()
            }
        } else {
            startNextQueuedTurn()
        }
    }

    func removeQueuedPrompt(_ id: UUID) {
        let count = queuedPrompts.count
        queuedPrompts.removeAll { $0.id == id }
        if queuedPrompts.count != count {
            noteQueueChange()
        }
    }

    /// Rewrites a queued message, keeping its place in line.
    ///
    /// Editing must not move it. With several messages waiting, an edit that
    /// jumped to the back would silently reorder turns the user wrote in a
    /// deliberate order — and the queue is exactly where that order is decided.
    /// Everything else about the prompt is preserved, so a correction cannot
    /// change the mode or speed the turn was written with.
    @discardableResult
    func updateQueuedPrompt(_ id: UUID, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        guard let index = queuedPrompts.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let existing = queuedPrompts[index]
        queuedPrompts[index] = QueuedPrompt(
            id: existing.id,
            text: trimmed,
            attachmentPaths: existing.attachmentPaths,
            extensionTags: existing.extensionTags,
            speedMode: existing.speedMode,
            mode: existing.mode
        )
        noteQueueChange()
        return true
    }

    /// Moves a queued message to another position in the queue.
    ///
    /// The queue is the order the turns will run in, so this is how the user
    /// decides what the agent does next while it is still busy. The destination
    /// is clamped rather than rejected: dropping a row past the last one means
    /// "at the end", not "nowhere".
    @discardableResult
    func moveQueuedPrompt(_ id: UUID, to destinationIndex: Int) -> Bool {
        guard let sourceIndex = queuedPrompts.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let prompt = queuedPrompts.remove(at: sourceIndex)
        let clamped = min(max(destinationIndex, 0), queuedPrompts.count)
        queuedPrompts.insert(prompt, at: clamped)
        if clamped != sourceIndex {
            noteQueueChange()
        }
        return clamped != sourceIndex
    }

    func clearQueuedPrompts() {
        guard !queuedPrompts.isEmpty else {
            return
        }
        queuedPrompts.removeAll()
        noteQueueChange()
    }

    // MARK: - Interactive Questions

    /// Presents an interactive question to the user during an active turn or upon completion.
    func askQuestion(_ question: AgentQuestion) {
        state.activeQuestion = question
    }

    /// Resolves the active question with the user's answer and continues the conversation.
    func answerActiveQuestion(_ answer: AgentQuestionAnswer) {
        guard var question = state.activeQuestion else {
            return
        }
        if pendingBackendQuestion != nil {
            answerBackendQuestion(answer)
            return
        }

        question.status = .answered(answer)
        state.questionHistory.append(question)
        state.activeQuestion = nil

        // Yanıt kaybolmamalı: boşta ise sonraki tur olur, meşgulse
        // kuyruğa girer ve çalışan turun ardından koşar.
        if !isBusy {
            let mode = activeTurnMode
            send(
                answer.formattedResponse,
                attachmentPaths: [],
                speedMode: activeTurnSpeedMode,
                mode: mode,
                tags: []
            )
        } else if !answer.formattedResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = send(
                answer.formattedResponse,
                attachmentPaths: [],
                speedMode: activeTurnSpeedMode,
                mode: activeTurnMode,
                tags: []
            )
        }
    }

    /// Dismisses or skips the active question.
    func dismissActiveQuestion() {
        guard var question = state.activeQuestion else {
            return
        }
        if pendingBackendQuestion != nil {
            rejectBackendQuestion()
            return
        }

        question.status = .dismissed
        state.questionHistory.append(question)
        state.activeQuestion = nil
    }

    /// Manually dismisses the current notice banner.
    func dismissNotice() {
        noticeAutoDismissTask?.cancel()
        noticeAutoDismissTask = nil
        if state.notice != nil {
            state.notice = nil
        }
    }

    /// Presents a non-fatal notice and schedules its automatic dismissal.
    func presentNotice(_ notice: AgentSessionNotice, autoDismissAfter duration: Duration) {
        state.notice = notice
        scheduleNoticeAutoDismiss(after: duration)
    }

    /// Schedules automatic dismissal of the notice banner after the specified duration.
    private func scheduleNoticeAutoDismiss(after duration: Duration) {
        noticeAutoDismissTask?.cancel()
        noticeAutoDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            self?.dismissNotice()
        }
    }

    // MARK: - Bağlam sıkıştırma

    /// Elle `/compact`: düşen ön eki özetler, sunucu tarafını döndürür.
    /// Transkripte yazmaz; özet sonraki isteklerin başına eklenir.
    func requestCompaction() {
        guard !isBusy, !isCompacting else {
            presentNotice(.compactionFailed(reason: .busy), autoDismissAfter: .seconds(6))
            return
        }
        guard
            let configuration,
            let runtime = runtime(for: configuration.providerID)
        else {
            presentNotice(.compactionFailed(reason: .unavailable), autoDismissAfter: .seconds(6))
            return
        }
        guard
            let plan = ContextCompactor.plan(
                messages: state.messages,
                budget: budget,
                summarizedThroughMessageID: summarizedThroughMessageID
            )
        else {
            presentNotice(.compactionFailed(reason: .nothingToCompact), autoDismissAfter: .seconds(6))
            return
        }
        runCompaction(plan: plan, runtime: runtime, configuration: configuration, manual: true)
    }

    /// Sürmekte olan özet turunu durdurur (uzak taraf da kapatılır).
    func cancelCompaction() {
        compactionTask?.cancel()
        compactionTask = nil
    }

    /// Tur sonu otomatik sıkıştırma: aynı korumalar artı kuyruk boşluğu.
    /// Başarısızlık sessizdir — kapsama değişmediği için bir sonraki
    /// yerleşmede yeniden denenir, nag üretilmez.
    private func maybeAutoCompact() {
        guard
            !isBusy, queuedPrompts.isEmpty, !isCompacting,
            let configuration,
            let runtime = runtime(for: configuration.providerID),
            let plan = ContextCompactor.plan(
                messages: state.messages,
                budget: budget,
                summarizedThroughMessageID: summarizedThroughMessageID
            )
        else {
            return
        }
        runCompaction(plan: plan, runtime: runtime, configuration: configuration, manual: false)
    }

    /// Özet turu: geçici sağlayıcı sorgusu, transkripte ve turn makinesine
    /// dokunmaz (`/btw` ile aynı izolasyon). Başarıda özet uygulanır ve
    /// sunucu tarafı döndürülür; sonraki tur özeti taşıyarak taze açılır.
    private func runCompaction(
        plan: ContextCompactor.Plan,
        runtime: any ProviderRuntime,
        configuration: SessionConfiguration,
        manual: Bool
    ) {
        let coveredThroughID = plan.staleMessages.last?.id
        let prompt = ContextCompactor.summarizationPrompt(
            priorSummary: contextSummary,
            staleMessages: plan.staleMessages
        )
        let query = SideQuestionQuery(
            configuration: configuration,
            historyMessages: [],
            activityGroups: [],
            followups: [],
            question: prompt,
            speedMode: .normal,
            mode: .build,
            contextSummary: ""
        )
        compactionTask = Task { @MainActor [weak self] in
            defer { self?.compactionTask = nil }
            do {
                let stream = try await runtime.answerSideQuestion(query)
                var summary = ""
                var overshot = false
                for try await event in stream.events {
                    try Task.checkCancellation()
                    if case .assistantTextDelta(let text) = event {
                        summary += text
                        if summary.count > ContextCompactor.maximumSummaryCharacters + 1_000 {
                            overshot = true
                            break
                        }
                    }
                }
                if overshot {
                    // Akış erken bırakıldı: geçici uzak oturumun temizliği
                    // iptale bağlıdır, yoksa sunucuda ölü oturum kalır.
                    await stream.cancel()
                }
                let bounded = ContextCompactor.boundSummary(summary)
                guard !bounded.isEmpty else {
                    throw CancellationError()
                }
                self?.applyCompaction(summary: bounded, throughMessageID: coveredThroughID)
            } catch is CancellationError {
                // İptal veya boş özet: kapsama değişmedi, otomatik tur
                // bir sonrakinde yeniden dener; elle istenmişse de sessizlik
                // yerine kısa bir not düşer.
                if manual {
                    self?.presentNotice(
                        .compactionFailed(reason: .summarizerError),
                        autoDismissAfter: .seconds(6)
                    )
                }
            } catch {
                AppLog.agentSession.error(
                    "Context compaction failed: \(String(describing: error), privacy: .public)"
                )
                if manual {
                    self?.presentNotice(
                        .compactionFailed(reason: .summarizerError),
                        autoDismissAfter: .seconds(6)
                    )
                }
            }
        }
    }

    /// Özeti işler ve sunucu tarafını döndürür: sonraki tur, özet +
    /// pencereyle taze bir uzak oturumda açılır. Meşgulse rotasyon atlanır
    /// (canlı turun oturumunu silmektense özet bir sonraki boşlukta döner);
    /// özet yine de saklanır, bir sonraki taze oturumda taşınır.
    private func applyCompaction(summary: String, throughMessageID: UUID?) {
        contextSummary = summary
        summarizedThroughMessageID = throughMessageID
        onImmediatePersistentChange?()
        guard !isBusy, queuedPrompts.isEmpty else {
            return
        }
        guard
            let configuration,
            let runtime = runtime(for: configuration.providerID)
        else {
            return
        }
        // Sunucu tarafı dönüyor: eski sayım bayatlar, sonraki turun
        // bildirimi gelene kadar halka bilinmeyen gösterir ("–").
        lastTurnUsage = nil
        presentNotice(.contextCompacted, autoDismissAfter: .seconds(6))
        // Yarış notu: `await` sırasında yeni bir tur başlayabilir; o turun ilk
        // gönderimi bilinmeyen-oturum hatasına düşerse çalışma zamanı onu
        // özet taşıyan preambulle otomatik yeniden kurar.
        let sessionID = id
        Task { @MainActor [weak self] in
            guard let self, !self.isBusy, self.queuedPrompts.isEmpty else {
                return
            }
            await runtime.releaseSession(sessionID)
        }
    }

    /// The question tool supplies a server request ID, not a suggested next prompt.
    private func receiveBackendQuestion(_ request: OpenCodeQuestionRequest, turnID: UUID) {
        guard !request.questions.isEmpty else { return }
        if pendingBackendQuestion != nil {
            guard !queuedBackendQuestions.contains(where: { $0.request.requestID == request.requestID }) else { return }
            queuedBackendQuestions.append((request: request, turnID: turnID))
            return
        }
        pendingBackendQuestion = PendingBackendQuestion(request: request, turnID: turnID)
        presentBackendQuestion(request.questions[0], toolCallID: request.toolCallID)
    }

    private func presentBackendQuestion(_ item: OpenCodeQuestionItem, toolCallID: String?) {
        state.activeQuestion = AgentQuestion(
            id: UUID(), toolCallID: toolCallID, prompt: item.prompt,
            options: item.options, allowCustomAnswer: item.allowCustomAnswer,
            isMultiSelect: item.isMultiSelect, createdAt: Date(), status: .pending
        )
        state.isQuestionSubmitting = false
        state.questionSubmissionFailed = false
        state.status = .waiting
    }

    private func answerBackendQuestion(_ answer: AgentQuestionAnswer) {
        guard !state.isQuestionSubmitting,
            var batch = pendingBackendQuestion,
            let current = state.activeQuestion,
            activeTurnID == batch.turnID
        else { return }

        if batch.answers.count < batch.request.questions.count {
            let item = batch.request.questions[batch.index]
            let validIDs = Set(item.options.map(\.id))
            let selected = Set(answer.selectedOptionIDs)
            let isAllSelected = selected.contains("__all__") || selected.contains("opt_all")
            guard isAllSelected || selected.isSubset(of: validIDs),
                item.isMultiSelect || selected.count <= 1
            else {
                state.questionSubmissionFailed = true
                return
            }

            var values: [String]
            if isAllSelected {
                if item.isMultiSelect {
                    values = item.options.map(\.label)
                } else {
                    let summary = item.options.map(\.label).joined(separator: "; ")
                    values = [summary.isEmpty ? "Hepsi" : "Hepsi (Tümünü uygula): " + summary]
                }
            } else {
                values = item.options.filter { selected.contains($0.id) }.map(\.label)
            }
            if item.allowCustomAnswer,
                let custom = answer.customText?.trimmingCharacters(in: .whitespacesAndNewlines),
                !custom.isEmpty
            {
                values.append(custom)
            }
            guard !values.isEmpty else {
                state.questionSubmissionFailed = true
                return
            }

            var answered = current
            answered.status = .answered(answer)
            batch.answers.append(values)
            batch.resolvedQuestions.append(answered)

            if batch.answers.count < batch.request.questions.count {
                batch.index += 1
                pendingBackendQuestion = batch
                presentBackendQuestion(batch.request.questions[batch.index], toolCallID: batch.request.toolCallID)
                return
            }
            pendingBackendQuestion = batch
        }
        submitBackendAnswers()
    }

    private func submitBackendAnswers() {
        guard let batch = pendingBackendQuestion,
            batch.answers.count == batch.request.questions.count,
            !state.isQuestionSubmitting
        else { return }
        // Akış kapanmışsa yanıt sessizce düşmemeli: soru beklemede tutulur
        // ve yeniden-dene bayrağı konur, yoksa oturum `.waiting` konumunda
        // asılı kalır.
        guard activeTurnID == batch.turnID, let stream = activeStream else {
            state.questionSubmissionFailed = true
            AppLog.agentSession.error(
                "Backend question answer could not be delivered: turn is no longer active"
            )
            return
        }

        state.isQuestionSubmitting = true
        state.questionSubmissionFailed = false
        Task { @MainActor [weak self] in
            do {
                try await stream.replyQuestion(requestID: batch.request.requestID, answers: batch.answers)
                guard let self,
                    self.activeTurnID == batch.turnID,
                    self.pendingBackendQuestion?.request.requestID == batch.request.requestID
                else { return }
                self.state.questionHistory.append(contentsOf: batch.resolvedQuestions)
                self.pendingBackendQuestion = nil
                self.state.activeQuestion = nil
                self.state.isQuestionSubmitting = false
                self.state.questionSubmissionFailed = false
                self.state.status = .streaming
                self.presentNextBackendQuestion(turnID: batch.turnID)
            } catch {
                guard let self,
                    self.activeTurnID == batch.turnID,
                    self.pendingBackendQuestion?.request.requestID == batch.request.requestID
                else { return }
                // A failed request is not an accepted answer. Keep earlier
                // answers for a multi-question batch, but allow editing the
                // final choice before retrying the same backend request.
                if var pending = self.pendingBackendQuestion {
                    pending.answers.removeLast()
                    pending.resolvedQuestions.removeLast()
                    self.pendingBackendQuestion = pending
                }
                self.state.isQuestionSubmitting = false
                self.state.questionSubmissionFailed = true
                AppLog.agentSession.error("OpenCode question reply could not be delivered")
            }
        }
    }

    private func rejectBackendQuestion() {
        guard let batch = pendingBackendQuestion,
            let stream = activeStream,
            !state.isQuestionSubmitting
        else { return }
        state.isQuestionSubmitting = true
        state.questionSubmissionFailed = false
        Task { @MainActor [weak self] in
            do {
                try await stream.rejectQuestion(requestID: batch.request.requestID)
                guard let self,
                    self.activeTurnID == batch.turnID,
                    self.pendingBackendQuestion?.request.requestID == batch.request.requestID
                else { return }
                if var active = self.state.activeQuestion {
                    active.status = .dismissed
                    self.state.questionHistory.append(active)
                }
                self.pendingBackendQuestion = nil
                self.state.activeQuestion = nil
                self.state.isQuestionSubmitting = false
                self.state.questionSubmissionFailed = false
                self.state.status = .streaming
                self.presentNextBackendQuestion(turnID: batch.turnID)
            } catch {
                guard let self,
                    self.activeTurnID == batch.turnID,
                    self.pendingBackendQuestion?.request.requestID == batch.request.requestID
                else { return }
                self.state.isQuestionSubmitting = false
                self.state.questionSubmissionFailed = true
                AppLog.agentSession.error("OpenCode question rejection could not be delivered")
            }
        }
    }

    private func presentNextBackendQuestion(turnID: UUID) {
        guard activeTurnID == turnID else { return }
        // Ölü turun sorusu yeni turun akışına karışmamalı: yalnız aynı
        // turne ait kuyruk sunulur, diğerleri düşürülür.
        while !queuedBackendQuestions.isEmpty, queuedBackendQuestions.first?.turnID != turnID {
            queuedBackendQuestions.removeFirst()
        }
        guard !queuedBackendQuestions.isEmpty else { return }
        let next = queuedBackendQuestions.removeFirst()
        receiveBackendQuestion(next.request, turnID: turnID)
    }

    /// A cancelled/completed stream cannot accept a stale question reply.
    private func clearBackendQuestions(turnID: UUID) {
        queuedBackendQuestions.removeAll { $0.turnID == turnID }
        guard pendingBackendQuestion?.turnID == turnID else { return }
        pendingBackendQuestion = nil
        state.activeQuestion = nil
        state.isQuestionSubmitting = false
        state.questionSubmissionFailed = false
    }

    /// Kuyruk `state` dışında durur, o yüzden değişimi kalıcılığa elle bildirir.
    ///
    /// Bildirilmezse kapanışta tur ortasında bekleyen mesajlar yazılmadan kalır
    /// ve açılışta kuyruk boş gelir.
    private func noteQueueChange() {
        onPersistentChange?()
    }

    /// Sends the oldest queued prompt, if the session is free again.
    private func startNextQueuedTurn() {
        guard activeTurnID == nil, !isBusy, !queuedPrompts.isEmpty else {
            return
        }

        let next = queuedPrompts.removeFirst()
        // Kuyruktan düşen mesaj ya tura dönüşür (o zaman `state` değişimi
        // kalıcılığı tetikler) ya da başlayamaz — ikinci hâlde başa iade
        // edilir, yoksa mesaj ne turda ne kuyruktadır.
        noteQueueChange()
        if startTurn(for: next) == nil {
            queuedPrompts.insert(next, at: 0)
            noteQueueChange()
            AppLog.agentSession.error(
                "A queued prompt could not start because the session has no usable provider"
            )
        }
    }

    @discardableResult
    private func startTurn(for queuedPrompt: QueuedPrompt) -> Task<Void, Never>? {
        guard
            let configuration = state.configuration,
            let runtime = runtime(for: configuration.providerID)
        else {
            return nil
        }

        let stagedAttachmentPaths = AttachmentStager.stage(
            paths: queuedPrompt.attachmentPaths,
            sessionID: id,
            date: Date(),
            uniquifier: DroppedImageAttachment.defaultUniquifier(),
            fileManager: FileManager.default,
            baseURL: AttachmentStager.liveBaseURL()
        )
        let userMessage = ChatMessage(
            role: .user,
            text: queuedPrompt.text,
            attachmentPaths: stagedAttachmentPaths,
            extensionTags: queuedPrompt.extensionTags
        )
        state.messages.append(userMessage)
        state.status = .streaming
        state.error = nil
        state.startedAt = Date()
        state.completedAt = nil
        todoRefreshGeneration &+= 1
        // Yeni tur önceki turun listesiyle açılmıyordu: ajan kendi listesini
        // yazana kadar besteci paneli eski maddeleri gösteriyordu.
        state.todos = []
        discardPendingAssistantText()
        activeAssistantMessageID = nil
        currentTurnAnchorMessageID = userMessage.id
        turnProducedAssistantText = false

        // Düşünme satırı tembeldir: ilk `thinkingDelta` gelene kadar grup boş
        // durur. Reasoning paylaşmayan modellerde `output` hiç dolmadığı için
        // her turda boş bir "Thought" satırı çiziliyordu.
        let turnID = UUID()
        state.activityGroups.append(
            AgentTurnActivityGroup(
                id: turnID,
                anchorMessageID: userMessage.id,
                activities: [],
                turnID: turnID
            )
        )
        hasRunningThinkingActivity = false

        let selection = budget.select(from: state.messages)
        if selection.droppedMessageCount != lastTrimNoticeDroppedCount {
            // Kayıp DEĞİŞTİ: büyüdü ya da küçüldü, bandı güncel tut.
            lastTrimNoticeDroppedCount = selection.droppedMessageCount
            if selection.droppedMessageCount > 0 {
                presentNotice(
                    .transcriptTrimmed(droppedMessageCount: selection.droppedMessageCount),
                    autoDismissAfter: .seconds(6)
                )
            } else {
                // Yalnız kırpma bildirimi geri çekilir: `dismissNotice()` koşulsuz
                // çağrıldığında, saniyeler önce gösterilmiş ilgisiz bir uyarıyı
                // (başarısız `/compact` gibi) yeni bir mesaj göndermek siliyordu.
                if state.notice?.isTranscriptTrim == true {
                    dismissNotice()
                }
            }
        }
        // Aynı kayıp sürüyorsa banner yeniden kurulmaz: her turda beliren
        // nag, bildirimin kendisinden usandırıyordu.

        let request = ProviderRequest(
            sessionID: id,
            configuration: configuration,
            messages: selection.messages,
            speedMode: queuedPrompt.speedMode,
            mode: queuedPrompt.mode,
            extensionContext: queuedPrompt.extensionTags.turnInstruction,
            activityGroups: state.activityGroups,
            contextSummary: contextSummary
        )
        activeTurnID = turnID
        activeTurnSpeedMode = queuedPrompt.speedMode
        activeTurnMode = queuedPrompt.mode
        onTurnStarted?(id, turnID)

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await self.consume(
                runtime: runtime,
                request: request,
                turnID: turnID
            )
        }
        activeTask = task
        return task
    }

    func cancel() async {
        // Both handles have to name a live turn: a finished turn's task handle
        // can linger behind (see consume), and cancelling through it would
        // settle whatever turn happens to run now — including clearing a newer
        // turn's state while its stream keeps running orphaned.
        guard let task = activeTask, let cancelledTurnID = activeTurnID else {
            return
        }

        state.status = .cancelling
        state.error = nil
        task.cancel()

        if let activeStream {
            await activeStream.cancel()
        }

        await task.value

        // A queued prompt may already have taken the session over while the
        // cancelled turn was unwinding; that turn's state must survive here.
        // The comparison is against a non-optional turn: a settle with no
        // active turn used to pass vacuously (`nil == nil`) and clear the
        // state of whatever turn had just started.
        guard activeTurnID == cancelledTurnID else {
            return
        }

        if state.status == .cancelling {
            state.status = .cancelled
            state.completedAt = Date()
        }

        // İptal edilen turun bekleyen sorusu ölü turne bağlı kalmamalı;
        // kart takılı kalır ve sonraki turun akışına karışır.
        clearBackendQuestions(turnID: cancelledTurnID)

        activeTask = nil
        activeStream = nil
        activeTurnID = nil
        // Bitiş bildirimi yalnızca `consume`'un `defer` bloğundan gelir (tek
        // kaynak); burada ikinci kez çağrılmaz, yoksa onay merkezi aynı turu
        // iki kez kapatır.
        onImmediatePersistentChange?()
        startNextQueuedTurn()
    }

    /// Settles a turn whose owner is gone without handing the session over.
    ///
    /// Every `guard activeTurnID == turnID` exit in `consume` means one of two
    /// things: a newer turn owns the session — then nothing here may touch it —
    /// or no turn does while the session still reports busy. The second case is
    /// a leaked turn, and without this recovery its stop control stays on
    /// screen forever: the transcript says the agent is done (its last text is
    /// already there) while the session never leaves the busy state.
    ///
    /// A `.cancelling` orphan was asked to stop, so it settles as `.cancelled`;
    /// any other busy orphan died silently and settles as an interruption.
    /// `onTurnEnded` still fires through `consume`'s `defer`, so the approval
    /// centre releases the turn exactly once.
    private func recoverOrphanedTurnIfNeeded(turnID: UUID) {
        guard activeTurnID == nil, isBusy else {
            return
        }

        AppLog.agentSession.error(
            "A turn ended without handing the session over; settling it instead of staying busy"
        )
        if state.status == .cancelling {
            finishRunningActivities(turnID: turnID, phase: .cancelled)
            state.status = .cancelled
        } else {
            finishRunningActivities(turnID: turnID, phase: .failed)
            state.status = .failed
            state.error = .streamInterrupted
        }
        state.completedAt = Date()
        clearBackendQuestions(turnID: turnID)
        activeTask = nil
        activeStream = nil
        activeTurnID = nil
        activeAssistantMessageID = nil
        discardPendingAssistantText()
        onImmediatePersistentChange?()
        startNextQueuedTurn()
    }

    private func consume(
        runtime: any ProviderRuntime,
        request: ProviderRequest,
        turnID: UUID
    ) async {
        defer {
            onTurnEnded?(id, turnID)
        }
        do {
            // A turn the user cancelled before it reached the provider must not
            // open a backend stream just to tear it down again: it would start a
            // real request (and, for OpenCode, a real session turn) whose only
            // possible fate is cancellation.
            if Task.isCancelled {
                throw CancellationError()
            }

            let stream = try await runtime.startStream(for: request)

            if Task.isCancelled {
                await stream.cancel()
                throw CancellationError()
            }

            guard activeTurnID == turnID else {
                await stream.cancel()
                recoverOrphanedTurnIfNeeded(turnID: turnID)
                return
            }

            activeStream = stream
            var didComplete = false

            for try await event in stream.events {
                try Task.checkCancellation()

                guard activeTurnID == turnID else {
                    await stream.cancel()
                    recoverOrphanedTurnIfNeeded(turnID: turnID)
                    return
                }

                switch event {
                case .questionAsked(let question):
                    flushPendingAssistantText(turnID: turnID)
                    flushPendingThinkingText(turnID: turnID)
                    finishThinkingActivity(turnID: turnID)
                    receiveBackendQuestion(question, turnID: turnID)

                case .assistantTextDelta(let delta):
                    flushPendingThinkingText(turnID: turnID)
                    finishThinkingActivity(turnID: turnID)
                    enqueueAssistantText(delta, turnID: turnID)

                case .thinkingDelta(let text):
                    appendThinkingText(text, turnID: turnID)

                case .turnUsage(let usage):
                    // Bu dal tur kimliği korumasının içindedir: sayı koşan
                    // turun adımına aittir, halka bir sonraki çizimde
                    // sağlayıcının gerçeğine oturur. Ömür boyu sayaç da
                    // burada birikir (tur başına tek bildirim varsayılır).
                    lastTurnUsage = usage
                    totalInputTokens += usage.inputTokens
                    totalOutputTokens += usage.outputTokens

                case .activityStarted(let activity):
                    flushPendingAssistantText(turnID: turnID)
                    flushPendingThinkingText(turnID: turnID)
                    finishThinkingActivity(turnID: turnID)
                    if activeAssistantMessageID != nil {
                        currentTurnAnchorMessageID = activeAssistantMessageID
                        activeAssistantMessageID = nil
                    }
                    startActivity(activity, turnID: turnID)

                    // Görev listesi yazı bitince okunur, başlarken değil: başlangıçta
                    // backend henüz eski listeyi tutar, o yüzden önceki turun
                    // bitmiş kartı yeni turun ortasında görünürdü. Yeniden okuma
                    // `activityFinished` dalında yapılır.
                    if activity.kind == .question,
                        request.configuration.providerID != ProviderID("opencode")
                    {
                        // OpenCode questions use question.asked, never a title-derived imitation.
                        let parsedQuestion = AgentQuestionParser.parseFromToolInput(
                            toolCallID: activity.id.rawValue,
                            input: [
                                "prompt": activity.title ?? "Question from assistant",
                                "detail": activity.detail as Any,
                            ]
                        )
                        if let parsedQuestion {
                            askQuestion(parsedQuestion)
                        }
                    }

                case .activityUpdated(let activity):
                    enqueueActivityUpdate(activity, turnID: turnID)

                case .activityFinished(let activityID, let outcome, let output, let diff):
                    flushPendingActivityUpdates(turnID: turnID)
                    flushPendingAssistantText(turnID: turnID)
                    flushPendingThinkingText(turnID: turnID)
                    let finishedKind = activityKind(for: activityID)
                    finishActivity(
                        activityID,
                        outcome: outcome,
                        output: output,
                        diff: diff,
                        turnID: turnID
                    )
                    restoreStatusAfterActivity(turnID: turnID)
                    // Görev listesi aracı bittiğinde backend yazıyı işlemiş olur:
                    // liste ancak burada okunursa kart yeni turun listesini
                    // gösterir, önceki turun bayat kartını değil.
                    if finishedKind == .todo {
                        refreshTodos()
                    }

                case .waiting:
                    flushPendingAssistantText(turnID: turnID)
                    state.status = .waiting

                case .completed:
                    flushPendingActivityUpdates(turnID: turnID)
                    flushPendingAssistantText(turnID: turnID)
                    flushPendingThinkingText(turnID: turnID)
                    finishRunningActivities(
                        turnID: turnID,
                        phase: .completed
                    )
                    didComplete = true
                    offerQuickReplyOptionsIfAvailable()
                }

                if didComplete {
                    break
                }
            }

            if Task.isCancelled {
                throw CancellationError()
            }

            guard activeTurnID == turnID else {
                recoverOrphanedTurnIfNeeded(turnID: turnID)
                return
            }

            flushPendingAssistantText(turnID: turnID)

            if didComplete {
                // Sağlayıcı "bitti" dedi ama ne metin ne araç üretti: bunu sessiz
                // bir başarı olarak göstermek, kullanıcının ekranda yeni hiçbir
                // şey göremeyip "ajan başlamadı" demesi demekti.
                //
                // Bildirim yuvası değil `error` kullanılır: tek bir bildirim
                // yuvası var ve buraya yazmak kırpma raporu gibi başka bir
                // bildirimi ezerdi (bkz. `startTurn`'daki aynı sınıf hata).
                if shouldReportEmptyTurn(turnID: turnID) {
                    state.status = .failed
                    state.error = .unexpectedBackendResponse
                } else {
                    state.status = .completed
                }
                state.completedAt = Date()
            } else {
                finishRunningActivities(turnID: turnID, phase: .failed)
                state.status = .failed
                state.error = .streamInterrupted
                state.completedAt = Date()
            }
        } catch is CancellationError {
            guard activeTurnID == turnID else {
                recoverOrphanedTurnIfNeeded(turnID: turnID)
                return
            }

            flushPendingAssistantText(turnID: turnID)
            finishRunningActivities(turnID: turnID, phase: .cancelled)
            state.status = .cancelled
            state.completedAt = Date()
        } catch let error as ProviderRuntimeError {
            guard activeTurnID == turnID else {
                recoverOrphanedTurnIfNeeded(turnID: turnID)
                return
            }

            flushPendingAssistantText(turnID: turnID)
            finishRunningActivities(turnID: turnID, phase: .failed)
            state.status = .failed
            state.error = Self.sessionError(for: error)
            state.completedAt = Date()
            AppLog.agentSession.error(
                "Turn failed with provider error \(String(describing: error), privacy: .public)"
            )
        } catch {
            guard activeTurnID == turnID else {
                recoverOrphanedTurnIfNeeded(turnID: turnID)
                return
            }

            flushPendingAssistantText(turnID: turnID)
            finishRunningActivities(turnID: turnID, phase: .failed)
            state.status = .failed
            state.error = .transportFailure
            state.completedAt = Date()
        }

        if activeTurnID == turnID {
            clearBackendQuestions(turnID: turnID)
            activeTask = nil
            activeStream = nil
            activeTurnID = nil
            activeAssistantMessageID = nil
            discardPendingAssistantText()
            pruneActivityHistory()
            // The last write of a turn and the turn's own completion are not the
            // same event, so the list is read once more at the end: the checklist
            // left on screen has to be the state the agent actually stopped in.
            refreshTodos()
            onImmediatePersistentChange?()
            let lastSnippet = state.messages.last(where: { $0.role == .assistant })?.text
            onTurnFinished?(id, title, state.status, lastSnippet)
            startNextQueuedTurn()
            // Kuyruk boşaldıysa ve pencere taştıysa özet turu: sunucu tarafı
            // büyümeden budanır, düşen ön ek özetten yaşamaya devam eder.
            maybeAutoCompact()
        }
    }

    /// Tur "tamamlandı" dedi ama ne metin ne araç üretti mi.
    ///
    /// Yalnız gerçekten boş turlar: araç çalıştırmış bir tur (ör. yalnız dosya
    /// okuyup metin üretmeyen bir tur) normaldir ve başarısız sayılmaz.
    ///
    /// Ölçülen olay: OpenCode'un oturum günlüğünde, kullanıcı mesajı oluşturulup
    /// yalnız `agent=title` akışı koştuğunda (model turu hiç başlamadığında)
    /// gelen tek olay `session.idle`'dır; uygulama bunu "tamamlandı" sayıp
    /// ekranda hiçbir şey göstermiyordu.
    private func shouldReportEmptyTurn(turnID: UUID) -> Bool {
        guard !turnProducedAssistantText else {
            return false
        }
        let hasRealActivity =
            state.activityGroups
            .filter { $0.id == turnID || $0.turnID == turnID }
            .flatMap(\.activities)
            .contains { $0.kind != .thinking }
        return !hasRealActivity
    }

    /// Tamamlanan turun sonunda hızlı-yanıt seçenekleri varsa soru olarak sunar.
    ///
    /// Olay döngüsünün `.completed` dalından çıkarılmıştır; döngü yalnızca
    /// olayı ilgili yönteme yönlendirir.
    private func offerQuickReplyOptionsIfAvailable() {
        guard
            let lastAssistant = state.messages.last,
            lastAssistant.role == .assistant
        else {
            return
        }

        let quickOptions = AgentQuestionParser.parseQuickReplyOptions(from: lastAssistant.text)
        guard !quickOptions.isEmpty, state.activeQuestion == nil else {
            return
        }

        askQuestion(
            AgentQuestion(
                id: UUID(),
                toolCallID: nil,
                prompt: "Choose an option or type an answer:",
                options: quickOptions,
                allowCustomAnswer: true,
                isMultiSelect: true,
                createdAt: Date(),
                status: .pending
            )
        )
    }

    /// Re-reads the agent's task list for this session.
    ///
    /// Every call replaces the list; a provider that has no list answers `nil` and
    /// leaves the last one in place, because "no answer" is not "no tasks".
    func refreshTodos() {
        guard let configuration = state.configuration,
            let runtime = runtime(for: configuration.providerID)
        else {
            return
        }

        todoRefreshGeneration &+= 1
        let generation = todoRefreshGeneration
        let sessionID = state.id
        Task { @MainActor [weak self] in
            guard let todos = await runtime.sessionTodos(sessionID: sessionID) else {
                return
            }

            self?.applyTodos(todos, sessionID: sessionID, generation: generation)
        }
    }

    private func applyTodos(_ todos: [AgentTodo], sessionID: UUID, generation: Int) {
        // A slow answer for a session the user has already left must not land in
        // whichever session is on screen now.
        guard state.id == sessionID, generation == todoRefreshGeneration else {
            return
        }

        guard state.todos != todos else {
            return
        }

        state.todos = todos
    }

    private func enqueueAssistantText(
        _ delta: String,
        turnID: UUID
    ) {
        guard activeTurnID == turnID else {
            return
        }

        let appendResult = streamingTextAccumulator.appending(delta)
        streamingTextAccumulator = appendResult.accumulator

        guard appendResult.shouldScheduleFlush else {
            return
        }

        let interval = Self.streamingTextInterval(
            forMessageLength: activeAssistantTextLength,
            speedMode: activeTurnSpeedMode,
            isVisibleInUI: isVisibleInUI
        )

        streamingTextFlushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            self?.flushPendingAssistantText(turnID: turnID)
        }
    }

    /// Akış hedefi asistan mesajının şu anki uzunluğu; yoksa sıfır.
    ///
    /// Boşaltma aralığı buna göre seçilir. `utf8.count` (karakter sayımının
    /// aksine) sabit zamanlıdır ve karakter sayısından küçük olamaz, yani eşik
    /// ön elemesi için yeterlidir.
    private var activeAssistantTextLength: Int {
        guard
            let id = activeAssistantMessageID,
            let index = messageIndex(id: id)
        else {
            return 0
        }

        return state.messages[index].text.utf8.count
    }

    private func flushPendingAssistantText(turnID: UUID) {
        guard activeTurnID == turnID else {
            return
        }

        streamingTextFlushTask?.cancel()
        streamingTextFlushTask = nil

        let drainResult = streamingTextAccumulator.draining()
        streamingTextAccumulator = drainResult.accumulator

        guard let text = drainResult.text else {
            return
        }
        turnProducedAssistantText = true

        if let activeAssistantMessageID,
            let index = messageIndex(id: activeAssistantMessageID)
        {
            state.messages[index].text += text
        } else {
            let message = ChatMessage(role: .assistant, text: text)
            activeAssistantMessageID = message.id
            currentTurnAnchorMessageID = message.id
            state.messages.append(message)
        }
        state.status = .streaming
    }

    private func discardPendingAssistantText() {
        hasRunningThinkingActivity = false
        streamingTextFlushTask?.cancel()
        streamingTextFlushTask = nil
        streamingTextAccumulator = .empty
        activityUpdateFlushTask?.cancel()
        activityUpdateFlushTask = nil
        pendingActivityUpdates.removeAll(keepingCapacity: false)
        discardPendingThinkingText()
    }

    /// Thinking deltasını biriktirir; kart 250 ms debounce ile yazılır.
    ///
    /// Her SSE satırında `state`'e dokunmak `@Observable` fırtınası çıkarır;
    /// düşünme kartı typewriter değil, periyodik tazelenen bir karttır.
    private func appendThinkingText(
        _ delta: String,
        turnID: UUID
    ) {
        guard activeTurnID == turnID, !delta.isEmpty else {
            return
        }

        pendingThinkingText += delta

        guard thinkingFlushTask == nil else {
            return
        }

        thinkingFlushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            self?.flushPendingThinkingText(turnID: turnID)
        }
    }

    private func flushPendingThinkingText(turnID: UUID) {
        guard activeTurnID == turnID else {
            return
        }

        thinkingFlushTask?.cancel()
        thinkingFlushTask = nil

        guard !pendingThinkingText.isEmpty else {
            return
        }
        let text = pendingThinkingText
        pendingThinkingText = ""
        appendThinkingContent(text, turnID: turnID)
    }

    /// Biriken düşünmeyi turdaki `.thinking` aktivitesine ekler.
    ///
    /// `output` seçimi bilinçlidir: arşiv sınırı (`boundedForArchive`) yalnız
    /// `output`/`diff`'i kırpar, `detail`'i değil — düşünme arşivi şişirmez.
    /// Geçmişe taşınmaz (`OpenCodeHistoryPreamble` thinking'i atlar) ve
    /// boş-tur sayılmaz (`shouldReportEmptyTurn` thinking'i yok sayar).
    ///
    /// Her reasoning bloğu kendi kartını kurar: koşan kart varsa metin oraya
    /// akar (aynı blok tek kartta birikir); kapanmış bir kart ASLA yeniden
    /// açılmaz — araç/metin sonrası gelen ikinci blok grubun sonuna yeni kart
    /// olarak eklenir. Böylece düşünme parçaları komutlar gibi çağrıldıkları
    /// yerde alt alta sıralanır, tek dev kartta toplanmaz.
    private func appendThinkingContent(_ text: String, turnID: UUID) {
        guard let groupIndex = activityGroupIndex(turnID: turnID) else {
            return
        }
        let activityIndex: Int
        if let runningIndex = state.activityGroups[groupIndex].activities.firstIndex(
            where: { $0.kind == .thinking && $0.phase == .running }
        ) {
            activityIndex = runningIndex
        } else {
            let segment = state.activityGroups[groupIndex].activities.filter { $0.kind == .thinking }.count
            state.activityGroups[groupIndex].activities.append(
                AgentActivity(
                    id: ProviderActivityID("turn-\(turnID.uuidString)-thinking-\(segment)"),
                    kind: .thinking,
                    phase: .running
                )
            )
            activityIndex = state.activityGroups[groupIndex].activities.count - 1
            hasRunningThinkingActivity = true
        }

        var activity = state.activityGroups[groupIndex].activities[activityIndex]
        let existing = activity.output ?? ""
        // Kapak dolduysa sessizce düşer: düşünme turu bozmaz.
        guard existing.utf8.count < Self.maximumThinkingCharacters else {
            return
        }
        let room = Self.maximumThinkingCharacters - existing.utf8.count
        let fitting = text.utf8.count <= room ? text : String(text.prefix(room)) + "\n… (thought truncated)"
        activity.output = existing + fitting
        state.activityGroups[groupIndex].activities[activityIndex] = activity
        noteActivityChange()
    }

    private func discardPendingThinkingText() {
        thinkingFlushTask?.cancel()
        thinkingFlushTask = nil
        pendingThinkingText = ""
    }

    /// Aktif turun grubu listenin sonundadır; her aktivite olayında bütün
    /// geçmişi taramak yerine önce oraya bakılır.
    private func activityGroupIndex(turnID: UUID) -> Int? {
        if let last = state.activityGroups.indices.last,
            state.activityGroups[last].id == turnID
        {
            return last
        }

        return state.activityGroups.firstIndex { $0.id == turnID }
    }

    /// Akış hedefi olan asistan mesajı transkriptin sonundadır; 40 ms'de bir
    /// bütün transkripti taramaya gerek yok.
    private func messageIndex(id: UUID) -> Int? {
        if let last = state.messages.indices.last,
            state.messages[last].id == id
        {
            return last
        }

        return state.messages.firstIndex { $0.id == id }
    }

    /// Bir araç sonucunun bellekte saklanan hâli.
    ///
    /// Dosya içerikleri ve terminal çıktıları sınırsızdır; tek bir uzun tur
    /// bunların tamamını RAM'de biriktirebilir.
    /// Aktivite içeriği her değiştiğinde artan sayaç.
    ///
    /// `TranscriptIndexCache` anahtarı yalnız sayı ve fazlara baktığı için, akan
    /// bir aracın başlığı/çıktısı güncellendiğinde anahtar değişmiyor ve satır
    /// önbellekteki eski kopyayla çiziliyordu.
    private func noteActivityChange() {
        state.activityRevision &+= 1
        pruneActivityHistoryDuringTurnIfNeeded()
    }

    /// Tur sürerken de zaman çizelgesini tavanda tutar.
    ///
    /// Bitişteki budama uzun tek bir turda işe yaramıyor: tur boyunca yüzlerce
    /// aktivite birikiyor, hem RAM hem de her yerleşim turunun maliyeti
    /// aktivite sayısıyla büyüyordu. Pay, budamanın her aktivitede O(n)
    /// çalışmasını engeller.
    private func pruneActivityHistoryDuringTurnIfNeeded() {
        let total = state.activityGroups.reduce(0) { $0 + $1.activities.count }
        guard total > Self.maximumInMemoryActivities + Self.activityPruneHeadroom else {
            return
        }
        pruneActivityHistory()
    }

    private static func boundedForMemory(_ text: String) -> String {
        // `count` bütün metni dolaşır; bir aracın her güncellemesinde 10 MB'lık
        // bir çıktıyı saymak ana iş parçacığını meşgul eder. Bayt sayısı sabit
        // zamanlıdır ve karakter sayısından küçük olamaz, yani ön eleme için
        // yeterlidir.
        guard text.utf8.count > maximumInMemoryOutputLength else {
            return text
        }

        let head = text.prefix(maximumInMemoryOutputLength)
        guard head.endIndex < text.endIndex else {
            return text
        }

        // Kaç karakterin düştüğü yazılmaz: bu sayı için metnin tamamını
        // dolaşmak gerekir ve budama her güncellemede çalışır.
        return String(head) + "\n… (truncated; the full result was not kept in memory)"
    }

    /// Biten turdan sonra bellekteki zaman çizelgesini sınırların içine çeker.
    private func pruneActivityHistory() {
        // Önce mesaj penceresi: en yeni 1000 mesaj tutulur, ön ek özetten yaşar.
        if state.messages.count > Self.maximumInMemoryMessages {
            let excess = state.messages.count - Self.maximumInMemoryMessages
            state.messages.removeFirst(excess)
        }
        // Yalnızca grup sayısı budanır: araç sonuçları zaten yakalandıkları anda
        // sınırlandı, burada yeniden kırpmak işareti her turda tazeleyip
        // sayısını yanlışlardı.
        let bounded = state.activityGroups.bounded(
            toActivityCount: Self.maximumInMemoryActivities,
            anchoredTo: Set(state.messages.map(\.id))
        )

        guard bounded != state.activityGroups else {
            return
        }

        state.activityGroups = bounded
    }

    private func finishThinkingActivity(turnID: UUID) {
        guard hasRunningThinkingActivity else {
            return
        }
        hasRunningThinkingActivity = false
        // Tur başına tek bir çalışan "thinking" satırı vardır ve o, aktif turun
        // — yani sondaki — grubundadır. Eskiden bütün geçmiş taranıyor ve
        // bulunduktan sonra da döngü kırılmıyordu.
        for groupIndex in state.activityGroups.indices.reversed() {
            guard
                let activityIndex = state.activityGroups[groupIndex].activities.firstIndex(
                    where: { $0.kind == .thinking && $0.phase == .running }
                )
            else {
                continue
            }
            state.activityGroups[groupIndex].activities[activityIndex].phase = .completed
            state.activityGroups[groupIndex].activities[activityIndex].completedAt = Date()
            return
        }
    }

    private func startActivity(
        _ descriptor: ProviderActivityDescriptor,
        turnID: UUID
    ) {
        if let existingGroupIndex = state.activityGroups.indices.reversed().first(where: {
            state.activityGroups[$0].activities.contains { $0.id == descriptor.id }
        }) {
            if let activityIndex = state.activityGroups[existingGroupIndex].activities.firstIndex(
                where: { $0.id == descriptor.id }
            ) {
                state.activityGroups[existingGroupIndex].activities[activityIndex].phase = .running
                if let output = descriptor.output {
                    state.activityGroups[existingGroupIndex].activities[activityIndex].output =
                        Self.boundedForMemory(output)
                }
                if let diff = descriptor.diff {
                    state.activityGroups[existingGroupIndex].activities[activityIndex].diff =
                        Self.boundedForMemory(diff)
                }
            }
            state.status = .runningTool(
                AgentActivityPresentation(kind: descriptor.kind).runningStatusName
            )
            noteActivityChange()
            return
        }

        let anchorID = currentTurnAnchorMessageID ?? state.messages.last?.id ?? UUID()
        let targetGroupIndex: Int
        if let lastGroupIndex = state.activityGroups.indices.last,
            state.activityGroups[lastGroupIndex].anchorMessageID == anchorID
        {
            targetGroupIndex = lastGroupIndex
        } else {
            let newGroup = AgentTurnActivityGroup(
                id: UUID(),
                anchorMessageID: anchorID,
                activities: [],
                turnID: activeTurnID
            )
            state.activityGroups.append(newGroup)
            guard let target = state.activityGroups.indices.last else {
                return
            }
            targetGroupIndex = target
        }

        state.activityGroups[targetGroupIndex].activities.append(
            AgentActivity(
                id: descriptor.id,
                kind: descriptor.kind,
                phase: .running,
                title: descriptor.title,
                detail: descriptor.detail,
                output: descriptor.output.map(Self.boundedForMemory),
                diff: descriptor.diff.map(Self.boundedForMemory),
                startedAt: Date(),
                completedAt: nil
            )
        )

        state.status = .runningTool(
            AgentActivityPresentation(kind: descriptor.kind).runningStatusName
        )
        noteActivityChange()
    }

    private func enqueueActivityUpdate(_ descriptor: ProviderActivityDescriptor, turnID: UUID) {
        guard activeTurnID == turnID else {
            return
        }
        pendingActivityUpdates[descriptor.id] = (descriptor: descriptor, turnID: turnID)

        guard activityUpdateFlushTask == nil else {
            return
        }

        activityUpdateFlushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            self?.flushPendingActivityUpdates(turnID: turnID)
        }
    }

    private func flushPendingActivityUpdates(turnID: UUID) {
        guard activeTurnID == turnID else {
            return
        }

        activityUpdateFlushTask?.cancel()
        activityUpdateFlushTask = nil

        guard !pendingActivityUpdates.isEmpty else {
            return
        }

        let updates = pendingActivityUpdates.values
        pendingActivityUpdates.removeAll(keepingCapacity: false)

        var didChange = false
        for item in updates {
            if applyActivityUpdate(item.descriptor, turnID: item.turnID) {
                didChange = true
            }
        }

        if didChange {
            noteActivityChange()
        }
    }

    @discardableResult
    private func applyActivityUpdate(_ descriptor: ProviderActivityDescriptor, turnID: UUID) -> Bool {
        guard
            let groupIndex = state.activityGroups.indices.reversed().first(where: {
                state.activityGroups[$0].activities.contains { $0.id == descriptor.id }
            }),
            let activityIndex = state.activityGroups[groupIndex].activities.firstIndex(
                where: { $0.id == descriptor.id }
            )
        else {
            return false
        }

        var activity = state.activityGroups[groupIndex].activities[activityIndex]
        if let title = descriptor.title {
            activity.title = title
        }
        if let detail = descriptor.detail {
            activity.detail = detail
        }
        if let output = descriptor.output {
            activity.output = Self.boundedForMemory(output)
        }
        if let diff = descriptor.diff {
            activity.diff = Self.boundedForMemory(diff)
        }
        guard activity != state.activityGroups[groupIndex].activities[activityIndex] else {
            return false
        }
        state.activityGroups[groupIndex].activities[activityIndex] = activity
        return true
    }

    /// Bitmiş bir etkinliğin türü, bitiş sonrası ne yapılacağına karar vermek
    /// için gruplardan bulunur (örn. görev listesi yalnız `todo` bitince okunur).
    private func activityKind(for activityID: ProviderActivityID) -> ProviderActivityKind? {
        for group in state.activityGroups.reversed() {
            if let activity = group.activities.first(where: { $0.id == activityID }) {
                return activity.kind
            }
        }
        return nil
    }

    private func finishActivity(
        _ activityID: ProviderActivityID,
        outcome: ProviderActivityOutcome,
        output: String?,
        diff: String?,
        turnID: UUID
    ) {
        guard
            let groupIndex = state.activityGroups.indices.reversed().first(where: {
                state.activityGroups[$0].activities.contains { $0.id == activityID }
            }),
            let activityIndex = state.activityGroups[groupIndex].activities.firstIndex(
                where: { $0.id == activityID }
            )
        else {
            return
        }

        var activity = state.activityGroups[groupIndex].activities[activityIndex]
        activity.phase =
            switch outcome {
            case .completed:
                .completed
            case .failed:
                .failed
            }

        // A tool's result only exists on its terminal update, so this is where
        // the output panel and the change preview get their content.
        if let output, !output.isEmpty {
            activity.output = Self.boundedForMemory(output)
        }
        if let diff, !diff.isEmpty {
            activity.diff = Self.boundedForMemory(diff)
        }

        activity.completedAt = Date()
        state.activityGroups[groupIndex].activities[activityIndex] = activity
        noteActivityChange()
    }

    /// A finished activity must not overwrite a newer session status such as
    /// `.waiting`: only a running-tool status is replaced with a fresh tool name
    /// or plain streaming once no activity of that turn is still running.
    private func restoreStatusAfterActivity(turnID: UUID) {
        guard case .runningTool = state.status else {
            return
        }

        var stillRunning: AgentActivity?
        for group in state.activityGroups.reversed() {
            if let running = group.activities.last(where: { $0.phase == .running }) {
                stillRunning = running
                break
            }
        }

        guard let stillRunning else {
            state.status = .streaming
            return
        }

        state.status = .runningTool(
            AgentActivityPresentation(kind: stillRunning.kind).runningStatusName
        )
    }

    private func finishRunningActivities(
        turnID: UUID,
        phase: AgentActivityPhase
    ) {
        let finishedAt = Date()
        for groupIndex in state.activityGroups.indices {
            let group = state.activityGroups[groupIndex]
            guard group.id == turnID || group.turnID == turnID else {
                continue
            }
            for activityIndex in state.activityGroups[groupIndex].activities.indices {
                if state.activityGroups[groupIndex].activities[activityIndex].phase == .running {
                    state.activityGroups[groupIndex].activities[activityIndex].phase = phase
                    state.activityGroups[groupIndex].activities[activityIndex].completedAt = finishedAt
                }
            }
        }
        noteActivityChange()
    }

    private func normalizeConfigurationState() {
        if var configuration = state.configuration,
            let provider = providers.first(where: { $0.id == configuration.providerID }),
            provider.model(id: configuration.modelID) != nil
        {
            if !provider.supports(
                variantID: configuration.variantID,
                for: configuration.modelID
            ) {
                configuration.variantID = nil
                state.configuration = configuration
            }
            return
        }

        // Hangi sağlayıcı ve modelin varsayılan olacağı bir ürün tercihidir;
        // oturum çekirdeği yalnızca sonucu uygular.
        let previousProviderID = state.configuration?.providerID
        let previousModelID = state.configuration?.modelID
        state.configuration = ProviderSelectionPolicy.defaultConfiguration(from: providers)
        if state.configuration?.providerID != previousProviderID {
            invalidateTodoReads()
            state.todos = []
        }
        if state.configuration?.modelID != previousModelID {
            lastTurnUsage = nil
        }
    }

    private func invalidateTodoReads() {
        todoRefreshGeneration &+= 1
    }

    private func runtime(for providerID: ProviderID) -> (any ProviderRuntime)? {
        runtimes.first { $0.id == providerID }
    }

    static func sessionError(for error: ProviderRuntimeError) -> AgentSessionError {
        switch error {
        case .missingCredential:
            .missingCredential
        case .executableUnavailable:
            .backendExecutableUnavailable
        case .startupFailure:
            .backendStartupFailure
        case .authenticationFailure:
            .authenticationFailure
        case .unavailable:
            .providerUnavailable
        case .rateLimited:
            .rateLimited
        case .contextLimitExceeded:
            .contextLimitExceeded
        case .transport:
            .transportFailure
        case .unexpectedResponse:
            .unexpectedBackendResponse
        case .unsupported:
            .unexpectedBackendResponse
        }
    }
}
