import SwiftUI

struct ComposerView: View {
    let sessionService: AgentSessionService

    @State private var draft = ""

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    ComposerTextEditor(
                        text: $draft,
                        submissionAvailability: submissionAvailability,
                        onSubmit: sendDraft
                    )

                    if draft.isEmpty {
                        Text("Ask AgenticSidebar…")
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 22, maxHeight: 104)
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
                        sendDraft()
                    } label: {
                        Image(systemName: "arrow.up")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(submissionAvailability == .unavailable)
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

    private var submissionAvailability: ComposerSubmissionAvailability {
        let hasContent = !draft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty

        return hasContent && sessionService.canSubmit
            ? .available
            : .unavailable
    }

    private func sendDraft() {
        if sessionService.submit(draft) != nil {
            draft = ""
        }
    }
}
