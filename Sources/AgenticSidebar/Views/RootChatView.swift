import SwiftUI

struct RootChatView: View {
    @Environment(\.openWindow) private var openWindow

    let sessionService: AgentSessionService
    let mainWindowController: MainWindowController
    let capturePrivacyController: CapturePrivacyController
    let settingsStore: SettingsStore
    let openAICredentialSettings: OpenAICredentialSettings
    let openCodeSettings: OpenCodeSettings
    let permissionApprovalCenter: PermissionApprovalCenter
    let onApplyGlobalShortcut: @MainActor (GlobalShortcutSpec) -> Void

    @Environment(\.colorScheme) private var systemColorScheme

    private var isDarkMode: Bool {
        settingsStore.isDark(systemColorScheme: systemColorScheme)
    }

    private var currentTheme: AppThemePreset {
        settingsStore.currentThemePreset
    }

    var body: some View {
        NavigationSplitView {
            ConversationSidebarView(sessionService: sessionService)
        } detail: {
            ConversationDetailView(
                sessionService: sessionService,
                permissionApprovalCenter: permissionApprovalCenter
            )
        }
        .navigationSplitViewStyle(.prominentDetail)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ToolApprovalLevelMenu(
                    settingsStore: settingsStore,
                    permissionApprovalCenter: permissionApprovalCenter
                )
            }
        }
        .background(currentTheme.background(isDark: isDarkMode))
        .toolbarBackground(currentTheme.background(isDark: isDarkMode), for: .windowToolbar)
        .frame(minWidth: 760, minHeight: 520)
        .environment(settingsStore)
        // `nil` for the System preference keeps the scene (and therefore every
        // semantic colour in it) tracking the real system appearance; forcing
        // the *resolved* mode here is what froze the app after one switch.
        .preferredColorScheme(settingsStore.colorSchemeMode.preferredColorScheme)
        .background {
            WindowLifecycleBridge(
                windowController: mainWindowController,
                capturePrivacyController: capturePrivacyController
            )
            .frame(width: 0, height: 0)
        }
        .onAppear {
            mainWindowController.setOpacity(settingsStore.windowOpacity)
            mainWindowController.setAppearance(settingsStore.colorSchemeMode)
            mainWindowController.setReopenAction {
                openWindow(id: "main")
            }
            onApplyGlobalShortcut(settingsStore.globalShortcutChoice.spec)
        }
        .onChange(of: settingsStore.colorSchemeMode) { _, newMode in
            mainWindowController.setAppearance(newMode)
        }
        .onChange(of: settingsStore.windowOpacity) { _, newOpacity in
            mainWindowController.setOpacity(newOpacity)
        }
        .onChange(of: settingsStore.globalShortcutChoice) { _, newChoice in
            onApplyGlobalShortcut(newChoice.spec)
        }
        .textSelection(.enabled)
    }
}
