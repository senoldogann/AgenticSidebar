import Foundation
import XCTest

@testable import AgenticSidebar

@MainActor
final class SessionComposerPrefsTests: XCTestCase {
    func testSessionsStartFromTheSharedDefault() {
        let prefs = SessionComposerPrefs()

        XCTAssertEqual(
            prefs.effectiveAgentMode(for: UUID(), default: .build),
            .build
        )
        XCTAssertEqual(
            prefs.effectiveSpeedMode(for: UUID(), default: .normal),
            .normal
        )
    }

    func testAChangeInOneSessionLeavesTheOtherAlone() {
        let prefs = SessionComposerPrefs()
        let first = UUID()
        let second = UUID()

        prefs.setAgentMode(.plan, for: first)
        prefs.setSpeedMode(.fast, for: first)

        XCTAssertEqual(prefs.effectiveAgentMode(for: first, default: .build), .plan)
        XCTAssertEqual(prefs.effectiveSpeedMode(for: first, default: .normal), .fast)
        XCTAssertEqual(
            prefs.effectiveAgentMode(for: second, default: .build),
            .build,
            "Bir sohbetteki mod değişimi diğer sohbeti etkilememeli"
        )
        XCTAssertEqual(
            prefs.effectiveSpeedMode(for: second, default: .normal),
            .normal,
            "Bir sohbetteki hız değişimi diğer sohbeti etkilememeli"
        )
    }

    func testDiscardDropsOnlyRemovedSessions() {
        let prefs = SessionComposerPrefs()
        let live = UUID()
        let removed = UUID()

        prefs.setAgentMode(.plan, for: live)
        prefs.setAgentMode(.review, for: removed)

        prefs.discardSessions(notIn: [live])

        XCTAssertEqual(prefs.effectiveAgentMode(for: live, default: .build), .plan)
        XCTAssertEqual(
            prefs.effectiveAgentMode(for: removed, default: .build),
            .build
        )
    }
}
