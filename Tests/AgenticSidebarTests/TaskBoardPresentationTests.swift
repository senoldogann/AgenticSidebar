import Foundation
import XCTest

@testable import AgenticSidebar

// MARK: - Fixtures

/// Görev panosu sunum testlerinin kullandığı sabit projeksiyonlar.
private enum TaskBoardFixtures {
    static let projectID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    static func card(
        id: UUID = UUID(),
        title: String = "Görev",
        objective: String = "Amaç",
        priority: Int = 1,
        status: TaskStatus = .backlog,
        stage: TaskStage = .analysis,
        blockReason: TaskBlockReason? = nil,
        previousStageBeforeBlock: TaskStage? = nil,
        version: Int = 1,
        currentAttemptID: UUID? = nil,
        activeAttempt: TaskBoardAttemptSummary? = nil,
        unmetPrerequisiteIDs: [UUID] = [],
        criteriaCompleted: Int = 0,
        criteriaTotal: Int = 0,
        budget: ExecutionBudget = ExecutionBudget(),
        updatedAt: Date = TaskBoardFixtures.fixedDate
    ) -> TaskBoardCard {
        TaskBoardCard(
            id: id,
            projectID: projectID,
            title: title,
            objective: objective,
            priority: priority,
            status: status,
            stage: stage,
            blockReason: blockReason,
            previousStageBeforeBlock: previousStageBeforeBlock,
            version: version,
            currentAttemptID: currentAttemptID,
            activeAttempt: activeAttempt,
            unmetPrerequisiteIDs: unmetPrerequisiteIDs,
            criteriaCompleted: criteriaCompleted,
            criteriaTotal: criteriaTotal,
            budget: budget,
            updatedAt: updatedAt
        )
    }

    static func availability(
        _ action: TaskBoardAction,
        isEnabled: Bool,
        disabledReason: String?
    ) -> TaskBoardActionAvailability {
        TaskBoardActionAvailability(
            action: action,
            isEnabled: isEnabled,
            disabledReason: disabledReason
        )
    }

    /// Her eylemi kapalı, verilen gerekçeli bir availability listesi üretir.
    static func disabledEverything(
        except enabled: Set<TaskBoardAction> = [],
        reason: String = "kullanılamaz"
    ) -> [TaskBoardActionAvailability] {
        TaskBoardAction.allCases.map { action in
            availability(action, isEnabled: enabled.contains(action), disabledReason: enabled.contains(action) ? nil : reason)
        }
    }
}

/// Pano, rozet, eylem çubuğu ve store matrisinin sunum testleri.
///
/// Tümü tek sınıfta toplanır çünkü planlanan filtre (`--filter
/// TaskBoardPresentationTests`) bu sınıfı hedefler; SwiftUI gövdeleri test
/// edilmez, saf sunum fonksiyonları ve store projeksiyonları doğrudan sınanır.
@MainActor
final class TaskBoardPresentationTests: XCTestCase {

    // MARK: - Board layout

    func testEveryStatusMapsToItsColumnOrDedicatedSection() {
        XCTAssertEqual(TaskBoardPresenter.column(for: .backlog), .backlog)
        XCTAssertEqual(TaskBoardPresenter.column(for: .ready), .ready)
        XCTAssertEqual(TaskBoardPresenter.column(for: .running), .running)
        XCTAssertEqual(TaskBoardPresenter.column(for: .review), .review)
        XCTAssertEqual(TaskBoardPresenter.column(for: .done), .done)
        XCTAssertNil(
            TaskBoardPresenter.column(for: .blocked),
            "Engellenen görev beş kolondan birine düşmemeli; ayrı ve belirgin bir bölümü var"
        )
        XCTAssertNil(
            TaskBoardPresenter.column(for: .cancelled),
            "İptal edilen görev arşiv bölümünde yaşar, aktif kolonlarda değil"
        )
    }

    func testEveryColumnKindKeepsADistinctStatusInCanonicalOrder() {
        XCTAssertEqual(
            TaskBoardColumnKind.allCases.map(\.rawValue),
            ["backlog", "ready", "running", "review", "done"]
        )
        for kind in TaskBoardColumnKind.allCases {
            XCTAssertEqual(TaskBoardPresenter.column(for: kind.status), kind)
            XCTAssertFalse(kind.title.isEmpty)
        }
    }

    func testPresentPartitionsCardsWithoutLosingAnyCard() {
        let blocked = TaskBoardFixtures.card(title: "Engelli", status: .blocked, blockReason: .rateLimited)
        let cancelled = TaskBoardFixtures.card(title: "İptal", status: .cancelled)
        let running = TaskBoardFixtures.card(title: "Koşan", status: .running)
        let backlog = TaskBoardFixtures.card(title: "Kuyruk", status: .backlog)

        let presentation = TaskBoardPresenter.present(
            cards: [backlog, running, blocked, cancelled],
            state: .loaded
        )

        XCTAssertEqual(presentation.columns.map(\.kind), TaskBoardColumnKind.allCases)
        XCTAssertEqual(presentation.columns.first { $0.kind == .backlog }?.cards.map(\.id), [backlog.id])
        XCTAssertEqual(presentation.columns.first { $0.kind == .running }?.cards.map(\.id), [running.id])
        XCTAssertEqual(presentation.blockedCards.map(\.id), [blocked.id])
        XCTAssertEqual(presentation.cancelledCards.map(\.id), [cancelled.id])

        let presented =
            presentation.columns.flatMap(\.cards).map(\.id)
            + presentation.blockedCards.map(\.id)
            + presentation.cancelledCards.map(\.id)
        XCTAssertEqual(Set(presented), Set([backlog.id, running.id, blocked.id, cancelled.id]))
    }

    func testBlockedFilterIsProminentExactlyWhenBlockedCardsExist() {
        let quiet = TaskBoardPresenter.present(cards: [TaskBoardFixtures.card()], state: .loaded)
        XCTAssertFalse(quiet.blockedFilter.isProminent)
        XCTAssertFalse(quiet.blockedFilter.accessibilityLabel.isEmpty)

        let loud = TaskBoardPresenter.present(
            cards: [
                TaskBoardFixtures.card(status: .blocked, blockReason: .rateLimited),
                TaskBoardFixtures.card(status: .blocked, blockReason: .approvalRequired),
            ],
            state: .loaded
        )
        XCTAssertTrue(loud.blockedFilter.isProminent)
        XCTAssertEqual(loud.blockedFilter.count, 2)
        XCTAssertTrue(loud.blockedFilter.label.contains("2"))
        XCTAssertTrue(loud.blockedFilter.accessibilityLabel.contains("2"))
    }

