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
