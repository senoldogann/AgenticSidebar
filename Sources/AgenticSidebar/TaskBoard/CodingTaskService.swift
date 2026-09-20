import Foundation

/// Typed failures raised by the app-facing task service.
///
/// The board UI never sees a raw repository, scheduler or provider error: every mutation
/// either returns a value or one of these cases, and a rejected backend call can never be
/// mistaken for success.
enum CodingTaskServiceError: LocalizedError, Equatable, Sendable {
    case projectNotFound(UUID)
    case taskNotFound(UUID)
    case invalidProjectInput(field: String, reason: String)
    case invalidTaskInput(field: String, reason: String)
    case staleVersion(taskID: UUID, expected: Int, actual: Int)
    case staleAttempt(taskID: UUID, expectedAttemptID: UUID?, actualAttemptID: UUID?)
    case actionAlreadyInFlight(taskID: UUID)
    case actionNotAvailable(taskID: UUID, status: TaskStatus)
    case noActiveAttempt(taskID: UUID)
    case budgetExhausted(taskID: UUID, reason: String)
    case acceptanceDenied(taskID: UUID, reasons: [AcceptanceBlockReason])
    case acceptanceInputUnavailable(taskID: UUID, reason: String)
    case liveDispatchUnavailable(taskID: UUID)
    case executionFingerprintUnavailable(taskID: UUID, reason: String)
    case criterionNotFound(taskID: UUID, criterionID: UUID)
    case dependencyRejected(projectID: UUID, reason: String)
    case transitionRejected(TaskTransitionError)
    case persistence(TaskRepositoryError)
    case schedulerRejected(reason: String)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .projectNotFound(let id):
            return "Project not found: \(id)"
        case .taskNotFound(let id):
            return "Task not found: \(id)"
        case .invalidProjectInput(let field, let reason):
            return "Invalid project \(field): \(reason)"
        case .invalidTaskInput(let field, let reason):
            return "Invalid task \(field): \(reason)"
        case .staleVersion(let taskID, let expected, let actual):
            return "Task \(taskID) changed since this view loaded: expected version \(expected), actual \(actual)"
        case .staleAttempt(let taskID, let expected, let actual):
            return
                "Task \(taskID) active attempt changed: expected \(expected?.uuidString ?? "none"), actual \(actual?.uuidString ?? "none")"
        case .actionAlreadyInFlight(let taskID):
            return "Task \(taskID) already has an action in flight"
        case .actionNotAvailable(let taskID, let status):
            return "Action is not available for task \(taskID) in status \(status.rawValue)"
        case .noActiveAttempt(let taskID):
            return "Task \(taskID) has no active attempt"
        case .budgetExhausted(let taskID, let reason):
            return "Task \(taskID) exhausted its execution budget: \(reason)"
        case .acceptanceDenied(let taskID, let reasons):
            return "Task \(taskID) cannot be accepted: \(reasons.count) blocking gate reason(s)"
        case .acceptanceInputUnavailable(let taskID, let reason):
            return "Acceptance inputs for task \(taskID) are unavailable: \(reason)"
        case .liveDispatchUnavailable(let taskID):
            return "Task \(taskID) cannot start a live run: no running port is wired in this composition"
        case .executionFingerprintUnavailable(let taskID, let reason):
            return "Task \(taskID) cannot start a live run: no current workspace fingerprint is available (\(reason))"
        case .criterionNotFound(let taskID, let criterionID):
            return "Task \(taskID) has no acceptance criterion \(criterionID.uuidString)"
        case .dependencyRejected(let projectID, let reason):
            return "Dependency for project \(projectID) rejected: \(reason)"
        case .transitionRejected(let error):
            return "Transition rejected: \(error)"
        case .persistence(let error):
            return "Task store rejected the operation: \(error.localizedDescription)"
        case .schedulerRejected(let reason):
            return "Scheduler rejected the operation: \(reason)"
        case .unexpected(let message):
            return "Unexpected task service failure: \(message)"
        }
    }
}

/// Why a start request could not reach a runtime, with the missing capability when known.
enum CodingTaskRuntimeUnavailability: Sendable, Equatable {
    case unsupported(missingCapabilities: [String])
    case providerUnavailable(reason: String)

    var message: String {
        switch self {
        case .unsupported(let missingCapabilities):
            guard !missingCapabilities.isEmpty else {
                return "No eligible runtime supports this task"
            }
            return "No eligible runtime provides: \(missingCapabilities.joined(separator: ", "))"
        case .providerUnavailable(let reason):
            return reason
        }
    }
}

/// Honest outcome of a start pass: claimed, blocked, refused for a missing runtime or deferred.
enum CodingTaskStartResult: Sendable, Equatable {
    case claimed(attemptID: UUID, generation: Int)
    case blocked(TaskBlockReason)
    case unavailable(CodingTaskRuntimeUnavailability)
    case deferred(reason: String)
}

