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

        XCTAssertEqual(fork?.messages.map(\.text), ["Birinci", "Yanıt"])
        XCTAssertEqual(fork?.messages.count, 2)
        XCTAssertTrue(
            Set(fork?.messages.map(\.id) ?? []).isDisjoint(with: Set(messages.map(\.id))),
            "Dal kaynakla aynı mesaj kimliklerini taşırsa bölme depoları karışır"
        )
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

    func testPlanKeepsOnlyGroupsAnchoredInsidePrefix() throws {
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

        XCTAssertEqual(fork?.activityGroups.count, 1)
        let kept = try XCTUnwrap(fork?.activityGroups.first)
        XCTAssertNotEqual(kept.id, inside.id)
        XCTAssertEqual(kept.anchorMessageID, fork?.messages.first?.id)
    }

    func testPlanRemapsActivityIDsAndKeepsAnchorConsistency() {
        let messages = [ChatMessage(role: .user, text: "Birinci")]
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
            throughMessageID: messages[0].id
        )

        let keptActivity = try? XCTUnwrap(fork?.activityGroups.first?.activities.first)
        XCTAssertNotEqual(keptActivity?.id.rawValue, "part_1")
        XCTAssertEqual(keptActivity?.detail, "ls")
        XCTAssertEqual(keptActivity?.output, "ok")
    }

    func testBusySourceDropsTrailingPartialAssistantMessage() {
        let messages = [
            ChatMessage(role: .user, text: "Soru"),
            ChatMessage(role: .assistant, text: "Yarım"),
        ]

        let busy = SessionFork.plan(
            sourceMessages: messages,
            sourceActivityGroups: [],
            sourceAutomaticTitle: "Soru",
            sourceCustomTitle: nil,
            throughMessageID: messages[1].id,
            isSourceBusy: true
        )
        XCTAssertEqual(busy?.messages.map(\.text), ["Soru"])

        let idle = SessionFork.plan(
            sourceMessages: messages,
            sourceActivityGroups: [],
            sourceAutomaticTitle: "Soru",
            sourceCustomTitle: nil,
            throughMessageID: messages[1].id,
            isSourceBusy: false
        )
        XCTAssertEqual(idle?.messages.map(\.text), ["Soru", "Yarım"])
        XCTAssertEqual(idle?.messages.count, 2)
    }

    func testBranchedTitleFallsBackForEmptyBase() {
        XCTAssertEqual(
            SessionFork.branchedTitle(customTitle: nil, automaticTitle: ""),
            "New session (branch)"
        )
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
            runtimes: [
                TestProviderRuntime(
                    id: ProviderID("test"),
                    displayName: "Test",
                    models: []
                )
            ],
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
        XCTAssertEqual(branch.state.messages.map(\.text), ["Birinci soru", "Birinci yanıt"])
        XCTAssertTrue(
            Set(branch.state.messages.map(\.id)).isDisjoint(with: Set(messages.map(\.id)))
        )
        XCTAssertEqual(branch.state.status, .idle)
        XCTAssertTrue(branch.title.hasSuffix(" (branch)"))

        guard let source = service.sessions.first(where: { $0.id == sourceID }) else {
            return XCTFail("Kaynak oturum kayboldu")
        }
        XCTAssertEqual(source.state.messages.map(\.id), messages.map(\.id))
    }

    @MainActor
    func testForkFromABackgroundSessionDoesNotStealFocus() {
        let messages = [ChatMessage(role: .user, text: "Arka plan sorusu")]
        let service = AgentSessionService(
            runtimes: [],
            state: AgentSessionState(messages: messages)
        )
        let backgroundID = service.activeSessionID
        let foregroundID = service.createSession()
        XCTAssertEqual(service.activeSessionID, foregroundID)

        guard let branchID = service.forkSession(id: backgroundID, throughMessageID: messages[0].id) else {
            return XCTFail("Dal oturumu açılamadı")
        }

        XCTAssertNotEqual(branchID, backgroundID)
        XCTAssertEqual(service.activeSessionID, foregroundID)
    }

    @MainActor
    func testForkSessionReturnsNilForUnknownSessionOrMessage() {
        let service = AgentSessionService(runtimes: [])
        XCTAssertNil(service.forkSession(id: UUID(), throughMessageID: UUID()))
        XCTAssertNil(
            service.forkSession(
                id: service.activeSessionID,
                throughMessageID: UUID()
            ))
        XCTAssertEqual(service.sessions.count, 1)
    }
}
