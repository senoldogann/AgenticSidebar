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
            actor: "reviewer"
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
        XCTAssertEqual(presentation.verificationBadge, .notLoaded)
        XCTAssertNil(presentation.verificationBadge.accessibilityLabel)
    }

    // MARK: - Action presentation (pure)

    func testCanonicalOrderIsStableAndComplete() {
        let actions = TaskActionBarPresenter.actions(
            availability: TaskBoardFixtures.disabledEverything(),
            isInFlight: false,
            actor: "reviewer"
        )
        XCTAssertEqual(
            actions.map(\.action),
            [.start, .pause, .resume, .stop, .retry, .requestChanges, .accept]
        )
        XCTAssertEqual(Set(actions.map(\.action)), Set(TaskBoardAction.allCases))
    }

    func testEveryDisabledActionCarriesItsReasonInTitleHintAndLabel() {
        let actions = TaskActionBarPresenter.actions(
            availability: TaskBoardFixtures.disabledEverything(reason: "Pano eskidi"),
            isInFlight: false,
            actor: "reviewer"
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
            actor: "reviewer"
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
            actor: "reviewer"
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
        XCTAssertEqual(TaskActionBarPresenter.busyMessage(isInFlight: true), TaskActionBarPresenter.busyExplanation)
        XCTAssertNil(TaskActionBarPresenter.busyMessage(isInFlight: false))
    }

    func testBlankActorDisablesReviewDecisionsWithExplanation() {
        let actions = TaskActionBarPresenter.actions(
            availability: TaskBoardFixtures.disabledEverything(except: [.accept, .requestChanges]),
            isInFlight: false,
            actor: "   "
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
            actor: "reviewer"
        )
        XCTAssertTrue(named.first { $0.action == .accept }?.isEnabled == true)
        XCTAssertTrue(named.first { $0.action == .requestChanges }?.isEnabled == true)
    }

    func testFailureMessageIsExplicitAndNilSafe() {
        XCTAssertNil(TaskActionBarPresenter.failureMessage(nil))
        let message = TaskActionBarPresenter.failureMessage("Pano okunamadı (db)")
        XCTAssertTrue(message?.contains("Pano okunamadı (db)") == true)
        XCTAssertTrue(message?.contains("uygulanmadı") == true)
    }

    func testDisabledActionWithoutAvailabilityIsExplainedNotSilent() {
        let actions = TaskActionBarPresenter.actions(availability: [], isInFlight: false, actor: "reviewer")
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
        actor: String
    ) -> Set<TaskBoardAction> {
        let actions = TaskActionBarPresenter.actions(
            availability: store.actionAvailability(for: taskID),
            isInFlight: store.isActionInFlight(for: taskID),
            actor: actor
        )
        return Set(actions.filter(\.isEnabled).map(\.action))
    }

    func testBacklogCardEnablesOnlyStart() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await seedTask(harness: harness, projectID: project.id, title: "Kuyruk", status: .backlog, stage: .analysis)
        let store = await makeLoadedStore(harness: harness, projectID: project.id)

        XCTAssertEqual(enabledActions(store: store, taskID: task.id, actor: "reviewer"), [.start])
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

        XCTAssertEqual(enabledActions(store: store, taskID: taskID, actor: "reviewer"), [.pause, .stop])
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
        XCTAssertEqual(enabledActions(store: store, taskID: task.id, actor: "reviewer"), [.resume, .retry])
    }

    func testTerminalCardsEnableNothing() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let done = try await seedTask(harness: harness, projectID: project.id, title: "Bitti", status: .done, stage: .acceptance)
        let cancelled = try await seedTask(harness: harness, projectID: project.id, title: "İptal", status: .cancelled, stage: .analysis)
        let store = await makeLoadedStore(harness: harness, projectID: project.id)

        XCTAssertTrue(enabledActions(store: store, taskID: done.id, actor: "reviewer").isEmpty)
        XCTAssertTrue(enabledActions(store: store, taskID: cancelled.id, actor: "reviewer").isEmpty)
    }

    func testReviewCardEnablesRequestChangesAndAcceptOnly() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let seeded = try await harness.seedReviewTask(projectID: project.id, criteriaCompleted: true, evidence: [])
        let store = await makeLoadedStore(harness: harness, projectID: project.id)

        XCTAssertEqual(
            enabledActions(store: store, taskID: seeded.task.id, actor: "reviewer"),
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
            actor: "reviewer"
        )
        let start = actions.first { $0.action == .start }
        XCTAssertFalse(start?.isEnabled == true)
        XCTAssertTrue(start?.disabledReason?.contains("toolUse") == true)
        XCTAssertTrue(start?.accessibilityLabel.contains("toolUse") == true)
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
            actor: "reviewer"
        )
        let accept = actions.first { $0.action == .accept }
        XCTAssertFalse(accept?.isEnabled == true)
        XCTAssertTrue(accept?.disabledReason?.contains("acceptance criterion") == true)
        XCTAssertTrue(accept?.accessibilityLabel.contains("acceptance criterion") == true)
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
            actor: "reviewer"
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
            actor: "reviewer"
        )
        XCTAssertTrue(after.contains { $0.action == .pause && $0.isEnabled })
    }
}