/// Evidence and current content fingerprint used by the acceptance gate.
struct TaskAcceptanceEvidence: Sendable, Equatable {
    let evidence: [VerificationEvidence]
    let currentFingerprint: String
}

/// Supplies gate inputs the repository protocol cannot list yet (evidence and fingerprint).
///
/// The composition root wires this to the verification runner and the owned workspace; Task 13
/// only defines the boundary so the service never inspects Git or SQLite itself.
protocol TaskAcceptanceEvidenceProviding: Sendable {
    func acceptanceEvidence(taskID: UUID) async throws -> TaskAcceptanceEvidence
}

/// Supplies the content fingerprint a human `executeRecipe` approval binds to.
///
/// The fingerprint is read from the attempt's owned workspace at start time, so the
/// approval authorizes running the agent against the exact revision the human saw
/// when they pressed start. An unavailable fingerprint refuses the start instead of
/// fabricating a value; the claimed attempt is retired so no naked run stays behind.
protocol TaskExecutionFingerprintProviding: Sendable {
    func executionFingerprint(projectID: UUID, taskID: UUID) async throws -> String
}

/// Typed failures of an execution fingerprint lookup.
enum TaskExecutionFingerprintError: LocalizedError, Equatable, Sendable {
    case workspaceNotOwned(taskID: UUID, reason: String)
    case fingerprintUnavailable(taskID: UUID, workspacePath: String)

    var errorDescription: String? {
        switch self {
        case .workspaceNotOwned(let taskID, let reason):
            return "Task \(taskID) has no owned workspace to fingerprint: \(reason)"
        case .fingerprintUnavailable(let taskID, let workspacePath):
            return "The owned workspace of task \(taskID) could not be fingerprinted at \(workspacePath)"
        }
    }
}

