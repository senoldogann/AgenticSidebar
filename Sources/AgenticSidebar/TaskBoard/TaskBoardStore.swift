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
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var refusals: [UUID: TaskBoardActionRefusal] = [:]

    private(set) var phase: Phase = .idle
    private(set) var cards: [TaskBoardCard] = []
    private(set) var detail: TaskBoardTaskDetail?
    private(set) var selectedProjectID: UUID?
    private(set) var selectedTaskID: UUID?
    private(set) var inFlightTaskIDs: Set<UUID> = []
    private(set) var lastFailure: String?
    private(set) var isCreatingTask = false
    private(set) var isAddingDependency = false

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
        boardSnapshot = nil
        cards = []
        phase = .idle
    }

    /// Selects a task and loads its attempt history; an in-flight action keeps running.
    func selectTask(_ taskID: UUID?) async {
        guard selectedTaskID != taskID else { return }
        selectedTaskID = taskID
        detail = nil
        selectedTaskAttempts = []
        guard let taskID else { return }
        await loadDetail(taskID: taskID)
    }

    // MARK: - Loading

    /// Reloads the board snapshot, coalescing a burst of requests into one follow-up load.
    func refresh() async {
        guard let projectID = selectedProjectID else {
            phase = .idle
            return
        }
        if isRefreshing {
            needsReload = true
            await withCheckedContinuation { continuation in
                refreshWaiters.append(continuation)
            }
            return
        }
        isRefreshing = true
        repeat {
            needsReload = false
            await loadSnapshot(projectID: projectID)
        } while needsReload
        isRefreshing = false
        let waiters = refreshWaiters
        refreshWaiters = []
        for waiter in waiters {
            waiter.resume()
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

    // MARK: - Task creation

    func createTask(
        projectID: UUID,
        title: String,
        objective: String,
        priority: Int,
        criteria: [String]
    ) async -> TaskBoardActionResult {
        guard !isCreatingTask else {
            return .refused(TaskBoardRefusal(kind: .busy, message: "Task creation is already in flight"))
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

    func addDependency(
        projectID: UUID,
        prerequisiteTaskID: UUID,
        dependentTaskID: UUID
    ) async -> TaskBoardActionResult {
        guard !isAddingDependency else {
            return .refused(TaskBoardRefusal(kind: .busy, message: "A dependency change is already in flight"))
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
                    return .refused(TaskBoardRefusal(kind: .unavailable, message: "Not dispatched: \(reason)"))
                }
            } catch {
                return .refused(Self.refusal(from: error))
            }
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
                try await self.service.stop(taskID: taskID, expectedAttemptID: card.currentAttemptID)
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
            return .refused(TaskBoardRefusal(kind: .unavailable, message: "Not dispatched: \(reason)"))
        }
    }

    private static func baseAvailability(
        for action: TaskBoardAction,
        card: TaskBoardCard
    ) -> TaskBoardActionAvailability {
        switch action {
        case .start:
            guard card.status == .backlog || card.status == .ready else {
                return disabled(action, "Start is only available for backlog or ready tasks (current: \(card.status.rawValue))")
            }
            guard card.activeAttempt == nil else {
                return disabled(action, "An attempt is already active")
            }
            return enabled(action)
        case .pause:
            guard card.status == .running, card.activeAttempt != nil else {
                return disabled(action, "Pause requires a running task with an active attempt")
            }
            return enabled(action)
        case .resume:
            guard card.status == .blocked, isSuspended(card.blockReason) else {
                return disabled(action, "Resume is only available for paused or stopped tasks")
            }
            return enabled(action)
        case .stop:
            guard card.status == .running else {
                return disabled(action, "Stop is only available for a running task")
            }
            return enabled(action)
        case .retry:
            guard card.status == .blocked else {
                return disabled(action, "Retry is only available for a blocked task; use Start for ready work")
            }
            return enabled(action)
        case .requestChanges:
            guard card.status == .review else {
                return disabled(action, "Request changes is only available while the task is in review")
            }
            return enabled(action)
        case .accept:
            guard card.status == .review else {
                return disabled(action, "Accept is only available while the task is in review")
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
        guard case .custom(let value) = reason else { return false }
        return value == "paused" || value == "stopped"
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

    // MARK: - Error mapping

    private static func describe(_ error: Error) -> String {
        if let serviceError = error as? CodingTaskServiceError {
            return serviceError.localizedDescription
        }
        return String(describing: error)
    }

    private static func refusal(from error: Error) -> TaskBoardRefusal {
        guard let serviceError = error as? CodingTaskServiceError else {
            return TaskBoardRefusal(kind: .rejected, message: "Unexpected error: \(error)")
        }
        switch serviceError {
        case .staleVersion(_, let expected, let actual):
            return TaskBoardRefusal(
                kind: .stale,
                message: "This task changed since the board loaded (expected version \(expected), now \(actual))"
            )
        case .staleAttempt:
            return TaskBoardRefusal(kind: .stale, message: "The active attempt changed since the board loaded")
        case .actionAlreadyInFlight:
            return TaskBoardRefusal(kind: .busy, message: "Another action is already in flight for this task")
        case .acceptanceDenied(_, let reasons):
            return TaskBoardRefusal(
                kind: .blocked,
                message: reasons.map(\.boardDescription).joined(separator: "; ")
            )
        case .budgetExhausted(_, let reason):
            return TaskBoardRefusal(kind: .blocked, message: reason)
        case .acceptanceInputUnavailable(_, let reason):
            return TaskBoardRefusal(kind: .unavailable, message: "Acceptance inputs unavailable: \(reason)")
        case .actionNotAvailable(_, let status):
            return TaskBoardRefusal(kind: .rejected, message: "This action is not available while the task is \(status.rawValue)")
        case .noActiveAttempt:
            return TaskBoardRefusal(kind: .rejected, message: "There is no active attempt for this task")
        case .transitionRejected(let transitionError):
            return TaskBoardRefusal(kind: .rejected, message: String(describing: transitionError))
        case .projectNotFound, .taskNotFound, .invalidProjectInput, .invalidTaskInput, .dependencyRejected,
            .persistence, .schedulerRejected:
            return TaskBoardRefusal(kind: .rejected, message: serviceError.localizedDescription)
        }
    }
}

extension TaskBlockReason {
    /// Short human-readable text for an action refusal or card subtitle.
    var boardDescription: String {
        switch self {
        case .prerequisitesNotSatisfied:
            return "prerequisites are not done"
        case .unsupportedCapability(let capability):
            return "unsupported capability: \(capability)"
        case .rateLimited:
            return "the runtime is rate limited"
        case .approvalRequired:
            return "an approval is required"
        case .verificationFailed(let details):
            return "verification failed: \(details)"
        case .uncertainExecution(let details):
            return "execution is uncertain: \(details)"
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
            return "task is \(status.rawValue), not in review"
        case .attemptNotCurrent:
            return "the reviewed attempt is no longer current"
        case .attemptTaskMismatch:
            return "the reviewed attempt belongs to another task"
        case .currentFingerprintUnavailable:
            return "no content fingerprint is available"
        case .noAcceptanceCriteria:
            return "the task has no acceptance criteria"
        case .unmetCriteria(let ids):
            return "\(ids.count) acceptance criterion/criteria are unmet"
        case .missingRequiredStep(let name):
            return "required step \(name) has no evidence"
        case .requiredStepNotPassed(let name, let status):
            return "required step \(name) is \(status.rawValue)"
        case .optionalStepFailed(let name):
            return "optional step \(name) failed"
        case .requiredStepUnknownRecipeVersion(let name, _):
            return "required step \(name) has an unknown recipe version"
        case .requiredStepFingerprintMissing(let name):
            return "required step \(name) has no workspace fingerprint"
        case .requiredStepFingerprintMismatch(let name, _, _):
            return "required step \(name) ran on a different revision"
        case .openBlockingFindings(let ids):
            return "\(ids.count) open blocking review finding(s)"
        case .acceptanceApprovalAttemptMismatch:
            return "the approval binds another attempt"
        case .acceptanceApprovalFingerprintMismatch:
            return "the approval binds different content"
        case .acceptanceApprovalMissingActor:
            return "the approval records no human actor"
        }
    }
}
