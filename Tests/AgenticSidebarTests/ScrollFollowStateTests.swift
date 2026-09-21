import Foundation
import XCTest

@testable import AgenticSidebar

/// Review paneli sonrası kara kalan transkriptin regresyon testleri.
///
/// Kök neden iki parçaydı: inspector yerleşimi bitmeden atılan kör `scrollTo`
/// görünümü geçici geometrinin ıssız bir bölgesine bırakıyordu; programatik
/// kayma kullanıcı konumu sayılmadığı için "Scroll to end" kurtarma düğmesi
/// de hiç belirmiyordu. İlki `TranscriptRepinPolicy` ile, ikincisi
/// `ScrollFollowState` içindeki ıssızlık kurtarmasıyla kapatıldı.
@MainActor
final class ScrollFollowStateTests: XCTestCase {
    func testStrandedViewportWithoutUserInputSurfacesRecovery() {
        let state = ScrollFollowState()
        state.record(snapshot: makeSnapshot(offsetY: 0, contentHeight: 1000, containerHeight: 600))

        XCTAssertEqual(state.takePending().awayFromBottom, true)
    }

    func testSuppressedTransientDoesNotSurfaceRecovery() {
        let state = ScrollFollowState()
        state.suppressTransientDrop()
        state.record(snapshot: makeSnapshot(offsetY: 0, contentHeight: 1000, containerHeight: 600))

        XCTAssertNil(state.takePending().awayFromBottom)
    }

    func testSuppressionExpiryLetsGenuineStrandSurface() async throws {
        let state = ScrollFollowState()
        state.suppressTransientDrop(for: 0.05)
        try await Task.sleep(for: .milliseconds(120))
        state.record(snapshot: makeSnapshot(offsetY: 0, contentHeight: 1000, containerHeight: 600))

        XCTAssertEqual(state.takePending().awayFromBottom, true)
    }

    func testNearBottomStaysQuiet() {
        let state = ScrollFollowState()
        state.record(snapshot: makeSnapshot(offsetY: 390, contentHeight: 1000, containerHeight: 600))

        XCTAssertNil(state.takePending().awayFromBottom)
    }

    func testUserDrivenFarViewportStillSurfacesButton() {
        let state = ScrollFollowState()
        state.setScrolling(true)
        state.record(snapshot: makeSnapshot(offsetY: 0, contentHeight: 1000, containerHeight: 600))

        XCTAssertEqual(state.takePending().awayFromBottom, true)
    }

    func testContentFittingViewportClearsAwayState() {
        let state = ScrollFollowState()
        state.record(snapshot: makeSnapshot(offsetY: 0, contentHeight: 1000, containerHeight: 600))
        XCTAssertEqual(state.takePending().awayFromBottom, true)

        state.record(snapshot: makeSnapshot(offsetY: 0, contentHeight: 400, containerHeight: 600))
        XCTAssertEqual(state.takePending().awayFromBottom, false)
    }

    func testLastDistanceTracksSnapshotsAndClearsOnReset() {
        let state = ScrollFollowState()
        XCTAssertNil(state.lastDistanceFromBottom)

        state.record(snapshot: makeSnapshot(offsetY: 100, contentHeight: 1000, containerHeight: 600))
        XCTAssertEqual(state.lastDistanceFromBottom, 300)

        state.reset()
        XCTAssertNil(state.lastDistanceFromBottom)

        state.record(snapshot: makeSnapshot(offsetY: 100, contentHeight: 1000, containerHeight: 600))
        XCTAssertEqual(state.lastDistanceFromBottom, 300)

        state.resumeFollow()
        XCTAssertNil(state.lastDistanceFromBottom)
    }

    func testRepinNeverYanksHistoryReader() {
        XCTAssertFalse(
            TranscriptRepinPolicy.shouldRepin(
                wasFollowing: false,
                isFollowingNow: true,
                distanceFromBottom: 400
            )
        )
    }

    func testRepinCancelsWhenUserMovedAwayBeforeFiring() {
        XCTAssertFalse(
            TranscriptRepinPolicy.shouldRepin(
                wasFollowing: true,
                isFollowingNow: false,
                distanceFromBottom: 400
            )
        )
    }

    func testRepinSkipsBlindJumpWhenAlreadyHome() {
        XCTAssertFalse(
            TranscriptRepinPolicy.shouldRepin(
                wasFollowing: true,
                isFollowingNow: true,
                distanceFromBottom: 10
            )
        )
    }

    func testRepinRepairsStrandedViewport() {
        XCTAssertTrue(
            TranscriptRepinPolicy.shouldRepin(
                wasFollowing: true,
                isFollowingNow: true,
                distanceFromBottom: 400
            )
        )
    }

    func testRepinFallsBackToPinWithoutMeasurement() {
        XCTAssertTrue(
            TranscriptRepinPolicy.shouldRepin(
                wasFollowing: true,
                isFollowingNow: true,
                distanceFromBottom: nil
            )
        )
    }

    private func makeSnapshot(offsetY: CGFloat, contentHeight: CGFloat, containerHeight: CGFloat) -> ChatScrollSnapshot {
        ChatScrollSnapshot(offsetY: offsetY, contentHeight: contentHeight, containerHeight: containerHeight)
    }
}
