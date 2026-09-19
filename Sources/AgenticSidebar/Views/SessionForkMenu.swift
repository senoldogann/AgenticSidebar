import SwiftUI

/// Mesaj satırına "Buradan dallan" menüsünü ekler.
///
/// Mantık `SessionFork` + `AgentSessionService.forkSession` içindedir, burada
/// yalnızca menü etiketi yaşar.
struct SessionForkMenuModifier: ViewModifier {
    let messageID: UUID
    let onFork: (UUID) -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                onFork(messageID)
            } label: {
                Label("Buradan dallan", systemImage: "arrow.triangle.branch")
            }
        }
    }
}

extension View {
    /// - Parameter onFork: Dallanacak mesajın kimliğiyle çağrılır; çağıran
    ///   `sessionService.forkSession(id:throughMessageID:)` sonucunu işler.
    func sessionForkMenu(messageID: UUID, onFork: @escaping (UUID) -> Void) -> some View {
        modifier(SessionForkMenuModifier(messageID: messageID, onFork: onFork))
    }
}
