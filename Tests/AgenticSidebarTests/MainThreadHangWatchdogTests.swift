import XCTest

@testable import AgenticSidebar

final class MainThreadHangWatchdogTests: XCTestCase {
    func testMonotonicSecondsMeasuresElapsedInterval() {
        let clock = SuspendingClock()
        let start = clock.now
        let end = start + .seconds(6)
        XCTAssertEqual(
            MainThreadHangWatchdog.monotonicSeconds(since: start, until: end),
            6,
            accuracy: 0.001
        )
    }

    func testMonotonicSecondsReturnsZeroForSameInstant() {
        let now = SuspendingClock().now
        XCTAssertEqual(
            MainThreadHangWatchdog.monotonicSeconds(since: now, until: now),
            0
        )
    }

    func testMonotonicSecondsClampsReversedIntervalToZero() {
        let clock = SuspendingClock()
        let later = clock.now
        let earlier = later - .seconds(3)
        XCTAssertEqual(
            MainThreadHangWatchdog.monotonicSeconds(since: later, until: earlier),
            0
        )
    }

    func testMonotonicSecondsKeepsSubSecondPrecision() {
        let clock = SuspendingClock()
        let start = clock.now
        let end = start + .milliseconds(1500)
        XCTAssertEqual(
            MainThreadHangWatchdog.monotonicSeconds(since: start, until: end),
            1.5,
            accuracy: 0.001
        )
    }
}
