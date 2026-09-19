import Foundation
import XCTest

@testable import AgenticSidebar

final class SessionPresentationStateTests: XCTestCase {
    func testStatusTitlesMatchSessionPhase() {
        XCTAssertEqual(SessionPresentationState(phase: .thinking).statusTitle, "Thinking")
        XCTAssertEqual(SessionPresentationState(phase: .runningTool("Search")).statusTitle, "Running Search")
        XCTAssertEqual(SessionPresentationState(phase: .waiting).statusTitle, "Waiting")
        XCTAssertEqual(SessionPresentationState(phase: .cancelling).statusTitle, "Cancelling")
        XCTAssertEqual(SessionPresentationState(phase: .cancelled).statusTitle, "Cancelled")
        XCTAssertEqual(SessionPresentationState(phase: .completed).statusTitle, "Completed")
        XCTAssertEqual(SessionPresentationState(phase: .failed).statusTitle, "Failed")
    }

    func testSymbolsMatchTerminalAndCancellationPhases() {
        XCTAssertEqual(SessionPresentationState(phase: .cancelling).symbolName, "stop.circle")
        XCTAssertEqual(SessionPresentationState(phase: .cancelled).symbolName, "xmark.circle")
        XCTAssertEqual(SessionPresentationState(phase: .failed).symbolName, "exclamationmark.triangle")
    }

    func testMapsAgentSessionStateIntoPresentationState() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let completedAt = Date(timeIntervalSince1970: 1_012)
        let mappings: [(AgentSessionStatus, SessionPhase)] = [
            (.idle, .idle),
            (.streaming, .thinking),
            (.runningTool("Search"), .runningTool("Search")),
            (.waiting, .waiting),
            (.cancelling, .cancelling),
            (.completed, .completed),
            (.cancelled, .cancelled),
            (.failed, .failed),
        ]

        for (status, expectedPhase) in mappings {
            let presentation = SessionPresentationState(
                agentSessionState: AgentSessionState(
                    status: status,
                    startedAt: startedAt,
                    completedAt: completedAt
                )
            )

            XCTAssertEqual(presentation.phase, expectedPhase)
            XCTAssertEqual(presentation.startedAt, startedAt)
            XCTAssertEqual(presentation.completedAt, completedAt)
        }
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
