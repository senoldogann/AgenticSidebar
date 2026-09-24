import CoreGraphics
import XCTest

@testable import AgenticSidebar

final class ComputerLiveCursorTests: XCTestCase {
    func testInsideBoundsNormalizes() throws {
        let bounds = CGRect(x: 0, y: 0, width: 2000, height: 1000)

        let point = try XCTUnwrap(
            ComputerLiveCaptureService.normalize(CGPoint(x: 500, y: 250), in: bounds)
        )

        XCTAssertEqual(Double(point.x), 0.25, accuracy: 0.0001)
        XCTAssertEqual(Double(point.y), 0.25, accuracy: 0.0001)
    }

    func testOffsetDisplaySubtractsOrigin() throws {
        let bounds = CGRect(x: -1440, y: 0, width: 1440, height: 900)

        let point = try XCTUnwrap(
            ComputerLiveCaptureService.normalize(CGPoint(x: -720, y: 450), in: bounds)
        )

        XCTAssertEqual(Double(point.x), 0.5, accuracy: 0.0001)
        XCTAssertEqual(Double(point.y), 0.5, accuracy: 0.0001)
    }

    func testOutsideBoundsIsNil() {
        let bounds = CGRect(x: 0, y: 0, width: 2000, height: 1000)

        XCTAssertNil(ComputerLiveCaptureService.normalize(CGPoint(x: 2500, y: 500), in: bounds))
        XCTAssertNil(ComputerLiveCaptureService.normalize(CGPoint(x: 1000, y: -1), in: bounds))
    }

    func testEmptyBoundsIsNil() {
        XCTAssertNil(ComputerLiveCaptureService.normalize(CGPoint(x: 0, y: 0), in: .zero))
    }
}
