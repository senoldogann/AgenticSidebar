import XCTest
@testable import AgenticSidebar

final class OpenCodeStreamNormalizerTests: XCTestCase {
    func testTextDeltaArrivingBeforePartTypeIsBufferedThenFlushed() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(
            try normalizer.consume(
                line: #"data: {"type":"message.part.delta","properties":{"sessionID":"ses_target","messageID":"msg_1","partID":"prt_1","field":"text","delta":"Hel"}}"#
            ),
            []
        )
        XCTAssertEqual(
            try normalizer.consume(
                line: #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_1","sessionID":"ses_target","messageID":"msg_1","type":"text","text":"Hel"},"time":1}}"#
            ),
            [.assistantTextDelta("Hel")]
        )
        XCTAssertEqual(
            try normalizer.consume(
                line: #"data: {"type":"message.part.delta","properties":{"sessionID":"ses_target","messageID":"msg_1","partID":"prt_1","field":"text","delta":"lo"}}"#
            ),
            [.assistantTextDelta("lo")]
        )
    }

    func testReasoningDeltaIsNeverExposedAsAssistantText() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(
            try normalizer.consume(
                line: #"data: {"type":"message.part.delta","properties":{"sessionID":"ses_target","messageID":"msg_1","partID":"prt_reason","field":"text","delta":"private reasoning"}}"#
            ),
            []
        )
        XCTAssertEqual(
            try normalizer.consume(
                line: #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_reason","sessionID":"ses_target","messageID":"msg_1","type":"reasoning","text":"private reasoning","time":{"start":1}},"time":1}}"#
            ),
            []
        )
        XCTAssertEqual(
            try normalizer.consume(
                line: #"data: {"type":"message.part.delta","properties":{"sessionID":"ses_target","messageID":"msg_1","partID":"prt_reason","field":"text","delta":" more"}}"#
            ),
            []
        )
    }

    func testToolRunningAndCompletedMapToProviderEvents() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(
            try normalizer.consume(
                line: #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_tool","sessionID":"ses_target","messageID":"msg_1","type":"tool","callID":"call_1","tool":"bash","state":{"status":"running","input":{},"time":{"start":1}}},"time":1}}"#
            ),
            [.toolStarted("bash")]
        )
        XCTAssertEqual(
            try normalizer.consume(
                line: #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_tool","sessionID":"ses_target","messageID":"msg_1","type":"tool","callID":"call_1","tool":"bash","state":{"status":"completed","input":{},"output":"ok","title":"done","metadata":{},"time":{"start":1,"end":2}}},"time":2}}"#
            ),
            [.toolFinished]
        )
    }

    func testTargetSessionIdleCompletesAndUnrelatedSessionIsIgnored() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(
            try normalizer.consume(
                line: #"data: {"type":"session.status","properties":{"sessionID":"ses_other","status":{"type":"idle"}}}"#
            ),
            []
        )
        XCTAssertEqual(
            try normalizer.consume(
                line: #"data: {"type":"session.status","properties":{"sessionID":"ses_target","status":{"type":"busy"}}}"#
            ),
            []
        )
        XCTAssertEqual(
            try normalizer.consume(
                line: #"data: {"type":"session.status","properties":{"sessionID":"ses_target","status":{"type":"idle"}}}"#
            ),
            [.completed]
        )
    }

    func testTargetSessionErrorThrowsUnexpectedResponse() {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertThrowsError(
            try normalizer.consume(
                line: #"data: {"type":"session.error","properties":{"sessionID":"ses_target","error":{"name":"UnknownError","data":{"message":"sensitive backend detail"}}}}"#
            )
        ) { error in
            XCTAssertEqual(error as? ProviderRuntimeError, .unexpectedResponse)
        }
    }

    func testSSEControlLinesAndUnknownEventsAreIgnored() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(try normalizer.consume(line: ""), [])
        XCTAssertEqual(try normalizer.consume(line: "event: message.part.delta"), [])
        XCTAssertEqual(
            try normalizer.consume(
                line: #"data: {"type":"server.connected","properties":{}}"#
            ),
            []
        )
    }
}