    func testCancelledHistoryNamesItsCount() {
        let empty = TaskBoardPresenter.present(cards: [], state: .loaded)
        XCTAssertTrue(empty.cancelledHistoryLabel.contains("İptal"))

        let withHistory = TaskBoardPresenter.present(
            cards: [TaskBoardFixtures.card(status: .cancelled), TaskBoardFixtures.card(status: .cancelled)],
            state: .loaded
        )
        XCTAssertTrue(withHistory.cancelledHistoryLabel.contains("2"))
        XCTAssertEqual(withHistory.cancelledCards.count, 2)
    }

    func testLoadingAndFailureBannersAreHonest() {
        XCTAssertEqual(TaskBoardPresenter.banner(state: .loading)?.kind, .loading)
        XCTAssertNil(TaskBoardPresenter.banner(state: .loaded))

        let failure = TaskBoardPresenter.banner(state: .failed(message: "Pano okunamadı (db)"))
        XCTAssertEqual(failure?.kind, .failure)
        XCTAssertEqual(failure?.message, "Pano okunamadı (db)")
        XCTAssertTrue(failure?.accessibilityLabel.contains("Pano okunamadı (db)") == true)

        let presentation = TaskBoardPresenter.present(
            cards: [TaskBoardFixtures.card()],
            state: .failed(message: "Pano okunamadı (db)")
        )
        XCTAssertEqual(presentation.banner?.kind, .failure)
        XCTAssertEqual(presentation.columns.flatMap(\.cards).count, 1, "Hata son bilinen kartları silmemeli")
    }

    func testEmptyMessagesDistinguishMissingProjectFromMissingTasks() {
        XCTAssertEqual(TaskBoardPresenter.present(cards: [], state: .idle).emptyMessage, "Proje seçilmedi")
        XCTAssertEqual(
            TaskBoardPresenter.present(cards: [], state: .loaded).emptyMessage,
            "Bu projede henüz görev yok"
        )
        XCTAssertNil(TaskBoardPresenter.present(cards: [TaskBoardFixtures.card()], state: .loaded).emptyMessage)
        XCTAssertNil(
            TaskBoardPresenter.present(cards: [], state: .loading).emptyMessage,
            "Yükleme sürerken boş mesajı gösterilmez"
        )
    }

    func testDropFeedbackIsNotATransitionAndNeverMutatesStatus() {
        let feedback = TaskBoardPresenter.dropFeedback(target: .running)

        XCTAssertFalse(feedback.mutatesStatus)
        XCTAssertEqual(feedback.target, .running)
        XCTAssertTrue(feedback.message.lowercased().contains("sürükle"))
        XCTAssertTrue(feedback.message.contains("durum"))
    }

    func testKeyboardFocusOrderIsDeterministic() {
        let backlog = TaskBoardFixtures.card(title: "Kuyruk", status: .backlog)
        let running = TaskBoardFixtures.card(title: "Koşan", status: .running)
        let blocked = TaskBoardFixtures.card(title: "Engelli", status: .blocked, blockReason: .rateLimited)
        let cancelled = TaskBoardFixtures.card(title: "İptal", status: .cancelled)

        let actions = TaskActionBarPresenter.actions(
            availability: TaskBoardFixtures.disabledEverything(except: [.stop]),
            isInFlight: false,
            actor: "reviewer",
            feedback: "geri bildirim"
        )

        let expected: [TaskBoardFocusTarget] = [
            .card(backlog.id),
            .card(running.id),
            .card(blocked.id),
            .card(cancelled.id),
            .action(.stop),
        ]
        let first = TaskBoardPresenter.keyboardFocusOrder(cards: [backlog, running, blocked, cancelled], actions: actions)
        let second = TaskBoardPresenter.keyboardFocusOrder(cards: [backlog, running, blocked, cancelled], actions: actions)
        XCTAssertEqual(first, expected)
        XCTAssertEqual(second, expected)
    }

    // MARK: - Verification badge

    private func evidence(
        taskID: UUID,
        attemptID: UUID,
        status: VerificationEvidenceStatus,
        fingerprint: String?,
        blockedBy: String? = nil,
        step: String = "build"
    ) -> VerificationEvidence {
        VerificationEvidence(
            taskID: taskID,
            attemptID: attemptID,
            recipeName: "recipe",
            stepName: step,
            status: status,
            detailsRedacted: "redacted",
            workspaceFingerprint: fingerprint,
            blockedBy: blockedBy,
            recordedAt: TaskBoardFixtures.fixedDate
        )
    }

    func testPassedEvidenceOnCurrentFingerprintIsVerified() {
        let attemptID = UUID()
        let card = TaskBoardFixtures.card(status: .review, currentAttemptID: attemptID)
        let badge = TaskBoardPresenter.verificationBadge(
            card: card,
            evidence: [evidence(taskID: card.id, attemptID: attemptID, status: .passed, fingerprint: "fp-current")],
            currentFingerprint: "fp-current"
        )
        XCTAssertEqual(badge, .verified)
        XCTAssertFalse(badge.isStale)
    }

    func testEvidenceFromOlderFingerprintIsStaleAndNamesBothFingerprints() {
        let attemptID = UUID()
        let card = TaskBoardFixtures.card(status: .review, currentAttemptID: attemptID)
        let badge = TaskBoardPresenter.verificationBadge(
            card: card,
            evidence: [evidence(taskID: card.id, attemptID: attemptID, status: .passed, fingerprint: "fp-old")],
            currentFingerprint: "fp-new"
        )

        guard case .stale(let reason) = badge else {
            XCTFail("Eski parmak izli kanıt stale olmalı, gelen: \(badge)")
            return
        }
        XCTAssertTrue(badge.isStale)
        XCTAssertTrue(reason.contains("fp-old"))
        XCTAssertTrue(reason.contains("fp-new"))
        XCTAssertTrue(badge.accessibilityLabel?.contains(reason) == true)
    }

