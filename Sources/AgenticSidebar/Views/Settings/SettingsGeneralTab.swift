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

                if settings.menuBarSessionEnabled {
                    Divider()
                        .padding(.vertical, 2)

                    Picker("Menu bar icon", selection: $settings.menuBarIconChoice) {
                        ForEach(SettingsStore.MenuBarIconChoice.allCases) { choice in
                            Label(choice.displayName, systemImage: choice.systemImage)
                                .tag(choice)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("Pick an inconspicuous native-like system icon (such as System Controls or CPU) to blend seamlessly into macOS.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }

        settingsCard(
            title: "Notifications & Audio",
            subtitle: "Receive system alerts and chime sounds when an agent completes a task.",
            icon: "bell.badge.fill"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    "Notify when session completes",
                    isOn: $settings.sessionNotificationsEnabled
                )
                .tint(currentTheme.accentGradient.first ?? .accentColor)

                Text("Sends a native macOS banner displaying the session title and completion status.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if settings.sessionNotificationsEnabled {
                    Divider()
                        .padding(.vertical, 2)

                    Toggle(
                        "Play sound on completion",
                        isOn: $settings.sessionNotificationSoundEnabled
                    )
                    .tint(currentTheme.accentGradient.first ?? .accentColor)

                    if settings.sessionNotificationSoundEnabled {
                        HStack(spacing: 10) {
                            Picker("Notification sound", selection: $settings.sessionNotificationSound) {
                                ForEach(SettingsStore.availableNotificationSounds, id: \.self) { sound in
                                    Text(sound).tag(sound)
                                }
                            }
                            .pickerStyle(.menu)

                            Button {
                                settings.playTestNotificationSound()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .font(.system(size: 11))
                                    Text("Test")
                                        .font(.system(size: 11.5))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .pointingHandCursor()
                            .help("Preview the selected notification sound")
                        }

                        Text("Select your preferred alert chime. The test button plays the audio immediately.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
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
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Hide window from screenshots and screen recordings (Stealth Mode)",
                    isOn: $settings.stealthModeEnabled
                )
                .tint(currentTheme.accentGradient.first ?? .accentColor)

                Text(capturePrivacyCapabilities.limitation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
