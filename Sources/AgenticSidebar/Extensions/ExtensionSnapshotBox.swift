import Foundation
import Synchronization

/// Holds the extension store so the server manager can be handed a way to ask
/// for the current snapshot **at construction**.
///
/// The wiring is unavoidably circular — the store needs the manager to apply its
/// configuration, and the manager needs the store to know what to load — and the
/// obvious fix (set the provider in a `Task` after both exist) leaves a window in
/// which a server can start with an empty picture of the extensions. That window
/// is not theoretical: a start in it wrote a configuration with no silencing
/// patterns, which is exactly the state in which a user's own MCP servers are
/// charged to every request.
///
/// The box removes the window instead of narrowing it: the provider exists from
/// the first line of construction and is empty only until the store is installed,
/// which happens synchronously, before any interface exists to start a server.
final class ExtensionSnapshotBox: Sendable {
    private let store = Mutex<ExtensionStore?>(nil)

    func install(_ store: ExtensionStore) {
        self.store.withLock { $0 = store }
    }

    func snapshot() async -> ExtensionRuntimeSnapshot {
        guard let store = store.withLock({ $0 }) else {
            return .empty
        }

        return await store.runtimeSnapshot
    }
}
