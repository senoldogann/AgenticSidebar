import XCTest

@testable import AgenticSidebar

final class OpenAIStreamDecoderTests: XCTestCase {
    func testOutputTextDeltaMapsToAssistantText() throws {
        let events = try OpenAIStreamDecoder.decode(
            line: #"data: {"type":"response.output_text.delta","delta":"Hello"}"#
        )

        XCTAssertEqual(events, [.assistantTextDelta("Hello")])
    }

    func testRefusalDeltaMapsToAssistantText() throws {
        let events = try OpenAIStreamDecoder.decode(
            line: #"data: {"type":"response.refusal.delta","delta":"I can’t help with that."}"#
        )

        XCTAssertEqual(events, [.assistantTextDelta("I can’t help with that.")])
    }

    /// Akıl yürütme özeti asistan metni değil, thinking kanalıdır.
    func testReasoningSummaryDeltasMapToThinking() throws {
        for type in ["response.reasoning_summary_text.delta", "response.reasoning_text.delta"] {
            let events = try OpenAIStreamDecoder.decode(
                line: #"data: {"type":"\#(type)","delta":"Considering options"}"#
            )

            XCTAssertEqual(events, [.thinkingDelta("Considering options")])
        }
    }

    func testReasoningDeltaWithoutPayloadIsSkipped() throws {
        XCTAssertEqual(
            try OpenAIStreamDecoder.decode(
                line: #"data: {"type":"response.reasoning_summary_text.delta"}"#
            ),
            []
        )
    }

    func testCompletedMapsToProviderCompletion() throws {
        let events = try OpenAIStreamDecoder.decode(
            line: #"data: {"type":"response.completed","response":{"status":"completed"}}"#
        )

        XCTAssertEqual(events, [.completed])
    }

    func testCompletedWithUsageEmitsTurnUsageFirst() throws {
        let events = try OpenAIStreamDecoder.decode(
            line: #"data: {"type":"response.completed","response":{"status":"completed","#
                + #""usage":{"input_tokens":23841,"output_tokens":1204,"total_tokens":25045}}}"#
        )

        XCTAssertEqual(
            events,
            [
                .turnUsage(TurnTokenUsage(inputTokens: 23841, outputTokens: 1204)),
                .completed,
            ]
        )
    }

    func testCompletedWithPartialUsageEmitsOnlyCompletion() throws {
        let events = try OpenAIStreamDecoder.decode(
            line: #"data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":100}}}"#
        )

        XCTAssertEqual(events, [.completed])
    }

    func testUnrelatedEventsAndSSEControlLinesAreIgnored() throws {
        XCTAssertEqual(try OpenAIStreamDecoder.decode(line: "event: response.created"), [])
        XCTAssertEqual(try OpenAIStreamDecoder.decode(line: ""), [])
        XCTAssertEqual(
            try OpenAIStreamDecoder.decode(
                line: #"data: {"type":"response.output_item.added"}"#
            ),
            []
        )
    }

    func testFailedIncompleteAndErrorEventsThrowUnexpectedResponse() {
        for type in ["response.failed", "response.incomplete", "error"] {
            XCTAssertThrowsError(
                try OpenAIStreamDecoder.decode(
                    line: #"data: {"type":"\#(type)"}"#
                )
            ) { error in
                XCTAssertEqual(error as? ProviderRuntimeError, .unexpectedResponse)
            }
        }
    }

    func testMalformedDataEventThrowsUnexpectedResponse() {
        XCTAssertThrowsError(
            try OpenAIStreamDecoder.decode(line: "data: {not-json}")
        ) { error in
            XCTAssertEqual(error as? ProviderRuntimeError, .unexpectedResponse)
        }
    }
}