    func testMissingFingerprintCanNeverClaimVerification() {
        let attemptID = UUID()
        let card = TaskBoardFixtures.card(status: .review, currentAttemptID: attemptID)
        let badge = TaskBoardPresenter.verificationBadge(
            card: card,
            evidence: [evidence(taskID: card.id, attemptID: attemptID, status: .passed, fingerprint: nil)],
            currentFingerprint: "fp-current"
        )
        XCTAssertNotEqual(badge, .verified)
        guard case .stale = badge else {
            XCTFail("Parmak izi bilinmeyen kanıt doğrulama iddia edemez, gelen: \(badge)")
            return
        }
    }

    func testFailedEvidenceCarriesBlockedByReason() {
        let attemptID = UUID()
        let card = TaskBoardFixtures.card(status: .blocked, blockReason: .verificationFailed("exit 1"))
        let badge = TaskBoardPresenter.verificationBadge(
            card: card,
            evidence: [
                evidence(
                    taskID: card.id,
                    attemptID: attemptID,
                    status: .failed,
                    fingerprint: "fp-current",
                    blockedBy: "workspace değişti"
                )
            ],
            currentFingerprint: "fp-current"
        )

        guard case .failed(let reason) = badge else {
            XCTFail("Başarısız kanıt failed olmalı, gelen: \(badge)")
            return
        }
        XCTAssertTrue(reason.contains("workspace değişti"))
        XCTAssertTrue(badge.accessibilityLabel?.contains("workspace değişti") == true)
    }

    func testNotWiredEvidenceIsExplicitRatherThanGreen() {
        let card = TaskBoardFixtures.card(status: .review)
        let badge = TaskBoardPresenter.verificationBadge(card: card, evidence: nil, currentFingerprint: nil)
        XCTAssertEqual(badge, .notWired)
        XCTAssertNotEqual(badge, .verified)
        XCTAssertTrue(badge.accessibilityLabel?.contains("bağlı değil") == true)
    }

    func testBoardCardsDefaultToNotLoadedBadgeRatherThanAnyClaim() {
        let card = TaskBoardFixtures.card()
        let presentation = TaskBoardPresenter.card(card, verification: .notLoaded)
        XCTAssertFalse(
            presentation.accessibilityLabel.contains("doğrulandı"),
            "Kanıtsız pano kartı doğrulama iddia etmez"
        )
        XCTAssertNil(TaskBoardVerificationBadge.notLoaded.accessibilityLabel)
    }

    // MARK: - Action presentation (pure)

    func testCanonicalOrderIsStableAndComplete() {
        let actions = TaskActionBarPresenter.actions(
            availability: TaskBoardFixtures.disabledEverything(),
            isInFlight: false,
            actor: "reviewer",
            feedback: "geri bildirim"
        )
        XCTAssertEqual(
            actions.map(\.action),
            [.start, .pause, .resume, .stop, .retry, .requestChanges, .accept, .reopen]
        )
        XCTAssertEqual(Set(actions.map(\.action)), Set(TaskBoardAction.allCases))
    }

    func testEveryDisabledActionCarriesItsReasonInTitleHintAndLabel() {
        let actions = TaskActionBarPresenter.actions(
            availability: TaskBoardFixtures.disabledEverything(reason: "Pano eskidi"),
            isInFlight: false,
            actor: "reviewer",
            feedback: "geri bildirim"
        )
        for action in actions {
            XCTAssertFalse(action.isEnabled)
            XCTAssertEqual(action.disabledReason, "Pano eskidi")
            XCTAssertTrue(action.accessibilityLabel.contains("devre dışı"))
            XCTAssertTrue(action.accessibilityLabel.contains("Pano eskidi"))
            XCTAssertEqual(action.accessibilityHint, "Pano eskidi")
        }
    }

    func testEnabledActionHasNoDisabledReason() {
        let actions = TaskActionBarPresenter.actions(
            availability: TaskBoardFixtures.disabledEverything(except: [.start]),
            isInFlight: false,
            actor: "reviewer",
            feedback: "geri bildirim"
        )
        let start = actions.first { $0.action == .start }
        XCTAssertEqual(start?.isEnabled, true)
        XCTAssertNil(start?.disabledReason)
        XCTAssertFalse(start?.accessibilityLabel.contains("devre dışı") == true)
    }

    func testInFlightDisablesEveryActionWithBusyExplanation() {
        let actions = TaskActionBarPresenter.actions(
            availability: TaskBoardFixtures.disabledEverything(except: [.start]),
            isInFlight: true,
            actor: "reviewer",
            feedback: "geri bildirim"
        )
        for action in actions {
            XCTAssertFalse(action.isEnabled)
            XCTAssertTrue(action.isInFlight)
        }
        let start = actions.first { $0.action == .start }
        XCTAssertEqual(start?.disabledReason, TaskActionBarPresenter.busyExplanation)
        let accept = actions.first { $0.action == .accept }
        XCTAssertEqual(
            accept?.disabledReason,
            "kullanılamaz",
            "Yapısal olarak kapalı eylem kendi gerekçesini korur; yalnızca normalde açık olan eylem 'işlem sürüyor' der"
        )
    }

    func testBlankActorDisablesReviewDecisionsWithExplanation() {
        let actions = TaskActionBarPresenter.actions(
            availability: TaskBoardFixtures.disabledEverything(except: [.accept, .requestChanges]),
            isInFlight: false,
            actor: "   ",
            feedback: "geri bildirim"
        )
        let accept = actions.first { $0.action == .accept }
        let requestChanges = actions.first { $0.action == .requestChanges }
        XCTAssertFalse(accept?.isEnabled == true)
        XCTAssertFalse(requestChanges?.isEnabled == true)
        XCTAssertTrue(accept?.disabledReason?.contains("insan") == true)
        XCTAssertTrue(requestChanges?.disabledReason?.contains("insan") == true)

        let named = TaskActionBarPresenter.actions(
            availability: TaskBoardFixtures.disabledEverything(except: [.accept, .requestChanges]),
            isInFlight: false,
            actor: "reviewer",
            feedback: "geri bildirim"
        )
        XCTAssertTrue(named.first { $0.action == .accept }?.isEnabled == true)
        XCTAssertTrue(named.first { $0.action == .requestChanges }?.isEnabled == true)
    }

