import Foundation
import Observation

/// A list of conversations plus provider capability discovery.
///
/// Each conversation is an `AgentSession` with its own turn task, so a
/// background session keeps streaming while the user reads or types in another
/// one. The most-used members below forward to the active session, which keeps
/// the chat, composer and menu bar views unchanged.
@MainActor
@Observable
final class AgentSessionService {
    @ObservationIgnored
    private let runtimes: [any ProviderRuntime]

    @ObservationIgnored
    private let archiveStore: SessionArchiveStore?

    @ObservationIgnored
    private var saveTask: Task<Void, Never>?

    @ObservationIgnored
    private var hasPendingSave = false

    /// Silinen oturumların uzak temizlik işleri. Kapanış yarışında kaybolmaması
    /// için `flushPendingSave()` bunları bekler; normal akışta kendiliğinden biter.
    @ObservationIgnored
    private var pendingCleanupTasks: [Task<Void, Never>] = []

    /// Streaming flushes are frequent, so writes are coalesced behind this delay
    /// while structure changes (create/select/delete) save immediately.
    private static let saveDebounce = Duration.seconds(2)

    private(set) var providers: [ProviderCapabilities] = []
    private(set) var sessions: [AgentSession] = []
    private(set) var activeSessionID: UUID

    /// Hook for notifications or observers when any session finishes a turn.
    var onSessionTurnCompleted:
        (@MainActor (_ sessionID: UUID, _ sessionTitle: String, _ status: AgentSessionStatus, _ previewText: String?) -> Void)?
    /// Tur sınırları: izin seviyesi tur başında anlık görüntülenir. Uygulama
    /// bu kancalarla merkeze turun kuralını verir; koşan tur eski kuralla
    /// devam eder, değişim sonraki turda geçerli olur.
    var onSessionTurnStarted: (@MainActor (_ sessionID: UUID, _ turnID: UUID) -> Void)?
    var onSessionTurnEnded: (@MainActor (_ sessionID: UUID, _ turnID: UUID) -> Void)?

    init(
        runtimes: [any ProviderRuntime],
        state: AgentSessionState = AgentSessionState(),
        archiveStore: SessionArchiveStore? = nil
    ) {
        self.runtimes = runtimes
        self.archiveStore = archiveStore

        let restored: [AgentSession]
        let restoredActiveID: UUID

        if let archive = archiveStore?.load(),
            !archive.sessions.isEmpty
        {
            // Sabitliler önce, sonra oluşturulma yeniden eskiye.
            let snapshots = archive.sessions.sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned {
                    return lhs.isPinned && !rhs.isPinned
                }
                return lhs.createdAt > rhs.createdAt
            }
            let mapped = snapshots.map { AgentSession(runtimes: runtimes, snapshot: $0) }
            if mapped.isEmpty {
                // `map` boş üretemez (girdi boş değil), ama savunma tuzağa
                // düşürmez: taze oturum yoluna düşülür.
                let session = AgentSession(runtimes: runtimes, state: state)
                restored = [session]
                restoredActiveID = session.id
            } else {
                restored = mapped
                restoredActiveID =
                    mapped.first { $0.id == archive.activeSessionID }?.id
                    ?? mapped[0].id
            }
        } else {
            let session = AgentSession(runtimes: runtimes, state: state)
            restored = [session]
            restoredActiveID = session.id
        }

        sessions = restored
        activeSessionID = restoredActiveID

