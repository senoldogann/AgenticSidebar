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

    @ObservationIgnored
    private var activeTask: Task<Void, Never>?

    @ObservationIgnored
    private var activeStream: ProviderStream?

    private(set) var activeTurnID: UUID?

    @ObservationIgnored
    private var activeAssistantMessageID: UUID?

    @ObservationIgnored
    private var streamingTextAccumulator = StreamingTextAccumulator.empty

    @ObservationIgnored
    private var streamingTextFlushTask: Task<Void, Never>?

    /// Called after every transcript/status change so the owner can debounce a
    /// persistence write. Streaming flushes fire often, hence the debounce.
    @ObservationIgnored
    var onPersistentChange: (@MainActor () -> Void)?

    @ObservationIgnored
    private let budget: TranscriptBudget

    private static let streamingTextUpdateInterval = Duration.milliseconds(40)

    /// Bellekte tutulan aktivite sayısı, arşivdekiyle aynı sınıra budanır.
    /// Budanmazsa uzun bir sohbette bütün tur geçmişi RAM'de birikir.
    private static let maximumInMemoryActivities = SessionArchiveStore.maximumActivitiesPerSession

    /// Bellekte bir aktivite için saklanan en fazla karakter.
    ///
    /// Arşiv sınırından yüksek tutulur — kullanıcı açtığı kartta hâlâ anlamlı
    /// bir çıktı görür — ama bir dosyanın tamamının süresiz durmasını engeller.
    private static let maximumInMemoryOutputLength = 64_000

    /// Kuyrukta bekleyebilecek en fazla mesaj.
    ///
    /// Sınırsız bir kuyruk, uzun süre yanıtlanmayan bir turun arkasında hem
    /// belleği hem de kullanıcının ne göndereceği üzerindeki kontrolünü
    /// kaybettiriyordu.
    static let maximumQueuedPrompts = 20

    private(set) var providers: [ProviderCapabilities] = []

    /// Prompts that arrived while a turn was running, oldest first.
    ///
    /// The transcript only shows a message once its turn starts, so a queued
    /// prompt is held here (and surfaced next to the composer) rather than being
    /// written to the conversation ahead of the turn that will answer it.
    private(set) var queuedPrompts: [QueuedPrompt] = []

    /// The session state, directly tracked through the Observation framework.
    var state: AgentSessionState {
        didSet {
            onPersistentChange?()
        }
    }

    /// Kullanıcının verdiği başlık; `nil` ise otomatik başlık gösterilir.
    /// `state` dışında tutulduğu için değişimde kalıcılık elle tetiklenir.
    var customTitle: String? {
        didSet {
            onPersistentChange?()
        }
    }

    /// Sabitli oturumlar listede üstte durur, arşiv budamada en son düşer.
    var isPinned: Bool {
        didSet {
            onPersistentChange?()
        }
    }

    init(
        runtimes: [any ProviderRuntime],
        state: AgentSessionState = AgentSessionState(),
        budget: TranscriptBudget = TranscriptBudget(),
        customTitle: String? = nil,
        isPinned: Bool = false
    ) {
        self.runtimes = runtimes
        self.state = state
        self.id = state.id
        self.createdAt = Date()
        self.budget = budget
        self.customTitle = customTitle
        self.isPinned = isPinned
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
        self.state = AgentSessionState(
            id: snapshot.id,
            configuration: snapshot.configuration,
            messages: snapshot.messages,
            status: .idle
        )
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
            isPinned: isPinned
        )
    }

    /// İlk kullanıcı mesajından türetilen otomatik başlık.
    var automaticTitle: String {
        guard let firstUserMessage = state.messages.first(where: { $0.role == .user }) else {
            return "New session"
        }

        let firstLine = firstUserMessage.text
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

    /// Kullanıcı başlığını günceller; boş ya da yalnızca boşluk ise `nil` olur.
    /// Başlık en fazla 120 karakter saklanır, fazlası kırpılır.
    func rename(to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            customTitle = nil
            return
        }
        customTitle = String(trimmed.prefix(120))
    }

    /// Sabitleme durumunu ayarlar.
    func setPinned(_ pinned: Bool) {
        isPinned = pinned
    }

    /// Sabitleme durumunu tersine çevirir.
    func togglePin() {
        isPinned.toggle()
    }

    var isBusy: Bool {
        switch state.status {
        case .streaming, .runningTool, .waiting, .cancelling:
            true
        case .idle, .completed, .cancelled, .failed:
            false
        }
    }

    var canSubmit: Bool {
        guard let configuration = state.configuration else {
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
            let configuration = state.configuration,
            runtime(for: configuration.providerID) != nil
        else {
            return false
        }

        return queuedPrompts.count < Self.maximumQueuedPrompts
    }

    var availableModels: [ProviderModelCapability] {
        guard
            let configuration = state.configuration,
            let provider = providers.first(where: { $0.id == configuration.providerID })
        else {
            return []
        }

        return provider.models
    }

    var availableVariants: [ProviderVariant] {
        guard
            let configuration = state.configuration,
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
        state.status = .idle
        state.error = nil
    }

    func failCapabilityDiscovery(with error: AgentSessionError) {
        state.configuration = nil
        state.status = .failed
        state.error = error
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
        state.error = nil
    }

    func selectModel(_ modelID: ProviderModelID) throws {
        guard !isBusy else {
            return
        }

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
    }

    func selectVariant(_ variantID: ProviderVariantID?) throws {
        guard !isBusy else {
            return
        }

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

        if canSubmit {
            return startTurn(for: queuedPrompt) == nil ? .rejected : .started
        }

        // A session with no usable configuration could never run the prompt
        // later, so only a genuinely busy session accepts a queued message.
        guard
            isBusy,
            let configuration = state.configuration,
            runtime(for: configuration.providerID) != nil
        else {
            return .rejected
        }

        guard queuedPrompts.count < Self.maximumQueuedPrompts else {
            AppLog.agentSession.error(
                "The prompt queue already holds \(Self.maximumQueuedPrompts, privacy: .public) messages; the new one was refused"
            )
            return .rejected
        }

        queuedPrompts.append(queuedPrompt)
        return .queued
    }

    func removeQueuedPrompt(_ id: UUID) {
        queuedPrompts.removeAll { $0.id == id }
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
        return clamped != sourceIndex
    }

    func clearQueuedPrompts() {
        queuedPrompts.removeAll()
    }

    /// Sends the oldest queued prompt, if the session is free again.
    private func startNextQueuedTurn() {
        guard activeTurnID == nil, !isBusy, !queuedPrompts.isEmpty else {
            return
        }

        let next = queuedPrompts.removeFirst()
        if startTurn(for: next) == nil {
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

        let userMessage = ChatMessage(
            role: .user,
            text: queuedPrompt.text,
            attachmentPaths: queuedPrompt.attachmentPaths,
            extensionTags: queuedPrompt.extensionTags
        )
        state.messages.append(userMessage)
        state.status = .streaming
        state.error = nil
        state.startedAt = Date()
        state.completedAt = nil
        // Yeni tur önceki turun listesiyle açılmıyordu: ajan kendi listesini
        // yazana kadar besteci paneli eski maddeleri gösteriyordu.
        state.todos = []
        discardPendingAssistantText()
        activeAssistantMessageID = nil

        let turnID = UUID()
        state.activityGroups.append(
            AgentTurnActivityGroup(
                id: turnID,
                anchorMessageID: userMessage.id,
                activities: [
                    AgentActivity(
                        id: thinkingActivityID(turnID: turnID),
                        kind: .thinking,
                        phase: .running
                    )
                ]
            )
        )

        let selection = budget.select(from: state.messages)
        state.notice = selection.droppedMessageCount > 0
            ? .transcriptTrimmed(droppedMessageCount: selection.droppedMessageCount)
            : nil

        let request = ProviderRequest(
            sessionID: id,
            configuration: configuration,
            messages: selection.messages,
            speedMode: queuedPrompt.speedMode,
            mode: queuedPrompt.mode,
            extensionContext: queuedPrompt.extensionTags.turnInstruction
        )
        activeTurnID = turnID

        let task = Task { [weak self] in
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
        guard let task = activeTask else {
            return
        }

        let cancelledTurnID = activeTurnID
        state.status = .cancelling
        state.error = nil
        task.cancel()

        if let activeStream {
            await activeStream.cancel()
        }

        await task.value

        // A queued prompt may already have taken the session over while the
        // cancelled turn was unwinding; that turn's state must survive here.
        guard activeTurnID == cancelledTurnID else {
            return
        }

        if state.status == .cancelling {
            state.status = .cancelled
            state.completedAt = Date()
        }

        activeTask = nil
        activeStream = nil
        activeTurnID = nil
        startNextQueuedTurn()
    }

    private func consume(
        runtime: any ProviderRuntime,
        request: ProviderRequest,
        turnID: UUID
    ) async {
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
                return
            }

            activeStream = stream
            var didComplete = false

            for try await event in stream.events {
                try Task.checkCancellation()

                guard activeTurnID == turnID else {
                    return
                }

                switch event {
                case let .assistantTextDelta(delta):
                    finishThinkingActivity(turnID: turnID)
                    enqueueAssistantText(delta, turnID: turnID)

                case let .activityStarted(activity):
                    flushPendingAssistantText(turnID: turnID)
                    finishThinkingActivity(turnID: turnID)
                    startActivity(activity, turnID: turnID)

                    // A task-list tool is the moment the agent's plan changes, so
                    // the checklist is re-read as it happens: the point of showing
                    // it is to see the work move, not to read it afterwards.
                    if activity.kind == .todo {
                        refreshTodos()
                    }

                case let .activityFinished(activityID, outcome, output, diff):
                    flushPendingAssistantText(turnID: turnID)
                    finishActivity(
                        activityID,
                        outcome: outcome,
                        output: output,
                        diff: diff,
                        turnID: turnID
                    )
                    restoreStatusAfterActivity(turnID: turnID)

                case .waiting:
                    flushPendingAssistantText(turnID: turnID)
                    state.status = .waiting

                case .completed:
                    flushPendingAssistantText(turnID: turnID)
                    finishRunningActivities(
                        turnID: turnID,
                        phase: .completed
                    )
                    didComplete = true
                }

                if didComplete {
                    break
                }
            }

            if Task.isCancelled {
                throw CancellationError()
            }

            guard activeTurnID == turnID else {
                return
            }

            flushPendingAssistantText(turnID: turnID)

            if didComplete {
                state.status = .completed
                state.completedAt = Date()
            } else {
                finishRunningActivities(turnID: turnID, phase: .failed)
                state.status = .failed
                state.error = .streamInterrupted
                state.completedAt = Date()
            }
        } catch is CancellationError {
            guard activeTurnID == turnID else {
                return
            }

            flushPendingAssistantText(turnID: turnID)
            finishRunningActivities(turnID: turnID, phase: .cancelled)
            state.status = .cancelled
            state.completedAt = Date()
        } catch let error as ProviderRuntimeError {
            guard activeTurnID == turnID else {
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
                return
            }

            flushPendingAssistantText(turnID: turnID)
            finishRunningActivities(turnID: turnID, phase: .failed)
            state.status = .failed
            state.error = .transportFailure
            state.completedAt = Date()
        }

        if activeTurnID == turnID {
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
            startNextQueuedTurn()
        }
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

        let sessionID = state.id
        Task { [weak self] in
            guard let todos = await runtime.sessionTodos(sessionID: sessionID) else {
                return
            }

            self?.applyTodos(todos, sessionID: sessionID)
        }
    }

    private func applyTodos(_ todos: [AgentTodo], sessionID: UUID) {
        // A slow answer for a session the user has already left must not land in
        // whichever session is on screen now.
        guard state.id == sessionID else {
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

        streamingTextFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.streamingTextUpdateInterval)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            self?.flushPendingAssistantText(turnID: turnID)
        }
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

        if
            let activeAssistantMessageID,
            let index = messageIndex(id: activeAssistantMessageID)
        {
            state.messages[index].text += text
        } else {
            let message = ChatMessage(role: .assistant, text: text)
            activeAssistantMessageID = message.id
            state.messages.append(message)
        }
        state.status = .streaming
    }

    private func discardPendingAssistantText() {
        streamingTextFlushTask?.cancel()
        streamingTextFlushTask = nil
        streamingTextAccumulator = .empty
    }

    /// Aktif turun grubu listenin sonundadır; her aktivite olayında bütün
    /// geçmişi taramak yerine önce oraya bakılır.
    private func activityGroupIndex(turnID: UUID) -> Int? {
        if
            let last = state.activityGroups.indices.last,
            state.activityGroups[last].id == turnID
        {
            return last
        }

        return state.activityGroups.firstIndex { $0.id == turnID }
    }

    /// Akış hedefi olan asistan mesajı transkriptin sonundadır; 40 ms'de bir
    /// bütün transkripti taramaya gerek yok.
    private func messageIndex(id: UUID) -> Int? {
        if
            let last = state.messages.indices.last,
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

    private func thinkingActivityID(turnID: UUID) -> ProviderActivityID {
        ProviderActivityID("turn-\(turnID.uuidString)-thinking")
    }

    private func finishThinkingActivity(turnID: UUID) {
        guard let groupIndex = activityGroupIndex(turnID: turnID) else {
            return
        }

        guard let activityIndex = state.activityGroups[groupIndex].activities.firstIndex(
            where: { $0.kind == .thinking && $0.phase == .running }
        ) else {
            return
        }

        state.activityGroups[groupIndex].activities[activityIndex].phase = .completed
        state.activityGroups[groupIndex].activities[activityIndex].completedAt = Date()
    }

    private func startActivity(
        _ descriptor: ProviderActivityDescriptor,
        turnID: UUID
    ) {
        guard let groupIndex = activityGroupIndex(turnID: turnID) else {
            return
        }

        if let activityIndex = state.activityGroups[groupIndex].activities.firstIndex(
            where: { $0.id == descriptor.id }
        ) {
            state.activityGroups[groupIndex].activities[activityIndex].phase = .running
            if let output = descriptor.output {
                state.activityGroups[groupIndex].activities[activityIndex].output =
                    Self.boundedForMemory(output)
            }
            if let diff = descriptor.diff {
                state.activityGroups[groupIndex].activities[activityIndex].diff =
                    Self.boundedForMemory(diff)
            }
        } else {
            state.activityGroups[groupIndex].activities.append(
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
        }

        state.status = .runningTool(
            AgentActivityPresentation(kind: descriptor.kind).runningStatusName
        )
    }

    private func finishActivity(
        _ activityID: ProviderActivityID,
        outcome: ProviderActivityOutcome,
        output: String?,
        diff: String?,
        turnID: UUID
    ) {
        guard
            let groupIndex = activityGroupIndex(turnID: turnID),
            let activityIndex = state.activityGroups[groupIndex].activities.firstIndex(
                where: { $0.id == activityID }
            )
        else {
            return
        }

        var activity = state.activityGroups[groupIndex].activities[activityIndex]
        activity.phase = switch outcome {
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
    }

    /// A finished activity must not overwrite a newer session status such as
    /// `.waiting`: only a running-tool status is replaced with a fresh tool name
    /// or plain streaming once no activity of that turn is still running.
    private func restoreStatusAfterActivity(turnID: UUID) {
        guard case .runningTool = state.status else {
            return
        }

        let stillRunning = activityGroupIndex(turnID: turnID).flatMap { groupIndex in
            state.activityGroups[groupIndex].activities.last { $0.phase == .running }
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
        guard let groupIndex = activityGroupIndex(turnID: turnID) else {
            return
        }

        let activities = state.activityGroups[groupIndex].activities
        let finishedAt = Date()
        state.activityGroups[groupIndex].activities = activities.map { activity in
            guard activity.phase == .running else {
                return activity
            }

            return activity.finishing(with: phase, at: finishedAt)
        }
    }

    private func normalizeConfigurationState() {
        if
            var configuration = state.configuration,
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
        state.configuration = ProviderSelectionPolicy.defaultConfiguration(from: providers)
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
        }
    }
}
