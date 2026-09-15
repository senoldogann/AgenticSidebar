import SwiftUI

struct ConversationDetailView: View {
    let sessionService: AgentSessionService

    var body: some View {
        let presentationState = SessionPresentationState(
            agentSessionState: sessionService.state
        )

        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New session")
                        .font(.title2.weight(.semibold))

                    Label(
                        presentationState.statusTitle,
                        systemImage: presentationState.symbolName
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if !sessionService.providers.isEmpty {
                    configurationControls
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if sessionService.state.messages.isEmpty {
                ContentUnavailableView(
                    "Start a conversation",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(emptyStateDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(sessionService.state.messages) { message in
                            ChatMessageRow(message: message)
                        }
                    }
                    .padding(20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            ComposerView(sessionService: sessionService)
        }
        .navigationTitle("New session")
    }

    @ViewBuilder
    private var configurationControls: some View {
        HStack(spacing: 8) {
            Picker("Provider", selection: providerSelection) {
                ForEach(sessionService.providers, id: \.id) { provider in
                    Text(provider.displayName)
                        .tag(Optional(provider.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 150)

            Picker("Model", selection: modelSelection) {
                ForEach(sessionService.availableModels, id: \.id) { model in
                    Text(model.displayName)
                        .tag(Optional(model.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 160)

            if !sessionService.availableVariants.isEmpty {
                Picker("Variant", selection: variantSelection) {
                    Text("Default")
                        .tag(ProviderVariantID?.none)

                    ForEach(sessionService.availableVariants, id: \.id) { variant in
                        Text(variant.displayName)
                            .tag(Optional(variant.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 130)
            }
        }
        .disabled(sessionService.isBusy)
    }

    private var providerSelection: Binding<ProviderID?> {
        Binding(
            get: { sessionService.state.configuration?.providerID },
            set: { providerID in
                guard let providerID else {
                    return
                }
                try? sessionService.selectProvider(providerID)
            }
        )
    }

    private var modelSelection: Binding<ProviderModelID?> {
        Binding(
            get: { sessionService.state.configuration?.modelID },
            set: { modelID in
                guard let modelID else {
                    return
                }
                try? sessionService.selectModel(modelID)
            }
        )
    }

    private var variantSelection: Binding<ProviderVariantID?> {
        Binding(
            get: { sessionService.state.configuration?.variantID },
            set: { variantID in
                try? sessionService.selectVariant(variantID)
            }
        )
    }

    private var emptyStateDescription: String {
        if sessionService.providers.isEmpty {
            "No provider adapter is available yet. Direct OpenAI and OpenCode adapters are added in later milestones."
        } else {
            "Choose a provider configuration and send a message below."
        }
    }
}

private struct ChatMessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == .user {
                Spacer(minLength: 80)
            }

            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    .quaternary,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )

            if message.role == .assistant {
                Spacer(minLength: 80)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
