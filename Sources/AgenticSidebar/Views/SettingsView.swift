import SwiftUI

struct SettingsView: View {
    let settingsStore: SettingsStore
    let capturePrivacyCapabilities: CapturePrivacyCapabilities

    var body: some View {
        @Bindable var settings = settingsStore

        Form {
            Toggle(
                "Show session status in the menu bar",
                isOn: $settings.menuBarSessionEnabled
            )

            Text(capturePrivacyCapabilities.limitation)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}
