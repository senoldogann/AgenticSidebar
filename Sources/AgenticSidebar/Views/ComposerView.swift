import SwiftUI

struct ComposerView: View {
    @State private var draft = ""

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask AgenticSidebar…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .glassEffect(
                        .regular.interactive(),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )

                Button {
                } label: {
                    Image(systemName: "arrow.up")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glassProminent)
                .disabled(true)
                .help("Agent runtime wiring follows the application shell milestone")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}
