import SwiftUI

struct ConversationSidebarView: View {
    let sessionService: AgentSessionService

    @Environment(SettingsStore.self) private var settingsStore
    @Environment(SettingsWindowController.self) private var settingsWindowController: SettingsWindowController?
    @Environment(\.colorScheme) private var systemColorScheme

    /// Onay bekleyen silme. Silinen bir sohbet geri getirilemez, bu yüzden tek
    /// bir bağlam menüsü tıklaması yüzlerce mesajı götürmemeli.
    @State private var sessionPendingDeletion: SessionSummary?

    private var isDarkMode: Bool {
        settingsStore.isDark(systemColorScheme: systemColorScheme)
    }

    private var currentTheme: AppThemePreset {
        settingsStore.currentThemePreset
    }

    var body: some View {
        List {
            Section("Sessions") {
                Button {
                    sessionService.createSession()
                } label: {
                    Label("New session", systemImage: "plus.message")
                        .foregroundStyle(.primary)
                        .pointingHandCursor()
                }
                .buttonStyle(.plain)

                ForEach(sessionService.sessionList) { session in
                    sessionRow(session)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .navigationTitle(AppIdentity.name)
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 290)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Divider()
                    .opacity(0.4)

                Button {
                    settingsWindowController?.show()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text("Settings")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)

                        Spacer()

                        Text("⌘,")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                            )
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .interactiveHoverPill(cornerRadius: 8)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Open application settings (⌘,)")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .background(currentTheme.background(isDark: isDarkMode))
        }
        .background(currentTheme.background(isDark: isDarkMode))
        .confirmationDialog(
            deletionPromptTitle,
            isPresented: isDeletionPromptPresented,
            titleVisibility: .visible,
            presenting: sessionPendingDeletion
        ) { session in
            Button("Delete", role: .destructive) {
                sessionService.deleteSession(session.id)
                sessionPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                sessionPendingDeletion = nil
            }
        } message: { _ in
            Text("This conversation and its messages cannot be restored.")
        }
    }

    private var deletionPromptTitle: String {
        guard let sessionPendingDeletion else {
            return "Delete session?"
        }

        return "Delete “\(sessionPendingDeletion.title)”?"
    }

    private var isDeletionPromptPresented: Binding<Bool> {
        Binding(
            get: { sessionPendingDeletion != nil },
            set: { isPresented in
                guard !isPresented else {
                    return
                }
                sessionPendingDeletion = nil
            }
        )
    }

    @ViewBuilder
    private func sessionRow(_ session: SessionSummary) -> some View {
        let isActive = session.id == sessionService.activeSessionID

        Button {
            sessionService.selectSession(session.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.text.bubble.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isActive ? (currentTheme.accentGradient.first ?? .primary) : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(sessionSubtitle(session))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if session.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? activeRowBackground : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isActive ? activeRowBorder : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityLabel("\(session.title), \(sessionSubtitle(session))")
        .contextMenu {
            Button("Delete Session", role: .destructive) {
                sessionPendingDeletion = session
            }
        }
    }

    /// The selected conversation gets a soft theme-tinted plate, so the active
    /// session is obvious at a glance without looking like a system selection.
    private var activeRowBackground: Color {
        (currentTheme.accentGradient.first ?? .accentColor)
            .opacity(isDarkMode ? 0.22 : 0.14)
    }

    private var activeRowBorder: Color {
        (currentTheme.accentGradient.first ?? .accentColor)
            .opacity(isDarkMode ? 0.34 : 0.26)
    }

    private func sessionSubtitle(_ session: SessionSummary) -> String {
        if session.isBusy {
            switch session.status {
            case .waiting:
                return "Waiting for you"
            case .cancelling:
                return "Stopping"
            case .runningTool(let name):
                return name
            default:
                return "Streaming"
            }
        }

        guard let reference = session.completedAt ?? session.lastMessageAt else {
            return "No messages yet"
        }

        // Cached per minute: this is a row subtitle, and the sidebar re-renders
        // on every state change of a running turn.
        return RelativeTimestamp.text(for: reference)
    }
}
