import AppKit
import XCTest

@testable import AgenticSidebar

@MainActor
final class CapturePrivacyControllerTests: XCTestCase {
    func testCapabilitiesReflectWindowSharingProtection() {
        let controller = CapturePrivacyController()

        XCTAssertTrue(controller.capabilities.externalCaptureExclusionApplied)
        XCTAssertFalse(controller.capabilities.limitation.isEmpty)
    }

    func testConfigureAppliesStealthModeWindowSharingRestriction() {
        _ = NSApplication.shared
        let window = makeWindow()
        let controller = CapturePrivacyController()

        let reportStealth = controller.configure(window: window, stealthMode: true)
        XCTAssertEqual(window.sharingType, .none)
        XCTAssertTrue(reportStealth.externalCaptureExclusionApplied)

        let reportNormal = controller.configure(window: window, stealthMode: false)
        XCTAssertEqual(window.sharingType, .readOnly)
        XCTAssertFalse(reportNormal.externalCaptureExclusionApplied)
    }

    func testSetStealthModeTogglesWindowSharingType() {
        _ = NSApplication.shared
        let window = makeWindow()
        let controller = CapturePrivacyController()
        controller.configure(window: window, stealthMode: false)
        XCTAssertEqual(window.sharingType, .readOnly)

        controller.setStealthMode(true)
        XCTAssertEqual(window.sharingType, .none)

        controller.setStealthMode(false)
        XCTAssertEqual(window.sharingType, .readOnly)
    }

    /// Stealth açıkken sonradan açılan bir sheet, ana pencerenin paylaşım
    /// tipini devralmaz; eskiden yalnız kuralın kurulduğu andaki çocuk
    /// pencereler gezildiği için kayıtlarda görünür kalıyordu.
    func testWindowAppearingLaterIsAdoptedIntoStealthMode() {
        _ = NSApplication.shared
        let parent = makeWindow()
        let controller = CapturePrivacyController()
        controller.configure(window: parent, stealthMode: true)
        XCTAssertEqual(parent.sharingType, .none)

        let sheet = makeWindow()
        parent.addChildWindow(sheet, ordered: .above)
        XCTAssertEqual(
            sheet.sharingType,
            .readOnly,
            "yeni bir pencere paylaşım tipini devralmaz"
        )

        // Pencereyi ekrana getiren AppKit yolu; gözlemci senkron çalışır.
        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: sheet
        )

        XCTAssertEqual(sheet.sharingType, .none)

        controller.setStealthMode(false)
        XCTAssertEqual(sheet.sharingType, .readOnly)
    }

    /// Gizli mod kapalıyken beliren pencere de tercihe uymalı: eski hâlini
    /// korumak, kapatılmış bir ayarın tek bir pencerede açık kalması demekti.
    func testWindowAppearingLaterFollowsTheDisabledSetting() {
        _ = NSApplication.shared
        let controller = CapturePrivacyController()
        controller.configure(window: makeWindow(), stealthMode: false)

        let panel = makeWindow()
        panel.sharingType = .none

        NotificationCenter.default.post(
            name: NSWindow.didChangeOcclusionStateNotification,
            object: panel
        )

        XCTAssertEqual(panel.sharingType, .readOnly)
    }

    /// Ana iş parçacığı dışından gelen bildirim yolu: pencere kimlikle
    /// çözülür, `NSWindow` iş parçacıkları arasında taşınmaz.
    func testAdoptWindowResolvesByIdentity() {
        _ = NSApplication.shared
        let window = makeWindow()
        let controller = CapturePrivacyController()
        controller.configure(window: window, stealthMode: true)
        window.sharingType = .readOnly

        controller.adoptWindow(identified: ObjectIdentifier(window))

        XCTAssertEqual(window.sharingType, .none)
    }

    /// Uygulama, kullanıcının tercihini okumadan hiçbir pencereyi değiştirmemeli:
    /// açılış anındaki varsayılan, kayıtlı ayarın yerine geçemez.
    func testNoWindowIsTouchedBeforeThePreferenceIsRead() {
        _ = NSApplication.shared
        let controller = CapturePrivacyController()
        let window = makeWindow()

        controller.adopt(window)

        XCTAssertEqual(window.sharingType, .readOnly)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }
}
