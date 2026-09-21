import Foundation
import Observation

/// Immutable board card projection; carries no SQL, Git or concrete provider types.
struct TaskBoardCard: Sendable, Identifiable, Equatable {
    let id: UUID
    let projectID: UUID
    let title: String
    let objective: String
    let priority: Int
    let status: TaskStatus
    let stage: TaskStage
    let blockReason: TaskBlockReason?
    let previousStageBeforeBlock: TaskStage?
    let version: Int
    let currentAttemptID: UUID?
    let activeAttempt: TaskBoardAttemptSummary?
    let unmetPrerequisiteIDs: [UUID]
    let criteriaCompleted: Int
    let criteriaTotal: Int
    let updatedAt: Date
}

/// Immutable projection of one persisted attempt.
struct TaskBoardAttemptSummary: Sendable, Identifiable, Equatable {
    let id: UUID
    let attemptSequence: Int
    let generation: Int
    let role: AgentRole
    let providerID: String
    let modelID: String
    let outcome: AttemptOutcome
    let startedAt: Date
    let endedAt: Date?
    let durationSeconds: Int?
    let toolCallCount: Int?
}

/// Immutable detail projection for the selected task.
struct TaskBoardTaskDetail: Sendable, Equatable {
    let card: TaskBoardCard
    let criteria: [CodingAcceptanceCriterion]
    let dependencies: [TaskDependency]
    let attempts: [TaskBoardAttemptSummary]
}

/// Actions a board surface can request through the store.
enum TaskBoardAction: String, Sendable, CaseIterable, Equatable {
    case start
    case pause
    case resume
    case stop
    case retry
    case requestChanges
    case accept
}

/// Availability of one action, including why an unavailable action is disabled.
struct TaskBoardActionAvailability: Sendable, Equatable {
    let action: TaskBoardAction
    let isEnabled: Bool
    let disabledReason: String?
}

/// Typed refusal shown for a rejected board action.
struct TaskBoardRefusal: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case stale
        case unavailable
        case deferred
        case blocked
        case busy
        case rejected
    }

    let kind: Kind
    let message: String
}

/// Result of one board action; success is only reported after the backend confirms it.
enum TaskBoardActionResult: Sendable, Equatable {
    case applied
    case refused(TaskBoardRefusal)
}

/// Refusal remembered per task so a disabled action can explain itself until reality changes.
struct TaskBoardActionRefusal: Sendable, Equatable {
    let action: TaskBoardAction
    let kind: TaskBoardRefusal.Kind
    let message: String
    let taskVersion: Int
}

/// Main-actor projection over `CodingTaskService`.
///
/// The store owns no chat or session state, never executes work on appearance, and only reads
/// through the service: `selectProject`/`selectTask` change selection without cancelling any
/// in-flight action, `refresh` coalesces bursts into at most one follow-up load, and every
/// action reports an explicit result instead of optimistically mutating a card.
@MainActor
@Observable
final class TaskBoardStore {
    /// Board load state; a failed reload keeps the last known cards and an explicit message.
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private let service: CodingTaskService
    private var boardSnapshot: CodingBoardSnapshot?
    private var selectedTaskAttempts: [TaskBoardAttemptSummary] = []
    private var needsReload = false
    private var isRefreshing = false
    /// Sürü hâlindeyken dizilen bekleyenler: anahtarlı harita tutulur ki iptal
    /// edilen bekleyen `onCancel` yolunda tekil düşürülebilsin; değersiz dizi
    /// iptalde asılı continuation bırakırdı (`BoundedChannel` deseni).
    private var refreshWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var refusals: [UUID: TaskBoardActionRefusal] = [:]

    private(set) var phase: Phase = .idle
    private(set) var cards: [TaskBoardCard] = []
    private(set) var detail: TaskBoardTaskDetail?
    private(set) var projects: [CodingProject] = []
    private(set) var selectedProjectID: UUID?
    private(set) var selectedTaskID: UUID?
    private(set) var inFlightTaskIDs: Set<UUID> = []
    private(set) var lastFailure: String?
    /// Denetçi girdilerinin hangi göreve ait olduğu; seçim değişince sıfırlanır,
    /// böylece eski görevin kanıtı yeni seçimde asla görünmez.
    private(set) var selectedInspectorTaskID: UUID?
    private(set) var selectedTaskEvidence: [VerificationEvidence]?
    private(set) var selectedTaskFingerprint: String?
    private(set) var selectedTaskFindings: [ReviewFinding]?
    private(set) var selectedTaskWorkspaceID: UUID?
    /// Denetçi okuma uyarısı (`nil` = kayıp yok): "henüz koşmadı" ile
    /// "yükleme patladı" ayrımı burada taşınır, seçim değişince sıfırlanır.
    private(set) var selectedInspectorWarning: String?
    private(set) var isCreatingTask = false
    private(set) var isUpdatingTask = false
    private(set) var isDeletingTask = false
    private(set) var isAddingDependency = false
    private(set) var isCreatingProject = false
    private(set) var isRenamingProject = false
    private(set) var isDeletingProject = false

