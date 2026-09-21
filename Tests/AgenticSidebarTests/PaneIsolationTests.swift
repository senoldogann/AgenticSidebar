import Foundation
import XCTest

@testable import AgenticSidebar

/// Bölmeler arası karışmama garantileri: iki bölme aynı grup kimliğini taşısa
/// (dal!) bile açık/kapalı durumu, taslak kapsamı ve kimlikler birbirine sızmaz.
final class PaneIsolationTests: XCTestCase {
    // MARK: - Collapse durumu oturum-ad-alanlıdır

    @MainActor
    func testGroupCollapseDoesNotLeakAcrossSessions() {
        let store = TimelineCollapseStore()
        let group = UUID()
        let sessionA = UUID()
        let sessionB = UUID()
        // A bölmesinde kapatılan kart B bölmesinde açık kalır.
        store.toggleGroup(groupID: group, sessionID: sessionA, isTurnRunning: true)
        XCTAssertFalse(store.isGroupExpanded(groupID: group, sessionID: sessionA, isTurnRunning: true))
        XCTAssertTrue(store.isGroupExpanded(groupID: group, sessionID: sessionB, isTurnRunning: true))
    }

    @MainActor
    func testActivityCollapseDoesNotLeakAcrossSessions() {
        let store = TimelineCollapseStore()
        let group = UUID()
        let sessionA = UUID()
        let sessionB = UUID()
        let activity = AgentActivity(
            id: ProviderActivityID(UUID().uuidString),
            kind: .command,
            phase: .completed,
            title: "Run",
            detail: "ls",
            output: nil,
            diff: nil,
            startedAt: Date(),
            completedAt: Date()
        )
        store.toggleActivity(activity, groupID: group, sessionID: sessionA, isTurnRunning: false)
        XCTAssertTrue(store.isActivityExpanded(activity, groupID: group, sessionID: sessionA, isTurnRunning: false))
        XCTAssertFalse(store.isActivityExpanded(activity, groupID: group, sessionID: sessionB, isTurnRunning: false))
    }

    @MainActor
    func testRunningThinkingIsExpandedByDefaultWhileTurnRuns() {
        let store = TimelineCollapseStore()
        let thinking = AgentActivity(
            id: ProviderActivityID(UUID().uuidString),
            kind: .thinking,
            phase: .running,
            title: nil,
            detail: nil,
            output: "Adım adım çözüm",
            diff: nil,
            startedAt: Date(),
            completedAt: nil
        )
        XCTAssertTrue(store.isActivityExpanded(thinking, groupID: UUID(), sessionID: UUID(), isTurnRunning: true))
    }

    @MainActor
    func testCompletedThinkingCollapsesByDefaultWhileTurnRuns() {
        let store = TimelineCollapseStore()
        let thinking = AgentActivity(
            id: ProviderActivityID(UUID().uuidString),
            kind: .thinking,
            phase: .completed,
            title: nil,
            detail: nil,
            output: "Adım adım çözüm",
            diff: nil,
            startedAt: Date(),
            completedAt: Date()
        )
        XCTAssertFalse(store.isActivityExpanded(thinking, groupID: UUID(), sessionID: UUID(), isTurnRunning: true))
    }

    @MainActor
    func testManuallyExpandedThinkingStaysOpenAfterCompletion() {
        let store = TimelineCollapseStore()
        let group = UUID()
        let session = UUID()
        let id = ProviderActivityID(UUID().uuidString)
        let running = AgentActivity(
            id: id,
            kind: .thinking,
            phase: .running,
            title: nil,
            detail: nil,
            output: "Adım adım çözüm",
            diff: nil,
            startedAt: Date(),
            completedAt: nil
        )
        store.toggleActivity(running, groupID: group, sessionID: session, isTurnRunning: true)
        XCTAssertFalse(store.isActivityExpanded(running, groupID: group, sessionID: session, isTurnRunning: true))
        let completed = AgentActivity(
            id: id,
            kind: .thinking,
            phase: .completed,
            title: nil,
            detail: nil,
            output: "Adım adım çözüm",
            diff: nil,
            startedAt: Date(),
            completedAt: Date()
        )
        store.toggleActivity(completed, groupID: group, sessionID: session, isTurnRunning: true)
        XCTAssertTrue(store.isActivityExpanded(completed, groupID: group, sessionID: session, isTurnRunning: true))
    }

