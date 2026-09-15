import SwiftUI

struct ConversationSidebarView: View {
    var body: some View {
        List {
            Section("Sessions") {
                Label("New session", systemImage: "plus.message")
                Label("Current session", systemImage: "bubble.left.and.text.bubble.right")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(AppIdentity.name)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        .safeAreaInset(edge: .bottom) {
            Text("Command-B toggles the window")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        }
    }
}
