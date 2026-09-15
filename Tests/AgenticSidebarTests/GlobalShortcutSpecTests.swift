import Carbon.HIToolbox
import XCTest
@testable import AgenticSidebar

final class GlobalShortcutSpecTests: XCTestCase {
    func testDefaultShortcutIsCommandB() {
        let shortcut = GlobalShortcutSpec.default

        XCTAssertEqual(shortcut.keyCode, UInt32(kVK_ANSI_B))
        XCTAssertEqual(shortcut.modifiers, UInt32(cmdKey))
    }
}
