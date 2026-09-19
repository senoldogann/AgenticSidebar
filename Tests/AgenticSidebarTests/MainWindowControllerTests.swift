import AppKit
import XCTest

@testable import AgenticSidebar

@MainActor
final class MainWindowControllerTests: XCTestCase {
    func testShowHideAndToggleControlRegisteredWindowVisibility() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let controller = MainWindowController()
        controller.register(window)

        controller.show()
        XCTAssertTrue(window.isVisible)

        controller.hide()
        XCTAssertFalse(window.isVisible)

        controller.toggle()
        XCTAssertTrue(window.isVisible)

        controller.toggle()
        XCTAssertFalse(window.isVisible)
    }

    func testAppearanceModeAppliesToRegisteredWindowAndSystemClearsIt() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let controller = MainWindowController()

        // A mode chosen before the window exists must still reach it.
        controller.setAppearance(.dark)
        controller.register(window)
        XCTAssertEqual(window.appearance?.name, .darkAqua)

        controller.setAppearance(.light)
        XCTAssertEqual(window.appearance?.name, .aqua)

        // `.system` must *clear* the override: leaving a concrete appearance in
        // place would pin every AppKit-drawn surface for the life of the window.
        controller.setAppearance(.system)
        XCTAssertNil(window.appearance)
    }

    func testShowUsesReopenActionWhenNoWindowIsRegistered() {
        var reopenCount = 0
        let controller = MainWindowController()
        controller.setReopenAction {
            reopenCount += 1
        }

        controller.show()

        XCTAssertEqual(reopenCount, 1)
    }

    func testShowRequestsApplicationActivationWhenReopeningWindow() {
        var reopenCount = 0
        var activationCount = 0
        let controller = MainWindowController(
            activateApplication: {
                activationCount += 1
            }
        )
        controller.setReopenAction {
            reopenCount += 1
        }

        controller.show()

        XCTAssertEqual(reopenCount, 1)
        XCTAssertEqual(activationCount, 1)
    }
}
