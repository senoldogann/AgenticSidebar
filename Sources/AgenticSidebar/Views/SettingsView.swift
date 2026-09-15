import SwiftUI

struct SettingsView: View {
    let settingsStore: SettingsStore
    let openAICredentialSettings: OpenAICredentialSettings
    let capturePrivacyCapabilities: CapturePrivacyCapabilities
    let onOpenAICredentialChange: @MainActor () -> Void

    init(
        settingsStore: SettingsStore,
        openAICredentialSettings: OpenAICredentialSettings,
        capturePrivacyCapabilities: CapturePrivacyCapabilities,
        onOpenAICredentialChange: @escaping @MainActor () -> Void = {}
    ) {
        self.settingsStore = settingsStore
        self.openAICredentialSettings = openAICredentialSettings
        self.capturePrivacyCapabilities = capturePrivacyCapabilities
        self.onOpenAICredentialChange = onOpenAICredentialChange
    }

    var body: some View {
        @Bindable var settings = settingsStore
        @Bindable var openAI = openAICredentialSettings

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
        .frame(width: 460)
        .padding()
        .onAppear {
            openAICredentialSettings.refreshStatus()
        }
    }
}
