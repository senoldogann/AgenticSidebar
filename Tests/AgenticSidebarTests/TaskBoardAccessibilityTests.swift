import Foundation
import XCTest

@testable import AgenticSidebar

/// Erişilebilirlik: VoiceOver etiketleri durumu ve gerekçeyi adıyla söyler,
/// klavye sırası deterministiktir, kaynak görünümler renk-dışı bilgi taşır.
final class TaskBoardAccessibilityTests: XCTestCase {

    private enum Fixture {
        static let projectID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

        static func card(
            id: UUID = UUID(),
            title: String = "Görev",
            status: TaskStatus = .backlog,
            stage: TaskStage = .analysis,
            blockReason: TaskBlockReason? = nil,
            unmetPrerequisiteIDs: [UUID] = [],
            criteriaCompleted: Int = 0,
            criteriaTotal: Int = 0
        ) -> TaskBoardCard {
            TaskBoardCard(
                id: id,
                projectID: projectID,
                title: title,
                objective: "Amaç",
                priority: 1,
                status: status,
                stage: stage,
                blockReason: blockReason,
                previousStageBeforeBlock: nil,
                version: 1,
                currentAttemptID: nil,
                activeAttempt: nil,
                unmetPrerequisiteIDs: unmetPrerequisiteIDs,
                criteriaCompleted: criteriaCompleted,
                criteriaTotal: criteriaTotal,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }

        static func availability(
            _ action: TaskBoardAction,
            isEnabled: Bool,
            disabledReason: String?
        ) -> TaskBoardActionAvailability {
            TaskBoardActionAvailability(action: action, isEnabled: isEnabled, disabledReason: disabledReason)
        }

        static func onlyEnabled(_ actions: Set<TaskBoardAction>) -> [TaskBoardActionAvailability] {
            TaskBoardAction.allCases.map { action in
                availability(
                    action,
                    isEnabled: actions.contains(action),
                    disabledReason: actions.contains(action) ? nil : "kapalı"
                )
            }
        }
    }

    // MARK: - Labels

    func testCardLabelNamesStatusAndBlockingReason() {
        let card = Fixture.card(
            title: "Şema değişikliği",
            status: .blocked,
            stage: .implementation,
            blockReason: .unsupportedCapability("toolUse"),
            unmetPrerequisiteIDs: [UUID()],
            criteriaCompleted: 1,
            criteriaTotal: 3
        )

        let presentation = TaskBoardPresenter.card(card, verification: .notLoaded)
        let label = presentation.accessibilityLabel

        XCTAssertTrue(label.contains("Şema değişikliği"))
        XCTAssertTrue(label.contains("Durum: Engellendi"))
        XCTAssertTrue(label.contains("toolUse"), "Engel nedeni etikette adıyla geçmeli")
        XCTAssertTrue(label.contains("1/3"), "Ölçüt ilerlemesi etikette sayıyla görünmeli")
        XCTAssertTrue(label.contains("önkoşul"))
        XCTAssertEqual(presentation.statusLabel, "Engellendi")
        XCTAssertEqual(presentation.blockReasonText, "desteklenmeyen yetenek: toolUse")
    }

    func testVerifiedBadgeNeverSpeaksWithoutAFingerprintWitness() {
        let card = Fixture.card(status: .review)
        let notLoaded = TaskBoardPresenter.card(card, verification: .notLoaded)
        XCTAssertFalse(notLoaded.accessibilityLabel.contains("doğrulandı"))

        let verified = TaskBoardPresenter.card(card, verification: .verified)
        XCTAssertTrue(verified.accessibilityLabel.contains("doğrulandı"))
    }

