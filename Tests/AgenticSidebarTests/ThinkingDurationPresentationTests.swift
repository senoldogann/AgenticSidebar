import Foundation
import XCTest

@testable import AgenticSidebar

final class ThinkingDurationPresentationTests: XCTestCase {
    private let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testARunningThoughtCountsUpFromItsStart() {
        XCTAssertEqual(
            ThinkingDurationPresentation.text(
                startedAt: startedAt,
                completedAt: nil,
                turnEndedAt: nil,
                isRunning: true,
                hasRunningChildren: false,
                now: startedAt.addingTimeInterval(7)
            ),
            "Thinking for 7s..."
        )
    }

    func testAFinishedThoughtReportsItsOwnDurationRatherThanTheTimeSince() {
        XCTAssertEqual(
            ThinkingDurationPresentation.text(
                startedAt: startedAt,
                completedAt: startedAt.addingTimeInterval(4),
                turnEndedAt: nil,
                isRunning: false,
                hasRunningChildren: false,
                now: startedAt.addingTimeInterval(600)
            ),
            "Thought for 4s",
            "A finished thought must not keep counting while the row stays on screen"
        )
    }

    func testAFinishedThoughtWithRunningToolsReportsBothDurations() {
        XCTAssertEqual(
            ThinkingDurationPresentation.text(
                startedAt: startedAt,
                completedAt: startedAt.addingTimeInterval(4),
                turnEndedAt: nil,
                isRunning: false,
                hasRunningChildren: true,
                now: startedAt.addingTimeInterval(11)
            ),
            "Thought for 4s",
            "The thought row only reports thought duration; overall work is shown in the group header"
        )
    }

    func testDurationsUnderOneSecondAndBackwardsClocksStillReadAsOneSecond() {
        XCTAssertEqual(
            ThinkingDurationPresentation.text(
                startedAt: startedAt,
                completedAt: startedAt.addingTimeInterval(0.2),
                turnEndedAt: nil,
                isRunning: false,
                hasRunningChildren: false,
                now: startedAt
            ),
            "Thought for 1s"
        )

        XCTAssertEqual(
            ThinkingDurationPresentation.text(
                startedAt: startedAt,
                completedAt: nil,
                turnEndedAt: nil,
                isRunning: true,
                hasRunningChildren: false,
                now: startedAt.addingTimeInterval(-30)
            ),
            "Thinking for 1s...",
            "A clock that moved backwards must not print a negative duration"
        )
    }

    func testAThoughtThatNeverFinishedIsMeasuredAgainstNow() {
        XCTAssertEqual(
            ThinkingDurationPresentation.text(
                startedAt: startedAt,
                completedAt: nil,
                turnEndedAt: nil,
                isRunning: false,
                hasRunningChildren: false,
                now: startedAt.addingTimeInterval(9)
            ),
            "Thought for 9s"
        )
    }

    func testVisibleContentRequiresNonBlankOutput() {
        XCTAssertFalse(ThinkingDurationPresentation.hasVisibleContent(output: nil))
        XCTAssertFalse(ThinkingDurationPresentation.hasVisibleContent(output: ""))
        XCTAssertFalse(ThinkingDurationPresentation.hasVisibleContent(output: "   \n  "))
        XCTAssertTrue(ThinkingDurationPresentation.hasVisibleContent(output: "Plan A"))
    }

    func testAFinishedTurnReportsTotalWorkBeyondThinking() {
        XCTAssertEqual(
            ThinkingDurationPresentation.text(
                startedAt: startedAt,
                completedAt: startedAt.addingTimeInterval(3),
                turnEndedAt: startedAt.addingTimeInterval(252),
                isRunning: false,
                hasRunningChildren: false,
                now: startedAt.addingTimeInterval(600)
            ),
            "Thought for 3s"
        )
    }

    func testCompactRunningThoughtOmitsForAndEllipsis() {
        XCTAssertEqual(
            ThinkingDurationPresentation.compactText(
                startedAt: startedAt,
                completedAt: nil,
                turnEndedAt: nil,
                isRunning: true,
                hasRunningChildren: false,
                now: startedAt.addingTimeInterval(3)
            ),
            "Thinking 3s"
        )
    }

    func testCompactFinishedThoughtReadsAsThoughtNs() {
        XCTAssertEqual(
            ThinkingDurationPresentation.compactText(
                startedAt: startedAt,
                completedAt: startedAt.addingTimeInterval(10),
                turnEndedAt: nil,
                isRunning: false,
                hasRunningChildren: false,
                now: startedAt.addingTimeInterval(600)
            ),
            "Thought 10s"
        )
    }

    func testCompactFinishedThoughtFormatsLongDurations() {
        XCTAssertEqual(
            ThinkingDurationPresentation.compactText(
                startedAt: startedAt,
                completedAt: startedAt.addingTimeInterval(100),
                turnEndedAt: nil,
                isRunning: false,
                hasRunningChildren: false,
                now: startedAt.addingTimeInterval(600)
            ),
            "Thought 1m 40s"
        )
    }
}
