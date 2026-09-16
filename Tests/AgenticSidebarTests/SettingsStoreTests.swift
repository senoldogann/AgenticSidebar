import Foundation
import XCTest
@testable import AgenticSidebar

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testMenuBarSessionDefaultsToEnabledAndPersistsChanges() {
        let suiteName = "AgenticSidebarTests.SettingsStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.menuBarSessionEnabled)

        store.menuBarSessionEnabled = false

        let reloadedStore = SettingsStore(defaults: defaults)
        XCTAssertFalse(reloadedStore.menuBarSessionEnabled)
    }

    func testWindowOpacityDefaultsToExpectedValueAndPersistsClampedChanges() {
        let suiteName = "AgenticSidebarTests.SettingsStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.windowOpacity, 0.95, accuracy: 0.001)

        store.windowOpacity = 0.75
        let reloadedStore = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.windowOpacity, 0.75, accuracy: 0.001)

        store.windowOpacity = 0.10
        XCTAssertEqual(store.windowOpacity, 0.40, accuracy: 0.001)
        XCTAssertEqual(
            SettingsStore(defaults: defaults).windowOpacity,
            0.40,
            accuracy: 0.001,
            "A clamped value has to reach the disk too, not only memory"
        )

        store.windowOpacity = 1.50
        XCTAssertEqual(store.windowOpacity, 1.00, accuracy: 0.001)
        XCTAssertEqual(
            SettingsStore(defaults: defaults).windowOpacity,
            1.00,
            accuracy: 0.001
        )
    }

    func testTypographySettingsDefaultsAndPersistence() {
        let suiteName = "AgenticSidebarTests.SettingsStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.fontFamily, .system)
        XCTAssertEqual(store.fontSize, .regular)
        XCTAssertEqual(store.codeFontSize, .standard)
        XCTAssertFalse(store.codeWordWrap)
        XCTAssertEqual(store.lineSpacing, .normal)

        store.fontFamily = .monospaced
        store.fontSize = .large
        store.codeFontSize = .comfortable
        store.codeWordWrap = true
        store.lineSpacing = .relaxed

        let reloadedStore = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.fontFamily, .monospaced)
        XCTAssertEqual(reloadedStore.fontSize, .large)
        XCTAssertEqual(reloadedStore.codeFontSize, .comfortable)
        XCTAssertTrue(reloadedStore.codeWordWrap)
        XCTAssertEqual(reloadedStore.lineSpacing, .relaxed)
    }

    /// The regression behind "text colours stay dark after switching".
    ///
    /// The app forces a colour scheme onto its own windows, and that forced
    /// value is written back into `@Environment(\.colorScheme)`. Resolving the
    /// System preference from the environment therefore reported the app's own
    /// choice, so the resolved mode froze at whatever the system was at launch.
    func testForcedAppearanceModesIgnoreTheColorSchemeEnvironment() {
        let suiteName = "AgenticSidebarTests.SettingsStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)

        store.colorSchemeMode = .dark
        XCTAssertTrue(store.isDark(systemColorScheme: .light))
        XCTAssertTrue(store.isDark(systemColorScheme: .dark))

        store.colorSchemeMode = .light
        XCTAssertFalse(store.isDark(systemColorScheme: .dark))
        XCTAssertFalse(store.isDark(systemColorScheme: .light))
    }

    func testSystemAppearanceModeFollowsTheColorSchemeEnvironment() {
        let suiteName = "AgenticSidebarTests.SettingsStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        store.colorSchemeMode = .system

        XCTAssertFalse(store.isDark(systemColorScheme: .light))
        XCTAssertTrue(store.isDark(systemColorScheme: .dark))
    }

    func testResponseSpeedModeDefaultsToNormalAndPersistsChanges() {
        let suiteName = "AgenticSidebarTests.SettingsStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.responseSpeedMode, .normal)

        store.responseSpeedMode = .fast

        let reloadedStore = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.responseSpeedMode, .fast)
    }

    func testComputerUseDefaultsAreOffWithTheDefaultRootAndPersist() {
        let suiteName = "AgenticSidebarTests.SettingsStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.computerUseEnabled)
        XCTAssertEqual(store.chatgptSystemRootPath, SettingsStore.defaultChatgptSystemRootPath)
        XCTAssertEqual(store.toolApprovalPolicy, .fullAccess)

        store.computerUseEnabled = true
        store.chatgptSystemRootPath = "~/code/chatgpt-system"
        store.toolApprovalPolicy = .ask

        let reloadedStore = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloadedStore.computerUseEnabled)
        XCTAssertEqual(reloadedStore.chatgptSystemRootPath, "~/code/chatgpt-system")
        XCTAssertEqual(reloadedStore.toolApprovalPolicy, .ask)
    }

    func testTheOlderComputerUseOnlyLevelIsStillReadAsTheGlobalLevel() {
        let suiteName = "AgenticSidebarTests.SettingsStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // An install that only ever knew the computer-use level keeps its choice
        // instead of silently starting to ask about everything.
        defaults.set("autoApproveActions", forKey: "settings.computerUseApprovalMode")

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.toolApprovalPolicy, .approveSafe)
    }
}

