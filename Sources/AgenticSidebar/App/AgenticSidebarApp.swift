import SwiftUI

@main
struct AgenticSidebarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var settingsStore = SettingsStore()
    @State private var openAICredentialSettings = OpenAICredentialSettings(
        credentialStore: KeychainCredentialStore()
    )
    @State private var sessionService = AgentSessionService(
        runtimes: [
            OpenAIProviderRuntime(
                transport: URLSessionOpenAITransport.shared(),
                credentialStore: KeychainCredentialStore()
            )
        ]
    )

    var body: some Scene {
        WindowGroup(AppIdentity.name, id: "main") {
            RootChatView(
                sessionService: sessionService,
                mainWindowController: appDelegate.mainWindowController,
                capturePrivacyController: appDelegate.capturePrivacyController
            )
        }
        .defaultSize(width: 980, height: 680)

        Settings {
            SettingsView(
                settingsStore: settingsStore,
                openAICredentialSettings: openAICredentialSettings,
                capturePrivacyCapabilities: appDelegate.capturePrivacyController.capabilities,
                onOpenAICredentialChange: {
                    Task {
                        await sessionService.refreshCapabilities()
                    }
                }
            )
        }

        MenuBarExtra(
            AppIdentity.name,
            systemImage: "sidebar.leading",
            isInserted: menuBarSessionBinding
        ) {
            MenuBarSessionView(
                sessionService: sessionService,
                mainWindowController: appDelegate.mainWindowController
            )
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSessionBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.menuBarSessionEnabled },
            set: { settingsStore.menuBarSessionEnabled = $0 }
        )
    }
}