    @MainActor
    func testLegacyBareKeyIsReadButWritesAreNamespaced() {
        let store = TimelineCollapseStore()
        let group = UUID()
        let session = UUID()
        // Eski çıplak anahtar okunur (sessiz göç), yeni yazma ad-alanlıdır.
        XCTAssertTrue(store.isGroupExpanded(groupID: group, sessionID: session, isTurnRunning: true))
        store.toggleGroup(groupID: group, sessionID: session, isTurnRunning: true)
        XCTAssertTrue(store.collapsedIDs.contains(TimelineCollapseStore.groupKey(group, sessionID: session)))
        XCTAssertFalse(store.collapsedIDs.contains(TimelineCollapseStore.groupKey(group)))
    }

    @MainActor
    func testSessionFilesCardIsExpandedByDefaultAndScopedToSession() {
        let store = TimelineCollapseStore()
        let sessionA = UUID()
        let sessionB = UUID()
        XCTAssertTrue(store.isSessionFilesExpanded(sessionID: sessionA))
        store.setSessionFilesExpanded(false, sessionID: sessionA)
        XCTAssertFalse(store.isSessionFilesExpanded(sessionID: sessionA))
        XCTAssertTrue(store.isSessionFilesExpanded(sessionID: sessionB))
        store.setSessionFilesExpanded(true, sessionID: sessionA)
        XCTAssertTrue(store.isSessionFilesExpanded(sessionID: sessionA))
    }

    // MARK: - Dal kimlikleri kaynakla çakışmaz

    func testForkSharesNoIdentitiesWithSource() {
        let messages = [
            ChatMessage(role: .user, text: "Birinci"),
            ChatMessage(role: .assistant, text: "Yanıt"),
        ]
        let group = AgentTurnActivityGroup(
            id: UUID(),
            anchorMessageID: messages[0].id,
            activities: [
                AgentActivity(
                    id: ProviderActivityID("part_1"),
                    kind: .command,
                    phase: .completed,
                    title: "Run",
                    detail: "ls",
                    output: "ok",
                    diff: nil,
                    startedAt: Date(),
                    completedAt: Date()
                )
            ]
        )
        let fork = SessionFork.plan(
            sourceMessages: messages,
            sourceActivityGroups: [group],
            sourceAutomaticTitle: "Birinci",
            sourceCustomTitle: nil,
            throughMessageID: messages[1].id
        )
        guard let branch = fork else {
            XCTFail("Dal planı kurulamadı")
            return
        }
        XCTAssertTrue(
            Set(branch.messages.map(\.id)).isDisjoint(with: Set(messages.map(\.id))),
            "Dal kaynakla aynı mesaj kimliğini taşırsa collapse deposu karışır"
        )
        guard let branchGroup = branch.activityGroups.first else {
            XCTFail("Çapası içerde kalan grup dala taşınmalıydı")
            return
        }
        XCTAssertNotEqual(branchGroup.id, group.id)
        XCTAssertEqual(branchGroup.anchorMessageID, branch.messages.first?.id)
        XCTAssertTrue(
            Set(branchGroup.activities.map(\.id.rawValue)).isDisjoint(with: ["part_1"]),
            "Dal aktivite kimlikleri yeniden üretilmelidir"
        )
    }

    // MARK: - Izgara iki bölmede aynı sohbeti göstermez

    @MainActor
    func testPinningAcrossSlotsNeverDuplicatesASession() {
        let defaults = UserDefaults(suiteName: "test-pane-\(UUID().uuidString)")!
        let store = SplitLayoutStore(userDefaults: defaults)
        let id = UUID()
        store.pin(id, to: .secondary)
        store.pin(id, to: .quaternary)
        // Takas olur: oturum tek yuvada kalır.
        XCTAssertEqual(store.pinnedSessionIDs, [id])
    }

    @MainActor
    func testValidateDropsDeadSessionsAndPrimaryDuplicatesInQuadSlots() {
        let defaults = UserDefaults(suiteName: "test-pane-\(UUID().uuidString)")!
        let live = UUID()
        let dead = UUID()
        defaults.set(
            ["tertiary:\(dead.uuidString)", "quaternary:\(live.uuidString)"],
            forKey: "SplitLayout.slots"
        )
        let store = SplitLayoutStore(userDefaults: defaults)
        store.validate(liveIDs: [live], primary: live)
        XCTAssertNil(store.sessionID(for: .tertiary))
        // Dördüncül canlıdır ama birincille aynı olamaz.
        XCTAssertNil(store.sessionID(for: .quaternary))
    }
}
