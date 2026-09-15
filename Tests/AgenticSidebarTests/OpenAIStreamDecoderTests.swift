import XCTest
@testable import AgenticSidebar

final class OpenAIStreamDecoderTests: XCTestCase {
    func testOutputTextDeltaMapsToAssistantText() throws {
        let event = try OpenAIStreamDecoder.decode(
            line: #"data: {"type":"response.output_text.delta","delta":"Hello"}"#
        )

        XCTAssertEqual(event, .assistantTextDelta("Hello"))
    }

    func testRefusalDeltaMapsToAssistantText() throws {
        let event = try OpenAIStreamDecoder.decode(
            line: #"data: {"type":"response.refusal.delta","delta":"I can’t help with that."}"#
        )

        XCTAssertEqual(event, .assistantTextDelta("I can’t help with that."))
    }

    func testCompletedMapsToProviderCompletion() throws {
        let event = try OpenAIStreamDecoder.decode(
            line: #"data: {"type":"response.completed","response":{"status":"completed"}}"#
        )

        XCTAssertEqual(event, .completed)
    }

    func testUnrelatedEventsAndSSEControlLinesAreIgnored() throws {
        XCTAssertNil(try OpenAIStreamDecoder.decode(line: "event: response.created"))
        XCTAssertNil(try OpenAIStreamDecoder.decode(line: ""))
        XCTAssertNil(
            try OpenAIStreamDecoder.decode(
                line: #"data: {"type":"response.output_item.added"}"#
            )
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
