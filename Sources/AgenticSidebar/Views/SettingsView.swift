import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case appearance = "Appearance"
    case ai = "AI & Models"
    case skills = "Skills"
    case mcp = "MCP Servers"
    case plugins = "Plugins"
    case automation = "Automation"
    case computerUse = "Computer Use"
    case general = "General"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .appearance: "paintpalette.fill"
        case .ai: "cpu.fill"
        case .skills: "sparkles"
        case .mcp: "server.rack"
        case .plugins: "puzzlepiece.extension.fill"
        case .automation: "bolt.fill"
        case .computerUse: "cursorarrow.rays"
        case .general: "gearshape.fill"
        }
    }
}

/// Settings shell: sidebar navigation, header and tab routing.
///
/// The tabs themselves live in `Views/Settings/Settings*Tab.swift`, and the
/// shared card/button chrome in `Views/Settings/SettingsComponents.swift`; each
/// tab only describes its own content.
struct SettingsView: View {
    @Environment(\.colorScheme) var systemColorScheme

    let settingsStore: SettingsStore
    let openAICredentialSettings: OpenAICredentialSettings
    let openCodeSettings: OpenCodeSettings
    let extensionStore: ExtensionStore
    /// The provider is chosen here rather than in the composer, so this screen
    /// needs the session it configures.
    let sessionService: AgentSessionService
    /// Owns this session's "Always allow" decisions and the audit log the tool
    /// approval card reads, so the two cards show the state the agent is in.
    let permissionApprovalCenter: PermissionApprovalCenter
    /// The tab and card the window should show. Outside state, because this view
    /// is built once and a link from the composer has to reach it later.
    let navigation: SettingsNavigation
    let capturePrivacyCapabilities: CapturePrivacyCapabilities
    let onOpenAICredentialChange: @MainActor () -> Void
    let onOpenCodeChange: @MainActor () -> Void
    let onDismiss: () -> Void

    /// The audit log's tail, loaded when the tool-approval card appears.
    @State var recentDecisions: [ToolAuditLog.Record] = []
    /// Observed tool lifecycle, distinct from permission decisions.
    @State var recentExecutions: [ToolAuditLog.ExecutionRecord] = []
    /// "Recent tool decisions" kartı kapalı başlar: kayıt dosyası zaten
    /// tutuluyor, kart yalnız kuyruğunu gösteren bir görüntüleyici.
    @State var isToolDecisionLogExpanded: Bool = false
    /// Bilgisayar kullanımı kartının canlı durumu: kurulu yardımcı, onun sahip
    /// olduğu macOS izinleri ve çalıştırılabilen kurulum adımları.
    @State var computerUseStatus = ComputerUseStatus()

    // Drafts for the MCP, plugin and skill forms. They live on the shell rather
    // than in the tab so typing survives a switch to another tab and back.
    @State var newMCPName = ""
    @State var newMCPTarget = ""
    @State var newMCPTransport: MCPTransport = .local
    @State var newPluginModule = ""
    @State var pluginQuery = ""
    @State var skillQuery = ""
    @State var skillRepository = ""
    @State var skillName = ""

