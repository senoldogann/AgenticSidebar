import Carbon.HIToolbox
import Foundation
import XCTest
@testable import AgenticSidebar

@MainActor
final class GlobalShortcutPreferenceTests: XCTestCase {
    func testChoicesExposeDistinctCommandShortcuts() {
        let specs = GlobalShortcutChoice.allCases.map(\.spec)

        XCTAssertEqual(Set(specs).count, GlobalShortcutChoice.allCases.count)

        for spec in specs {
            XCTAssertEqual(spec.keyCode, UInt32(kVK_ANSI_B))
            XCTAssertNotEqual(spec.modifiers & UInt32(cmdKey), 0)
        }

        XCTAssertEqual(GlobalShortcutChoice.commandShiftB.spec, .default)
        XCTAssertNotEqual(
            GlobalShortcutChoice.commandB.spec,
            GlobalShortcutChoice.commandShiftB.spec
        )
    }

    func testShortcutChoiceDefaultsAndPersists() {
        let suiteName = "AgenticSidebarTests.Shortcut.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.globalShortcutChoice, .commandShiftB)

        store.globalShortcutChoice = .optionCommandB

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.globalShortcutChoice, .optionCommandB)
    }

    /// The new default must not rebind an install that already chose plain ⌘B.
    func testAStoredChoiceSurvivesTheDefaultChange() {
        let suiteName = "AgenticSidebarTests.Shortcut.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(GlobalShortcutChoice.commandB.rawValue, forKey: "settings.globalShortcut")

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.globalShortcutChoice, .commandB)
    }

    func testLegacyThemeIdentifiersNormaliseToCurrentPresets() {
        XCTAssertEqual(
            AppThemes.normalizedThemeID(from: "t3Code"),
            ThemeIdentifier.monolith.rawValue
        )
        XCTAssertEqual(
            AppThemes.normalizedThemeID(from: "t3Chat"),
            ThemeIdentifier.nebula.rawValue
        )
        XCTAssertEqual(
            AppThemes.normalizedThemeID(from: ThemeIdentifier.ocean.rawValue),
            ThemeIdentifier.ocean.rawValue
        )

        XCTAssertEqual(AppThemes.preset(for: "t3Code").id, .monolith)
        XCTAssertEqual(AppThemes.preset(for: "t3Chat").id, .nebula)
        XCTAssertEqual(
            AppThemes.preset(for: "unknown-theme-id").id,
            .nebula,
            "Unknown identifiers must fall back to a real preset"
        )
    }

    func testStoredLegacyThemeIdentifierIsMigratedOnLoad() {
        let suiteName = "AgenticSidebarTests.LegacyTheme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("t3Code", forKey: "settings.activeThemeID")

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.activeThemeID, ThemeIdentifier.monolith.rawValue)
    }
}
