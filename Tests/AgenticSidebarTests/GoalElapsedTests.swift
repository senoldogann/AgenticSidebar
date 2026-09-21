import Foundation
import XCTest

@testable import AgenticSidebar

/// Hedef sayacı: `m:ss` / `h:mm:ss` biçimi ve etiketin motora bağlanması.
/// Panelin kendisi (`TimelineView`) burada koşmaz; dizgi ve veri kancası
/// donanımsız test edilir.
final class GoalElapsedTests: XCTestCase {
    func testFormatsMinutesAndSeconds() {
        XCTAssertEqual(GoalElapsedFormat.text(seconds: 0), "0:00")
        XCTAssertEqual(GoalElapsedFormat.text(seconds: 7), "0:07")
        XCTAssertEqual(GoalElapsedFormat.text(seconds: 65), "1:05")
        XCTAssertEqual(GoalElapsedFormat.text(seconds: 3_599), "59:59")
    }

    func testFormatsHours() {
        XCTAssertEqual(GoalElapsedFormat.text(seconds: 3_600), "1:00:00")
        XCTAssertEqual(GoalElapsedFormat.text(seconds: 3_661), "1:01:01")
    }

    func testNegativeClampsToZero() {
        XCTAssertEqual(GoalElapsedFormat.text(seconds: -12), "0:00")
    }

    @MainActor
    func testLabelShowsEngineElapsed() {
        let start = Date(timeIntervalSince1970: 5_000_000)
        let engine = GoalEngine(
            objective: "Sayaç",
            budget: GoalBudget(maxIterations: 5, maxDurationSeconds: 3_600, maxToolCalls: 300),
            startedAt: start
        )
        let label = GoalElapsedLabel(engine: engine)
        XCTAssertEqual(label.elapsedText(at: start.addingTimeInterval(125)), "2:05")
    }

    @MainActor
    func testLabelIsEmptyWithoutEngine() {
        let label = GoalElapsedLabel(engine: nil)
        XCTAssertEqual(label.elapsedText(at: Date()), "")
    }

    func testStartClockIsNotEmpty() {
        let date = Date(timeIntervalSince1970: 5_000_000)
        XCTAssertFalse(GoalStartFormat.clock(date).isEmpty, "Başlangıç saati boş olmamalı")
        XCTAssertFalse(GoalStartFormat.full(date).isEmpty)
    }
}