    init(
        settingsStore: SettingsStore,
        openAICredentialSettings: OpenAICredentialSettings,
        openCodeSettings: OpenCodeSettings,
        extensionStore: ExtensionStore,
        sessionService: AgentSessionService,
        permissionApprovalCenter: PermissionApprovalCenter,
        navigation: SettingsNavigation,
        capturePrivacyCapabilities: CapturePrivacyCapabilities,
        onOpenAICredentialChange: @escaping @MainActor () -> Void,
        onOpenCodeChange: @escaping @MainActor () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.settingsStore = settingsStore
        self.openAICredentialSettings = openAICredentialSettings
        self.openCodeSettings = openCodeSettings
        self.extensionStore = extensionStore
        self.sessionService = sessionService
        self.permissionApprovalCenter = permissionApprovalCenter
        self.navigation = navigation
        self.capturePrivacyCapabilities = capturePrivacyCapabilities
        self.onOpenAICredentialChange = onOpenAICredentialChange
        self.onOpenCodeChange = onOpenCodeChange
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left Sidebar Navigation
            VStack(alignment: .leading, spacing: 12) {
                Text("Settings")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.top, 4)

                // Vertical Tab Items
                VStack(spacing: 3) {
                    ForEach(SettingsTab.allCases) { tab in
                        let isSelected = navigation.tab == tab

                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                navigation.tab = tab
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: tab.iconName)
                                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                                    .frame(width: 18)
                                    .foregroundStyle(isSelected ? .primary : .secondary)

                                Text(tab.rawValue)
                                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                                    .foregroundStyle(
                                        isSelected
                                            ? Color.primary
                                            : (isDarkMode ? Color.white.opacity(0.82) : Color.black.opacity(0.78))
                                    )

                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6.5)
                            .background {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(isDarkMode ? Color.white.opacity(0.12) : Color.black.opacity(0.07))
                                }
                            }
                            .contentShape(Rectangle())
                            .interactiveHoverPill(cornerRadius: 8)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                }

                Spacer()

                // Active Theme Info Card at Bottom of Sidebar
                HStack(spacing: 8) {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: currentTheme.accentGradient,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 12, height: 12)

                    Text(currentTheme.displayName)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    isDarkMode ? Color.white.opacity(0.05) : Color.black.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
            .padding(.horizontal, 12)
            .padding(.top, 36)
            .padding(.bottom, 14)
            .frame(width: 220)
            .background(
                currentTheme.background(isDark: isDarkMode)
            )
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(currentTheme.border(isDark: isDarkMode).opacity(0.4 * settingsStore.contrast))
                    .frame(width: 1)
            }

            // Right Main Content Area
            VStack(spacing: 0) {
                // Content Header Bar
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: navigation.tab.iconName)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text(navigation.tab.rawValue)
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(.primary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 28)
                .padding(.top, 38)
                .padding(.bottom, 14)
                .background(
                    currentTheme.background(isDark: isDarkMode)
                )
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(currentTheme.border(isDark: isDarkMode).opacity(0.3 * settingsStore.contrast))
                        .frame(height: 1)
                }

                // Tab Content ScrollView, with the deep-link target handling: a
                // link from the composer has to reveal the card it names, not
                // just the tab that contains it.
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 20) {
                            switch navigation.tab {
                            case .appearance:
                                appearanceTabContent
                            case .ai:
                                aiTabContent
                            case .skills:
                                skillsTabContent
                            case .mcp:
                                mcpServersTabContent
                            case .plugins:
                                pluginsTabContent
                            case .automation:
                                automationTabContent
                            case .computerUse:
                                computerUseTabContent
                            case .general:
                                generalTabContent
                            }
                        }
                        .frame(maxWidth: 820)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: navigation.scrollRequest) { _, request in
                        guard let request else {
                            return
                        }

                        // One run loop turn, so the tab's content exists before
                        // the scroll target is looked up.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(30))
                            withAnimation(.easeInOut(duration: 0.28)) {
                                proxy.scrollTo(request.anchor, anchor: .top)
                            }
                        }
                    }
                }
                .background(
                    currentTheme.background(isDark: isDarkMode)
                )
            }
        }
        .environment(settingsStore)
        .environment(extensionStore)
        .background(
            currentTheme.background(isDark: isDarkMode)
        )
        .preferredColorScheme(settingsStore.colorSchemeMode.preferredColorScheme)
        .background {
            SettingsWindowAppearanceBridge(mode: settingsStore.colorSchemeMode)
        }
        .onAppear {
            openAICredentialSettings.refreshStatus()
            Task {
                await openCodeSettings.refreshStatus()
            }
            Task {
                await extensionStore.refresh()
            }
        }
        // Every label, path and command on these screens is text the user may
        // need to copy — a config path, a module name, an error message.
        .textSelection(.enabled)
    }
}
