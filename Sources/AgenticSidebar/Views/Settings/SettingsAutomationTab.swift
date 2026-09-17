import SwiftUI

// MARK: - Automation Tab

extension SettingsView {
    @ViewBuilder
    var automationTabContent: some View {
        @Bindable var settings = settingsStore

        settingsCard(
            title: "Clipboard Monitoring (⌘C)",
            subtitle: "Automatically feed copied text to the assistant across all macOS applications.",
            icon: "doc.on.clipboard.fill"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Auto-send copied text (⌘C)",
                    isOn: $settings.autoSubmitClipboard
                )
                .tint(currentTheme.accentGradient.first ?? .accentColor)

                Text("Whenever you copy text anywhere on macOS using Command+C, AgenticSidebar automatically receives it and prompts the agent, even when running in the background.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        settingsCard(
            title: "Screenshot OCR & Vision",
            subtitle: "Analyze screenshots using Apple Vision OCR to extract text and intent.",
            icon: "camera.viewfinder"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Auto-analyze screenshots",
                    isOn: $settings.autoAnalyzeScreenshots
                )
                .tint(currentTheme.accentGradient.first ?? .accentColor)

                Text("Automatically detect newly saved desktop screenshots or clipboard captures, perform on-device OCR, and let the agent deduce problem solutions or descriptions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        settingsCard(
            title: "Snap Context (⇧⌘D)",
            subtitle: "Capture the frontmost app's context into the composer.",
            icon: "rectangle.dashed.badge.record"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Enable Snap Context shortcut",
                    isOn: $settings.contextSnapEnabled
                )
                .tint(currentTheme.accentGradient.first ?? .accentColor)

                Text("Copies the frontmost app name, window title, browser URL and selected text into the composer as a reviewable draft. URL needs Automation permission, selected text needs Accessibility permission — without them the snap degrades to app and window title only.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
