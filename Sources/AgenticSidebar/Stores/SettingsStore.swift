import Foundation
import Observation

@MainActor
@Observable
final class SettingsStore {
    private enum Key {
        static let menuBarSessionEnabled = "settings.menuBarSessionEnabled"
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    var menuBarSessionEnabled: Bool {
        didSet {
            defaults.set(menuBarSessionEnabled, forKey: Key.menuBarSessionEnabled)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if defaults.object(forKey: Key.menuBarSessionEnabled) == nil {
            menuBarSessionEnabled = true
        } else {
            menuBarSessionEnabled = defaults.bool(forKey: Key.menuBarSessionEnabled)
        }
    }
}