    func testDisabledActionWithoutAvailabilityIsExplainedNotSilent() {
        let actions = TaskActionBarPresenter.actions(
            availability: [],
            isInFlight: false,
            actor: "reviewer",
            feedback: "geri bildirim"
        )
        XCTAssertEqual(actions.count, TaskBoardAction.allCases.count)
        for action in actions {
            XCTAssertFalse(action.isEnabled)
            XCTAssertFalse(action.disabledReason?.isEmpty == true)
        }
    }

    // MARK: - Store-backed action matrix

    private func makeProject(service: CodingTaskService) async throws -> CodingProject {
        try await service.createProject(
            name: "Board",
            repositoryPath: "/tmp/agentic-sidebar-taskboard-ui-tests/repo",
            gitIdentity: "dev@example.com",
            protectedRefs: ["main"]
        )
    }

    @discardableResult
    private func seedTask(
        harness: ServiceTestHarness,
        projectID: UUID,
        title: String,
        status: TaskStatus,
        stage: TaskStage,
        blockReason: TaskBlockReason? = nil,
        previousStageBeforeBlock: TaskStage? = nil,
        criteria: [String] = []
    ) async throws -> CodingTask {
        let taskID = UUID()
        let now = harness.clock.now()
        let task = CodingTask(
            id: taskID,
            projectID: projectID,
            title: title,
            objective: "Objective for \(title)",
            priority: 1,
            status: status,
            stage: stage,
            blockReason: blockReason,
            previousStageBeforeBlock: previousStageBeforeBlock,
            version: 1,
            criteria: criteria.map { CodingAcceptanceCriterion(taskID: taskID, description: $0) },
            createdAt: now,
            updatedAt: now
        )
        try await harness.store.createTask(task)
        return task
    }

    private func makeLoadedStore(
        harness: ServiceTestHarness,
        projectID: UUID
    ) async -> TaskBoardStore {
        let store = TaskBoardStore(service: harness.makeService())
        store.selectProject(projectID)
        await store.refresh()
        return store
    }

    private func enabledActions(
        store: TaskBoardStore,
        taskID: UUID,
        actor: String,
        feedback: String
    ) -> Set<TaskBoardAction> {
        let actions = TaskActionBarPresenter.actions(
            availability: store.actionAvailability(for: taskID),
            isInFlight: store.isActionInFlight(for: taskID),
            actor: actor,
            feedback: feedback
        )
        return Set(actions.filter(\.isEnabled).map(\.action))
    }

    func testBacklogCardEnablesOnlyStart() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await seedTask(harness: harness, projectID: project.id, title: "Kuyruk", status: .backlog, stage: .analysis)
        let store = await makeLoadedStore(harness: harness, projectID: project.id)

