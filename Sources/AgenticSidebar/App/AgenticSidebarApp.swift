import SwiftUI

@main
struct AgenticSidebarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var settingsStore = SettingsStore()
    @State private var sessionService = AgentSessionService(runtimes: [])

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
                capturePrivacyCapabilities: appDelegate.capturePrivacyController.capabilities
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
