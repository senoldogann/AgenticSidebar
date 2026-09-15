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
