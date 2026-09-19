import XCTest

@testable import AgenticSidebar

@MainActor
final class ThemeSystemTests: XCTestCase {
    func testAllPresetsContainExpectedThemes() {
        XCTAssertEqual(AppThemes.allPresets.count, 9)

        let identifiers = Set(AppThemes.allPresets.map(\.id))
        XCTAssertTrue(identifiers.contains(.monolith))
        XCTAssertTrue(identifiers.contains(.nebula))
        XCTAssertTrue(identifiers.contains(.grove))
        XCTAssertTrue(identifiers.contains(.ocean))
        XCTAssertTrue(identifiers.contains(.ember))
        XCTAssertTrue(identifiers.contains(.iris))
        XCTAssertTrue(identifiers.contains(.auroraNocturne))
        XCTAssertTrue(identifiers.contains(.codex))
        XCTAssertTrue(identifiers.contains(.claude))
    }

    /// `System` has to reach the scene as `nil`, not as the mode it currently
    /// resolves to — a concrete preference is what pins the window and stops it
    /// tracking later system switches.
    func testColorSchemeModeMapsToScenePreference() {
        XCTAssertNil(ColorSchemeMode.system.preferredColorScheme)
        XCTAssertEqual(ColorSchemeMode.light.preferredColorScheme, .light)
        XCTAssertEqual(ColorSchemeMode.dark.preferredColorScheme, .dark)
    }

    /// Framework surfaces resolve light/dark from the window's `NSAppearance`,
    /// so the System preference must clear that override rather than write the
    /// appearance it happens to resolve to right now.
    func testColorSchemeModeMapsToWindowAppearance() {
        XCTAssertNil(ColorSchemeMode.system.windowAppearance)
        XCTAssertEqual(ColorSchemeMode.light.windowAppearance?.name, .aqua)
        XCTAssertEqual(ColorSchemeMode.dark.windowAppearance?.name, .darkAqua)
    }

    func testUserBubbleForegroundFlipsWithTheAppearance() {
        let preset = AppThemes.preset(for: ThemeIdentifier.nebula.rawValue)

        XCTAssertEqual(preset.userBubbleForeground(isDark: true), .white)
        XCTAssertNotEqual(preset.userBubbleForeground(isDark: false), .white)

        // The light bubble gradients are pale, so white text on them is unreadable.
        XCTAssertEqual(preset.userBubbleDark.count, preset.userBubbleLight.count)
        XCTAssertNotEqual(
            preset.userBubbleForeground(isDark: true),
            preset.userBubbleForeground(isDark: false)
        )
    }

    func testThemeSettingsPersistenceAndClamping() {
        let suiteName = "AgenticSidebarTests.ThemeSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.colorSchemeMode, .dark)
        XCTAssertEqual(store.activeThemeID, ThemeIdentifier.nebula.rawValue)
        XCTAssertEqual(store.contrast, 1.10, accuracy: 0.001)
        XCTAssertEqual(store.glassOpacity, 1.00, accuracy: 0.001)
        XCTAssertFalse(store.autoSubmitClipboard)
        XCTAssertFalse(store.autoAnalyzeScreenshots)

        store.colorSchemeMode = .light
        store.activeThemeID = ThemeIdentifier.ocean.rawValue
        store.contrast = 1.30
        store.glassOpacity = 0.70
        store.autoSubmitClipboard = true
        store.autoAnalyzeScreenshots = true

        let reloadedStore = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.colorSchemeMode, .light)
        XCTAssertEqual(reloadedStore.activeThemeID, ThemeIdentifier.ocean.rawValue)
        XCTAssertEqual(reloadedStore.contrast, 1.30, accuracy: 0.001)
        XCTAssertEqual(reloadedStore.glassOpacity, 0.70, accuracy: 0.001)
        XCTAssertTrue(reloadedStore.autoSubmitClipboard)
        XCTAssertTrue(reloadedStore.autoAnalyzeScreenshots)

        // Clamping check
        store.contrast = 2.00
        XCTAssertEqual(store.contrast, 1.50, accuracy: 0.001)
        store.contrast = 0.10
        XCTAssertEqual(store.contrast, 0.80, accuracy: 0.001)

        store.glassOpacity = 1.50
        XCTAssertEqual(store.glassOpacity, 1.00, accuracy: 0.001)
        store.glassOpacity = 0.05
        XCTAssertEqual(store.glassOpacity, 0.30, accuracy: 0.001)
    }
}
