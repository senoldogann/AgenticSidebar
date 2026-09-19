import SwiftUI

/// Kenar çubuğu bölümü: dokuz sekme dört başlık altında toplanır, her kart
/// kendi işinin menüsünde durur (ajan davranışı AI'da, gözlem Diagnostics'te,
/// eklentiler Extensions'ta).
enum SettingsSection: String, CaseIterable, Identifiable {
    case workspace = "Workspace"
    case agent = "Agent"
    case extensions = "Extensions"
    case system = "System"

    var id: String { rawValue }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case appearance = "Appearance"
    case general = "General"
    case ai = "AI & Models"
    case automation = "Automation"
    case computerUse = "Computer Use"
    case skills = "Skills"
    case mcp = "MCP Servers"
    case plugins = "Plugins"
    case diagnostics = "Diagnostics"

    var id: String { rawValue }

    /// Sekmenin durduğu bölüm: kenar çubuğu bu sırayla kümeler.
    var section: SettingsSection {
        switch self {
        case .appearance, .general:
            return .workspace
        case .ai, .automation, .computerUse:
            return .agent
        case .skills, .mcp, .plugins:
            return .extensions
        case .diagnostics:
            return .system
        }
    }

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
        case .diagnostics: "heart.text.square"
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
    /// Harici `opencode.json` ezmesi, diskten bir kez okunur.
    ///
    /// Kart gövdesinde eşzamanlı okumak her render'da dosya I/O demekti;
    /// o yüzden ilk görünümde arka planda yüklenip burada tutulur.
    @State var externalPermissionOverride: GlobalOpenCodeConfigReader.GlobalPermissionOverride?
    @State var externalPermissionOverrideChecked = false
    /// "Recent tool decisions" kartı kapalı başlar: kayıt dosyası zaten
    /// tutuluyor, kart yalnız kuyruğunu gösteren bir görüntüleyici.
    @State var isToolDecisionLogExpanded: Bool = false
    /// Bilgisayar kullanımı kartının canlı durumu: kurulu yardımcı, onun sahip
    /// olduğu macOS izinleri ve çalıştırılabilen kurulum adımları.
    @State var computerUseStatus = ComputerUseStatus()
    /// Diagnostics sekmesi durumu: kabukta yaşar, diğer sekmelerdeki
    /// desene uyar (kart dosyası yalnız içeriği anlatır).
    @State var diagnosticsSnapshot: DiagnosticsSnapshot?
    @State var diagnosticsIsLoading = false
    @State var diagnosticsExpandedReportID: String?
    @State var diagnosticsExportError: String?

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

    /// Tek sekme satırı: bölüm başlıklı kenar çubuğunun yapı taşı.
    private func settingsTabRow(_ tab: SettingsTab, isSelected: Bool) -> some View {
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
        .help("Open \(tab.rawValue) settings")
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

                // Vertical Tab Items, grouped by section so each card lives
                // under the menu it belongs to.
                VStack(spacing: 10) {
                    ForEach(SettingsSection.allCases) { section in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(section.rawValue.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 10)
                                .padding(.top, 2)

                            ForEach(SettingsTab.allCases.filter { $0.section == section }) { tab in
                                settingsTabRow(tab, isSelected: navigation.tab == tab)
                            }
                        }
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
                            case .diagnostics:
                                diagnosticsTabContent
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
