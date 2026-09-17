import XCTest
@testable import AgenticSidebar

final class StreamingTextAccumulatorTests: XCTestCase {
    func testBurstDeltasScheduleOneFlushAndDrainAsOneUpdate() {
        let firstAppend = StreamingTextAccumulator.empty.appending("Hel")

        XCTAssertTrue(firstAppend.shouldScheduleFlush)
        XCTAssertEqual(firstAppend.accumulator.pendingText, "Hel")

        let secondAppend = firstAppend.accumulator.appending("lo")
        let thirdAppend = secondAppend.accumulator.appending(" world")

        XCTAssertFalse(secondAppend.shouldScheduleFlush)
        XCTAssertFalse(thirdAppend.shouldScheduleFlush)

        let drain = thirdAppend.accumulator.draining()

        XCTAssertEqual(drain.text, "Hello world")
        XCTAssertEqual(drain.accumulator, .empty)
    }

    func testEmptyDeltaDoesNotScheduleOrChangeAccumulator() {
        let result = StreamingTextAccumulator.empty.appending("")

        XCTAssertFalse(result.shouldScheduleFlush)
        XCTAssertEqual(result.accumulator, .empty)
    }
}

@MainActor
final class StreamingTextIntervalTests: XCTestCase {
    /// Kısa yanıtlar akıcı kalır; uzun yanıtta boşaltma seyrekleşir, yoksa her
    /// boşaltmada bütün yanıt yeniden ayrıştırılıp arayüz kilitlenir.
    func testTheIntervalGrowsWithTheAnswerLength() {
        XCTAssertEqual(
            AgentSession.streamingTextInterval(forMessageLength: 0, speedMode: .normal),
            .milliseconds(40)
        )
        XCTAssertEqual(
            AgentSession.streamingTextInterval(forMessageLength: 19_999, speedMode: .normal),
            .milliseconds(40)
        )
        XCTAssertEqual(
            AgentSession.streamingTextInterval(forMessageLength: 20_000, speedMode: .normal),
            .milliseconds(90)
        )
        XCTAssertEqual(
            AgentSession.streamingTextInterval(forMessageLength: 79_999, speedMode: .normal),
            .milliseconds(90)
        )
        XCTAssertEqual(
            AgentSession.streamingTextInterval(forMessageLength: 80_000, speedMode: .normal),
            .milliseconds(180)
        )
    }

    func testFastModeUsesFasterStreamingIntervals() {
        XCTAssertEqual(
            AgentSession.streamingTextInterval(forMessageLength: 0, speedMode: .fast),
            .milliseconds(16)
        )
        XCTAssertEqual(
            AgentSession.streamingTextInterval(forMessageLength: 29_999, speedMode: .fast),
            .milliseconds(16)
        )
        XCTAssertEqual(
            AgentSession.streamingTextInterval(forMessageLength: 30_000, speedMode: .fast),
            .milliseconds(40)
        )
        XCTAssertEqual(
            AgentSession.streamingTextInterval(forMessageLength: 80_000, speedMode: .fast),
            .milliseconds(80)
        )
    }
}
