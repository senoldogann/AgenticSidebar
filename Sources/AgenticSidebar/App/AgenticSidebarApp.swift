import SwiftUI

@main
struct AgenticSidebarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var settingsStore: SettingsStore
    @State private var openAICredentialSettings: OpenAICredentialSettings
    @State private var openCodeSettings: OpenCodeSettings
    @State private var sessionService: AgentSessionService

    init() {
        let credentialStore = KeychainCredentialStore()
        let openCodeServerManager = ManagedOpenCodeServerManager.live(
            credentialStore: credentialStore
        )
        let openCodeTransport = URLSessionOpenCodeTransport.shared()

        _settingsStore = State(initialValue: SettingsStore())
        _openAICredentialSettings = State(
            initialValue: OpenAICredentialSettings(
                credentialStore: credentialStore
            )
        )
        _openCodeSettings = State(
            initialValue: OpenCodeSettings(
                executableLocator: SystemOpenCodeExecutableLocator.current(),
                serverManager: openCodeServerManager,
                clientFactory: { connection in
                    OpenCodeClient(
                        transport: openCodeTransport,
                        connection: connection
                    )
                }
            )
        )
        _sessionService = State(
            initialValue: AgentSessionService(
                runtimes: [
                    OpenAIProviderRuntime(
                        transport: URLSessionOpenAITransport.shared(),
                        credentialStore: credentialStore
                    ),
                    OpenCodeProviderRuntime.live(
                        serverManager: openCodeServerManager,
                        transport: openCodeTransport
                    )
                ]
            )
        )

        appDelegate.managedShutdown = {
            await openCodeServerManager.stop()
        }
    }

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
                openCodeSettings: openCodeSettings,
                capturePrivacyCapabilities: appDelegate.capturePrivacyController.capabilities,
                onOpenAICredentialChange: {
                    Task {
                        await sessionService.refreshCapabilities()
                    }
                },
                onOpenCodeChange: {
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
