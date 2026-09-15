import SwiftUI

struct ConversationDetailView: View {
    let sessionStore: SessionPresentationStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New session")
                        .font(.title2.weight(.semibold))

                    Label(
                        sessionStore.state.statusTitle,
                        systemImage: sessionStore.state.symbolName
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                ContentUnavailableView(
                    "Start a conversation",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Provider and agent runtime wiring follows the native application shell milestone.")
                )
                .frame(maxWidth: .infinity, minHeight: 360)
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ComposerView()
        }
        .navigationTitle("New session")
    }
}
