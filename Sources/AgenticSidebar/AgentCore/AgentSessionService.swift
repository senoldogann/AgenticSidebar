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

    /// Streaming flushes are frequent, so writes are coalesced behind this delay
    /// while structure changes (create/select/delete) save immediately.
    private static let saveDebounce = Duration.seconds(2)

    private(set) var providers: [ProviderCapabilities] = []
    private(set) var sessions: [AgentSession] = []
    private(set) var activeSessionID: UUID

    init(
        runtimes: [any ProviderRuntime],
        state: AgentSessionState = AgentSessionState(),
        archiveStore: SessionArchiveStore? = nil
    ) {
        self.runtimes = runtimes
        self.archiveStore = archiveStore

        let restored: [AgentSession]
        let restoredActiveID: UUID

        if
            let archive = archiveStore?.load(),
            !archive.sessions.isEmpty
        {
            let snapshots = archive.sessions.sorted { $0.createdAt > $1.createdAt }
            restored = snapshots.map { AgentSession(runtimes: runtimes, snapshot: $0) }
            restoredActiveID = restored.first { $0.id == archive.activeSessionID }?.id
                ?? restored[0].id
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
    }

    // MARK: - Active session

    /// The session the views are bound to. The list always holds at least one
    /// session, so this never has to fall back to an optional.
    var activeSession: AgentSession {
        sessions.first { $0.id == activeSessionID } ?? sessions[0]
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

    var sessionList: [SessionSummary] {
        sessions.map { session in
            SessionSummary(
                id: session.id,
                title: session.title,
                isBusy: session.isBusy,
                status: session.state.status,
                completedAt: session.state.completedAt,
                lastMessageAt: session.state.messages.last?.createdAt
            )
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
        saveImmediately()
        return session.id
    }

    func selectSession(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }), activeSessionID != id else {
            return
        }

        activeSessionID = id
        saveImmediately()
    }

    /// Removes a conversation and stops whatever it was doing. The last session
    /// is never removed: a fresh empty one replaces it.
    func deleteSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            return
        }

        let session = sessions.remove(at: index)
        let runtimes = self.runtimes
        Task {
            await session.cancel()
            // Sunucu tarafındaki oturum da kapatılır; aksi halde her silinen
            // sohbet backend'de ölü bir oturum bırakır.
            for runtime in runtimes {
                await runtime.releaseSession(id)
            }
        }

        guard !sessions.isEmpty else {
            let replacement = AgentSession(runtimes: runtimes)
            adopt(replacement)
            replacement.applyCapabilities(providers, normalizeConfiguration: !providers.isEmpty)
            sessions = [replacement]
            activeSessionID = replacement.id
            saveImmediately()
            return
        }

        if activeSessionID == id {
            activeSessionID = sessions[min(index, sessions.count - 1)].id
        }

        saveImmediately()
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

    func removeQueuedPrompt(_ id: UUID) {
        activeSession.removeQueuedPrompt(id)
    }

    func clearQueuedPrompts() {
        activeSession.clearQueuedPrompts()
    }

    func cancel() async {
        await activeSession.cancel()
    }

    // MARK: - Persistence

    private func adopt(_ session: AgentSession) {
        session.onPersistentChange = { [weak self] in
            self?.scheduleSave()
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

        saveTask = Task { [weak self] in
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
        Task { [weak self] in
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
    }

    /// Writes the archive immediately. Structure changes (create, select, delete)
    /// call this directly; transcript updates go through the debounce above.
    func saveNow() async {
        guard let archiveStore else {
            hasPendingSave = false
            return
        }

        hasPendingSave = false

        var snapshots = sessions
            .map { $0.snapshot() }
            .filter { !$0.messages.isEmpty }

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
            .unexpectedBackendResponse
        ]

        return priority.first { errors.contains($0) } ?? .providerUnavailable
    }
}
