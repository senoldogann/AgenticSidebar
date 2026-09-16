import Carbon.HIToolbox
import Foundation
import XCTest
@testable import AgenticSidebar

@MainActor
final class SettingsNavigationTests: XCTestCase {
    func testOpeningALinkSelectsTheTabAndNamesTheCard() {
        let navigation = SettingsNavigation()

        navigation.open(tab: .ai, anchor: .toolApprovals)

        XCTAssertEqual(navigation.tab, .ai)
        XCTAssertEqual(navigation.scrollRequest?.anchor, .toolApprovals)
    }

    /// Pressing the same link twice has to scroll twice, which an unchanged value
    /// could not signal — hence the sequence number.
    func testRepeatingTheSameLinkAsksForAnotherScroll() {
        let navigation = SettingsNavigation()

        navigation.open(tab: .ai, anchor: .toolApprovals)
        let first = navigation.scrollRequest

        navigation.open(tab: .ai, anchor: .toolApprovals)
        let second = navigation.scrollRequest

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second?.sequence, (first?.sequence ?? 0) + 1)
        XCTAssertEqual(second?.anchor, .toolApprovals)
    }

    func testOpeningWithoutACardLeavesTheScrollRequestAlone() {
        let navigation = SettingsNavigation()

        navigation.open(tab: .ai, anchor: .toolApprovals)
        let request = navigation.scrollRequest

        navigation.open(tab: .general)

        XCTAssertEqual(navigation.tab, .general)
        XCTAssertEqual(
            navigation.scrollRequest,
            request,
            "Switching tabs by hand must not re-fire an old scroll"
        )
    }
}

/// The launch path registered the built-in default after the window had already
/// registered the stored choice, so the user's own shortcut was silently replaced.
@MainActor
final class LaunchShortcutTests: XCTestCase {
    func testLaunchRegistersTheStoredChoiceRatherThanTheDefault() {
        let suiteName = "AgenticSidebarTests.LaunchShortcut.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(GlobalShortcutChoice.commandB.rawValue, forKey: "settings.globalShortcut")

        let store = SettingsStore(defaults: defaults)
        let delegate = AppDelegate()
        delegate.settingsStore = store

        XCTAssertEqual(delegate.launchShortcut, GlobalShortcutChoice.commandB.spec)
        XCTAssertEqual(delegate.launchShortcut.modifiers, UInt32(cmdKey))
        XCTAssertNotEqual(
            delegate.launchShortcut,
            GlobalShortcutSpec.default,
            "The stored choice is what the user expects to keep working"
        )
    }

    func testAFreshInstallFallsBackToTheBuiltInDefault() {
        let suiteName = "AgenticSidebarTests.LaunchShortcut.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // The delegate holds the store weakly, so the test keeps it alive.
        let store = SettingsStore(defaults: defaults)
        let delegate = AppDelegate()
        delegate.settingsStore = store

        XCTAssertEqual(store.globalShortcutChoice, .commandShiftB)
        XCTAssertEqual(delegate.launchShortcut, GlobalShortcutSpec.default)
    }
}

/// The approval level's one-word names are what the composer shows; a missing case
/// would make the control read as an empty chip.
final class ToolApprovalCompactNameTests: XCTestCase {
    func testEveryLevelHasAShortNameThatFitsTheComposer() {
        for policy in ToolApprovalPolicy.allCases {
            XCTAssertFalse(policy.compactName.isEmpty)
            XCTAssertLessThanOrEqual(
                policy.compactName.count,
                12,
                "\(policy.rawValue)'s compact name is too long for the composer row"
            )
            XCTAssertFalse(policy.compactName.contains("—"))
        }
    }
}