    func testEveryBadgeKindSpeaksItsStateInsteadOfRelyingOnColor() {
        let badges: [TaskBoardVerificationBadge] = [
            .notLoaded,
            .notWired,
            .missing,
            .verified,
            .stale(reason: "parmak izi fp-old"),
            .failed(reason: "exit 1"),
        ]
        for badge in badges {
            XCTAssertEqual(
                badge.label == nil,
                badge.accessibilityLabel == nil,
                "Görsel etiketi olan her rozet konuşur; renk tek başına bilgi taşımaz"
            )
        }
        XCTAssertTrue(TaskBoardVerificationBadge.failed(reason: "exit 1").accessibilityLabel?.contains("exit 1") == true)
        XCTAssertEqual(TaskBoardVerificationBadge.verified.tone, .positive)
        XCTAssertEqual(TaskBoardVerificationBadge.stale(reason: "fp").tone, .warning)
        XCTAssertEqual(TaskBoardVerificationBadge.failed(reason: "fp").tone, .negative)
    }

    func testEvidenceRowsSpeakFailureStaleAndBlockedReasonInText() {
        let card = Fixture.card(status: .review)
        let summary = TaskDetailPresenter.evidenceSummary(
            card: card,
            evidence: [
                VerificationEvidence(
                    taskID: card.id,
                    attemptID: UUID(),
                    recipeName: "recipe",
                    stepName: "build",
                    status: .failed,
                    detailsRedacted: "redacted",
                    workspaceFingerprint: "fp",
                    blockedBy: "derleme kırıldı",
                    recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
                VerificationEvidence(
                    taskID: card.id,
                    attemptID: UUID(),
                    recipeName: "recipe",
                    stepName: "lint",
                    status: .passed,
                    detailsRedacted: "redacted",
                    workspaceFingerprint: "fp-old",
                    recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
            ],
            currentFingerprint: "fp-new",
            workspaceID: nil,
            diffSummary: nil
        )

        let failedRow = summary.rows.first { $0.stepLabel.contains("build") }
        XCTAssertEqual(failedRow?.tone, .negative)
        XCTAssertTrue(failedRow?.accessibilityLabel.contains("Başarısız") == true)
        XCTAssertTrue(failedRow?.accessibilityLabel.contains("derleme kırıldı") == true)

        let staleRow = summary.rows.first { $0.stepLabel.contains("lint") }
        XCTAssertEqual(staleRow?.tone, .warning)
        XCTAssertTrue(staleRow?.accessibilityLabel.contains("Güncel içerikle eşleşmiyor") == true)
    }

    func testStaleVerificationBadgeSpeaksItsReason() {
        let badge = TaskBoardVerificationBadge.stale(reason: "kanıt parmak izi fp-old, güncel fp-new")
        XCTAssertTrue(badge.isStale)
        XCTAssertTrue(badge.accessibilityLabel?.contains("fp-old") == true)
        XCTAssertTrue(badge.accessibilityLabel?.contains("fp-new") == true)
    }

    func testDisabledActionExposesReasonInLabelAndHint() {
        let actions = TaskActionBarPresenter.actions(
            availability: Fixture.onlyEnabled([]),
            isInFlight: false,
            actor: "reviewer",
            feedback: "geri bildirim"
        )
        for action in actions {
            XCTAssertTrue(action.accessibilityLabel.contains(action.title))
            XCTAssertTrue(action.accessibilityLabel.contains("kapalı"))
            XCTAssertEqual(action.accessibilityHint, "kapalı")
        }
    }

    func testEnabledActionAccessibilityHintDescribesTheInvocation() {
        let actions = TaskActionBarPresenter.actions(
            availability: Fixture.onlyEnabled([.accept]),
            isInFlight: false,
            actor: "reviewer",
            feedback: "geri bildirim"
        )
        let accept = actions.first { $0.action == .accept }
        XCTAssertTrue(accept?.isEnabled == true)
        XCTAssertTrue(accept?.accessibilityHint?.contains("Kabul") == true)
    }

    func testBlockedFilterAndCancelledHistoryExposeCounts() {
        let presentation = TaskBoardPresenter.present(
            cards: [
                Fixture.card(status: .blocked, blockReason: .rateLimited),
                Fixture.card(status: .cancelled),
            ],
            state: .loaded
        )
        XCTAssertTrue(presentation.blockedFilter.accessibilityLabel.contains("1"))
        XCTAssertTrue(presentation.blockedFilter.accessibilityLabel.contains("engellenen"))
        XCTAssertTrue(presentation.cancelledHistoryLabel.contains("1"))
    }

    func testFailureBannerIsAnnouncedWithItsMessage() {
        let banner = TaskBoardPresenter.banner(state: .failed(message: "Pano okunamadı (db)"))
        XCTAssertEqual(banner?.kind, .failure)
        XCTAssertTrue(banner?.accessibilityLabel.contains("Pano okunamadı (db)") == true)
    }

    func testKeyboardTabOrderIsEnabledActionsOnlyInCanonicalOrder() {
        let enabled: Set<TaskBoardAction> = [.start, .stop, .accept]
        let actions = TaskActionBarPresenter.actions(
            availability: Fixture.onlyEnabled(enabled),
            isInFlight: false,
            actor: "reviewer",
            feedback: "geri bildirim"
        )

        let tabOrder = TaskActionBarPresenter.keyboardTabOrder(actions)
        XCTAssertEqual(tabOrder, [.start, .stop, .accept])
        XCTAssertEqual(
            tabOrder,
            TaskActionBarPresenter.keyboardTabOrder(actions),
            "Klavye sırası her çağrıda aynı olmalı"
        )
        XCTAssertEqual(
            tabOrder,
            TaskActionBarPresenter.displayOrder.filter { tabOrder.contains($0) },
            "Klavye sırası kanonik sunum sırasının alt dizisidir"
        )
    }

    func testActivityRowsNameOutcomeProviderAndRole() {
        let attempt = TaskBoardAttemptSummary(
            id: UUID(),
            attemptSequence: 2,
            generation: 1,
            role: .reviewer,
            providerID: "runtime-1",
            modelID: "model-1",
            outcome: .failed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_120),
            durationSeconds: 120,
            toolCallCount: 7
        )

        let rows = TaskActivityPresenter.rows([attempt])
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertEqual(row.sequenceLabel, "Deneme 2")
        XCTAssertEqual(row.outcomeLabel, "Başarısız")
        XCTAssertTrue(row.accessibilityLabel.contains("Başarısız"))
        XCTAssertTrue(row.accessibilityLabel.contains("runtime-1"))
        XCTAssertTrue(row.accessibilityLabel.contains("İnceleyici"))
        XCTAssertTrue(row.accessibilityLabel.contains("7"))
        XCTAssertEqual(TaskActivityPresenter.summary([attempt]), "1 deneme")
        XCTAssertEqual(TaskActivityPresenter.summary([]), "Etkinlik yok")
    }

    // MARK: - Source guards

    func testBoardSurfacesNeverTouchServiceSQLStateMachineOrDragDrop() throws {
        for file in ["TaskBoardView.swift", "TaskDetailView.swift", "TaskActionBar.swift", "TaskActivityView.swift"] {
            let source = try taskBoardSource(named: file)
            for forbidden in ["CodingTaskService", "SQLite", "TaskStateMachine", "onDrop", "dropDestination"] {
                XCTAssertFalse(source.contains(forbidden), "\(file) içinde \(forbidden) yasak")
            }
        }
    }

    /// Odak sırası yalnızca modelde değil, gerçek SwiftUI odak bağlarında da uygulanır.
    func testActionBarBindsFocusInPresenterOrderInsteadOfOnlyModelingIt() throws {
        let source = try taskBoardSource(named: "TaskActionBar.swift")

        XCTAssertTrue(source.contains("@FocusState"), "Eylem çubuğu odak durumunu bağlar")
        XCTAssertTrue(source.contains(".focused("), "Her eylem butonu presenter sırasında odaklanır")
        XCTAssertTrue(source.contains(".focusSection()"), "Eylem çubuğu tek odak bölümü olarak gezinir")
        XCTAssertTrue(source.contains("TaskActionBarPresenter.primary(actions)"), "Görünür butonlar presenter birincil setinden gelir")
        XCTAssertTrue(source.contains("TaskActionBarPresenter.overflow(actions)"), "İkincil eylemler taşma menüsünden gelir")
    }

    private func taskBoardSource(named file: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source =
            testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AgenticSidebar/Views/TaskBoard/\(file)")
        return try String(contentsOf: source, encoding: .utf8)
    }
}