    /// Yeni proje kaydı tamamlandığında çağrılır; kompozisyon bu köprüyle
    /// süreç ömürlü proje kayıt defterini besler ve kaydı hemen uzlaştırır.
    /// Açılış uzlaştırması ve kapanış yalnızca kayıt defterindeki projeleri
    /// kapsar. `async`tir çünkü kayıt sonrası uzlaştırma turu, kayıt dönmeden
    /// önce tamamlanmalıdır; aksi hâlde `createProject` başarı döndürdüğünde
    /// proje henüz bilinmiyor olabilirdi.
    var onProjectRegistered: (@MainActor (UUID) async -> Void)?

    init(service: CodingTaskService) {
        self.service = service
    }

    // MARK: - Selection

    /// Selects a project. Selection never cancels an in-flight action and never touches chat state.
    func selectProject(_ projectID: UUID?) {
        guard selectedProjectID != projectID else { return }
        selectedProjectID = projectID
        selectedTaskID = nil
        detail = nil
        selectedTaskAttempts = []
        clearInspector()
        boardSnapshot = nil
        cards = []
        phase = .idle
    }

    /// Selects a task and loads its attempt history; an in-flight action keeps running.
    ///
    /// The previous selection's failure is cleared so an old detail-load error can never
    /// appear as if it belonged to the newly selected task.
    func selectTask(_ taskID: UUID?) async {
        guard selectedTaskID != taskID else { return }
        selectedTaskID = taskID
        detail = nil
        selectedTaskAttempts = []
        clearInspector()
        lastFailure = nil
        guard let taskID else { return }
        await loadDetail(taskID: taskID)
    }

    // MARK: - Loading

    /// Kayıtlı projeleri kalıcı depodan yükler; seçim yoksa ilk projeyi seçer.
    ///
    /// Yeniden başlatma sonrası pano boş görünmesin diye kompozisyon açılışta
    /// bu çağrıyı yapar; proje listesi süreç ömürlü değildir.
    func refreshProjects() async {
        let stored = await service.listProjects()
        projects = stored.sorted { $0.createdAt < $1.createdAt }
        if selectedProjectID == nil, let first = projects.first {
            selectProject(first.id)
            await refresh()
        } else if let selected = selectedProjectID, !projects.contains(where: { $0.id == selected }) {
            selectProject(nil)
        }
    }

    /// Canlı gönderim bu kompozisyonda bağlı mı; alt bant bu değere göre çizilir.
    func liveDispatchAvailable() async -> Bool {
        await service.isLiveDispatchAvailable
    }

    /// Reloads the board snapshot, coalescing a burst of requests into one follow-up load.
    func refresh() async {
        guard let projectID = selectedProjectID else {
            phase = .idle
            return
        }
        if isRefreshing {
            needsReload = true
            await waitForOngoingRefresh()
            return
        }
        isRefreshing = true
        defer { finishRefresh() }
        repeat {
            needsReload = false
            await loadSnapshot(projectID: projectID)
        } while needsReload
    }

