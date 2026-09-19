import XCTest

@testable import AgenticSidebar

/// HUD eşlemesi: yalnızca çalışan bilgisayar adımları, son üçü; biten adım
/// timeline'da kalır, HUD'dan düşer ve panel gizlenir.
final class HUDMapperTests: XCTestCase {
    private func activity(
        id: String,
        kind: ProviderActivityKind,
        phase: AgentActivityPhase,
        title: String?
    ) -> AgentActivity {
        AgentActivity(
            id: ProviderActivityID(id),
            kind: kind,
            phase: phase,
            title: title,
            detail: "detay",
            output: nil,
            diff: nil,
            startedAt: Date(),
            completedAt: nil
        )
    }

    func testNonComputerActivitiesAreDropped() {
        let items = HUDActivityMapper.items(from: [
            activity(id: "1", kind: .command, phase: .running, title: "ls"),
            activity(id: "2", kind: .thinking, phase: .running, title: "Düşünme"),
        ])
        XCTAssertTrue(items.isEmpty)
    }

    func testCompletedComputerStepsAreHidden() {
        let items = HUDActivityMapper.items(from: [
            activity(id: "c1", kind: .computer, phase: .running, title: "Click (412, 208)"),
            activity(id: "c2", kind: .computer, phase: .completed, title: "Type metin"),
        ])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Click (412, 208)")
        XCTAssertTrue(items[0].isRunning)
    }

    func testAllCompletedHidesHUD() {
        let items = HUDActivityMapper.items(from: [
            activity(id: "c1", kind: .computer, phase: .completed, title: "Click (1, 2)")
        ])
        XCTAssertTrue(items.isEmpty)
    }

    func testOnlyLastThreeAreKept() {
        let all = (1...5).map { index in
            activity(
                id: "c\(index)",
                kind: .computer,
                phase: .running,
                title: "Adım \(index)"
            )
        }
        let items = HUDActivityMapper.items(from: all)
        XCTAssertEqual(items.map(\.title), ["Adım 3", "Adım 4", "Adım 5"])
    }
}
