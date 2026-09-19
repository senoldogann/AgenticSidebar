import Foundation
import XCTest

@testable import AgenticSidebar

/// Kapalı grup özeti önizlemesi: koşan varsa en son koşan, yoksa en son
/// aktivite, boş listede `nil`.
final class AgentActivityTimelinePreviewTests: XCTestCase {
    private func activity(id: String, kind: ProviderActivityKind, phase: AgentActivityPhase) -> AgentActivity {
        AgentActivity(
            id: ProviderActivityID(id),
            kind: kind,
            phase: phase,
            title: id,
            detail: nil,
            output: nil,
            diff: nil,
            startedAt: Date(),
            completedAt: phase == .running ? nil : Date()
        )
    }

    func testPrefersMostRecentRunningActivity() {
        let activities = [
            activity(id: "a", kind: .read, phase: .completed),
            activity(id: "b", kind: .command, phase: .running),
            activity(id: "c", kind: .webSearch, phase: .running),
        ]
        XCTAssertEqual(
            AgentActivityTimelineView.collapsedPreviewActivity(from: activities)?.id.rawValue,
            "c"
        )
    }

    func testFallsBackToLastActivityWhenNothingRunning() {
        let activities = [
            activity(id: "a", kind: .read, phase: .completed),
            activity(id: "b", kind: .command, phase: .completed),
        ]
        XCTAssertEqual(
            AgentActivityTimelineView.collapsedPreviewActivity(from: activities)?.id.rawValue,
            "b"
        )
    }

    func testEmptyListHasNoPreview() {
        XCTAssertNil(AgentActivityTimelineView.collapsedPreviewActivity(from: []))
    }
}