        for session in restored {
            adopt(session)
        }
        refreshSessionList()
    }

    // MARK: - Active session

    /// The session the views are bound to. The list always holds at least one
    /// session, so this never has to fall back to an optional.
    var activeSession: AgentSession {
        if let match = sessions.first(where: { $0.id == activeSessionID }) {
            return match
        }
        if let first = sessions.first {
            return first
        }
        // Değişmez ihlali (boş liste): tuzağa düşmek yerine taze oturum
        // açılır. Silme yolları zaten bunu garanti eder; bu dal yalnız
        // gelecekteki bir kaymaya karşı son savunmadır.
        AppLog.agentSession.error("Session list was empty; opening a fresh session")
        let session = AgentSession(runtimes: runtimes, state: AgentSessionState())
        adopt(session)
        sessions = [session]
        activeSessionID = session.id
        refreshSessionList()
        return session
    }

    /// Kimliğe göre oturum: yan yana görünümün ikincil bölmesi aktif olmayan
    /// oturumu doğrudan buradan çözer, görünüm `activeSessionID` değiştirmez.
    func session(for id: UUID) -> AgentSession? {
        sessions.first { $0.id == id }
    }

    /// Yan soru (`/btw`) anlık görüntüsü: soru anındaki runtime,
    /// yapılandırma ve geçmiş. Turn makinesine, kuyruğa ve transkripte
    /// dokunulmaz; meşgul oturumdan da alınabilir.
    func sideQuestionContext(for id: UUID) -> SideQuestionContext? {
        guard
            let session = session(for: id),
            let configuration = session.configuration,
            let runtime = runtimes.first(where: { $0.id == configuration.providerID })
        else {
            return nil
        }
        return SideQuestionContext(
            runtime: runtime,
            configuration: configuration,
            messages: session.state.messages,
            activityGroups: session.state.activityGroups,
            contextSummary: session.contextSummary
        )
    }

    var state: AgentSessionState {
        activeSession.state
    }

    var isBusy: Bool {
        activeSession.isBusy
    }

    var canSubmit: Bool {
        activeSession.canSubmit
    }

    /// Aktif oturum şu anda bir mesaj alabilir mi (hemen başlatarak ya da
    /// kuyruğa ekleyerek).
    var canAcceptPrompt: Bool {
        activeSession.canAcceptPrompt
    }

    var availableModels: [ProviderModelCapability] {
        activeSession.availableModels
    }

    var availableVariants: [ProviderVariant] {
        activeSession.availableVariants
    }

    var activeSessionTitle: String {
        activeSession.title
    }

    var activeTurnID: UUID? {
        activeSession.activeTurnID
    }

    /// Prompts waiting behind the active session's running turn, oldest first.
    var queuedPrompts: [QueuedPrompt] {
        activeSession.queuedPrompts
    }

    private(set) var sessionList: [SessionSummary] = []

    func refreshSessionList() {
        let newList = sessions.map { session in
            SessionSummary(
                id: session.id,
                title: session.title,
                isBusy: session.isBusy,
                status: session.status,
                completedAt: session.state.completedAt,
                lastMessageAt: session.state.messages.last?.createdAt,
                createdAt: session.createdAt,
                customTitle: session.customTitle,
                isPinned: session.isPinned
            )
        }
        if sessionList != newList {
            sessionList = newList
        }
    }

    func updateVisibleSessions(_ visibleIDs: Set<UUID>) {
        for session in sessions {
            let isVisible = visibleIDs.contains(session.id)
            if session.isVisibleInUI != isVisible {
                session.isVisibleInUI = isVisible
            }
        }
    }

    // MARK: - Session management

    @discardableResult
    func createSession() -> UUID {
        let session = AgentSession(
            runtimes: runtimes,
            state: AgentSessionState(configuration: activeSession.state.configuration)
        )
        adopt(session)
        // Normalizing with no known capabilities yet would throw away the
        // configuration the new session just inherited.
        session.applyCapabilities(providers, normalizeConfiguration: !providers.isEmpty)
        sessions.insert(session, at: 0)
        activeSessionID = session.id
        refreshSessionList()
        saveImmediately()
        return session.id
    }

    func selectSession(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }), activeSessionID != id else {
            return
        }

        activeSessionID = id
        saveImmediately()
        // The checklist lives with the backend's session, not with the archive, so
        // it is re-read when a conversation is opened rather than restored.
        activeSession.refreshTodos()
    }

    /// The agent's task list for the conversation on screen.
    var todos: [AgentTodo] {
        activeSession.state.todos
    }

    /// Removes a conversation and stops whatever it was doing. The last session
    /// is never removed: a fresh empty one replaces it.
    func deleteSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            return
        }

        let session = sessions.remove(at: index)
        let runtimes = self.runtimes
        let cleanup = Task {
            await session.cancel()
            // Sunucu tarafındaki oturum da kapatılır; aksi halde her silinen
            // sohbet backend'de ölü bir oturum bırakır.
            for runtime in runtimes {
                await runtime.releaseSession(id)
            }
        }
        pendingCleanupTasks.append(cleanup)

        guard !sessions.isEmpty else {
            let replacement = AgentSession(runtimes: runtimes)
            adopt(replacement)
            replacement.applyCapabilities(providers, normalizeConfiguration: !providers.isEmpty)
            sessions = [replacement]
            activeSessionID = replacement.id
            refreshSessionList()
            saveImmediately()
            return
        }

        if activeSessionID == id {
            activeSessionID = sessions[min(index, sessions.count - 1)].id
        }

        refreshSessionList()
        saveImmediately()
    }

    /// Kullanıcı başlığını günceller; boş başlık otomatiğe döndürür.
    func renameSession(_ id: UUID, to newTitle: String) {
        guard let session = sessions.first(where: { $0.id == id }) else {
            return
        }
        session.rename(to: newTitle)
        saveImmediately()
    }

    /// Sabitleme durumunu ayarlar.
    func setSessionPinned(_ id: UUID, pinned: Bool) {
        guard let session = sessions.first(where: { $0.id == id }) else {
            return
        }
        session.setPinned(pinned)
        saveImmediately()
    }

    /// Sabitleme durumunu tersine çevirir.
    func toggleSessionPin(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else {
            return
        }
        session.togglePin()
        saveImmediately()
    }

    /// Birden fazla sohbeti tek onay ile siler. Meşgul oturumlar durdurulur,
    /// backend oturumları kapatılır; son oturum silinemez, yerine boş gelir.
    func deleteSessions(_ ids: Set<UUID>) {
        guard !ids.isEmpty else {
            return
        }

        let targets = sessions.filter { ids.contains($0.id) }
        guard !targets.isEmpty else {
            return
        }

        let runtimes = self.runtimes
        let removedIDs = Set(targets.map(\.id))
        let removedActive = removedIDs.contains(activeSessionID)
        // Seçim sıralı KİMLİK listesinden türetilir. Eskiden aktifin eski indeksi
        // silme sonrası diziye uygulanıyordu; aktiften daha yeni bir sohbet de
        // silindiğinde indeks kayıyor ve "aktiften sonraki ilk kalan" seçimi
        // tesadüfe kalıyordu (bir sonraki yerine daha yaşlısı seçilebiliyordu).
        let orderedIDs = sessions.map(\.id)
        let activeOldIndex = orderedIDs.firstIndex(of: activeSessionID)

        sessions.removeAll { removedIDs.contains($0.id) }

        for session in targets {
            let cleanup = Task {
                await session.cancel()
                for runtime in runtimes {
                    await runtime.releaseSession(session.id)
                }
            }
            pendingCleanupTasks.append(cleanup)
        }

        guard !sessions.isEmpty else {
            let replacement = AgentSession(runtimes: runtimes)
            adopt(replacement)
            replacement.applyCapabilities(providers, normalizeConfiguration: !providers.isEmpty)
            sessions = [replacement]
            activeSessionID = replacement.id
            refreshSessionList()
            saveImmediately()
            return
        }

        if removedActive {
            let survivors = Set(sessions.map(\.id))
            // Silinen aktiften sonraki ilk kalan; aktif sondaydıysa sondaki
            // kalan. Bir sohbet her zaman seçili olmalı.
            let nextAfter = activeOldIndex.flatMap { index in
                orderedIDs.dropFirst(index + 1).first { survivors.contains($0) }
            }
            activeSessionID = nextAfter ?? sessions[sessions.count - 1].id
        }

        refreshSessionList()
        saveImmediately()
    }

    /// Mesaj dizisindeki bir dönüm noktasından yeni bir dal oturumu açar.
    ///
    /// Kaynak oturuma dokunulmaz; ön ek yeni bir `AgentSession` olarak başa
    /// eklenir. Kaynak aktif oturumsa dal aktif yapılır, yoksa aktiflik
    /// korunur. Backend tarafında istekli (lazy) çalışır:
    /// burada sunucuya `POST` yapılmaz, ilk gönderimde runtime ön eki history
    /// preamble olarak tekrar oynatır. Meşgul bir kaynaktan da dallanılabilir,
    /// çünkü yalnızca bitmiş `state` kopyalanır, çalışan turun görevi değil.
    ///
    /// - Returns: Dönüm noktası bulunamazsa `nil`.
    @discardableResult
    func forkSession(id: UUID, throughMessageID: UUID) -> UUID? {
        guard let source = sessions.first(where: { $0.id == id }) else {
            return nil
        }
        guard
            let fork = SessionFork.plan(
                sourceMessages: source.state.messages,
                sourceActivityGroups: source.state.activityGroups,
                sourceAutomaticTitle: source.automaticTitle,
                sourceCustomTitle: source.customTitle,
                throughMessageID: throughMessageID,
                isSourceBusy: source.isBusy
            )
        else {
            source.state.notice = .forkUnavailable
            return nil
        }
        var forkedState = AgentSessionState(
            configuration: source.state.configuration,
            messages: fork.messages,
            status: .idle
        )
        forkedState.activityGroups = fork.activityGroups
        let branch = AgentSession(
            runtimes: runtimes,
            state: forkedState,
            customTitle: fork.title
        )
        adopt(branch)
        branch.applyCapabilities(providers, normalizeConfiguration: !providers.isEmpty)
        sessions.insert(branch, at: 0)
        // Odağı yalnız kaynaktan dallanıldıysa taşı: ikincil bölmedeki ya da
        // arşivdeki bir sohbetten dallanma aktif sohbeti çalmamalıdır.
        if activeSessionID == id {
            activeSessionID = branch.id
        }
        refreshSessionList()
        saveImmediately()
        return branch.id
    }

    // MARK: - Configuration

    func selectProvider(_ providerID: ProviderID) throws {
        try activeSession.selectProvider(providerID)
    }

    func selectModel(_ modelID: ProviderModelID) throws {
        try activeSession.selectModel(modelID)
    }

    func selectVariant(_ variantID: ProviderVariantID?) throws {
        try activeSession.selectVariant(variantID)
    }

    func refreshCapabilities() async {
        var loadedProviders: [ProviderCapabilities] = []
        var capabilityErrors: [AgentSessionError] = []

        for runtime in runtimes {
            do {
                let capabilities = try await runtime.capabilities()
                guard capabilities.id == runtime.id else {
                    continue
                }
                loadedProviders.append(capabilities)
            } catch let error as ProviderRuntimeError {
                capabilityErrors.append(AgentSession.sessionError(for: error))
            } catch {
                capabilityErrors.append(.providerUnavailable)
                continue
            }
        }

        providers = loadedProviders

        // Every session keeps a usable configuration, but only idle ones are
        // re-normalized: a running turn already captured its configuration.
        for session in sessions {
            session.applyCapabilities(
                loadedProviders,
                normalizeConfiguration: !session.isBusy
            )
        }

        if !capabilityErrors.isEmpty {
            AppLog.agentSession.error(
                "Capability discovery failed for \(capabilityErrors.count, privacy: .public) of \(self.runtimes.count, privacy: .public) providers"
            )
        }

        let active = activeSession
        guard !active.isBusy else {
            return
        }

        if runtimes.isEmpty {
            active.clearConfiguration()
            return
        }

        guard !loadedProviders.isEmpty else {
            active.failCapabilityDiscovery(
                with: Self.preferredCapabilityError(from: capabilityErrors)
            )
            return
        }

        active.markIdle()
    }

    // MARK: - Turns

    @discardableResult
    func submit(_ prompt: String) -> Task<Void, Never>? {
        activeSession.submit(prompt)
    }

    @discardableResult
    func submit(
        _ prompt: String,
        attachmentPaths: [String]
    ) -> Task<Void, Never>? {
        activeSession.submit(prompt, attachmentPaths: attachmentPaths)
    }

    @discardableResult
    func submit(
        _ prompt: String,
        attachmentPaths: [String],
        speedMode: ResponseSpeedMode
    ) -> Task<Void, Never>? {
        activeSession.submit(
            prompt,
            attachmentPaths: attachmentPaths,
            speedMode: speedMode
        )
    }

    /// Starts the turn or queues the prompt behind the one that is running.
    @discardableResult
    func send(
        _ prompt: String,
        attachmentPaths: [String] = [],
        speedMode: ResponseSpeedMode = .normal,
        mode: AgentMode = .build,
        tags: [ExtensionTag] = []
    ) -> PromptAcceptance {
        activeSession.send(
            prompt,
            attachmentPaths: attachmentPaths,
            speedMode: speedMode,
            mode: mode,
            tags: tags
        )
    }

    @discardableResult
    func send(
        _ prompt: String,
        speedMode: ResponseSpeedMode,
        mode: AgentMode
    ) -> PromptAcceptance {
        send(
            prompt,
            attachmentPaths: [],
            speedMode: speedMode,
            mode: mode,
            tags: []
        )
    }

    func removeQueuedPrompt(_ id: UUID) {
        activeSession.removeQueuedPrompt(id)
    }

    func sendQueuedPromptImmediately(_ id: UUID) {
        activeSession.sendQueuedPromptImmediately(id)
    }

    @discardableResult
    func updateQueuedPrompt(_ id: UUID, text: String) -> Bool {
        activeSession.updateQueuedPrompt(id, text: text)
    }

    @discardableResult
    func moveQueuedPrompt(_ id: UUID, to destinationIndex: Int) -> Bool {
        activeSession.moveQueuedPrompt(id, to: destinationIndex)
    }

    func clearQueuedPrompts() {
        activeSession.clearQueuedPrompts()
    }

    func drainQueuedPrompts() {
        activeSession.drainQueueIfPossible()
    }

    func cancel() async {
        await activeSession.cancel()
    }

    // MARK: - Interactive Questions

    func answerActiveQuestion(_ answer: AgentQuestionAnswer) {
        activeSession.answerActiveQuestion(answer)
    }

    func dismissActiveQuestion() {
        activeSession.dismissActiveQuestion()
    }

    // MARK: - Persistence

    private func adopt(_ session: AgentSession) {
        session.onPersistentChange = { [weak self] in
            self?.scheduleSave()
        }
        session.onImmediatePersistentChange = { [weak self] in
            self?.saveImmediately()
        }
        session.onSummaryChange = { [weak self] in
            self?.refreshSessionList()
        }
        session.onTurnFinished = { [weak self] sessionID, sessionTitle, status, snippet in
            self?.refreshSessionList()
            self?.onSessionTurnCompleted?(sessionID, sessionTitle, status, snippet)
        }
        session.onTurnStarted = { [weak self] sessionID, turnID in
            self?.refreshSessionList()
            self?.onSessionTurnStarted?(sessionID, turnID)
        }
        session.onTurnEnded = { [weak self] sessionID, turnID in
            self?.refreshSessionList()
            self?.onSessionTurnEnded?(sessionID, turnID)
        }
    }

    private func scheduleSave() {
        guard archiveStore != nil else {
            return
        }

        hasPendingSave = true
        guard saveTask == nil else {
            return
        }

        saveTask = Task { @MainActor [weak self] in
            while let self, self.hasPendingSave {
                try? await Task.sleep(for: Self.saveDebounce)
                guard !Task.isCancelled else {
                    break
                }
                self.hasPendingSave = false
                await self.saveNow()
            }

            // İptal edilmiş bir görev, yerine kurulmuş olabilecek yeni görevin
            // izini silmemeli; aksi halde iki debounce döngüsü aynı anda çalışır.
            if !Task.isCancelled {
                self?.saveTask = nil
            }
        }
    }

    /// Yapısal değişiklikler beklemeden yazılır; çağıran ana iş parçacığını
    /// tutmaz çünkü kodlama ve disk yazımı arşiv aktöründe çalışır.
    private func saveImmediately() {
        Task { @MainActor [weak self] in
            await self?.saveNow()
        }
    }

    /// Bekleyen debounce'u boşaltır.
    ///
    /// Kapanışta çağrılmazsa son iki saniyedeki değişiklikler — pratikte biten
    /// turun nihai hâli — hiç yazılmaz.
    func flushPendingSave() async {
        saveTask?.cancel()
        saveTask = nil
        await saveNow()
        // Silme sonrası hemen kapanılırsa uzak oturumlar arkada kalmasın diye
        // bekleyen temizlik işleri burada tüketilir.
        let cleanups = pendingCleanupTasks
        pendingCleanupTasks = []
        for cleanup in cleanups {
            await cleanup.value
        }
    }

    /// Writes the archive immediately. Structure changes (create, select, delete)
    /// call this directly; transcript updates go through the debounce above.
    func saveNow() async {
        guard let archiveStore else {
            hasPendingSave = false
            return
        }

        hasPendingSave = false

        var snapshots =
            sessions
            .map { $0.snapshot() }
            .filter { snapshot in
                // A blank selected conversation still owns the current provider/model.
                if snapshot.id == activeSessionID {
                    return true
                }
                // Boş ama sabitli ya da başlıklı oturum kaybolmamalı; yoksa
                // kullanıcı sabitlediği boş taslağı relaunch'ta kaybeder.
                if !snapshot.messages.isEmpty {
                    return true
                }
                if snapshot.isPinned {
                    return true
                }
                if let customTitle = snapshot.customTitle {
                    return !customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                return false
            }

        // An empty active session still has to be restored, otherwise a relaunch
        // would lose the selected provider and model.
        if snapshots.isEmpty {
            snapshots = [activeSession.snapshot()]
        }

        await archiveStore.save(
            SessionArchive(
                version: SessionArchive.currentVersion,
                activeSessionID: activeSessionID,
                sessions: snapshots
            )
        )
    }

    /// Capability discovery can fail for several providers at once. Surface the
    /// most actionable cause instead of a generic unavailability message, so a
    /// missing credential is never hidden behind an unrelated provider outage.
    private static func preferredCapabilityError(
        from errors: [AgentSessionError]
    ) -> AgentSessionError {
        let priority: [AgentSessionError] = [
            .missingCredential,
            .authenticationFailure,
            .backendExecutableUnavailable,
            .backendStartupFailure,
            .providerUnavailable,
            .rateLimited,
            .contextLimitExceeded,
            .transportFailure,
            .unsupportedCapability,
            .streamInterrupted,
            .unexpectedBackendResponse,
        ]

        return priority.first { errors.contains($0) } ?? .providerUnavailable
    }
}