        XCTAssertEqual(enabledActions(store: store, taskID: task.id, actor: "reviewer", feedback: "geri bildirim"), [.start])
    }

    func testRunningCardEnablesPauseAndStopOnly() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let taskID = UUID()
        let attemptID = UUID()
        let now = harness.clock.now()
        try await harness.store.createTask(
            CodingTask(
                id: taskID,
                projectID: project.id,
                title: "Koşan",
                objective: "Koşan görev",
                priority: 1,
                status: .running,
                stage: .implementation,
                version: 1,
                criteria: [],
                createdAt: now,
                updatedAt: now
            )
        )
        _ = try await harness.store.claimAttempt(
            taskID: taskID,
            expectedVersion: 1,
            attempt: TaskAttempt(
                id: attemptID,
                taskID: taskID,
                attemptSequence: 1,
                role: .developer,
                providerID: "runtime-1",
                modelID: "model-1",
                generation: 1,
                startedAt: now
            )
        )
        let store = await makeLoadedStore(harness: harness, projectID: project.id)

        XCTAssertEqual(enabledActions(store: store, taskID: taskID, actor: "reviewer", feedback: "geri bildirim"), [.pause, .stop])
    }

    func testPausedBlockedCardEnablesResumeAndRetryButNotStart() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await seedTask(
            harness: harness,
            projectID: project.id,
            title: "Duraklatıldı",
            status: .blocked,
            stage: .analysis,
            blockReason: .custom(TaskScheduler.pausedBlockReason),
            previousStageBeforeBlock: .analysis
        )
        let store = await makeLoadedStore(harness: harness, projectID: project.id)

        // Store sözleşmesi: blocked her görev için retry açık, sürdürme yalnızca kullanıcı
        // askıya almasında açık; start ise yalnızca backlog/ready içindir.
        XCTAssertEqual(enabledActions(store: store, taskID: task.id, actor: "reviewer", feedback: "geri bildirim"), [.resume, .retry])
    }

    func testTerminalCardsEnableOnlyReopen() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let done = try await seedTask(harness: harness, projectID: project.id, title: "Bitti", status: .done, stage: .acceptance)
        let cancelled = try await seedTask(harness: harness, projectID: project.id, title: "İptal", status: .cancelled, stage: .analysis)
        let store = await makeLoadedStore(harness: harness, projectID: project.id)

        // Terminal kartlarda yalnız yeniden açma açıktır.
        XCTAssertEqual(enabledActions(store: store, taskID: done.id, actor: "reviewer", feedback: "geri bildirim"), [.reopen])
        XCTAssertEqual(enabledActions(store: store, taskID: cancelled.id, actor: "reviewer", feedback: "geri bildirim"), [.reopen])
    }

    func testReviewCardEnablesRequestChangesAndAcceptOnly() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let seeded = try await harness.seedReviewTask(projectID: project.id, criteriaCompleted: true, evidence: [])
        let store = await makeLoadedStore(harness: harness, projectID: project.id)

        XCTAssertEqual(
            enabledActions(store: store, taskID: seeded.task.id, actor: "reviewer", feedback: "geri bildirim"),
            [.requestChanges, .accept]
        )
    }

    func testUnavailableRuntimeDisablesStartWithMissingCapabilityReason() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await seedTask(harness: harness, projectID: project.id, title: "Desteklenmiyor", status: .backlog, stage: .analysis)
        await harness.providers.setResult(.unsupported(missingCapabilities: ["toolUse"]))
        let store = await makeLoadedStore(harness: harness, projectID: project.id)

        let result = await store.start(taskID: task.id)
        guard case .refused(let refusal) = result else {
            XCTFail("Çalışma ortamı yoksa başlatma reddedilmeli, gelen: \(result)")
            return
        }
        XCTAssertEqual(refusal.kind, .unavailable)

        let actions = TaskActionBarPresenter.actions(
            availability: store.actionAvailability(for: task.id),
            isInFlight: store.isActionInFlight(for: task.id),
            actor: "reviewer",
            feedback: "geri bildirim"
        )
        // Geçici ret sabitlenmez: gerekçe çağrıya döner, düğme bir
        // sonraki denemede yeniden değerlendirilir.
        let start = actions.first { $0.action == .start }
        XCTAssertTrue(start?.isEnabled == true)
    }

    func testBlockedAcceptanceKeepsAcceptDisabledWithGateReasons() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let seeded = try await harness.seedReviewTask(projectID: project.id, criteriaCompleted: false, evidence: [])
        let store = await makeLoadedStore(harness: harness, projectID: project.id)

        let result = await store.accept(taskID: seeded.task.id, actor: "reviewer")
        guard case .refused(let refusal) = result else {
            XCTFail("Kapı kapanmadan kabul reddedilmeli, gelen: \(result)")
            return
        }
        XCTAssertEqual(refusal.kind, .blocked)

        let actions = TaskActionBarPresenter.actions(
            availability: store.actionAvailability(for: seeded.task.id),
            isInFlight: store.isActionInFlight(for: seeded.task.id),
            actor: "reviewer",
            feedback: "geri bildirim"
        )
        let accept = actions.first { $0.action == .accept }
        XCTAssertFalse(accept?.isEnabled == true)
        XCTAssertTrue(accept?.disabledReason?.contains("kabul ölçütü") == true)
        XCTAssertTrue(accept?.accessibilityLabel.contains("kabul ölçütü") == true)
        XCTAssertEqual(
            store.cards.first { $0.id == seeded.task.id }?.status,
            .review,
            "Reddedilen kabul kartı mutasyona uğratmamalı"
        )
    }

    func testInFlightActionDisablesEveryActionWithBusyReason() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await seedTask(harness: harness, projectID: project.id, title: "Uçuşta", status: .backlog, stage: .analysis)
        let store = await makeLoadedStore(harness: harness, projectID: project.id)

        let gate = AsyncGate()
        await harness.repository.gateTaskReads(gate)
        let action = Task { await store.start(taskID: task.id) }
        await gate.waitUntilEntered()
        XCTAssertTrue(store.isActionInFlight(for: task.id))

        let actions = TaskActionBarPresenter.actions(
            availability: store.actionAvailability(for: task.id),
            isInFlight: store.isActionInFlight(for: task.id),
            actor: "reviewer",
            feedback: "geri bildirim"
        )
        XCTAssertTrue(actions.allSatisfy { !$0.isEnabled })
        let start = actions.first { $0.action == .start }
        XCTAssertEqual(
            start?.disabledReason,
            TaskActionBarPresenter.busyExplanation,
            "Normalde açık olan start, uçuş sırasında yalnızca 'işlem sürüyor' gerekçesiyle kapalı olmalı"
        )

        await gate.release()
        let result = await action.value
        XCTAssertEqual(result, .applied)
        let after = TaskActionBarPresenter.actions(
            availability: store.actionAvailability(for: task.id),
            isInFlight: store.isActionInFlight(for: task.id),
            actor: "reviewer",
            feedback: "geri bildirim"
        )
        XCTAssertTrue(after.contains { $0.action == .pause && $0.isEnabled })
    }

    // MARK: - Detail presenter

    private func detail(
        card: TaskBoardCard? = nil,
        criteria: [CodingAcceptanceCriterion] = [],
        dependencies: [TaskDependency] = [],
        attempts: [TaskBoardAttemptSummary] = []
    ) -> TaskBoardTaskDetail {
        TaskBoardTaskDetail(
            card: card ?? TaskBoardFixtures.card(),
            criteria: criteria,
            dependencies: dependencies,
            attempts: attempts
        )
    }

    private func criterion(
        _ taskID: UUID,
        _ text: String,
        isCompleted: Bool = false,
        evidenceID: UUID? = nil
    ) -> CodingAcceptanceCriterion {
        CodingAcceptanceCriterion(
            taskID: taskID,
            description: text,
            isCompleted: isCompleted,
            evidenceID: evidenceID
        )
    }

    private func finding(
        _ taskID: UUID,
        severity: ReviewFindingSeverity,
        summary: String
    ) -> ReviewFinding {
        ReviewFinding(taskID: taskID, severity: severity, summary: summary)
    }

    func testCriteriaLabelsNamePendingCompletionAndEvidencePresence() {
        let taskID = UUID()
        let rows = TaskDetailPresenter.criteria(
            detail(criteria: [
                criterion(taskID, "derleme"),
                criterion(taskID, "testler", isCompleted: true, evidenceID: UUID()),
                criterion(taskID, "doküman", isCompleted: true),
            ])
        )

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].evidenceLabel, "Bekliyor")
        XCTAssertFalse(rows[0].isCompleted)
        XCTAssertEqual(rows[1].evidenceLabel, "Kanıt kayıtlı")
        XCTAssertEqual(rows[2].evidenceLabel, "Kanıt kimliği yok")
        XCTAssertTrue(rows[2].accessibilityLabel.contains("Kanıt kimliği yok"))
        XCTAssertTrue(rows[1].accessibilityLabel.contains("Tamamlandı"))
    }

    func testDependenciesReadSatisfactionOnlyFromBoardCards() {
        let taskID = UUID()
        let doneID = UUID()
        let unknownID = UUID()
        let dependentID = UUID()
        let dependency = TaskDependency(
            projectID: TaskBoardFixtures.projectID,
            prerequisiteTaskID: doneID,
            dependentTaskID: taskID
        )
        let unknownDependency = TaskDependency(
            projectID: TaskBoardFixtures.projectID,
            prerequisiteTaskID: unknownID,
            dependentTaskID: taskID
        )
        let dependentDependency = TaskDependency(
            projectID: TaskBoardFixtures.projectID,
            prerequisiteTaskID: taskID,
            dependentTaskID: dependentID
        )

        let rows = TaskDetailPresenter.dependencies(
            detail(
                card: TaskBoardFixtures.card(id: taskID),
                dependencies: [dependency, unknownDependency, dependentDependency]
            ),
            cards: [
                TaskBoardFixtures.card(id: doneID, title: "Biten", status: .done),
                TaskBoardFixtures.card(id: dependentID, title: "Bağımlı görev", status: .backlog),
            ]
        )

        XCTAssertEqual(rows.count, 3)
        let satisfiedRow = rows.first { $0.taskID == doneID }
        XCTAssertEqual(satisfiedRow?.direction, .prerequisite)
        XCTAssertEqual(satisfiedRow?.title, "Biten")
        XCTAssertEqual(satisfiedRow?.isSatisfied, true)
        XCTAssertTrue(satisfiedRow?.accessibilityLabel.contains("Tamamlandı") == true)

        let unknownRow = rows.first { $0.taskID == unknownID }
        XCTAssertNil(unknownRow?.isSatisfied, "Panoda olmayan önkoşulun tatmini bilinmez, uydurulmaz")
        XCTAssertTrue(unknownRow?.accessibilityLabel.contains("Önkoşul") == true)

        let dependentRow = rows.first { $0.taskID == dependentID }
        XCTAssertEqual(dependentRow?.direction, .dependent)
        XCTAssertNil(dependentRow?.isSatisfied, "Yalnızca önkoşulun tatmini panodan okunur")
        XCTAssertTrue(dependentRow?.accessibilityLabel.contains("Bağımlı") == true)
    }

    func testProviderCapabilityNoticeAppearsOnlyWhenStartIsRefused() {
        let older = TaskBoardAttemptSummary(
            id: UUID(),
            attemptSequence: 1,
            generation: 1,
            role: .developer,
            providerID: "runtime-1",
            modelID: "model-1",
            outcome: .succeeded,
            startedAt: TaskBoardFixtures.fixedDate,
            endedAt: TaskBoardFixtures.fixedDate,
            durationSeconds: 10,
            toolCallCount: 3
        )
        let latest = TaskBoardAttemptSummary(
            id: UUID(),
            attemptSequence: 2,
            generation: 1,
            role: .reviewer,
            providerID: "runtime-2",
            modelID: "model-2",
            outcome: .failed,
            startedAt: TaskBoardFixtures.fixedDate,
            endedAt: TaskBoardFixtures.fixedDate,
            durationSeconds: 20,
            toolCallCount: 4
        )
        let refusal = TaskBoardFixtures.availability(.start, isEnabled: false, disabledReason: "çalışma ortamı yok")
        let backlog = TaskBoardFixtures.card(status: .backlog)

        let capability = TaskDetailPresenter.providerCapability(
            card: backlog,
            attempts: [older, latest],
            startAvailability: refusal
        )
        XCTAssertEqual(capability.providerLabel, "runtime-2")
        XCTAssertEqual(capability.modelLabel, "model-2")
        XCTAssertEqual(capability.notice, "çalışma ortamı yok")
        XCTAssertTrue(capability.accessibilityLabel.contains("çalışma ortamı yok"))

        let running = TaskDetailPresenter.providerCapability(
            card: TaskBoardFixtures.card(status: .running),
            attempts: [],
            startAvailability: refusal
        )
        XCTAssertEqual(running.providerLabel, "Kayıtlı sağlayıcı yok")
        XCTAssertEqual(running.modelLabel, "—")
        XCTAssertNil(running.notice, "Başlatma dışındaki durumlarda yetenek uyarısı gösterilmez")

        let enabled = TaskBoardFixtures.availability(.start, isEnabled: true, disabledReason: nil)
        XCTAssertNil(
            TaskDetailPresenter.providerCapability(card: backlog, attempts: [], startAvailability: enabled).notice
        )
    }

    func testApprovalScopeBindsAttemptVersionAndExplainsDisabledState() {
        let attemptID = UUID()
        let card = TaskBoardFixtures.card(status: .review, version: 4)
        let enabled = TaskDetailPresenter.approval(
            card: card,
            attemptID: attemptID,
            availability: TaskBoardFixtures.availability(.accept, isEnabled: true, disabledReason: nil)
        )
        XCTAssertTrue(enabled.isEnabled)
        XCTAssertNil(enabled.disabledReason)
        XCTAssertTrue(enabled.scopeDescription.contains("sürümü 4"))
        XCTAssertTrue(enabled.scopeDescription.contains(attemptID.uuidString.prefix(8)))
        XCTAssertTrue(enabled.accessibilityLabel.contains("insan aktör"))

        let missingAttempt = TaskDetailPresenter.approval(card: card, attemptID: nil, availability: nil)
        XCTAssertEqual(missingAttempt.scopeDescription, "Onaylanacak aktif deneme yok")
        XCTAssertFalse(missingAttempt.isEnabled)
        XCTAssertTrue(missingAttempt.disabledReason?.isEmpty == false)
        XCTAssertTrue(missingAttempt.accessibilityLabel.contains("Devre dışı"))

        let refused = TaskDetailPresenter.approval(
            card: card,
            attemptID: attemptID,
            availability: TaskBoardFixtures.availability(.accept, isEnabled: false, disabledReason: "ölçütler eksik")
        )
        XCTAssertEqual(refused.disabledReason, "ölçütler eksik")
        XCTAssertTrue(refused.accessibilityLabel.contains("ölçütler eksik"))
    }

    func testEvidenceSummaryNamesWorkspaceRowsAndUnwiredDiff() {
        let card = TaskBoardFixtures.card(status: .review)
        let workspaceID = UUID()
        let summary = TaskDetailPresenter.evidenceSummary(
            card: card,
            evidence: [
                evidence(taskID: card.id, attemptID: UUID(), status: .passed, fingerprint: "fp")
            ],
            currentFingerprint: "fp",
            workspaceID: workspaceID,
            diffSummary: nil
        )

        XCTAssertTrue(summary.isWired)
        XCTAssertEqual(summary.rows.count, 1)
        XCTAssertTrue(summary.worktreeLabel.contains(workspaceID.uuidString.prefix(8)))
        XCTAssertEqual(summary.diffNotice, "Diff özeti bu sürümde bağlı değil", "Bağlanmayan diff açıkça söylenir")
        XCTAssertTrue(summary.accessibilityLabel.contains("1 kanıt kaydı"))

        let unwired = TaskDetailPresenter.evidenceSummary(
            card: card,
            evidence: nil,
            currentFingerprint: nil,
            workspaceID: nil,
            diffSummary: "12 dosya değişti"
        )
        XCTAssertFalse(unwired.isWired)
        XCTAssertTrue(unwired.rows.isEmpty)
        XCTAssertEqual(unwired.worktreeLabel, "Çalışma alanı kaydı yok")
        XCTAssertEqual(unwired.diffNotice, "12 dosya değişti")
    }

    // MARK: - Findings gating

    func testDismissedBlockingFindingIsListedButNeverCountsAsBlocking() throws {
        let taskID = UUID()
        let open = finding(taskID, severity: .critical, summary: "açık kritik")
        let dismissed = try finding(taskID, severity: .critical, summary: "kapatılmış kritik")
            .dismissed(by: "reviewer", reason: "kabul edildi", at: TaskBoardFixtures.fixedDate)

        let presentation = TaskDetailPresenter.findings([open, dismissed])

        XCTAssertTrue(presentation.isWired)
        XCTAssertEqual(presentation.rows.count, 2, "Kapatılan bulgu listeden düşmez")
        XCTAssertEqual(presentation.blockingCount, 1)
        XCTAssertTrue(presentation.accessibilityLabel.contains("1 tanesi kabulü engelliyor"))

        let dismissedRow = presentation.rows.first { $0.id == dismissed.id }
        XCTAssertEqual(dismissedRow?.statusLabel, "Kapatıldı")
        XCTAssertFalse(dismissedRow?.blocksAcceptance == true)
        XCTAssertFalse(dismissedRow?.accessibilityLabel.contains("engelliyor") == true)

        let openRow = presentation.rows.first { $0.id == open.id }
        XCTAssertTrue(openRow?.blocksAcceptance == true)
        XCTAssertTrue(openRow?.accessibilityLabel.contains("Kabulü engelliyor") == true)
        XCTAssertEqual(presentation.rows.first?.id, open.id, "Engelleyen bulgu üstte sıralanır")
    }

    func testOpenFindingsBelowBlockingSeverityAreListedWithoutBlocking() {
        let taskID = UUID()
        let presentation = TaskDetailPresenter.findings([
            finding(taskID, severity: .low, summary: "düşük"),
            finding(taskID, severity: .medium, summary: "orta"),
            finding(taskID, severity: .high, summary: "yüksek"),
        ])

        XCTAssertEqual(presentation.rows.count, 3)
        XCTAssertEqual(presentation.blockingCount, 1, "Yalnızca yüksek ve kritik engeller; bu listede tek yüksek var")
        XCTAssertTrue(presentation.accessibilityLabel.contains("1 tanesi kabulü engelliyor"))
        XCTAssertFalse(presentation.rows.first { $0.summary == "düşük" }?.blocksAcceptance == true)
    }

    func testUnwiredFindingsAreExplicitRatherThanEmpty() {
        let presentation = TaskDetailPresenter.findings(nil)

        XCTAssertFalse(presentation.isWired)
        XCTAssertTrue(presentation.rows.isEmpty)
        XCTAssertEqual(presentation.blockingCount, 0)
        XCTAssertTrue(presentation.accessibilityLabel.contains("bağlı değil"))
    }

    // MARK: - Verification badge tones

    func testBadgeToneIsGreenOnlyForVerified() {
        XCTAssertEqual(TaskBoardVerificationBadge.verified.tone, .positive, "Yeşil yalnızca doğrulanmış kanıta aittir")
        XCTAssertEqual(TaskBoardVerificationBadge.notWired.tone, .neutral)
        XCTAssertEqual(TaskBoardVerificationBadge.missing.tone, .neutral)
        XCTAssertEqual(TaskBoardVerificationBadge.notLoaded.tone, .neutral)
        XCTAssertEqual(TaskBoardVerificationBadge.stale(reason: "fp eski").tone, .warning)
        XCTAssertEqual(TaskBoardVerificationBadge.failed(reason: "exit 1").tone, .negative)
    }

    func testEvidenceRowsCarryFailureStaleAndSkippedTones() {
        let attemptID = UUID()
        let card = TaskBoardFixtures.card(status: .blocked, blockReason: .verificationFailed("exit 1"))
        let summary = TaskDetailPresenter.evidenceSummary(
            card: card,
            evidence: [
                evidence(
                    taskID: card.id,
                    attemptID: attemptID,
                    status: .failed,
                    fingerprint: "fp",
                    blockedBy: "derleme kırıldı",
                    step: "build"
                ),
                evidence(taskID: card.id, attemptID: attemptID, status: .passed, fingerprint: "fp-old", step: "lint"),
                evidence(taskID: card.id, attemptID: attemptID, status: .skipped, fingerprint: nil, step: "e2e"),
            ],
            currentFingerprint: "fp-new",
            workspaceID: nil,
            diffSummary: nil
        )

        XCTAssertEqual(summary.rows.count, 3)
        let failedRow = summary.rows.first { $0.stepLabel.contains("build") }
        XCTAssertEqual(failedRow?.tone, .negative, "Başarısız kanıt satırı kırmızı tonda olmalı")
        XCTAssertEqual(failedRow?.statusLabel, "Başarısız")
        XCTAssertTrue(failedRow?.accessibilityLabel.contains("derleme kırıldı") == true)

        let staleRow = summary.rows.first { $0.stepLabel.contains("lint") }
        XCTAssertEqual(staleRow?.tone, .warning)
        XCTAssertTrue(staleRow?.isStale == true)

        let skippedRow = summary.rows.first { $0.stepLabel.contains("e2e") }
        XCTAssertEqual(skippedRow?.tone, .neutral)

        XCTAssertEqual(summary.badge.tone, .negative, "Başarısız kanıt rozeti de kırmızı tonda olmalı")
    }

    // MARK: - Detail pane states

    func testDetailPaneStateDistinguishesIdleLoadingFailureAndLoaded() {
        let taskID = UUID()
        let loadedDetail = detail(card: TaskBoardFixtures.card(id: taskID))

        XCTAssertEqual(TaskDetailPresenter.paneState(selectedTaskID: nil, detail: nil, lastFailure: "db"), .idle)
        XCTAssertEqual(
            TaskDetailPresenter.paneState(selectedTaskID: taskID, detail: nil, lastFailure: nil),
            .loading(taskID: taskID)
        )
        XCTAssertEqual(
            TaskDetailPresenter.paneState(selectedTaskID: taskID, detail: nil, lastFailure: "Görev okunamadı (db)"),
            .failed(taskID: taskID, message: "Görev okunamadı (db)")
        )
        XCTAssertEqual(
            TaskDetailPresenter.paneState(selectedTaskID: taskID, detail: loadedDetail, lastFailure: "db"),
            .loaded,
            "Yüklü detay son hatayı gölgeler"
        )
    }

    func testDetailPaneIdentityIsStablePerTaskAndDistinctAcrossTasks() {
        let first = UUID()
        let second = UUID()

        XCTAssertEqual(TaskDetailPresenter.paneIdentity(for: first), TaskDetailPresenter.paneIdentity(for: first))
        XCTAssertNotEqual(
            TaskDetailPresenter.paneIdentity(for: first),
            TaskDetailPresenter.paneIdentity(for: second),
            "Görev değişince bölme kimliği değişir ve yerel form durumu sıfırlanır"
        )
    }

    // MARK: - Action refusal surfacing

    func testRefusalMessageIsNilWhenAppliedAndNamesTheRefusal() {
        XCTAssertNil(TaskActionBarPresenter.refusalMessage(.applied))

        let refusal = TaskBoardRefusal(kind: .stale, message: "This task changed since the board loaded")
        let message = TaskActionBarPresenter.refusalMessage(.refused(refusal))
        XCTAssertTrue(message?.contains("uygulanmadı") == true)
        XCTAssertTrue(message?.contains("This task changed since the board loaded") == true)
    }

    // MARK: - Feedback gate

    func testBlankFeedbackDisablesRequestChangesWithItsOwnReason() {
        let availability = TaskBoardFixtures.disabledEverything(except: [.accept, .requestChanges])
        let blank = TaskActionBarPresenter.actions(
            availability: availability,
            isInFlight: false,
            actor: "reviewer",
            feedback: "   "
        )

        let requestChanges = blank.first { $0.action == .requestChanges }
        XCTAssertFalse(requestChanges?.isEnabled == true)
        XCTAssertTrue(requestChanges?.disabledReason?.contains("geri bildirim") == true)
        XCTAssertTrue(requestChanges?.accessibilityLabel.contains("geri bildirim") == true)
        XCTAssertTrue(blank.first { $0.action == .accept }?.isEnabled == true, "Geri bildirim kapısı accept'i bağlamaz")

        let named = TaskActionBarPresenter.actions(
            availability: availability,
            isInFlight: false,
            actor: "reviewer",
            feedback: "şu alanı düzelt"
        )
        XCTAssertTrue(named.first { $0.action == .requestChanges }?.isEnabled == true)
    }

    // MARK: - Primary / overflow split

    func testPrimaryAndOverflowSetsPartitionEveryActionInCanonicalOrder() {
        XCTAssertEqual(TaskActionBarPresenter.primaryActions, [.start, .pause, .resume, .stop, .accept])
        XCTAssertEqual(TaskActionBarPresenter.secondaryActions, [.retry, .requestChanges, .reopen])
        XCTAssertTrue(
            Set(TaskActionBarPresenter.primaryActions)
                .isDisjoint(with: Set(TaskActionBarPresenter.secondaryActions))
        )
        XCTAssertEqual(
            Set(TaskActionBarPresenter.primaryActions).union(TaskActionBarPresenter.secondaryActions),
            Set(TaskBoardAction.allCases),
            "Her eylem tam olarak bir yuvada görünür"
        )
        for subset in [TaskActionBarPresenter.primaryActions, TaskActionBarPresenter.secondaryActions] {
            XCTAssertEqual(
                subset,
                TaskActionBarPresenter.displayOrder.filter { subset.contains($0) },
                "Alt kümeler kanonik sunum sırasını korur"
            )
        }

        let actions = TaskActionBarPresenter.actions(
            availability: TaskBoardFixtures.disabledEverything(except: [.retry, .requestChanges]),
            isInFlight: false,
            actor: "reviewer",
            feedback: "geri bildirim metni"
        )
        XCTAssertEqual(
            TaskActionBarPresenter.primary(actions).map(\.action),
            [.start, .pause, .resume, .stop, .accept]
        )
        XCTAssertEqual(TaskActionBarPresenter.overflow(actions).map(\.action), [.retry, .requestChanges, .reopen])
    }

    // MARK: - Board injection point

    func testBoardViewCarriesInspectorInputWithoutEditingItsBody() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let store = TaskBoardStore(service: harness.makeService())
        let wired = TaskBoardInspectorInput(
            evidence: [],
            currentFingerprint: "fp-current",
            findings: [],
            workspaceID: UUID(),
            diffSummary: "12 dosya değişti"
        )

        let wiredView = TaskBoardView(store: store, preset: AppThemes.allPresets[0], isDark: false, inspectorInput: wired)
        XCTAssertEqual(wiredView.inspectorInput, wired)

        let unwiredView = TaskBoardView(store: store, preset: AppThemes.allPresets[0], isDark: false)
        XCTAssertEqual(unwiredView.inspectorInput, .unwired, "Varsayılan init açıkça unwired sözleşmesini taşır")
    }
}
