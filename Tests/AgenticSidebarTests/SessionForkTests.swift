import Foundation
import XCTest
@testable import AgenticSidebar

/// `SessionFork` saf mantığı ile `AgentSessionService.forkSession` davranışı.
///
/// Çıta: bilinmeyen dönüm noktası `nil` döndürür, kaynak oturuma dokunulmaz,
/// dal ön eki + çapası içerde kalan grupları taşır ve başlık "(branch)" alır.
final class SessionForkTests: XCTestCase {
    // MARK: - Saf plan

    func testPlanSlicesMessagesThroughAnchorInclusive() {
        let messages = [
            ChatMessage(role: .user, text: "Birinci"),
            ChatMessage(role: .assistant, text: "Yanıt"),
            ChatMessage(role: .user, text: "İkinci"),
        ]

        let fork = SessionFork.plan(
            sourceMessages: messages,
            sourceActivityGroups: [],
            sourceAutomaticTitle: "Birinci",
            sourceCustomTitle: nil,
            throughMessageID: messages[1].id
        )

        XCTAssertEqual(fork?.messages.map(\.id), [messages[0].id, messages[1].id])
        XCTAssertEqual(fork?.title, "Birinci (branch)")
    }

    func testPlanReturnsNilForUnknownMessageID() {
        let messages = [ChatMessage(role: .user, text: "Tek")]

        let fork = SessionFork.plan(
            sourceMessages: messages,
            sourceActivityGroups: [],
            sourceAutomaticTitle: "Tek",
            sourceCustomTitle: nil,
            throughMessageID: UUID()
        )

        XCTAssertNil(fork)
    }

    func testPlanKeepsOnlyGroupsAnchoredInsidePrefix() {
        let messages = [
            ChatMessage(role: .user, text: "Birinci"),
            ChatMessage(role: .user, text: "İkinci"),
        ]
        let inside = AgentTurnActivityGroup(
            id: UUID(),
            anchorMessageID: messages[0].id,
            activities: []
        )
        let outside = AgentTurnActivityGroup(
            id: UUID(),
            anchorMessageID: messages[1].id,
            activities: []
        )

        let fork = SessionFork.plan(
            sourceMessages: messages,
            sourceActivityGroups: [inside, outside],
            sourceAutomaticTitle: "Birinci",
            sourceCustomTitle: nil,
            throughMessageID: messages[0].id
        )

        XCTAssertEqual(fork?.activityGroups.map(\.id), [inside.id])
    }

    func testBranchedTitlePrefersCustomTitleAndAvoidsDoubleSuffix() {
        XCTAssertEqual(
            SessionFork.branchedTitle(customTitle: "  Rapor  ", automaticTitle: "Otomatik"),
            "Rapor (branch)"
        )
        XCTAssertEqual(
            SessionFork.branchedTitle(customTitle: "Rapor (branch)", automaticTitle: "Otomatik"),
            "Rapor (branch)"
        )
        XCTAssertEqual(
            SessionFork.branchedTitle(customTitle: "   ", automaticTitle: "Otomatik"),
            "Otomatik (branch)"
        )
    }

    // MARK: - Servis davranışı

    @MainActor
    func testForkSessionCreatesBranchAndLeavesSourceUntouched() {
        let messages = [
            ChatMessage(role: .user, text: "Birinci soru"),
            ChatMessage(role: .assistant, text: "Birinci yanıt"),
            ChatMessage(role: .user, text: "İkinci soru"),
        ]
        let service = AgentSessionService(
            runtimes: [TestProviderRuntime(
                id: ProviderID("test"),
                displayName: "Test",
                models: []
            )],
            state: AgentSessionState(messages: messages)
        )
        let sourceID = service.activeSessionID
        let sourceCount = service.sessions.count

        guard let branchID = service.forkSession(id: sourceID, throughMessageID: messages[1].id) else {
            return XCTFail("Dal oturumu açılamadı")
        }

        XCTAssertNotEqual(branchID, sourceID)
        XCTAssertEqual(service.sessions.count, sourceCount + 1)
        XCTAssertEqual(service.activeSessionID, branchID)

        let branch = service.activeSession
        XCTAssertEqual(branch.state.messages.map(\.id), [messages[0].id, messages[1].id])
        XCTAssertEqual(branch.state.status, .idle)
        XCTAssertTrue(branch.title.hasSuffix(" (branch)"))

        guard let source = service.sessions.first(where: { $0.id == sourceID }) else {
            return XCTFail("Kaynak oturum kayboldu")
        }
        XCTAssertEqual(source.state.messages.map(\.id), messages.map(\.id))
    }

    @MainActor
    func testForkSessionReturnsNilForUnknownSessionOrMessage() {
        let service = AgentSessionService(runtimes: [])
        XCTAssertNil(service.forkSession(id: UUID(), throughMessageID: UUID()))
        XCTAssertNil(service.forkSession(
            id: service.activeSessionID,
            throughMessageID: UUID()
        ))
        XCTAssertEqual(service.sessions.count, 1)
    }
}
