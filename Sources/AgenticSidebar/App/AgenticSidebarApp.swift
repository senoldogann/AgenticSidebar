import SwiftUI

@main
struct AgenticSidebarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var settingsStore: SettingsStore
    @State private var openAICredentialSettings: OpenAICredentialSettings
    @State private var openCodeSettings: OpenCodeSettings
    @State private var sessionService: AgentSessionService
    @State private var clipboardMonitor: ClipboardMonitorService
    @State private var screenshotMonitor: ScreenshotMonitorService
    @State private var permissionApprovalCenter: PermissionApprovalCenter
    @State private var extensionStore: ExtensionStore

    init() {
        let credentialStore = KeychainCredentialStore()
        let initialSettingsStore = SettingsStore()
        // The store is created after the manager and the manager asks the store
        // for the extensions to load. The box holds that circular promise so the
        // provider exists from the manager's first line rather than from a task
        // that may run after a server has already started.
        let extensionSnapshotBox = ExtensionSnapshotBox()
        let openCodeServerManager = ManagedOpenCodeServerManager.live(
            credentialStore: credentialStore,
            extensionSnapshot: { await extensionSnapshotBox.snapshot() }
        )
        let openCodeTransport = URLSessionOpenCodeTransport.streaming()

        // Extensions are decided here and applied by the server manager, which
        // asks this store for the current snapshot every time it starts. Nothing
        // in the store knows how a server is launched, and nothing in the server
        // knows what skills.sh is.
        let initialExtensionStore = ExtensionStore(
            applyConfiguration: { snapshot in
                await openCodeServerManager.setExtensionConfiguration(snapshot)
            },
            clientProvider: {
                guard let connection = await openCodeServerManager.currentConnection() else {
                    return nil
                }
                return OpenCodeClient(transport: openCodeTransport, connection: connection)
            }
        )
        extensionSnapshotBox.install(initialExtensionStore)

        Task {
            await initialExtensionStore.refresh()
        }
        // One audit log for the app: the centre records into it and the settings
        // screen reads it, so both have to be the same instance.
        let toolAuditLog = ToolAuditLog.live()

        // Every tool decision passes through here. The level is read per request
        // from the settings store, which is what makes changing it take effect on
        // the next tool call instead of at the next backend start; a request the
        // selected level has no answer for is deferred to the user, never granted
        // on the agent's behalf.
        let permissionApprovalCenter = PermissionApprovalCenter(
            automaticReplyProvider: { toolName, patterns in
                initialSettingsStore.toolApprovalPolicy.automaticReply(
                    for: toolName,
                    patterns: patterns
                )
            },
            decisionTimeout: PermissionApprovalCenter.defaultDecisionTimeout,
            auditLog: toolAuditLog
        )

        let initialSessionService = AgentSessionService(
            runtimes: [
                OpenCodeProviderRuntime.live(
                    serverManager: openCodeServerManager,
                    transport: openCodeTransport,
                    permissionHandler: { request in
                        await permissionApprovalCenter.submit(request)
                    },
                    cancelPendingPermissions: { remoteSessionID in
                        await permissionApprovalCenter.rejectAll(
                            remoteSessionID: remoteSessionID
                        )
                    }
                ),
                OpenAIProviderRuntime(
                    transport: URLSessionOpenAITransport.streaming(),
                    credentialStore: credentialStore
                )
            ],
            // Conversations survive a relaunch; a damaged archive is kept aside
            // and the app starts clean instead of failing to open.
            archiveStore: SessionArchiveStore.live()
        )

        let initialClipboardMonitor = ClipboardMonitorService(
            sessionService: initialSessionService,
            settingsStore: initialSettingsStore
        )
        let initialScreenshotMonitor = ScreenshotMonitorService(
            sessionService: initialSessionService,
            settingsStore: initialSettingsStore
        )

        let initialOpenAICredentialSettings = OpenAICredentialSettings(
            credentialStore: credentialStore
        )
        let initialOpenCodeSettings = OpenCodeSettings(
            executableLocator: SystemOpenCodeExecutableLocator.current(),
            serverManager: openCodeServerManager,
            clientFactory: { connection in
                OpenCodeClient(
                    transport: openCodeTransport,
                    connection: connection
                )
            },
            computerUseProvider: {
                ComputerUseConfiguration.decision(
                    enabled: initialSettingsStore.computerUseEnabled,
                    rootPath: initialSettingsStore.chatgptSystemRootPath,
                    workingDirectoryURL: ManagedOpenCodeServerManager.managedWorkingDirectoryURL(),
                    environment: ProcessInfo.processInfo.environment,
                    fileManager: .default
                )
            }
        )

        _settingsStore = State(initialValue: initialSettingsStore)
        _sessionService = State(initialValue: initialSessionService)
        _clipboardMonitor = State(initialValue: initialClipboardMonitor)
        _screenshotMonitor = State(initialValue: initialScreenshotMonitor)
        _openAICredentialSettings = State(initialValue: initialOpenAICredentialSettings)
        _openCodeSettings = State(initialValue: initialOpenCodeSettings)
        _permissionApprovalCenter = State(initialValue: permissionApprovalCenter)
        _extensionStore = State(initialValue: initialExtensionStore)

        // The one thing the extensions screen cannot do itself: bring the agent
        // back up so a configuration change takes effect. That is this screen's
        // own start/stop path, so it stays the only place that knows how.
        initialExtensionStore.restartAgent = { [weak initialOpenCodeSettings] in
            guard let initialOpenCodeSettings else {
                return
            }
            _ = await initialOpenCodeSettings.restart()
        }

        // The global shortcut is registered by the delegate; it reports the
        // outcome here so a shortcut another app already owns is visible in
        // Settings instead of failing silently.
        appDelegate.settingsStore = initialSettingsStore

        appDelegate.settingsWindowController.configure { [weak initialSettingsStore, weak initialOpenAICredentialSettings, weak initialOpenCodeSettings, weak initialSessionService, weak initialExtensionStore, weak appDelegate] in
            guard let initialSettingsStore,
                  let initialOpenAICredentialSettings,
                  let initialOpenCodeSettings,
                  let initialSessionService,
                  let initialExtensionStore,
                  let appDelegate else {
                return AnyView(EmptyView())
            }

            return AnyView(
                SettingsView(
                    settingsStore: initialSettingsStore,
                    openAICredentialSettings: initialOpenAICredentialSettings,
                    openCodeSettings: initialOpenCodeSettings,
                    extensionStore: initialExtensionStore,
                    sessionService: initialSessionService,
                    permissionApprovalCenter: permissionApprovalCenter,
                    navigation: appDelegate.settingsWindowController.navigation,
                    capturePrivacyCapabilities: appDelegate.capturePrivacyController.capabilities,
                    onOpenAICredentialChange: {
                        Task {
                            await initialSessionService.refreshCapabilities()
                        }
                    },
                    onOpenCodeChange: {
                        Task {
                            await initialSessionService.refreshCapabilities()
                        }
                    },
                    onDismiss: { [weak appDelegate] in
                        appDelegate?.settingsWindowController.close()
                    }
                )
                // No colour-scheme preference here: this view is built once, so
                // a value captured now could outrank the live one inside
                // `SettingsView` and pin the window it is meant to follow.
                .environment(initialSettingsStore)
                .environment(initialExtensionStore)
                .environment(appDelegate.settingsWindowController)
            )
        }

        initialClipboardMonitor.start()
        initialScreenshotMonitor.start()

        appDelegate.managedShutdown = {
            permissionApprovalCenter.rejectAll()
            initialClipboardMonitor.stop()
            initialScreenshotMonitor.stop()
            // Debounce boşaltılmazsa son iki saniyedeki değişiklikler — biten
            // turun nihai hâli — hiç yazılmadan kapanılır.
            await initialSessionService.flushPendingSave()
            await openCodeServerManager.stop()
            AppLog.lifecycle.info("Managed shutdown completed")
        }
    }

    var body: some Scene {
        WindowGroup(AppIdentity.name, id: "main") {
            RootChatView(
                sessionService: sessionService,
                mainWindowController: appDelegate.mainWindowController,
                capturePrivacyController: appDelegate.capturePrivacyController,
                settingsStore: settingsStore,
                openAICredentialSettings: openAICredentialSettings,
                openCodeSettings: openCodeSettings,
                permissionApprovalCenter: permissionApprovalCenter,
                onApplyGlobalShortcut: { spec in
                    appDelegate.applyGlobalShortcut(spec)
                }
            )
            .environment(appDelegate.settingsWindowController)
            .environment(extensionStore)
            .preferredColorScheme(settingsStore.colorSchemeMode.preferredColorScheme)
            // Yetenek keşfi yalnızca burada yapılır; `RootChatView` de çağırdığında
            // her açılışta iki kez /provider ve /models isteği gidiyordu.
            .task {
                // Extensions first: the server reads its configuration once, so a
                // start that ran before discovery would load the user's own MCP
                // servers with nothing silencing them.
                await extensionStore.refresh()
                await openCodeSettings.start()
                await sessionService.refreshCapabilities()
            }
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    appDelegate.settingsWindowController.show()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
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
            .environment(settingsStore)
            .environment(appDelegate.settingsWindowController)
            // The menu bar panel is a separate scene; without this it always
            // followed the system even when the user forced a mode.
            .preferredColorScheme(settingsStore.colorSchemeMode.preferredColorScheme)
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
