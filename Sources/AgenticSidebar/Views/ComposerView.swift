import SwiftUI

struct ComposerView: View {
    let sessionService: AgentSessionService

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

                if sessionService.isBusy {
                    Button {
                        Task {
                            await sessionService.cancel()
                        }
                    } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.glassProminent)
                    .help("Cancel the active turn")
                } else {
                    Button {
                        if sessionService.submit(draft) != nil {
                            draft = ""
                        }
                    } label: {
                        Image(systemName: "arrow.up")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(
                        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !sessionService.canSubmit
                    )
                    .help(sendButtonHelp)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var sendButtonHelp: String {
        if sessionService.providers.isEmpty {
            "A provider adapter is required before sending messages"
        } else {
            "Send message"
        }
    }
}
