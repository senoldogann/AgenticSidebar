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
}