/// App-facing task service: the only surface the board UI is allowed to mutate through.
///
/// Every mutating call is single-flight per task, takes the caller's expected version or
/// attempt identity where the layer supports it, and reports an explicit typed refusal instead
/// of an optimistic success. The service never dispatches work its injected runtime cannot run.
actor CodingTaskService {
    private let repository: CodingTaskRepository
    private let scheduler: TaskScheduler
    private let recovery: TaskRecovery
    private let providers: TaskProviderRegistryPort
    private let acceptanceEvidence: TaskAcceptanceEvidenceProviding
    private let executionFingerprints: any TaskExecutionFingerprintProviding
    private let clock: TaskSchedulerClock
    private let requiredSteps: [String]

    /// Gönderim yeteneğinin bu kompozisyonda gerçekten bağlı olup olmadığı.
    ///
    /// `false` iken canlı koşu başlatma isteği talebi hiç doğurmadan reddedilir;
    /// `true` iken başlatma yalnızca zamanlayıcının kendi kapılarından geçerse
    /// koşu doğurur.
    private let liveDispatchAvailable: Bool

    /// Process-lifetime project registry. Persistence arrives with the project repository port
    /// in the composition task; nothing here writes SQL or guesses Git state.
    private var registeredProjects: [UUID: CodingProject] = [:]

    /// Tasks with an action currently suspended at a port; a second action is refused, not raced.
    private var inFlightTaskIDs: Set<UUID> = []

    init(
        repository: CodingTaskRepository,
        scheduler: TaskScheduler,
        recovery: TaskRecovery,
        providers: TaskProviderRegistryPort,
        acceptanceEvidence: TaskAcceptanceEvidenceProviding,
        executionFingerprints: any TaskExecutionFingerprintProviding,
        clock: TaskSchedulerClock,
        requiredSteps: [String],
        liveDispatchAvailable: Bool
    ) {
        self.repository = repository
        self.scheduler = scheduler
        self.recovery = recovery
        self.providers = providers
        self.acceptanceEvidence = acceptanceEvidence
        self.executionFingerprints = executionFingerprints
        self.clock = clock
        self.requiredSteps = requiredSteps
        self.liveDispatchAvailable = liveDispatchAvailable
    }

    // MARK: - Projects and tasks

    /// Registers a project for this process after validating its display and repository identity.
    func createProject(
        name: String,
        repositoryPath: String,
        gitIdentity: String,
        protectedRefs: [String]
    ) async throws -> CodingProject {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw CodingTaskServiceError.invalidProjectInput(field: "name", reason: "must not be blank")
        }
        let trimmedPath = repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw CodingTaskServiceError.invalidProjectInput(field: "repositoryPath", reason: "must not be blank")
        }
        let trimmedIdentity = gitIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIdentity.isEmpty else {
            throw CodingTaskServiceError.invalidProjectInput(field: "gitIdentity", reason: "must not be blank")
        }

        let project = CodingProject(
            id: UUID(),
            name: trimmedName,
            repositoryPath: trimmedPath,
            gitIdentity: trimmedIdentity,
            protectedRefs: protectedRefs,
            createdAt: clock.now()
        )
        registeredProjects[project.id] = project
        return project
    }

    func project(id: UUID) -> CodingProject? {
        registeredProjects[id]
    }

    /// Creates a backlog task with ordered criteria; a repository rejection is surfaced, never absorbed.
    func createTask(
        projectID: UUID,
        title: String,
        objective: String,
        priority: Int,
        criteria: [String]
    ) async throws -> CodingTask {
        guard registeredProjects[projectID] != nil else {
            throw CodingTaskServiceError.projectNotFound(projectID)
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw CodingTaskServiceError.invalidTaskInput(field: "title", reason: "must not be blank")
        }
        let trimmedObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedObjective.isEmpty else {
            throw CodingTaskServiceError.invalidTaskInput(field: "objective", reason: "must not be blank")
        }
        guard priority >= 0 else {
            throw CodingTaskServiceError.invalidTaskInput(field: "priority", reason: "must not be negative")
        }
        let trimmedCriteria = criteria.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard trimmedCriteria.allSatisfy({ !$0.isEmpty }) else {
            throw CodingTaskServiceError.invalidTaskInput(field: "criteria", reason: "must not contain blank descriptions")
        }

        let taskID = UUID()
        let now = clock.now()
        let acceptanceCriteria = trimmedCriteria.map { description in
            CodingAcceptanceCriterion(taskID: taskID, description: description)
        }
        let task = CodingTask(
            id: taskID,
            projectID: projectID,
            title: trimmedTitle,
            objective: trimmedObjective,
            priority: priority,
            status: .backlog,
            stage: .analysis,
            version: 1,
            criteria: acceptanceCriteria,
            createdAt: now,
            updatedAt: now
        )
        try await mapped { try await self.repository.createTask(task) }
        return task
    }

    /// Adds a dependency edge after a pure cycle/self/duplicate test; a rejected edge never persists.
    func addDependency(
        projectID: UUID,
        prerequisiteTaskID: UUID,
        dependentTaskID: UUID
    ) async throws -> TaskDependency {
        let edge = TaskDependency(
            projectID: projectID,
            prerequisiteTaskID: prerequisiteTaskID,
            dependentTaskID: dependentTaskID
        )
        let snapshot = try await snapshot(projectID: projectID)
        do {
            _ = try TaskDependencyGraph.add(edge, to: snapshot.dependencies, tasks: snapshot.tasks)
        } catch let error as DependencyGraphError {
            throw CodingTaskServiceError.dependencyRejected(projectID: projectID, reason: error.localizedDescription)
        }
        try await mapped { try await self.repository.addDependency(edge) }
        return edge
    }

    // MARK: - Reads

    func snapshot(projectID: UUID) async throws -> CodingBoardSnapshot {
        try await mapped { try await self.repository.snapshot(projectID: projectID) }
    }

    func attemptHistory(taskID: UUID) async throws -> [TaskAttempt] {
        try await mapped { try await self.repository.attemptHistory(taskID: taskID) }
    }

    /// Evaluates the completion gate without mutating anything; reasons are always explicit.
    func evaluateAcceptance(taskID: UUID) async throws -> AcceptanceDecision {
        let task = try await requireTask(taskID)
        let context = try await acceptanceContext(task: task)
        return context.decision
    }

    /// Conservative launch-time reconciliation through the recovery actor.
    func reconcile(projectID: UUID) async -> RecoveryReport {
        await recovery.reconcile(projectID: projectID)
    }

    // MARK: - Execution control

    /// Starts a backlog or ready task: pre-checks the runtime, then arms and claims one attempt.
    ///
    /// An unsupported or unavailable runtime is refused before any scheduler call, so no claim,
    /// lease or transition is written for work this machine cannot run. Workspace readiness is
    /// surfaced exactly as the scheduler reports it (for example `.deferred(reason:)`).
    /// The re-arm is fenced with "no active attempt expected": an attempt claimed concurrently
    /// between the guard above and the scheduler call is refused as typed stale, never cancelled.
    func start(taskID: UUID, expectedVersion: Int) async throws -> CodingTaskStartResult {
        try await withExclusiveTaskAction(taskID: taskID) {
            let task = try await self.requireTask(taskID)
            try Self.requireVersion(task: task, expectedVersion: expectedVersion)
            guard task.status == .backlog || task.status == .ready else {
                throw CodingTaskServiceError.actionNotAvailable(taskID: taskID, status: task.status)
            }
            guard task.currentAttemptID == nil else {
                return .deferred(reason: "activeAttempt")
            }

            let stage: TaskStage = task.status == .backlog ? .plan : task.stage
            switch await self.providers.candidate(for: task, stage: stage) {
            case .unsupported(let missingCapabilities):
                return .unavailable(.unsupported(missingCapabilities: missingCapabilities))
            case .unavailable(let reason):
                return .unavailable(.providerUnavailable(reason: reason))
            case .eligible:
                break
            }

            let entry = try await self.mapped {
                try await self.scheduler.retry(taskID: taskID, expectedAttemptID: nil, expectedGeneration: nil)
            }
            return Self.startResult(from: entry)
        }
    }

    /// İnsan onayıyla canlı koşu başlatır: talep, parmak izi ve koşu tek eylemde.
    ///
    /// Sıra: sağlayıcı uygunluğu → deneme talebi (çalışma alanı bu adımda doğar) →
    /// güncel içerik parmak izi → insan `executeRecipe` onayı → gönderim. Parmak
    /// izi alınamazsa onay uydurulmaz; talep edilmiş deneme geri çekilir ve açık
    /// bir hata döner. Gönderim, dışlama kilidi bırakıldıktan sonra arka planda
    /// başlar; koşunun sonucu panoya bir sonraki yenilemede yansır ve `stop` onu
    /// iptal eder.
    @discardableResult
    func startRun(taskID: UUID, expectedVersion: Int, actor: String) async throws -> CodingTaskStartResult {
        let outcome = try await withExclusiveTaskAction(taskID: taskID) { () async throws -> StartRunOutcome in
            guard self.liveDispatchAvailable else {
                throw CodingTaskServiceError.liveDispatchUnavailable(taskID: taskID)
            }
            let trimmedActor = try Self.requireHumanText(actor, field: "actor")
            let task = try await self.requireTask(taskID)
            try Self.requireVersion(task: task, expectedVersion: expectedVersion)
            guard task.status == .backlog || task.status == .ready else {
                throw CodingTaskServiceError.actionNotAvailable(taskID: taskID, status: task.status)
            }
            guard task.currentAttemptID == nil else {
                return .resolved(.deferred(reason: "activeAttempt"))
            }

            let stage: TaskStage = task.status == .backlog ? .plan : task.stage
            switch await self.providers.candidate(for: task, stage: stage) {
            case .unsupported(let missingCapabilities):
                return .resolved(.unavailable(.unsupported(missingCapabilities: missingCapabilities)))
            case .unavailable(let reason):
                return .resolved(.unavailable(.providerUnavailable(reason: reason)))
            case .eligible:
                break
            }

            let entry = try await self.mapped {
                try await self.scheduler.retry(taskID: taskID, expectedAttemptID: nil, expectedGeneration: nil)
            }
            guard case .claimed(let attemptID, let generation) = entry.disposition else {
                return .resolved(Self.startResult(from: entry))
            }

            let fingerprint: String
            do {
                fingerprint = try await self.executionFingerprints.executionFingerprint(
                    projectID: task.projectID,
                    taskID: taskID
                )
            } catch {
                // Onaysız koşu başlamaz; talep edilmiş deneme arkada kalmasın diye
                // tam kimliğiyle geri çekilir ve hata olduğu gibi yüzeye çıkar.
                await self.retireClaimedAttemptIfCurrent(taskID: taskID, attemptID: attemptID, generation: generation)
                throw CodingTaskServiceError.executionFingerprintUnavailable(
                    taskID: taskID,
                    reason: String(describing: error)
                )
            }

            let approval = TaskApproval(
                id: UUID(),
                taskID: taskID,
                attemptID: attemptID,
                fingerprint: fingerprint,
                actor: trimmedActor,
                timestamp: self.clock.now(),
                action: .executeRecipe
            )
            do {
                try await self.mapped { try await self.repository.recordApproval(approval) }
            } catch {
                // Onay kaydı düşerse talep edilmiş deneme `.running` olarak asılı
                // kalamaz: tam kimliğiyle geri çekilir ve hata yüzeye çıkar.
                await self.retireClaimedAttemptIfCurrent(taskID: taskID, attemptID: attemptID, generation: generation)
                throw error
            }
            return .dispatch(attemptID: attemptID, generation: generation, fingerprint: fingerprint)
        }

        switch outcome {
        case .resolved(let result):
            return result
        case .dispatch(let attemptID, let generation, let fingerprint):
            // Gönderim dışlama kilidinin dışında başlar: arka plan hatasının
            // fenced geri çekmesi kilit yüzünden reddedilmez.
            await self.dispatch(attempt: attemptID, generation: generation, fingerprint: fingerprint, taskID: taskID)
            return .claimed(attemptID: attemptID, generation: generation)
        }
    }

    /// `startRun` eyleminin dışlama kilidi içindeki sonucu.
    private enum StartRunOutcome {
        case resolved(CodingTaskStartResult)
        case dispatch(attemptID: UUID, generation: Int, fingerprint: String)
    }

    /// Gönderim reddinde veya onay kaydı hatasında, yalnızca hâlâ geçerli olan
    /// talep edilmiş denemeyi geri çeker; bayat bir hata yeni bir denemeyi asla
    /// durduramaz.
    ///
    /// Dışlama kilidi, kimlik kontrolü ile durdurma arasına başka bir servis
    /// eyleminin girmesini engeller; kimlik uyuşmuyorsa hiçbir şey durdurulmaz.
    private func retireClaimedAttempt(taskID: UUID, attemptID: UUID, generation: Int, reason: String) async {
        do {
            try await withExclusiveTaskAction(taskID: taskID) {
                await self.retireClaimedAttemptIfCurrent(taskID: taskID, attemptID: attemptID, generation: generation)
            }
        } catch {
            AppLog.lifecycle.error(
                "Could not retire claim of task \(taskID.uuidString, privacy: .public) attempt \(attemptID.uuidString, privacy: .public) after dispatch refusal (\(reason, privacy: .public)): \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Çağıran dışlamayı zaten tutuyorsa kullanılan iç geri çekme.
    ///
    /// Deneme kimliği ve nesli eşleşmiyorsa hiçbir şey durdurulmaz; eşleşiyorsa
    /// `scheduler.stop` o anda aktif olan bu denemeyi emekliye ayırır.
    private func retireClaimedAttemptIfCurrent(taskID: UUID, attemptID: UUID, generation: Int) async {
        do {
            guard
                let active = try await self.activeAttempt(taskID: taskID),
                active.id == attemptID,
                active.generation == generation
            else {
                AppLog.lifecycle.info(
                    "Skipped retiring claim of task \(taskID.uuidString, privacy: .public): attempt \(attemptID.uuidString, privacy: .public)/gen \(generation) is no longer current"
                )
                return
            }
            try await self.mapped { try await self.scheduler.stop(taskID: taskID) }
        } catch {
            AppLog.lifecycle.error(
                "Retiring claim of task \(taskID.uuidString, privacy: .public) attempt \(attemptID.uuidString, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Gönderimi sahipli bir arka plan görevinde sürer; sonuç panoyu yeniden
    /// yükleyerek görünür olur. Başlatma kapıları (onay, sahiplik, kimlik,
    /// bütçe) zamanlayıcının içindedir; burada yalnızca yaşam döngüsü tutulur.
    ///
    /// Her gönderim hatası (çalıştırıcı başlayamadı, sahiplik/kimlik reddi,
    /// sağlayıcı uygun değil, bütçe tükendi, koşu zaten aktif) loglanır ve
    /// talep edilmiş deneme yalnızca kimliği hâlâ geçerliyse fenced bir geri
    /// çekmeyle emekliye ayrılır; bayat bir hata daha yeni bir denemeyi
    /// durduramaz.
    private func dispatch(attempt attemptID: UUID, generation: Int, fingerprint: String, taskID: UUID) async {
        let handle = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.scheduler.dispatch(
                    taskID: taskID,
                    attemptID: attemptID,
                    generation: generation,
                    fingerprint: fingerprint
                )
            } catch {
                AppLog.lifecycle.error(
                    "Live dispatch for task \(taskID.uuidString, privacy: .public) attempt \(attemptID.uuidString, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
                await self.retireClaimedAttempt(
                    taskID: taskID,
                    attemptID: attemptID,
                    generation: generation,
                    reason: String(describing: error)
                )
            }
        }
        dispatchedRuns[taskID] = handle
    }

    /// Bekleyen koşu görevleri; kapanış ve durdurma bu tutamağı bekler.
    private var dispatchedRuns: [UUID: Task<Void, Never>] = [:]

    /// Bu süreçte başlatılmış koşu görevlerinin bitmesini bekler (kapanış yolu).
    func awaitDispatchedRuns() async {
        let handles = dispatchedRuns.values
        for handle in handles {
            _ = await handle.value
        }
    }

    /// İnsan bir kabul ölçütünü tamamlandı ya da geri aldı olarak işaretler.
    ///
    /// Sürüm çiti çağıranın gördüğü kart sürümüdür; bayat işaretleme sessizce
    /// uygulanmaz. Ölçüt bulunamazsa açık bir `criterionNotFound` hatası döner.
    @discardableResult
    func setCriterionCompletion(
        taskID: UUID,
        criterionID: UUID,
        isCompleted: Bool,
        expectedVersion: Int
    ) async throws -> CodingTask {
        try await withExclusiveTaskAction(taskID: taskID) {
            let task = try await self.requireTask(taskID)
            guard task.criteria.contains(where: { $0.id == criterionID }) else {
                throw CodingTaskServiceError.criterionNotFound(taskID: taskID, criterionID: criterionID)
            }
            return try await self.mapped {
                try await self.repository.setCriterionCompletion(
                    taskID: taskID,
                    criterionID: criterionID,
                    isCompleted: isCompleted,
                    expectedVersion: expectedVersion
                )
            }
        }
    }

    /// Suspends scheduling for the exact active attempt the caller saw.
    func pause(taskID: UUID, expectedAttemptID: UUID) async throws {
        try await withExclusiveTaskAction(taskID: taskID) {
            _ = try await self.requireTask(taskID)
            guard let active = try await self.activeAttempt(taskID: taskID) else {
                throw CodingTaskServiceError.noActiveAttempt(taskID: taskID)
            }
            guard active.id == expectedAttemptID else {
                throw CodingTaskServiceError.staleAttempt(
                    taskID: taskID,
                    expectedAttemptID: expectedAttemptID,
                    actualAttemptID: active.id
                )
            }
            try await self.mapped { try await self.scheduler.pause(taskID: taskID) }
        }
    }

    /// Resumes a user-suspended task by re-arming it; the scheduler has no non-destructive resume.
    ///
    /// Only a `paused` or `stopped` block is resumable: a system block such as
    /// `.uncertainExecution` needs reconciliation, never a silent relaunch. Resume replaces the
    /// suspended attempt with a fresh generation, so the caller must name the attempt it saw;
    /// a mismatch is a typed stale refusal, never a silent cancellation.
    @discardableResult
    func resume(taskID: UUID, expectedVersion: Int, expectedAttemptID: UUID?) async throws -> TaskScheduleEntry {
        try await withExclusiveTaskAction(taskID: taskID) {
            let task = try await self.requireTask(taskID)
            try Self.requireVersion(task: task, expectedVersion: expectedVersion)
            guard task.status == .blocked else {
                throw CodingTaskServiceError.actionNotAvailable(taskID: taskID, status: task.status)
            }
            guard TaskScheduler.isUserSuspension(task.blockReason) else {
                throw CodingTaskServiceError.actionNotAvailable(taskID: taskID, status: task.status)
            }
            let active = try await self.activeAttempt(taskID: taskID)
            guard active?.id == expectedAttemptID else {
                throw CodingTaskServiceError.staleAttempt(
                    taskID: taskID,
                    expectedAttemptID: expectedAttemptID,
                    actualAttemptID: active?.id
                )
            }
            return try await self.mapped {
                try await self.scheduler.retry(
                    taskID: taskID,
                    expectedAttemptID: expectedAttemptID,
                    expectedGeneration: active?.generation
                )
            }
        }
    }

    /// Stops the running task the caller saw, fenced by version and active attempt.
    ///
    /// The stop is only legal while the task is still running: a task that advanced to
    /// review behind the caller's back must be refused with a typed stale/not-available
    /// error instead of being cancelled into `blocked(custom("stopped"))`.
    func stop(taskID: UUID, expectedVersion: Int, expectedAttemptID: UUID?) async throws {
        try await withExclusiveTaskAction(taskID: taskID) {
            let task = try await self.requireTask(taskID)
            try Self.requireVersion(task: task, expectedVersion: expectedVersion)
            guard task.status == .running else {
                throw CodingTaskServiceError.actionNotAvailable(taskID: taskID, status: task.status)
            }
            guard task.currentAttemptID == expectedAttemptID else {
                throw CodingTaskServiceError.staleAttempt(
                    taskID: taskID,
                    expectedAttemptID: expectedAttemptID,
                    actualAttemptID: task.currentAttemptID
                )
            }
            try await self.mapped { try await self.scheduler.stop(taskID: taskID) }
        }
    }

    /// Re-arms a task and claims a new attempt, fenced to the exact active generation.
    ///
    /// The scheduler's `retry` cancels whichever attempt is active, so the service refuses to
    /// call it unless the caller's expected attempt identity and generation match the persisted
    /// active attempt; the review finding M5 gap is closed here.
    @discardableResult
    func retry(
        taskID: UUID,
        expectedActiveAttemptID: UUID?,
        expectedActiveGeneration: Int?
    ) async throws -> TaskScheduleEntry {
        try await withExclusiveTaskAction(taskID: taskID) {
            let task = try await self.requireTask(taskID)
            guard !task.status.isTerminal else {
                throw CodingTaskServiceError.actionNotAvailable(taskID: taskID, status: task.status)
            }
            let active = try await self.activeAttempt(taskID: taskID)
            guard active?.id == expectedActiveAttemptID, active?.generation == expectedActiveGeneration else {
                throw CodingTaskServiceError.staleAttempt(
                    taskID: taskID,
                    expectedAttemptID: expectedActiveAttemptID,
                    actualAttemptID: active?.id
                )
            }
            return try await self.mapped {
                try await self.scheduler.retry(
                    taskID: taskID,
                    expectedAttemptID: expectedActiveAttemptID,
                    expectedGeneration: expectedActiveGeneration
                )
            }
        }
    }

    // MARK: - Review and acceptance

    /// Sends a reviewed task back to ready with the reviewer's feedback.
    func requestChanges(
        taskID: UUID,
        expectedVersion: Int,
        actor: String,
        feedback: String
    ) async throws -> CodingTask {
        try await withExclusiveTaskAction(taskID: taskID) {
            let trimmedActor = try Self.requireHumanText(actor, field: "actor")
            let trimmedFeedback = try Self.requireHumanText(feedback, field: "feedback")
            let task = try await self.requireTask(taskID)
            try Self.requireVersion(task: task, expectedVersion: expectedVersion)
            guard task.status == .review else {
                throw CodingTaskServiceError.actionNotAvailable(taskID: taskID, status: task.status)
            }
            return try await self.mapped {
                try await self.repository.transition(
                    taskID: taskID,
                    expectedVersion: expectedVersion,
                    action: .requestChanges(feedback: trimmedFeedback),
                    context: TaskTransitionContext(
                        fingerprint: task.currentAttemptID?.uuidString ?? "",
                        actor: trimmedActor
                    )
                )
            }
        }
    }

    /// Accepts a task only when the completion gate passes; the approval binds actor, attempt and content.
    ///
    /// The approval travels inside the version-fenced transition context: `SQLiteTaskStore`
    /// persists the task state and the approval row in one transaction, so a rejected
    /// transition can never leave an orphan approval that authorizes later work.
    func accept(taskID: UUID, expectedVersion: Int, actor: String) async throws -> CodingTask {
        try await withExclusiveTaskAction(taskID: taskID) {
            let trimmedActor = try Self.requireHumanText(actor, field: "actor")
            let task = try await self.requireTask(taskID)
            try Self.requireVersion(task: task, expectedVersion: expectedVersion)
            guard task.status == .review else {
                throw CodingTaskServiceError.actionNotAvailable(taskID: taskID, status: task.status)
            }

            let context = try await self.acceptanceContext(task: task)
            if case .blocked(let reasons) = context.decision {
                throw CodingTaskServiceError.acceptanceDenied(taskID: taskID, reasons: reasons)
            }

            let existingApproval = Self.matchingApproval(for: context, actor: trimmedActor)
            let approval =
                existingApproval
                ?? TaskApproval(
                    id: UUID(),
                    taskID: context.task.id,
                    attemptID: context.attempt.id,
                    fingerprint: context.currentFingerprint,
                    actor: trimmedActor,
                    timestamp: clock.now(),
                    action: .accept
                )
            let evidenceIDs = context.evidence
                .filter { entry in
                    entry.taskID == task.id
                        && entry.status == .passed
                        && entry.workspaceFingerprint == context.currentFingerprint
                }
                .map(\.id)
            return try await self.mapped {
                try await self.repository.transition(
                    taskID: taskID,
                    expectedVersion: expectedVersion,
                    action: .accept,
                    context: TaskTransitionContext(
                        fingerprint: context.currentFingerprint,
                        actor: trimmedActor,
                        evidenceIDs: evidenceIDs,
                        humanApproval: approval
                    )
                )
            }
        }
    }

    // MARK: - Acceptance context

    private struct AcceptanceContext {
        let task: CodingTask
        let attempt: TaskAttempt
        let evidence: [VerificationEvidence]
        let findings: [ReviewFinding]
        let approvals: [TaskApproval]
        let currentFingerprint: String
        let decision: AcceptanceDecision
    }

    private func acceptanceContext(task: CodingTask) async throws -> AcceptanceContext {
        guard let attemptID = task.currentAttemptID else {
            throw CodingTaskServiceError.noActiveAttempt(taskID: task.id)
        }
        let history = try await attemptHistory(taskID: task.id)
        guard let attempt = history.first(where: { $0.id == attemptID }) else {
            throw CodingTaskServiceError.noActiveAttempt(taskID: task.id)
        }
        let inputs: TaskAcceptanceEvidence
        do {
            inputs = try await acceptanceEvidence.acceptanceEvidence(taskID: task.id)
        } catch {
            throw CodingTaskServiceError.acceptanceInputUnavailable(taskID: task.id, reason: String(describing: error))
        }
        let findings = try await mapped { try await self.repository.findings(taskID: task.id) }
        let approvals = try await mapped { try await self.repository.approvals(taskID: task.id) }
        let decision = AcceptanceGate.evaluate(
            task: task,
            attempt: attempt,
            evidence: inputs.evidence,
            findings: findings,
            approvals: approvals,
            currentFingerprint: inputs.currentFingerprint,
            requiredSteps: requiredSteps
        )
        return AcceptanceContext(
            task: task,
            attempt: attempt,
            evidence: inputs.evidence,
            findings: findings,
            approvals: approvals,
            currentFingerprint: inputs.currentFingerprint,
            decision: decision
        )
    }

    /// Returns an approval that already authorizes this exact attempt, content and actor,
    /// or nil when a fresh actor-bound approval must be constructed.
    ///
    /// A same-content approval from another actor is not reused: acceptance must record the
    /// human who actually accepted this content.
    private static func matchingApproval(for context: AcceptanceContext, actor: String) -> TaskApproval? {
        context.approvals.first { approval in
            approval.authorizes(
                action: .accept,
                taskID: context.task.id,
                attemptID: context.attempt.id,
                fingerprint: context.currentFingerprint
            )
                && approval.actor.trimmingCharacters(in: .whitespacesAndNewlines) == actor
        }
    }

    // MARK: - Guards and mapping

    private func withExclusiveTaskAction<T>(taskID: UUID, _ operation: () async throws -> T) async throws -> T {
        guard inFlightTaskIDs.insert(taskID).inserted else {
            throw CodingTaskServiceError.actionAlreadyInFlight(taskID: taskID)
        }
        defer { inFlightTaskIDs.remove(taskID) }
        return try await operation()
    }

    private func requireTask(_ taskID: UUID) async throws -> CodingTask {
        let task = try await mapped { try await self.repository.task(id: taskID) }
        guard let task else {
            throw CodingTaskServiceError.taskNotFound(taskID)
        }
        return task
    }

    private func activeAttempt(taskID: UUID) async throws -> TaskAttempt? {
        let history = try await attemptHistory(taskID: taskID)
        return history.first { $0.outcome == .inProgress && $0.endedAt == nil }
    }

    private func mapped<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            throw Self.mapError(error)
        }
    }

    static func mapError(_ error: Error) -> CodingTaskServiceError {
        if let serviceError = error as? CodingTaskServiceError {
            return serviceError
        }
        if let repositoryError = error as? TaskRepositoryError {
            switch repositoryError {
            case .staleVersion(let taskID, let expected, let actual):
                return .staleVersion(taskID: taskID, expected: expected, actual: actual)
            case .taskNotFound(let id):
                return .taskNotFound(id)
            default:
                return .persistence(repositoryError)
            }
        }
        if let transitionError = error as? TaskTransitionError {
            return .transitionRejected(transitionError)
        }
        if let schedulerError = error as? TaskSchedulerError {
            switch schedulerError {
            case .taskNotFound(let id):
                return .taskNotFound(id)
            case .noActiveAttempt(let id):
                return .noActiveAttempt(taskID: id)
            case .retryNotAvailable(let taskID, let status):
                return .actionNotAvailable(taskID: taskID, status: status)
            case .attemptBudgetExhausted(let taskID, let used, let maximum):
                return .budgetExhausted(taskID: taskID, reason: "attempt budget exhausted (\(used)/\(maximum))")
            case .timeBudgetExhausted(let taskID, let used, let maximum):
                return .budgetExhausted(taskID: taskID, reason: "time budget exhausted (\(used)s/\(maximum)s)")
            case .toolCallBudgetExhausted(let taskID, let used, let maximum):
                return .budgetExhausted(taskID: taskID, reason: "tool-call budget exhausted (\(used)/\(maximum))")
            case .invalidCompletionOutcome(let outcome):
                return .schedulerRejected(reason: "invalid completion outcome \(outcome.rawValue)")
            case .staleAttempt(let taskID, let expectedAttemptID, _, let actualAttemptID, _):
                return .staleAttempt(taskID: taskID, expectedAttemptID: expectedAttemptID, actualAttemptID: actualAttemptID)
            }
        }
        return .unexpected(String(describing: error))
    }

    private static func requireVersion(task: CodingTask, expectedVersion: Int) throws {
        guard task.version == expectedVersion else {
            throw CodingTaskServiceError.staleVersion(
                taskID: task.id,
                expected: expectedVersion,
                actual: task.version
            )
        }
    }

    private static func requireHumanText(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CodingTaskServiceError.invalidTaskInput(field: field, reason: "must not be blank")
        }
        return trimmed
    }

    private static func startResult(from entry: TaskScheduleEntry) -> CodingTaskStartResult {
        switch entry.disposition {
        case .claimed(let attemptID, let generation):
            return .claimed(attemptID: attemptID, generation: generation)
        case .blocked(let reason):
            return .blocked(reason)
        case .deferred(let reason):
            return .deferred(reason: reason)
        }
    }
}
