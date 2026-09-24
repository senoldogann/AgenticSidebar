import CoreGraphics
import XCTest

@testable import AgenticSidebar

final class SimulatorTouchMapperTests: XCTestCase {
    func testCenterMapsToHalf() {
        let point = SimulatorTouchMapper.normalized(
            location: CGPoint(x: 50, y: 100),
            in: CGSize(width: 100, height: 200)
        )

        XCTAssertEqual(point.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.5, accuracy: 0.0001)
    }

    func testOutsideIsClamped() {
        let point = SimulatorTouchMapper.normalized(
            location: CGPoint(x: -10, y: 250),
            in: CGSize(width: 100, height: 200)
        )

        XCTAssertEqual(point.x, 0, accuracy: 0.0001)
        XCTAssertEqual(point.y, 1, accuracy: 0.0001)
    }

    func testDegenerateSizeFallsToZero() {
        let empty = SimulatorTouchMapper.normalized(
            location: CGPoint(x: 10, y: 10),
            in: .zero
        )

        XCTAssertEqual(empty.x, 0, accuracy: 0.0001)
        XCTAssertEqual(empty.y, 0, accuracy: 0.0001)
    }

    func testNonFiniteLocationFallsToZero() {
        let point = SimulatorTouchMapper.normalized(
            location: CGPoint(x: CGFloat.nan, y: 10),
            in: CGSize(width: 100, height: 200)
        )

        XCTAssertEqual(point.x, 0, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.05, accuracy: 0.0001)
    }
}