    /// Koşan yenilemenin bitmesini bekler; beklerken iptal edilirse haritadan
    /// düşer ve `CancellationError` ile uyanır. İptal sessizce yutulur: koşan
    /// yenileme yine biter, çekilen bekleyen sıradaki tura katılmaz.
    private func waitForOngoingRefresh() async {
        let id = UUID()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    refreshWaiters[id] = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelRefreshWaiter(id: id)
                }
            }
        } catch {
            // İptal: kayıt `cancelRefreshWaiter` içinde düşürüldü.
        }
    }

    /// İptal edilen bekleyeni haritadan düşürüp uyandırır; `finishRefresh`
    /// önce davrandıysa kayıt yoktur ve ikinci uyandırma olmaz (çift
    /// `resume` tuzağa düşürürdü).
    private func cancelRefreshWaiter(id: UUID) {
        guard let waiter = refreshWaiters.removeValue(forKey: id) else {
            return
        }
        waiter.resume(throwing: CancellationError())
    }

    /// Ends one refresh pass and wakes every coalesced waiter; `defer`-owned so no future
    /// throwing or cancelled path can leak `isRefreshing` or a suspended waiter.
    private func finishRefresh() {
        isRefreshing = false
        let waiters = refreshWaiters
        refreshWaiters = [:]
        for waiter in waiters.values {
            waiter.resume(returning: ())
        }
    }

    private func loadSnapshot(projectID: UUID) async {
        if cards.isEmpty, phase != .loading {
            phase = .loading
        }
        do {
            let snapshot = try await service.snapshot(projectID: projectID)
            guard selectedProjectID == projectID else { return }
            boardSnapshot = snapshot
            cards = Self.makeCards(from: snapshot)
            phase = .loaded
            lastFailure = nil
            if let selectedTaskID {
                rebuildDetail(taskID: selectedTaskID)
            }
        } catch {
            guard selectedProjectID == projectID else { return }
            let message = Self.describe(error)
            phase = .failed(message)
            lastFailure = message
        }
    }

    private func loadDetail(taskID: UUID) async {
        do {
            let attempts = try await service.attemptHistory(taskID: taskID)
            guard selectedTaskID == taskID else { return }
            selectedTaskAttempts = attempts.map(Self.makeAttemptSummary)
            rebuildDetail(taskID: taskID)
        } catch {
            guard selectedTaskID == taskID else { return }
            lastFailure = Self.describe(error)
        }
        // Denetçi girdileri okuma yüzeyidir: yokluğu bölmeyi başarısız yapmaz,
        // yalnızca kanıt/bulgu alanları boş görünür.
        let inspector = await service.inspectorInputs(taskID: taskID)
        guard selectedTaskID == taskID else { return }
        selectedInspectorTaskID = taskID
        selectedTaskEvidence = inspector.evidence
        selectedTaskFingerprint = inspector.currentFingerprint
        selectedTaskFindings = inspector.findings
        selectedTaskWorkspaceID = inspector.workspaceID
        selectedInspectorWarning = inspector.warning
    }

    /// Seçim değişiminde denetçi durumunu sıfırlar.
    private func clearInspector() {
        selectedInspectorTaskID = nil
        selectedTaskEvidence = nil
        selectedTaskFingerprint = nil
        selectedTaskFindings = nil
        selectedTaskWorkspaceID = nil
        selectedInspectorWarning = nil
    }

    private func rebuildDetail(taskID: UUID) {
        guard let snapshot = boardSnapshot,
            let task = snapshot.tasks.first(where: { $0.id == taskID }),
            let card = cards.first(where: { $0.id == taskID })
        else {
            detail = nil
            return
        }
        detail = TaskBoardTaskDetail(
            card: card,
            criteria: task.criteria,
            dependencies: snapshot.dependencies
                .filter { $0.dependentTaskID == taskID || $0.prerequisiteTaskID == taskID }
                .sorted { $0.id < $1.id },
            attempts: selectedTaskAttempts
        )
    }

    // MARK: - Availability

    func isActionInFlight(for taskID: UUID) -> Bool {
        inFlightTaskIDs.contains(taskID)
    }

    /// Action availability for one task, with the refusal reason while the card is unchanged.
    func actionAvailability(for taskID: UUID) -> [TaskBoardActionAvailability] {
        guard let card = cards.first(where: { $0.id == taskID }) else { return [] }
        let refusal = refusals[taskID]
        return TaskBoardAction.allCases.map { action in
            if let refusal, refusal.action == action, refusal.taskVersion == card.version {
                return TaskBoardActionAvailability(action: action, isEnabled: false, disabledReason: refusal.message)
            }
            return Self.baseAvailability(for: action, card: card)
        }
    }

    // MARK: - Project registration

    /// Pano için proje kaydeder, kaydı seçer ve panoyu yükler.
    ///
    /// Kayıt servise devredilir; servisin doğrulama hataları (boş ad gibi)
    /// diğer eylemlerle aynı `TaskBoardRefusal` kanalıyla yüzeye çıkar.
    /// Klasör denetimi en iyi çabadır: var olmayan ya da Git işareti
    /// taşımayan bir klasör servise hiç gönderilmez; asıl depo sahipliği
    /// denetimi talep anındaki çalışma alanı ön kontrolüne aittir. Proje
    /// listesi bu sürümde süreç ömürlüdür (bkz. kompozisyon kayıt defteri).
    func createProject(name: String, repositoryURL: URL) async -> TaskBoardActionResult {
        guard !isCreatingProject else {
            return .refused(TaskBoardRefusal(kind: .busy, message: "Proje kaydı zaten sürüyor"))
        }
        isCreatingProject = true
        defer { isCreatingProject = false }

        if let message = Self.repositoryFolderValidationMessage(for: repositoryURL) {
            lastFailure = message
            return .refused(TaskBoardRefusal(kind: .rejected, message: message))
        }

        do {
            let project = try await service.createProject(
                name: name,
                repositoryPath: repositoryURL.path,
                gitIdentity: Self.defaultGitIdentity,
                protectedRefs: []
            )
            selectProject(project.id)
            lastFailure = nil
            await onProjectRegistered?(project.id)
            await refreshProjects()
            await refresh()
            return .applied
        } catch {
            let refusal = Self.refusal(from: error)
            lastFailure = refusal.message
            return .refused(refusal)
        }
    }

    // MARK: - Task creation

    func createTask(
        projectID: UUID,
        title: String,
        objective: String,
        priority: Int,
        criteria: [String]
    ) async -> TaskBoardActionResult {
        guard !isCreatingTask else {
            return .refused(TaskBoardRefusal(kind: .busy, message: "Görev oluşturma zaten sürüyor"))
        }
        isCreatingTask = true
        defer { isCreatingTask = false }
        do {
            _ = try await service.createTask(
                projectID: projectID,
                title: title,
                objective: objective,
                priority: priority,
                criteria: criteria
            )
            await refresh()
            return .applied
        } catch {
            let refusal = Self.refusal(from: error)
            lastFailure = refusal.message
            return .refused(refusal)
        }
    }

    // MARK: - Task metadata

    /// Başlık/amaç/öncelik üstverisini günceller; kart sürüm çitiyle korunur.
    func updateTask(
        taskID: UUID,
        title: String,
        objective: String,
        priority: Int
    ) async -> TaskBoardActionResult {
        guard !isUpdatingTask else {
            return .refused(TaskBoardRefusal(kind: .busy, message: "Görev güncelleme zaten sürüyor"))
        }
        guard let card = cards.first(where: { $0.id == taskID }) else {
            return .refused(TaskBoardRefusal(kind: .rejected, message: "This task is not loaded on the board"))
        }
        guard !inFlightTaskIDs.contains(taskID) else {
            return .refused(TaskBoardRefusal(kind: .busy, message: "Bu görev için zaten bir işlem sürüyor"))
        }
        isUpdatingTask = true
        defer { isUpdatingTask = false }
        do {
            _ = try await service.updateTaskDetails(
                taskID: taskID,
                expectedVersion: card.version,
                title: title,
                objective: objective,
                priority: priority
            )
            lastFailure = nil
            await refresh()
            return .applied
        } catch {
            let refusal = Self.refusal(from: error)
            lastFailure = refusal.message
            await refresh()
            return .refused(refusal)
        }
    }

    /// Görevi panodan siler; seçim silinen görevdeyse detay kapanır.
    func deleteTask(taskID: UUID) async -> TaskBoardActionResult {
        guard !isDeletingTask else {
            return .refused(TaskBoardRefusal(kind: .busy, message: "Görev silme zaten sürüyor"))
        }
        guard cards.contains(where: { $0.id == taskID }) else {
            return .refused(TaskBoardRefusal(kind: .rejected, message: "This task is not loaded on the board"))
        }
        guard !inFlightTaskIDs.contains(taskID) else {
            return .refused(TaskBoardRefusal(kind: .busy, message: "Bu görev için zaten bir işlem sürüyor"))
        }
        isDeletingTask = true
        defer { isDeletingTask = false }
        do {
            try await service.deleteTask(taskID: taskID)
            if selectedTaskID == taskID {
                selectedTaskID = nil
                detail = nil
                selectedTaskAttempts = []
                clearInspector()
                lastFailure = nil
            }
            lastFailure = nil
            await refresh()
            return .applied
        } catch {
            let refusal = Self.refusal(from: error)
            lastFailure = refusal.message
            await refresh()
            return .refused(refusal)
        }
    }

    // MARK: - Project rename and deletion

    /// Projenin görünen adını değiştirir ve proje listesini tazeler.
    func renameProject(id: UUID, name: String) async -> TaskBoardActionResult {
        guard !isRenamingProject else {
            return .refused(TaskBoardRefusal(kind: .busy, message: "Proje adı değiştirme zaten sürüyor"))
        }
        isRenamingProject = true
        defer { isRenamingProject = false }
        do {
            _ = try await service.renameProject(id: id, name: name)
            lastFailure = nil
            await refreshProjects()
            return .applied
        } catch {
            let refusal = Self.refusal(from: error)
            lastFailure = refusal.message
            return .refused(refusal)
        }
    }

    /// Projeyi ve görevlerini siler; silinen proje seçiliyse seçim düşer.
    func deleteProject(id: UUID) async -> TaskBoardActionResult {
        guard !isDeletingProject else {
            return .refused(TaskBoardRefusal(kind: .busy, message: "Proje silme zaten sürüyor"))
        }
        isDeletingProject = true
        defer { isDeletingProject = false }
        do {
            try await service.deleteProject(id: id)
            if selectedProjectID == id {
                selectedProjectID = nil
                selectedTaskID = nil
                detail = nil
                selectedTaskAttempts = []
                clearInspector()
                boardSnapshot = nil
                cards = []
                phase = .idle
            }
            lastFailure = nil
            await refreshProjects()
            await refresh()
            return .applied
        } catch {
            let refusal = Self.refusal(from: error)
            lastFailure = refusal.message
            await refresh()
            return .refused(refusal)
        }
    }

    func addDependency(
        projectID: UUID,
        prerequisiteTaskID: UUID,
        dependentTaskID: UUID
    ) async -> TaskBoardActionResult {
        guard !isAddingDependency else {
            return .refused(TaskBoardRefusal(kind: .busy, message: "Bağımlılık değişikliği zaten sürüyor"))
        }
        isAddingDependency = true
        defer { isAddingDependency = false }
        do {
            _ = try await service.addDependency(
                projectID: projectID,
                prerequisiteTaskID: prerequisiteTaskID,
                dependentTaskID: dependentTaskID
            )
            await refresh()
            return .applied
        } catch {
            let refusal = Self.refusal(from: error)
            lastFailure = refusal.message
            return .refused(refusal)
        }
    }

    // MARK: - Execution actions

    func start(taskID: UUID) async -> TaskBoardActionResult {
        await perform(.start, taskID: taskID) { card in
            do {
                switch try await self.service.start(taskID: taskID, expectedVersion: card.version) {
                case .claimed:
                    return .applied
                case .blocked(let reason):
                    return .refused(TaskBoardRefusal(kind: .blocked, message: reason.boardDescription))
                case .unavailable(let unavailability):
                    return .refused(TaskBoardRefusal(kind: .unavailable, message: unavailability.message))
                case .deferred(let reason):
                    return .refused(Self.deferredRefusal(reason: reason))
                }
            } catch {
                return .refused(Self.refusal(from: error))
            }
        }
    }

    /// Canlı koşuyu insan aktörüyle başlatır: talep, parmak izine bağlı
    /// `executeRecipe` onayı ve gönderim tek eylemde yürür.
    ///
    /// Aktör zorunludur; boş aktörle gönderim onaysız kalırdı. Pano yine
    /// iyimser davranmaz: yalnızca servis talebi doğruladıysa `.applied` döner.
    func startRun(taskID: UUID, actor: String) async -> TaskBoardActionResult {
        await perform(.start, taskID: taskID) { card in
            do {
                switch try await self.service.startRun(
                    taskID: taskID,
                    expectedVersion: card.version,
                    actor: actor
                ) {
                case .claimed:
                    return .applied
                case .blocked(let reason):
                    return .refused(TaskBoardRefusal(kind: .blocked, message: reason.boardDescription))
                case .unavailable(let unavailability):
                    return .refused(TaskBoardRefusal(kind: .unavailable, message: unavailability.message))
                case .deferred(let reason):
                    return .refused(Self.deferredRefusal(reason: reason))
                }
            } catch {
                return .refused(Self.refusal(from: error))
            }
        }
    }

    /// İnsan bir kabul ölçütünü tamamlandı ya da geri aldı olarak işaretler.
    ///
    /// Eylem çubuğunun dışında ayrı bir yüzeydir; yine de panonun ortak
    /// sonuç/refusal sözleşmesini kullanır ve sonrasında panoyu tazeler.
    func setCriterionCompletion(
        taskID: UUID,
        criterionID: UUID,
        isCompleted: Bool
    ) async -> TaskBoardActionResult {
        guard !inFlightTaskIDs.contains(taskID) else {
            let refusal = TaskBoardRefusal(kind: .busy, message: "Another action is already in flight for this task")
            return .refused(refusal)
        }
        guard let card = cards.first(where: { $0.id == taskID }) else {
            return .refused(TaskBoardRefusal(kind: .rejected, message: "This task is not loaded on the board"))
        }
        inFlightTaskIDs.insert(taskID)
        defer { inFlightTaskIDs.remove(taskID) }

        do {
            _ = try await service.setCriterionCompletion(
                taskID: taskID,
                criterionID: criterionID,
                isCompleted: isCompleted,
                expectedVersion: card.version
            )
            lastFailure = nil
            await refresh()
            return .applied
        } catch {
            let refusal = Self.refusal(from: error)
            lastFailure = refusal.message
            await refresh()
            return .refused(refusal)
        }
    }

    func pause(taskID: UUID) async -> TaskBoardActionResult {
        await perform(.pause, taskID: taskID) { card in
            guard let attemptID = card.activeAttempt?.id else {
                return .refused(TaskBoardRefusal(kind: .rejected, message: "There is no active attempt to pause"))
            }
            do {
                try await self.service.pause(taskID: taskID, expectedAttemptID: attemptID)
                return .applied
            } catch {
                return .refused(Self.refusal(from: error))
            }
        }
    }

    func resume(taskID: UUID) async -> TaskBoardActionResult {
        await perform(.resume, taskID: taskID) { card in
            do {
                let entry = try await self.service.resume(
                    taskID: taskID,
                    expectedVersion: card.version,
                    expectedAttemptID: card.activeAttempt?.id
                )
                return Self.result(for: entry)
            } catch {
                return .refused(Self.refusal(from: error))
            }
        }
    }

    func stop(taskID: UUID) async -> TaskBoardActionResult {
        await perform(.stop, taskID: taskID) { card in
            do {
                try await self.service.stop(
                    taskID: taskID,
                    expectedVersion: card.version,
                    expectedAttemptID: card.currentAttemptID
                )
                return .applied
            } catch {
                return .refused(Self.refusal(from: error))
            }
        }
    }

    func retry(taskID: UUID) async -> TaskBoardActionResult {
        await perform(.retry, taskID: taskID) { card in
            do {
                let entry = try await self.service.retry(
                    taskID: taskID,
                    expectedActiveAttemptID: card.activeAttempt?.id,
                    expectedActiveGeneration: card.activeAttempt?.generation
                )
                return Self.result(for: entry)
            } catch {
                return .refused(Self.refusal(from: error))
            }
        }
    }

    // MARK: - Review actions

    func requestChanges(taskID: UUID, actor: String, feedback: String) async -> TaskBoardActionResult {
        await perform(.requestChanges, taskID: taskID) { card in
            do {
                _ = try await self.service.requestChanges(
                    taskID: taskID,
                    expectedVersion: card.version,
                    actor: actor,
                    feedback: feedback
                )
                return .applied
            } catch {
                return .refused(Self.refusal(from: error))
            }
        }
    }

    func accept(taskID: UUID, actor: String) async -> TaskBoardActionResult {
        await perform(.accept, taskID: taskID) { card in
            do {
                _ = try await self.service.accept(taskID: taskID, expectedVersion: card.version, actor: actor)
                return .applied
            } catch {
                return .refused(Self.refusal(from: error))
            }
        }
    }

    // MARK: - Action plumbing

    private func perform(
        _ action: TaskBoardAction,
        taskID: UUID,
        operation: (TaskBoardCard) async -> TaskBoardActionResult
    ) async -> TaskBoardActionResult {
        guard let card = cards.first(where: { $0.id == taskID }) else {
            return .refused(TaskBoardRefusal(kind: .rejected, message: "This task is not loaded on the board"))
        }
        guard !inFlightTaskIDs.contains(taskID) else {
            return .refused(TaskBoardRefusal(kind: .busy, message: "Another action is already in flight for this task"))
        }
        inFlightTaskIDs.insert(taskID)
        defer { inFlightTaskIDs.remove(taskID) }

        let result = await operation(card)
        switch result {
        case .applied:
            refusals[taskID] = nil
        case .refused(let refusal):
            refusals[taskID] = TaskBoardActionRefusal(
                action: action,
                kind: refusal.kind,
                message: refusal.message,
                taskVersion: card.version
            )
        }
        await refresh()
        return result
    }

    private static func result(for entry: TaskScheduleEntry) -> TaskBoardActionResult {
        switch entry.disposition {
        case .claimed:
            return .applied
        case .blocked(let reason):
            return .refused(TaskBoardRefusal(kind: .blocked, message: reason.boardDescription))
        case .deferred(let reason):
            return .refused(Self.deferredRefusal(reason: reason))
        }
    }

    /// Ertelenen gönderim reddini, ham nedeni koruyarak eyleme dönüştürür.
    ///
    /// Ham `reason` metni mesajda aynen tutulur (testler ve loglar ona göre
    /// eşleşir); bilinen çalışma alanı ve doğrulama engellerine yalnızca
    /// Türkçe çözüm cümlesi eklenir. Kirli kaynak, Git-olmayan klasör, kapsam
    /// dışı yol ve çözülemeyen proje en sık görülen "pano çalışmıyor"
    /// nedenleridir. Korumalı dal kapısı kaldırıldı: çalışma alanı taban
    /// committe ayrık kurulduğu için temiz `main`/`master` checkout artık
    /// engel değildir.
    private static func deferredRefusal(reason: String) -> TaskBoardRefusal {
        var message = "Gönderilmedi: \(reason)"
        if reason.contains("WORKTREE_DIRTY") {
            message += ". Kaynak depoda commitlenmemiş değişiklik var — önce commit/stash yapıp tekrar Başlat'a basın"
        } else if reason.contains("WORKTREE_NOT_A_REPOSITORY") {
            message += ". Seçili klasör bir Git deposu değil — proje kaydında depo kökünü seçin"
        } else if reason.contains("WORKTREE_SCOPE_VIOLATION") {
            message += ". Yol yetkili kapsam dışında — proje kökünü ve pano çalışma dizinini doğrulayın"
        } else if reason.contains("VERIFICATION_UNRECOGNIZED_PROJECT") {
            message += ". Bu pano sürümü yalnız SwiftPM projelerini doğrular — `Package.swift` içeren bir depo seçin ya da görevi SwiftPM köküne taşıyın; ajan koşusu başlamadan reddedildi"
        } else if reason.contains("WORKTREE_PROJECT_UNKNOWN") || reason.contains("is unknown") {
            message += ". Proje bu süreçte tanınmıyor — panoyu yenileyip projeyi yeniden seçin"
        } else if reason.contains("providerUnavailable") {
            message += ". Sohbette yazma yetenekli bir sağlayıcı/model seçili değil"
        }
        return TaskBoardRefusal(kind: .deferred, message: message)
    }

    private static func baseAvailability(
        for action: TaskBoardAction,
        card: TaskBoardCard
    ) -> TaskBoardActionAvailability {
        switch action {
        case .start:
            guard card.status == .backlog || card.status == .ready else {
                return disabled(action, "Başlat yalnız birikmiş ya da hazır görevlerde çalışır (şu an: \(card.status.rawValue))")
            }
            guard card.activeAttempt == nil else {
                return disabled(action, "Bu görevde zaten aktif bir deneme var")
            }
            return enabled(action)
        case .pause:
            guard card.status == .running, card.activeAttempt != nil else {
                return disabled(action, "Duraklatma için koşan bir görev ve aktif bir deneme gerekir")
            }
            return enabled(action)
        case .resume:
            guard card.status == .blocked, isSuspended(card.blockReason) else {
                return disabled(action, "Sürdürme yalnız duraklatılmış ya da durdurulmuş görevlerde çalışır")
            }
            return enabled(action)
        case .stop:
            guard card.status == .running else {
                return disabled(action, "Durdurma yalnız koşan görevlerde çalışır")
            }
            return enabled(action)
        case .retry:
            guard card.status == .blocked else {
                return disabled(action, "Tekrar yalnız takılmış görevlerde çalışır; hazır iş için Başlat'ı kullanın")
            }
            return enabled(action)
        case .requestChanges:
            guard card.status == .review else {
                return disabled(action, "Değişiklik isteme yalnız görev incelemedeyken çalışır")
            }
            return enabled(action)
        case .accept:
            guard card.status == .review else {
                return disabled(action, "Kabul yalnız görev incelemedeyken çalışır")
            }
            return enabled(action)
        }
    }

    private static func enabled(_ action: TaskBoardAction) -> TaskBoardActionAvailability {
        TaskBoardActionAvailability(action: action, isEnabled: true, disabledReason: nil)
    }

    private static func disabled(_ action: TaskBoardAction, _ reason: String) -> TaskBoardActionAvailability {
        TaskBoardActionAvailability(action: action, isEnabled: false, disabledReason: reason)
    }

    private static func isSuspended(_ reason: TaskBlockReason?) -> Bool {
        TaskScheduler.isUserSuspension(reason)
    }

    // MARK: - Projections

    private static func makeCards(from snapshot: CodingBoardSnapshot) -> [TaskBoardCard] {
        let statusByTaskID = Dictionary(
            snapshot.tasks.map { ($0.id, $0.status) },
            uniquingKeysWith: { first, _ in first }
        )
        let activeByTaskID = Dictionary(
            snapshot.activeAttempts.map { ($0.taskID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let prerequisitesByTaskID = Dictionary(grouping: snapshot.dependencies, by: \.dependentTaskID)
        let ordered = snapshot.tasks.sorted { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority > rhs.priority
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return ordered.map { task in
            let prerequisites = (prerequisitesByTaskID[task.id] ?? []).map(\.prerequisiteTaskID)
            let unmet = prerequisites.filter { statusByTaskID[$0] != .done }.sorted { $0.uuidString < $1.uuidString }
            return TaskBoardCard(
                id: task.id,
                projectID: task.projectID,
                title: task.title,
                objective: task.objective,
                priority: task.priority,
                status: task.status,
                stage: task.stage,
                blockReason: task.blockReason,
                previousStageBeforeBlock: task.previousStageBeforeBlock,
                version: task.version,
                currentAttemptID: task.currentAttemptID,
                activeAttempt: activeByTaskID[task.id].map(makeAttemptSummary),
                unmetPrerequisiteIDs: unmet,
                criteriaCompleted: task.criteria.filter(\.isCompleted).count,
                criteriaTotal: task.criteria.count,
                updatedAt: task.updatedAt
            )
        }
    }

    private static func makeAttemptSummary(_ attempt: TaskAttempt) -> TaskBoardAttemptSummary {
        TaskBoardAttemptSummary(
            id: attempt.id,
            attemptSequence: attempt.attemptSequence,
            generation: attempt.generation,
            role: attempt.role,
            providerID: attempt.providerID,
            modelID: attempt.modelID,
            outcome: attempt.outcome,
            startedAt: attempt.startedAt,
            endedAt: attempt.endedAt,
            durationSeconds: attempt.durationSeconds,
            toolCallCount: attempt.toolCallCount
        )
    }

    // MARK: - Project validation

    /// Klasör denetimi en iyi çabadır ve servis çağrısından önce koşar:
    /// var olmayan bir klasör, `.git` girdisi taşımayan bir klasör ya da
    /// `Package.swift` barındırmayan bir klasör için kayıt reddedilir.
    /// Çalışma kopyalarında (worktree) `.git` bir dosya da olabileceğinden
    /// yalnızca varlığına bakılır; gerçek depo sahipliği denetimi talep
    /// anındaki çalışma alanı ön kontrolüne aittir. `Package.swift` kapısı
    /// kayıt anında fail-fast verir: çözülemeyen depo daha Başlat'a
    /// basılmadan, Türkçe gerekçeyle reddedilir.
    private static func repositoryFolderValidationMessage(for repositoryURL: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repositoryURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return "Seçilen klasör bulunamadı: \(repositoryURL.path)"
        }
        let gitMarker = repositoryURL.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitMarker.path) else {
            return "Seçilen klasör bir Git deposu değil: \(repositoryURL.path)"
        }
        let packageMarker = repositoryURL.appendingPathComponent("Package.swift", isDirectory: false)
        guard FileManager.default.fileExists(atPath: packageMarker.path) else {
            return "Seçilen klasörde Package.swift yok — bu pano sürümü yalnız SwiftPM projelerini doğrular: \(repositoryURL.path)"
        }
        return nil
    }

    /// Form Git kimliği sormaz; süreç kullanıcısından türetilen sabit bir
    /// kimlik yeterlidir çünkü bu sürümde kimlik yalnızca proje kaydında
    /// taşınır ve hiçbir Git yazımında kullanılmaz.
    private static var defaultGitIdentity: String {
        let userName = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return userName.isEmpty ? "agentic-sidebar" : "\(userName)@agentic-sidebar"
    }

    // MARK: - Error mapping

    private static func describe(_ error: Error) -> String {
        if let serviceError = error as? CodingTaskServiceError {
            return serviceError.localizedDescription
        }
        return String(describing: error)
    }

    static func refusal(from error: Error) -> TaskBoardRefusal {
        guard let serviceError = error as? CodingTaskServiceError else {
            return TaskBoardRefusal(kind: .rejected, message: "Beklenmeyen hata: \(error)")
        }
        switch serviceError {
        case .staleVersion(_, let expected, let actual):
            return TaskBoardRefusal(
                kind: .stale,
                message: "Bu görev pano yüklendikten sonra değişti (görünen sürüm \(expected), güncel \(actual))"
            )
        case .staleAttempt:
            return TaskBoardRefusal(kind: .stale, message: "Aktif deneme pano yüklendikten sonra değişti")
        case .actionAlreadyInFlight:
            return TaskBoardRefusal(kind: .busy, message: "Bu görev için zaten bir işlem sürüyor")
        case .acceptanceDenied(_, let reasons):
            return TaskBoardRefusal(
                kind: .blocked,
                message: reasons.map(\.boardDescription).joined(separator: "; ")
            )
        case .budgetExhausted(_, let reason):
            return TaskBoardRefusal(kind: .blocked, message: reason)
        case .acceptanceInputUnavailable(_, let reason):
            return TaskBoardRefusal(kind: .unavailable, message: "Kabul girdileri yok: \(reason)")
        case .liveDispatchUnavailable:
            return TaskBoardRefusal(kind: .unavailable, message: "Bu kompozisyonda canlı gönderim bağlı değil")
        case .executionFingerprintUnavailable(_, let reason):
            return TaskBoardRefusal(
                kind: .unavailable,
                message: "Güncel çalışma alanı parmak izi olmadan başlatılamaz: \(reason)"
            )
        case .criterionNotFound(_, let criterionID):
            return TaskBoardRefusal(kind: .rejected, message: "Kabul ölçütü bulunamadı: \(criterionID.uuidString)")
        case .actionNotAvailable(_, let status):
            return TaskBoardRefusal(kind: .rejected, message: "Bu işlem görev \(status.rawValue) durumundayken çalışmaz")
        case .noActiveAttempt:
            return TaskBoardRefusal(kind: .rejected, message: "Bu görevde aktif deneme yok")
        case .transitionRejected(let transitionError):
            return TaskBoardRefusal(kind: .rejected, message: String(describing: transitionError))
        case .projectNotFound, .taskNotFound, .invalidProjectInput, .invalidTaskInput, .dependencyRejected,
            .persistence, .schedulerRejected, .unexpected:
            return TaskBoardRefusal(kind: .rejected, message: serviceError.localizedDescription)
        }
    }
}

extension TaskBlockReason {
    /// Short human-readable text for an action refusal or card subtitle.
    var boardDescription: String {
        switch self {
        case .prerequisitesNotSatisfied:
            return "önkoşullar tamamlanmadı"
        case .unsupportedCapability(let capability):
            return "desteklenmeyen yetenek: \(capability)"
        case .rateLimited:
            return "çalıştırıcı hız sınırına takıldı"
        case .approvalRequired:
            return "onay gerekiyor"
        case .verificationFailed(let details):
            return "doğrulama başarısız: \(details)"
        case .uncertainExecution(let details):
            return "koşu belirsiz: \(details)"
        case .custom(let reason):
            return reason
        }
    }
}

extension AcceptanceBlockReason {
    /// Short human-readable denial reason for the board.
    var boardDescription: String {
        switch self {
        case .taskNotInReview(let status):
            return "görev \(status.rawValue) durumunda, incelemede değil"
        case .attemptNotCurrent:
            return "incelenen deneme artık güncel değil"
        case .attemptTaskMismatch:
            return "incelenen deneme başka bir göreve ait"
        case .currentFingerprintUnavailable:
            return "güncel içerik parmak izi yok"
        case .noAcceptanceCriteria:
            return "görevde kabul ölçütü yok"
        case .unmetCriteria(let ids):
            return "\(ids.count) kabul ölçütü karşılanmadı"
        case .missingRequiredStep(let name):
            return "gerekli adımın kanıtı yok: \(name)"
        case .requiredStepNotPassed(let name, let status):
            return "gerekli adım geçemedi: \(name) (\(status.rawValue))"
        case .optionalStepFailed(let name):
            return "isteğe bağlı adım başarısız: \(name)"
        case .requiredStepUnknownRecipeVersion(let name, _):
            return "gerekli adımın tarif sürümü bilinmiyor: \(name)"
        case .requiredStepFingerprintMissing(let name):
            return "gerekli adımın çalışma alanı parmak izi yok: \(name)"
        case .requiredStepFingerprintMismatch(let name, _, _):
            return "gerekli adım başka bir revizyonda koşmuş: \(name)"
        case .openBlockingFindings(let ids):
            return "\(ids.count) açık engelleyici bulgu var"
        case .acceptanceApprovalAttemptMismatch:
            return "onay başka bir denemeye bağlı"
        case .acceptanceApprovalFingerprintMismatch:
            return "onay başka bir içeriğe bağlı"
        case .acceptanceApprovalMissingActor:
            return "onayda insan aktör kaydı yok"
        }
    }
}
