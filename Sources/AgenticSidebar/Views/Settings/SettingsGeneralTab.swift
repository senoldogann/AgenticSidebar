import SwiftUI

// MARK: - General Tab

extension SettingsView {
    @ViewBuilder
    var generalTabContent: some View {
        @Bindable var settings = settingsStore

        settingsCard(
            title: "Menu Bar Integration",
            subtitle: "Configure quick access and session monitoring from the macOS status bar.",
            icon: "menubar.rectangle"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Show session status in the menu bar",
                    isOn: $settings.menuBarSessionEnabled
                )
                .tint(currentTheme.accentGradient.first ?? .accentColor)

                Text("Displays agent idle/running state and elapsed timer directly in your Mac menu bar with a quick access popup.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        settingsCard(
            title: "Global Shortcut",
            subtitle: "Show or hide the main window from any application.",
            icon: "command"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Toggle shortcut", selection: $settings.globalShortcutChoice) {
                    ForEach(GlobalShortcutChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.segmented)

                Text("The shortcut is stored as a preference, so it keeps working from the menu bar without reopening the main window.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        settingsCard(
            title: "Capture & Privacy Status",
            subtitle: "System permission state and screen capture restrictions.",
            icon: "lock.shield.fill"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(capturePrivacyCapabilities.limitation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
