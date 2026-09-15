import AppKit
import XCTest
@testable import AgenticSidebar

@MainActor
final class CapturePrivacyControllerTests: XCTestCase {
    func testCapabilitiesNeverClaimGuaranteedExternalCaptureExclusion() {
        let controller = CapturePrivacyController()

        XCTAssertFalse(controller.capabilities.externalCaptureExclusionGuaranteed)
        XCTAssertTrue(controller.capabilities.supportsSelfCaptureFiltering)
        XCTAssertFalse(controller.capabilities.limitation.isEmpty)
    }

    func testConfigureDoesNotApplyLegacyWindowSharingRestriction() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let originalSharingType = window.sharingType
        let controller = CapturePrivacyController()

        let report = controller.configure(window: window)

        XCTAssertEqual(window.sharingType, originalSharingType)
        XCTAssertFalse(report.externalCaptureExclusionApplied)
    }
}
