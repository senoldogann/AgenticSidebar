import Foundation
import XCTest

@testable import AgenticSidebar

final class ComputerLivePresentationTests: XCTestCase {
    private func activity(
        id: String,
        kind: ProviderActivityKind,
        phase: AgentActivityPhase,
        title: String?,
        detail: String? = nil
    ) -> AgentActivity {
        AgentActivity(
            id: ProviderActivityID(id),
            kind: kind,
            phase: phase,
            title: title,
            detail: detail,
            output: nil,
            startedAt: Date(),
            completedAt: phase == .running ? nil : Date()
        )
    }

    private func group(_ activities: [AgentActivity]) -> AgentTurnActivityGroup {
        AgentTurnActivityGroup(id: UUID(), anchorMessageID: UUID(), activities: activities)
    }

    /// Oturum meşgul değilse tur yoktur: panel boş durur.
    func testIdleWhenSessionIsNotBusy() {
        let state = ComputerLivePresentation.state(
            isSessionBusy: false,
            groups: [group([activity(id: "1", kind: .computer, phase: .running, title: "Open an app")])]
        )

        XCTAssertEqual(state, .idle)
    }

    /// Meşgul ama son turda bilgisayar adımı yoksa panel boş durur.
    func testIdleWhenLastTurnHasNoComputerActivity() {
        let state = ComputerLivePresentation.state(
            isSessionBusy: true,
            groups: [group([activity(id: "1", kind: .thinking, phase: .running, title: nil)])]
        )

        XCTAssertEqual(state, .idle)
    }

    /// Yalnız son tur sayılır: eski turdaki bilgisayar adımı akış başlatmaz.
    func testIdleWhenOnlyEarlierTurnsUsedTheComputer() {
        let state = ComputerLivePresentation.state(
            isSessionBusy: true,
            groups: [
                group([activity(id: "old", kind: .computer, phase: .completed, title: "Old step")]),
                group([activity(id: "new", kind: .thinking, phase: .running, title: nil)]),
            ]
        )

        XCTAssertEqual(state, .idle)
    }

    /// Koşan bilgisayar adımı akışı başlatır ve adı rozete taşınır.
    func testActiveWithRunningStep() {
        let state = ComputerLivePresentation.state(
            isSessionBusy: true,
            groups: [
                group([
                    activity(id: "1", kind: .computer, phase: .completed, title: "Find open windows"),
                    activity(id: "2", kind: .computer, phase: .running, title: "Open an app", detail: "Notes"),
                ])
            ]
        )

        XCTAssertEqual(
            state,
            .active(
                step: ComputerLiveStep(title: "Open an app", detail: "Notes", isRunning: true)
            )
        )
    }

    /// Adımlar arasındaki düşünmede akış sürer: son bilgisayar adımı
    /// "bekliyor" olarak kalır, panel boşalıp yanıp sönmez.
    func testActiveKeepsLastStepWhileThinking() {
        let state = ComputerLivePresentation.state(
            isSessionBusy: true,
            groups: [
                group([
                    activity(id: "1", kind: .computer, phase: .completed, title: "Open an app"),
                    activity(id: "2", kind: .thinking, phase: .running, title: nil),
                ])
            ]
        )

        XCTAssertEqual(
            state,
            .active(step: ComputerLiveStep(title: "Open an app", detail: nil, isRunning: false))
        )
    }

    /// Başlık yoksa ayrıntı, o da yoksa sabit ad kullanılır.
    func testStepTitleFallsBackToDetail() {
        let state = ComputerLivePresentation.state(
            isSessionBusy: true,
            groups: [group([activity(id: "1", kind: .computer, phase: .running, title: nil, detail: "Type five numbers")])]
        )

        XCTAssertEqual(
            state,
            .active(step: ComputerLiveStep(title: "Type five numbers", detail: "Type five numbers", isRunning: true))
        )
    }
}
