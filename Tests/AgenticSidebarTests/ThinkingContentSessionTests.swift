import Foundation
import XCTest

@testable import AgenticSidebar

/// Thinking kanalı (`ProviderEvent.thinkingDelta`) turdaki `.thinking`
/// aktivitesini doldurur: transkripte karışmaz, boş-tur sayılmaz, araç sonrası
/// ikinci reasoning bloğunda kart yeniden açılır.
@MainActor
final class ThinkingContentSessionTests: XCTestCase {
    func testThinkingDeltasAccumulateInThinkingActivity() async throws {
        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        let session = makeSession(pair: pair)
        let turn = try XCTUnwrap(session.submit("Explain this code"))

        pair.continuation.yield(.thinkingDelta("First thought. "))
        pair.continuation.yield(.thinkingDelta("Second."))
        pair.continuation.yield(.assistantTextDelta("Answer"))
        pair.continuation.yield(.completed)
        pair.continuation.finish()
        await turn.value

        let thinking = try XCTUnwrap(
            session.state.activityGroups.flatMap(\.activities).first(where: { $0.kind == .thinking })
        )
        XCTAssertEqual(thinking.output, "First thought. Second.")
        XCTAssertEqual(session.state.messages.last?.text, "Answer")
        XCTAssertEqual(session.state.status, .completed)
        XCTAssertNil(session.state.error)
    }

    /// Yalnız düşünen tur hâlâ boş turdur: ekranda yanıt yoktur.
    func testThinkingOnlyTurnStillReportsEmpty() async throws {
        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        let session = makeSession(pair: pair)
        let turn = try XCTUnwrap(session.submit("Think quietly"))

        pair.continuation.yield(.thinkingDelta("Hmm"))
        pair.continuation.yield(.completed)
        pair.continuation.finish()
        await turn.value

        XCTAssertEqual(session.state.status, .failed)
        XCTAssertEqual(session.state.error, .unexpectedBackendResponse)
        let thinking = try XCTUnwrap(
            session.state.activityGroups.flatMap(\.activities).first(where: { $0.kind == .thinking })
        )
        XCTAssertEqual(thinking.output, "Hmm")
    }

    /// Araç sonrası ikinci reasoning bloğu kapanan kartı yeniden açar.
    func testSecondReasoningBlockAfterToolReopensThinking() async throws {
        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        let session = makeSession(pair: pair)
        let turn = try XCTUnwrap(session.submit("Check then decide"))

        pair.continuation.yield(.thinkingDelta("Plan A"))
        pair.continuation.yield(
            .activityStarted(
                ProviderActivityDescriptor(
                    id: ProviderActivityID("tool_1"), kind: .read,
                    title: "Read", detail: nil, output: nil
                )))
        pair.continuation.yield(
            .activityFinished(
                ProviderActivityID("tool_1"), outcome: .completed, output: "file contents"
            ))
        pair.continuation.yield(.thinkingDelta("Plan B"))
        pair.continuation.yield(.assistantTextDelta("Done"))
        pair.continuation.yield(.completed)
        pair.continuation.finish()
        await turn.value

        let thinking = try XCTUnwrap(
            session.state.activityGroups.flatMap(\.activities).first(where: { $0.kind == .thinking })
        )
        XCTAssertEqual(thinking.output, "Plan APlan B")
        XCTAssertEqual(session.state.status, .completed)
    }

    /// Thinking deltası gelmeyen turda thinking satırı kurulmaz: reasoning
    /// paylaşmayan modellerde boş "Thought" satırı çizilmez.
    func testTurnWithoutThinkingDeltasCreatesNoThinkingActivity() async throws {
        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        let session = makeSession(pair: pair)
        let turn = try XCTUnwrap(session.submit("Read the project"))

        pair.continuation.yield(.assistantTextDelta("Answer"))
        pair.continuation.yield(.completed)
        pair.continuation.finish()
        await turn.value

        XCTAssertTrue(
            session.state.activityGroups.flatMap(\.activities).allSatisfy { $0.kind != .thinking }
        )
        XCTAssertEqual(session.state.status, .completed)
    }

    private func makeSession(
        pair: (stream: AsyncThrowingStream<ProviderEvent, Error>, continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation)
    ) -> AgentSession {
        let runtime = TestProviderRuntime(
            id: ProviderID("opencode"), displayName: "OpenCode",
            models: [
                ProviderModelCapability(
                    id: ProviderModelID("test/model"), displayName: "Test Model", variants: []
                )
            ],
            streamFactory: { _ in ProviderStream(events: pair.stream) }
        )
        return AgentSession(
            runtimes: [runtime],
            state: AgentSessionState(
                configuration: SessionConfiguration(
                    providerID: ProviderID("opencode"),
                    modelID: ProviderModelID("test/model"), variantID: nil
                )
            ))
    }
}
