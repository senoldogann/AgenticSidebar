import AppKit
import SwiftUI

struct MenuBarSessionView: View {
    let sessionService: AgentSessionService
    let mainWindowController: MainWindowController

    @Environment(SettingsStore.self) private var settingsStore
    @Environment(SettingsWindowController.self) private var settingsWindowController: SettingsWindowController?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let presentationState = SessionPresentationState(
                agentSessionState: sessionService.state
            )
            contentView(presentationState: presentationState, date: context.date)
        }
    }

    @ViewBuilder
    private func contentView(presentationState: SessionPresentationState, date: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header Card
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            // The panel used a fixed purple, so it never matched
                            // the theme the rest of the app was using.
                            LinearGradient(
                                colors: settingsStore.currentThemePreset.accentGradient,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
                        )

                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("AgenticSidebar")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    HStack(spacing: 4) {
                        Text(presentationState.statusTitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        Text("·")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)

                        Text(
                            ElapsedTimeFormatter.string(
                                seconds: presentationState.elapsed(at: date)
                            )
                        )
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { settingsStore.menuBarSessionEnabled },
                    set: { settingsStore.menuBarSessionEnabled = $0 }
                ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel("Show session status in the menu bar")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

                Divider()
                    .opacity(0.4)
                    .padding(.vertical, 2)

                // Menu Items
                MenuBarRowButton(
                    title: "Show AgenticSidebar",
                    icon: settingsStore.menuBarIconChoice.systemImage,
                    shortcut: settingsStore.globalShortcutChoice.displayName,
                    action: {
                        mainWindowController.show()
                        NSApp.activate()
                    }
                )

                MenuBarRowButton(
                    title: "Settings",
                    icon: "gearshape",
                    shortcut: "⌘ ,",
                    action: {
                        settingsWindowController?.show()
                    }
                )

                Divider()
                    .opacity(0.4)
                    .padding(.vertical, 2)

                MenuBarRowButton(
                    title: "Quit AgenticSidebar",
                    icon: "power",
                    shortcut: "⌘ Q",
                    action: {
                        NSApp.terminate(nil)
                    }
                )
            }
            .padding(8)
            .frame(width: 260)
    }
}

private struct MenuBarRowButton: View {
    let title: String
    let icon: String?
    let shortcut: String?
    let action: () -> Void

    @State private var isHovered = false

    init(
        title: String,
        icon: String?,
        shortcut: String?,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }

                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)

                Spacer()

                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isHovered ? Color.primary.opacity(0.09) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
