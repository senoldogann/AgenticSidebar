import Carbon.HIToolbox
import XCTest

@testable import AgenticSidebar

final class GlobalShortcutSpecTests: XCTestCase {
    /// ⇧⌘B, not ⌘B: the hot key is consumed before the frontmost app sees it, and
    /// plain ⌘B is "bold" in essentially every text field on the system.
    func testDefaultShortcutIsCommandShiftB() {
        let shortcut = GlobalShortcutSpec.default

        XCTAssertEqual(shortcut.keyCode, UInt32(kVK_ANSI_B))
        XCTAssertEqual(shortcut.modifiers, UInt32(cmdKey | shiftKey))
    }

    func testPlainCommandBRemainsAvailableAsAChoice() {
        XCTAssertEqual(
            GlobalShortcutChoice.commandB.spec,
            GlobalShortcutSpec(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey))
        )
    }
}
