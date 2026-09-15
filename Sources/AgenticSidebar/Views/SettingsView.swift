import SwiftUI

struct SettingsView: View {
    let settingsStore: SettingsStore
    let openAICredentialSettings: OpenAICredentialSettings
    let openCodeSettings: OpenCodeSettings
    let capturePrivacyCapabilities: CapturePrivacyCapabilities
    let onOpenAICredentialChange: @MainActor () -> Void
    let onOpenCodeChange: @MainActor () -> Void

    init(
        settingsStore: SettingsStore,
        openAICredentialSettings: OpenAICredentialSettings,
        openCodeSettings: OpenCodeSettings,
        capturePrivacyCapabilities: CapturePrivacyCapabilities,
        onOpenAICredentialChange: @escaping @MainActor () -> Void = {},
        onOpenCodeChange: @escaping @MainActor () -> Void = {}
    ) {
        self.settingsStore = settingsStore
        self.openAICredentialSettings = openAICredentialSettings
        self.openCodeSettings = openCodeSettings
        self.capturePrivacyCapabilities = capturePrivacyCapabilities
        self.onOpenAICredentialChange = onOpenAICredentialChange
        self.onOpenCodeChange = onOpenCodeChange
    }

    var body: some View {
        @Bindable var settings = settingsStore
        @Bindable var openAI = openAICredentialSettings
        @Bindable var openCode = openCodeSettings

        Form {
            Section("OpenAI") {
                SecureField("OpenAI API key", text: $openAI.apiKeyDraft)

                HStack {
                    Button("Save API Key") {
                        if openAICredentialSettings.save() {
                            onOpenAICredentialChange()
                        }
                    }
                    .disabled(
                        openAICredentialSettings.apiKeyDraft
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                    )

                    Button("Delete API Key", role: .destructive) {
                        if openAICredentialSettings.delete() {
                            onOpenAICredentialChange()
                        }
                    }
                    .disabled(!openAICredentialSettings.hasStoredCredential)
                }

                if openAICredentialSettings.hasStoredCredential {
                    Text("API key saved in macOS Keychain.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The saved API key is stored only in macOS Keychain and is never displayed here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = openAICredentialSettings.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("OpenCode") {
                HStack {
                    Text(openCodeStatusText)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if isOpenCodeRunning {
                        Button("Stop OpenCode", role: .destructive) {
                            Task {
                                await openCodeSettings.stop()
                                onOpenCodeChange()
                            }
                        }
                    } else {
                        Button("Start OpenCode") {
                            Task {
                                if await openCodeSettings.start() {
                                    onOpenCodeChange()
                                }
                            }
                        }
                        .disabled(!openCodeSettings.isInstalled)
                    }
                }

                if isOpenCodeRunning {
                    if !openCodeSettings.apiProviderIDs.isEmpty {
                        Picker(
                            "Provider credential",
                            selection: providerSelection
                        ) {
                            ForEach(openCodeSettings.apiProviderIDs, id: \.self) { providerID in
                                Text(providerID).tag(providerID)
                            }
                        }

                        if openCodeSettings.selectedAPIMethods.count > 1 {
                            Picker(
                                "Authentication method",
                                selection: methodSelection
                            ) {
                                ForEach(
                                    Array(openCodeSettings.selectedAPIMethods.enumerated()),
                                    id: \.offset
                                ) { index, method in
                                    Text(method.label).tag(index)
                                }
                            }
                        } else if let method = openCodeSettings.selectedAPIMethod {
                            LabeledContent("Authentication method", value: method.label)
                        }

                        ForEach(openCodeSettings.activePrompts, id: \.key) { prompt in
                            metadataControl(for: prompt)
                        }

                        SecureField("Provider API key", text: $openCode.apiKeyDraft)

                        Button("Save Provider Credential") {
                            Task {
                                if await openCodeSettings.saveAPIKey() {
                                    onOpenCodeChange()
                                }
                            }
                        }
                        .disabled(
                            openCodeSettings.apiKeyDraft
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                        )

                        Text("Provider credentials are sent to the local OpenCode server and are not persisted by AgenticSidebar.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No API-key authentication methods are advertised by this OpenCode installation.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if !oauthProviderIDs.isEmpty {
                        Text("OAuth sign-in is available for \(oauthProviderIDs.joined(separator: ", ")), but browser OAuth setup is not implemented in this milestone.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage = openCodeSettings.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Application") {
                Toggle(
                    "Show session status in the menu bar",
                    isOn: $settings.menuBarSessionEnabled
                )

                Text(capturePrivacyCapabilities.limitation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
        .onAppear {
            openAICredentialSettings.refreshStatus()
            Task {
                await openCodeSettings.refreshStatus()
            }
        }
    }

    @ViewBuilder
    private func metadataControl(for prompt: OpenCodeAuthPrompt) -> some View {
        switch prompt.type {
        case .text:
            TextField(
                prompt.message,
                text: metadataBinding(for: prompt.key),
                prompt: prompt.placeholder.map(Text.init)
            )

        case .select:
            Picker(
                prompt.message,
                selection: metadataBinding(for: prompt.key)
            ) {
                ForEach(prompt.options ?? [], id: \.value) { option in
                    Text(option.hint.map { "\(option.label) — \($0)" } ?? option.label)
                        .tag(option.value)
                }
            }
        }
    }

    private var providerSelection: Binding<String> {
        Binding(
            get: { openCodeSettings.selectedProviderID ?? "" },
            set: { openCodeSettings.selectProvider($0) }
        )
    }

    private var methodSelection: Binding<Int> {
        Binding(
            get: { openCodeSettings.selectedMethodIndex },
            set: { openCodeSettings.selectMethod(index: $0) }
        )
    }

    private func metadataBinding(for key: String) -> Binding<String> {
        Binding(
            get: { openCodeSettings.metadataDrafts[key] ?? "" },
            set: { openCodeSettings.metadataDrafts[key] = $0 }
        )
    }

    private var isOpenCodeRunning: Bool {
        if case .running = openCodeSettings.serverStatus {
            return true
        }
        return false
    }

    private var openCodeStatusText: String {
        switch openCodeSettings.serverStatus {
        case .stopped:
            openCodeSettings.isInstalled
                ? "Installed — server stopped"
                : "OpenCode executable not found"
        case .starting:
            "Starting local server…"
        case let .running(version, _):
            "Running OpenCode \(version) on authenticated loopback"
        }
    }

    private var oauthProviderIDs: [String] {
        openCodeSettings.authMethods
            .filter { _, methods in methods.contains(where: { $0.type == .oauth }) }
            .map(\.key)
            .sorted()
    }
}
