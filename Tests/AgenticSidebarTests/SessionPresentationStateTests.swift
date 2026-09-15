import Foundation
import XCTest
@testable import AgenticSidebar

final class SessionPresentationStateTests: XCTestCase {
    func testStatusTitlesMatchSessionPhase() {
        XCTAssertEqual(SessionPresentationState(phase: .thinking).statusTitle, "Thinking")
        XCTAssertEqual(SessionPresentationState(phase: .runningTool("Search")).statusTitle, "Running Search")
        XCTAssertEqual(SessionPresentationState(phase: .waiting).statusTitle, "Waiting")
        XCTAssertEqual(SessionPresentationState(phase: .completed).statusTitle, "Completed")
    }

    func testElapsedClampsBeforeStartAndFreezesAtCompletion() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let completedAt = Date(timeIntervalSince1970: 1_012)
        let state = SessionPresentationState(
            phase: .completed,
            startedAt: startedAt,
            completedAt: completedAt
        )

        XCTAssertEqual(state.elapsed(at: Date(timeIntervalSince1970: 999)), 0)
        XCTAssertEqual(state.elapsed(at: Date(timeIntervalSince1970: 2_000)), 12)
    }
}
