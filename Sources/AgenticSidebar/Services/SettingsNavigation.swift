import Foundation
import Observation

/// A card inside a settings tab that a link from elsewhere can point at.
///
/// The composer shows the approval level in one short line; everything that
/// explains it lives in Settings. "More info" therefore has to do three things at
/// once — open the window, select the tab, and scroll to the card — or the user
/// lands at the top of a screen that does not contain what they asked about.
enum SettingsAnchor: String, Hashable, CaseIterable, Sendable {
    /// The tool approval level picker: what the agent may do without asking.
    case toolApprovals
    /// The shortcut picker, which is where a failed registration is reported.
    case globalShortcut
}

/// Where the settings window should open, owned outside the view.
///
/// `SettingsView` is built once by the window controller, so a value handed to it
/// at construction could not carry a later request. This object is the one piece
/// of state the controller can change and the (already built) view observes.
@MainActor
@Observable
final class SettingsNavigation {
    /// The tab the window is showing.
    var tab: SettingsTab = .appearance

    /// The last scroll request.
    ///
    /// It carries a sequence number rather than being cleared after use, because
    /// the same link has to work twice: pressing "More info" again after scrolling
    /// away must scroll back, and an unchanged value would not notify anyone.
    private(set) var scrollRequest: ScrollRequest?

    struct ScrollRequest: Equatable, Sendable {
        let anchor: SettingsAnchor
        let sequence: Int
    }

    /// Selects a tab, and optionally asks the view to scroll to a card on it.
    func open(tab: SettingsTab, anchor: SettingsAnchor?) {
        self.tab = tab

        guard let anchor else {
            return
        }

        scrollRequest = ScrollRequest(
            anchor: anchor,
            sequence: (scrollRequest?.sequence ?? 0) + 1
        )
    }

    /// Selects a tab without requesting a scroll to a specific card.
    func open(tab: SettingsTab) {
        open(tab: tab, anchor: nil)
    }
}
