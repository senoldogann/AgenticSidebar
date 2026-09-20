import Foundation
import SwiftUI
import Synchronization

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
    /// Shared by the transcript (which asks for a message to be written again)
    /// and the composer (which owns the draft it lands in).
    @State private var composerDraftCenter = ComposerDraftCenter()
    /// Unsent composer drafts, kept across relaunches next to the archive.
    @State private var composerDraftStore: ComposerDraftStore
    /// Çalışırken yazılmamış taslaklar: görünüm yok olsa da yaşar, böylece
    /// tekli↔yan yana geçiş besteci içeriğini silmez.
    @State private var composerDraftMemory = ComposerDraftMemory()
    /// Ajan modu ve hız modu oturum başınadır; bir sohbetteki değişim
    /// diğerini etkilemez.
    @State private var composerPrefs: SessionComposerPrefs
    /// Timeline kartlarının açık/kapalı durumu; sohbet değişiminde korunur.
    @State private var collapseStore = TimelineCollapseStore()
    /// Yan yana sohbet düzeni; yeniden başlatmada korunur.
    @State private var splitStore = SplitLayoutStore()
    /// Görev panosunun ana aktör projeksiyonu; `nil` ise pano bağlanmamıştır.
    @State private var taskBoardStore: TaskBoardStore?

    /// HUD'un gördüğü bilgisayar adımları: odaklı bölmenin oturumu. Dört akış
    /// üst üste bindirilmez; odaksız bölme başlığındaki meşgul noktasıyla yetinir.
    private var hudActivities: [AgentActivity] {
        let focusID = splitStore.resolvedFocusSessionID(
            activeID: sessionService.activeSessionID,
            liveIDs: Set(sessionService.sessionList.map(\.id))
        )
        guard focusID != sessionService.activeSessionID,
            let focused = sessionService.session(for: focusID)
        else {
            return sessionService.state.activityGroups.flatMap(\.activities)
        }
        return focused.state.activityGroups.flatMap(\.activities)
    }

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

        // One audit log for the app: the centre records into it and the settings
        // screen reads it, so both have to be the same instance.
        let toolAuditLog = ToolAuditLog.live()

        // Every tool decision passes through here. Without a running turn the
        // level is read per request from the settings store; once a turn
        // starts its level is snapshotted (see `onSessionTurnStarted`), so a
        // mid-turn change waits for the next turn instead of rewriting the
        // rules under a working agent. A request the effective level has no
        // answer for is deferred to the user, never granted on the agent's
        // behalf.
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
                    cancelPendingPermissions: { remoteSessionID, appSessionID in
                        await permissionApprovalCenter.rejectAll(
                            remoteSessionID: remoteSessionID,
                            appSessionID: appSessionID
                        )
                    },
                    auditLog: toolAuditLog
                ),
                OpenAIProviderRuntime(
                    transport: URLSessionOpenAITransport.streaming(),
                    credentialStore: credentialStore
                ),
            ],
            // Conversations survive a relaunch; a damaged archive is kept aside
            // and the app starts clean instead of failing to open.
            archiveStore: SessionArchiveStore.live()
        )

        let notificationService = SessionNotificationService.shared
        notificationService.onSelectSession = { [weak initialSessionService] sessionID in
            initialSessionService?.selectSession(sessionID)
        }

        initialSessionService.onSessionTurnCompleted = { [weak initialSettingsStore] sessionID, sessionTitle, status, snippet in
            guard let initialSettingsStore else { return }
            SessionNotificationService.shared.postSessionCompletionNotification(
                sessionID: sessionID,
                sessionTitle: sessionTitle,
                status: status,
                previewText: snippet,
                soundName: initialSettingsStore.sessionNotificationSound,
                playSound: initialSettingsStore.sessionNotificationSoundEnabled,
                enabled: initialSettingsStore.sessionNotificationsEnabled,
                includePreview: initialSettingsStore.sessionNotificationPreviewEnabled
            )
        }

        // İzin seviyesi turun kuralıdır: tur başlarken o anki seviye merkeze
        // anlık görüntü olarak verilir. Tur ortasında besteciden seviye
        // değişirse koşan tur eski kuralla devam eder; yeni kural tur bitince
        // sonraki mesajlarda geçerli olur.
        initialSessionService.onSessionTurnStarted = { [weak permissionApprovalCenter, weak initialSettingsStore] sessionID, turnID in
            guard let permissionApprovalCenter, let initialSettingsStore else {
                return
            }
            permissionApprovalCenter.beginTurn(
                appSessionID: sessionID,
                turnID: turnID,
                policy: initialSettingsStore.toolApprovalPolicy
            )
        }
        initialSessionService.onSessionTurnEnded = { [weak permissionApprovalCenter] sessionID, turnID in
            permissionApprovalCenter?.endTurn(appSessionID: sessionID, turnID: turnID)
        }

        Task {
            await notificationService.requestAuthorization()
        }

        let initialClipboardMonitor = ClipboardMonitorService(
            sessionService: initialSessionService,
            settingsStore: initialSettingsStore
        )
        let initialScreenshotMonitor = ScreenshotMonitorService(
            sessionService: initialSessionService,
            settingsStore: initialSettingsStore
        )
        let initialComposerPrefs = SessionComposerPrefs()
        initialClipboardMonitor.composerPrefs = initialComposerPrefs
        initialScreenshotMonitor.composerPrefs = initialComposerPrefs

        // Görev panosu yığını süreç ömrü boyunca tek kez burada kurulur; pano
        // yalnızca bu mağazadan konuşur. Canlı yazma gönderimi bu sürümde
        // bağlı değildir: zamanlayıcının sağlayıcıya koşu gönderen bir çağrısı
        // yoktur, bu yüzden panodaki başlatma yalnızca defter kaydı üretir.
        let taskBoardComposition = TaskBoardComposition.live(
            applicationSupportDirectory: FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first,
            openCodeServerManager: openCodeServerManager,
            openCodeTransport: openCodeTransport,
            credentialStore: credentialStore,
            toolAuditLog: toolAuditLog,
            permissionApprovalCenter: permissionApprovalCenter,
            sessionConfiguration: { [weak initialSessionService] in
                initialSessionService?.activeSession.state.configuration
            }
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
        _taskBoardStore = State(initialValue: taskBoardComposition?.store)
        _sessionService = State(initialValue: initialSessionService)
        _composerPrefs = State(initialValue: initialComposerPrefs)
        _clipboardMonitor = State(initialValue: initialClipboardMonitor)
        _screenshotMonitor = State(initialValue: initialScreenshotMonitor)
        _openAICredentialSettings = State(initialValue: initialOpenAICredentialSettings)
        _openCodeSettings = State(initialValue: initialOpenCodeSettings)
        _permissionApprovalCenter = State(initialValue: permissionApprovalCenter)
        _extensionStore = State(initialValue: initialExtensionStore)
        // Unsent drafts survive a relaunch beside the archive. The local holds the
        // instance for the shutdown path below; State shares it with the views.
        let initialComposerDraftStore = ComposerDraftStore.live()
        _composerDraftStore = State(initialValue: initialComposerDraftStore)

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
        appDelegate.settingsWindowController.setStealthMode(initialSettingsStore.stealthModeEnabled)

        appDelegate.settingsWindowController.configure {
            [
                weak initialSettingsStore, weak initialOpenAICredentialSettings, weak initialOpenCodeSettings, weak initialSessionService,
                weak initialExtensionStore, weak appDelegate
            ] in
            guard let initialSettingsStore,
                let initialOpenAICredentialSettings,
                let initialOpenCodeSettings,
                let initialSessionService,
                let initialExtensionStore,
                let appDelegate
            else {
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
            await initialComposerDraftStore.flush()
            // Pano kapanışı: bu sürecin sahiplendiği koşan denemeler iptal
            // edilir ve mağaza boşaltılır; OpenCode sunucu yaşam döngüsüne
            // dokunulmaz, ilgisiz hiçbir süreç sonlandırılmaz.
            await taskBoardComposition?.shutdown()
            await openCodeServerManager.stop()
            AppLog.lifecycle.info("Managed shutdown completed")
        }
    }

    var body: some Scene {
        Window(AppIdentity.name, id: "main") {
            RootChatView(
                sessionService: sessionService,
                mainWindowController: appDelegate.mainWindowController,
                capturePrivacyController: appDelegate.capturePrivacyController,
                settingsStore: settingsStore,
                openAICredentialSettings: openAICredentialSettings,
                openCodeSettings: openCodeSettings,
                permissionApprovalCenter: permissionApprovalCenter,
                clipboardMonitor: clipboardMonitor,
                screenshotMonitor: screenshotMonitor,
                collapseStore: collapseStore,
                splitStore: splitStore,
                taskBoardStore: taskBoardStore,
                onApplyGlobalShortcut: { spec in
                    appDelegate.applyGlobalShortcut(spec)
                }
            )
            .environment(appDelegate.settingsWindowController)
            .environment(extensionStore)
            .environment(composerDraftCenter)
            .environment(composerDraftStore)
            .environment(composerDraftMemory)
            .environment(composerPrefs)
            .preferredColorScheme(settingsStore.colorSchemeMode.preferredColorScheme)
            // Canlı HUD: görünmez ana bilgisayar bilgisayar adımlarını panele
            // taşır; boşken gizlenir, `AgentSession` dosyasına dokunulmaz.
            // Aktif oturumun yanında ikincil bölmedeki oturum da izlenir,
            // yoksa yan sohbetteki bilgisayar adımları HUD'a hiç düşmezdi.
            .background {
                FloatingHUDHostView(
                    activities: hudActivities
                )
            }
            // Yetenek keşfi yalnızca burada yapılır; `RootChatView` de çağırdığında
            // her açılışta iki kez /provider ve /models isteği gidiyordu.
            .task {
                // Snap Context bağlantısı: kısayol AppDelegate'de hazırdır,
                // koordinatör atanır atanmaz `didSet` üzerinden kendini kaydeder.
                if appDelegate.snapCoordinator == nil {
                    appDelegate.snapCoordinator = ContextSnapCoordinator(
                        snapService: ContextSnapService.live(),
                        draftCenter: composerDraftCenter,
                        settings: settingsStore,
                        activeSessionID: { sessionService.activeSessionID }
                    )
                }
                // Extensions first: the server reads its configuration once, so a
                // start that ran before discovery would load the user's own MCP
                // servers with nothing silencing them.
                await extensionStore.refresh()
                await openCodeSettings.start()
                await sessionService.refreshCapabilities()
            }
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)
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
            systemImage: settingsStore.menuBarIconChoice.systemImage,
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

// MARK: - Görev panosu kompozisyonu

/// Uygulama ömrü boyunca tek bir görev panosu yığını.
///
/// Mağaza, çalışma alanı yöneticisi, zamanlayıcı, kurtarma, doğrulayıcı ve
/// uygulamaya bakan servis burada bir kez kurulur; pano görünümü yalnızca
/// `store` üzerinden konuşur. `make` bütün portları dışarıdan alır, böylece
/// entegrasyon testleri üretim kablolamasını sahte portlarla sınar.
@MainActor
final class TaskBoardComposition {
    let store: TaskBoardStore
    let service: CodingTaskService
    let scheduler: TaskScheduler
    let recovery: TaskRecovery
    let repository: SQLiteTaskStore

    init(
        store: TaskBoardStore,
        service: CodingTaskService,
        scheduler: TaskScheduler,
        recovery: TaskRecovery,
        repository: SQLiteTaskStore
    ) {
        self.store = store
        self.service = service
        self.scheduler = scheduler
        self.recovery = recovery
        self.repository = repository
    }

    /// Enjekte edilen portlarla tam yığını kurar.
    static func make(
        repository: SQLiteTaskStore,
        providers: any TaskProviderRegistryPort,
        workspacePreflight: any TaskWorkspacePreflightPort,
        provisioning: any TaskWorkspaceProvisioningPort,
        recoveryProviders: any TaskProviderSessionInspecting,
        recoveryWorkspaces: any TaskWorkspaceOwnershipInspecting,
        recoveryProcesses: any TaskProcessOwnershipInspecting,
        verifier: any TaskVerifying,
        acceptanceEvidence: any TaskAcceptanceEvidenceProviding,
        clock: any TaskSchedulerClock,
        schedulerID: String,
        recoveryID: String,
        requiredSteps: [String]
    ) -> TaskBoardComposition {
        let scheduler = TaskScheduler(
            repository: repository,
            providers: providers,
            workspaces: workspacePreflight,
            verifier: verifier,
            clock: clock,
            schedulerID: schedulerID,
            provisioning: provisioning
        )
        let recovery = TaskRecovery(
            repository: repository,
            providers: recoveryProviders,
            workspaces: recoveryWorkspaces,
            processes: recoveryProcesses,
            clock: clock,
            recoveryID: recoveryID
        )
        let service = CodingTaskService(
            repository: repository,
            scheduler: scheduler,
            recovery: recovery,
            providers: providers,
            acceptanceEvidence: acceptanceEvidence,
            clock: clock,
            requiredSteps: requiredSteps
        )
        return TaskBoardComposition(
            store: TaskBoardStore(service: service),
            service: service,
            scheduler: scheduler,
            recovery: recovery,
            repository: repository
        )
    }

    /// Açılış uzlaştırması; zamanlayıcı herhangi bir tur işlemeden önce koşar.
    func reconcile(projectID: UUID) async -> RecoveryReport {
        await service.reconcile(projectID: projectID)
    }

    /// Bu sürecin sahiplendiği koşan denemeleri iptal eder ve mağazayı boşaltır.
    ///
    /// Yalnızca panonun gösterdiği projedeki `running` görevler durdurulur;
    /// başka hiçbir süreç sinyalle hedeflenmez ve OpenCode sunucu yaşam
    /// döngüsü uygulama temsilcisinde kalır.
    func shutdown() async {
        if let projectID = store.selectedProjectID,
            let snapshot = try? await service.snapshot(projectID: projectID)
        {
            for task in snapshot.tasks where task.status == .running {
                try? await service.stop(
                    taskID: task.id,
                    expectedVersion: task.version,
                    expectedAttemptID: task.currentAttemptID
                )
            }
        }
        await repository.close()
    }
}

extension TaskBoardComposition {
    /// Üretim yığınını kurar; görev veritabanı açılamazsa `nil` döner ve
    /// pano hiç takılmaz, uygulama açılışı bu yüzden başarısız olmaz.
    static func live(
        applicationSupportDirectory: URL?,
        openCodeServerManager: any OpenCodeServerManaging,
        openCodeTransport: any OpenCodeTransport,
        credentialStore: any CredentialStore,
        toolAuditLog: ToolAuditLog,
        permissionApprovalCenter: PermissionApprovalCenter,
        sessionConfiguration: @escaping @MainActor @Sendable () -> SessionConfiguration?
    ) -> TaskBoardComposition? {
        guard let applicationSupportDirectory else { return nil }
        let boardDirectory = applicationSupportDirectory.appendingPathComponent(
            AppIdentity.name,
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: boardDirectory, withIntermediateDirectories: true)
        } catch {
            AppLog.lifecycle.error(
                "Task board directory could not be created: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        let repository: SQLiteTaskStore
        do {
            repository = try SQLiteTaskStore.open(
                at: boardDirectory.appendingPathComponent("taskboard.sqlite", isDirectory: false)
            )
        } catch {
            AppLog.lifecycle.error(
                "Task board database could not be opened: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        // Yetenek kaydı: koşu gönderimi bu sürümde bağlı değildir; kayıt
        // yalnızca uygunluk sorusunu dürüstçe yanıtlar.
        let codingAgentRegistry = CodingAgentRegistry()
        codingAgentRegistry.register(
            runtime: OpenCodeCodingAgentAdapter(
                serverManager: openCodeServerManager,
                clientFactory: { connection in
                    OpenCodeClient(transport: openCodeTransport, connection: connection)
                },
                permissionHandler: { request in
                    await permissionApprovalCenter.submit(request)
                },
                cancelPendingPermissions: { remoteSessionID, appSessionID in
                    await permissionApprovalCenter.rejectAll(
                        remoteSessionID: remoteSessionID,
                        appSessionID: appSessionID
                    )
                },
                auditLog: toolAuditLog
            )
        )
        codingAgentRegistry.register(
            runtime: OpenAITextCodingAdapter(
                providerRuntime: OpenAIProviderRuntime(
                    transport: URLSessionOpenAITransport.streaming(),
                    credentialStore: credentialStore
                )
            )
        )

        let serviceBox = TaskBoardServiceBox()
        let projectResolver = TaskBoardProjectResolver(service: { serviceBox.service })
        let workspaceManager = GitWorkspaceManager(
            runner: GitCommandRunner(
                executableDirectory: URL(fileURLWithPath: "/usr/bin"),
                maxOutputBytes: 262_144
            ),
            projects: projectResolver,
            events: repository,
            configuration: WorkspaceManagerConfiguration(
                authorizedRoot: boardDirectory.appendingPathComponent("taskboard-workspaces", isDirectory: true),
                authorizedProjectRoots: []
            )
        )
        let provisioning = GitWorkspaceSchedulerProvisioningAdapter(
            manager: workspaceManager,
            approvalActor: "taskboard-composition"
        )
        let preflight = GitWorkspaceSchedulerAdapter(
            manager: workspaceManager,
            projects: projectResolver,
            tasks: repository
        )
        let recoveryWorkspaces = GitWorkspaceRecoveryAdapter(manager: workspaceManager)

        let verificationRunner = VerificationRunner(
            maxOutputBytes: 262_144,
            maxDetailsCharacters: 8_192,
            terminationGrace: 5,
            drainGrace: 2,
            gitExecutableDirectory: URL(fileURLWithPath: "/usr/bin")
        )
        let evidenceLedger = TaskEvidenceLedger(
            probe: WorkspaceFingerprintProbe(runner: verificationRunner)
        )
        let verifier = RecipeTaskVerifier(
            resolver: VerificationResolver(toolchain: .detected()),
            runner: verificationRunner,
            repository: repository,
            ledger: evidenceLedger
        )

        let composition = make(
            repository: repository,
            providers: LiveTaskProviderRegistry(
                registry: codingAgentRegistry,
                configuration: sessionConfiguration
            ),
            workspacePreflight: preflight,
            provisioning: provisioning,
            recoveryProviders: NoLiveTaskProviderSessions(),
            recoveryWorkspaces: recoveryWorkspaces,
            recoveryProcesses: NoLiveTaskProcesses(),
            verifier: verifier,
            acceptanceEvidence: evidenceLedger,
            clock: SystemTaskSchedulerClock(),
            schedulerID: "taskboard-scheduler",
            recoveryID: "taskboard-recovery",
            requiredSteps: AcceptanceGate.swiftPMRequiredSteps
        )
        serviceBox.install(composition.service)
        return composition
    }
}

/// Servis kurulmadan önce çalışma alanı yöneticisine verilen çözümleyici
/// kutusu; döngüsel kurulumu tek bir noktadan çözer.
private final class TaskBoardServiceBox: Sendable {
    private let storage = Mutex<CodingTaskService?>(nil)

    func install(_ service: CodingTaskService) {
        storage.withLock { $0 = service }
    }

    var service: CodingTaskService? {
        storage.withLock { $0 }
    }
}

private struct TaskBoardProjectResolver: WorkspaceProjectResolving {
    let service: @Sendable () async -> CodingTaskService?

    func resolveProject(id: UUID) async -> CodingProject? {
        guard let service = await service() else { return nil }
        return await service.project(id: id)
    }
}

/// Sohbette seçili sağlayıcı/model ile yetenek kaydını uzlaştıran uygunluk
/// portu. Eksik yetenekler olduğu gibi raporlanır; uygun olmayan sağlayıcı
/// asla sessizce yedeklenmez.
private struct LiveTaskProviderRegistry: TaskProviderRegistryPort {
    let registry: CodingAgentRegistry
    let configuration: @MainActor @Sendable () -> SessionConfiguration?

    func candidate(for task: CodingTask, stage: TaskStage) async -> TaskProviderCandidate {
        guard let configuration = await MainActor.run(body: configuration) else {
            return .unavailable(reason: "No chat provider configuration is selected")
        }
        switch await registry.checkEligibility(
            runtimeID: configuration.providerID.rawValue,
            configuration: configuration,
            required: Self.requiredCapabilities(for: stage)
        ) {
        case .supported:
            return .eligible(
                runtimeID: configuration.providerID.rawValue,
                modelID: configuration.modelID.rawValue
            )
        case .runtimeNotFound(let runtimeID):
            return .unavailable(reason: "Runtime \(runtimeID) is not registered for task runs")
        case .missingCapabilities(let missing, _):
            return .unsupported(missingCapabilities: missing)
        }
    }

    /// Aşamaya göre gereken yetenekler: plan metin okur, uygulama çalışma
    /// alanına yazar, inceleme çalışma alanını okur.
    static func requiredCapabilities(for stage: TaskStage) -> CodingAgentCapabilities {
        switch stage {
        case .analysis, .plan:
            return [.textAnalysis, .structuredEvents, .cancellable]
        case .implementation, .verification:
            return [.textAnalysis, .workspaceWrite, .tools, .structuredEvents, .cancellable]
        case .codeReview, .qa, .acceptance:
            return [.textAnalysis, .workspaceRead, .structuredEvents, .cancellable]
        }
    }
}

/// Koşu gönderimi bağlı olmadığından hiçbir sağlayıcı oturumu kalıcı bir
/// denemeye bağlı olamaz; kurtarma bu gerçeği `.stopped` olarak görür.
private struct NoLiveTaskProviderSessions: TaskProviderSessionInspecting {
    func providerStatus(for attempt: TaskAttempt) async -> TaskProviderSessionStatus {
        .stopped
    }
}

/// Hiçbir görev süreci başlatılmadığından sahipli süreç yoktur.
private struct NoLiveTaskProcesses: TaskProcessOwnershipInspecting {
    func processStatus(for attempt: TaskAttempt) async -> TaskProcessOwnershipStatus {
        .absent
    }
}

/// Çözümlenmiş güvenilir tarifi koşturur ve adım kanıtını görev/deneme
/// kimliğiyle bağlayıp mağazaya ve kanıt defterine yazar.
private struct RecipeTaskVerifier: TaskVerifying {
    let resolver: VerificationResolver
    let runner: VerificationRunner
    let repository: any CodingTaskRepository
    let ledger: TaskEvidenceLedger

    func verify(
        task: CodingTask,
        attempt: TaskAttempt,
        workspace: TaskWorkspaceDescriptor
    ) async -> TaskVerificationReport {
        let workspaceURL = URL(fileURLWithPath: workspace.workspacePath)
        do {
            let recipe = try await resolver.resolve(repository: workspaceURL)
            let raw = try await runner.verify(recipe: recipe, workspace: workspaceURL)
            let bound = raw.map { entry in
                VerificationEvidence(
                    id: entry.id,
                    taskID: task.id,
                    attemptID: attempt.id,
                    recipeName: entry.recipeName,
                    stepName: entry.stepName,
                    status: entry.status,
                    exitCode: entry.exitCode,
                    timedOut: entry.timedOut,
                    detailsRedacted: entry.detailsRedacted,
                    workspaceFingerprint: entry.workspaceFingerprint,
                    blockedBy: entry.blockedBy,
                    recordedAt: entry.recordedAt,
                    recipeVersion: entry.recipeVersion
                )
            }
            for entry in bound {
                try await repository.recordEvidence(entry)
            }
            await ledger.record(
                taskID: task.id,
                attemptID: attempt.id,
                workspacePath: workspace.workspacePath,
                evidence: bound
            )
            let requiredNames = recipe.steps.filter(\.required).map(\.name)
            let latestByStep = Dictionary(grouping: bound) { $0.stepName ?? "" }
                .mapValues { entries in entries.max { $0.recordedAt < $1.recordedAt } }
            let passed =
                !requiredNames.isEmpty
                && requiredNames.allSatisfy { name in
                    guard let entry = latestByStep[name] ?? nil else { return false }
                    return entry.status == .passed
                }
            return TaskVerificationReport(
                passed: passed,
                recipeName: recipe.name,
                detailsRedacted: passed
                    ? "Required recipe steps passed on the owned workspace revision"
                    : "Required recipe steps failed, were skipped, or changed the workspace revision"
            )
        } catch {
            return TaskVerificationReport(
                passed: false,
                recipeName: "unresolved",
                detailsRedacted: "Recipe resolution or execution failed: \(error)"
            )
        }
    }
}

/// Süreç ömürlü kanıt defteri.
///
/// Depo protokolü kanıt kaydedebilir ama henüz listeleyemez; bu yüzden
/// kompozisyon bu süreçte üretilen adım kanıtlarını ve çalışma alanı yolunu
/// saklar. Kabul değerlendirmesinde güncel içerik parmak izi, gerçek doğrulama
/// yürütücüsünün aynı algoritmasıyla yeniden okunur. Yeniden başlatmada defter
/// boştur ve kabul, kanıt görülmüş gibi yapmak yerine açık bir
/// `acceptanceInputUnavailable` gerekçesiyle reddedilir.
actor TaskEvidenceLedger: TaskAcceptanceEvidenceProviding {
    private let probe: WorkspaceFingerprintProbe
    private var entries: [UUID: [VerificationEvidence]] = [:]
    private var workspacePaths: [UUID: String] = [:]

    fileprivate init(probe: WorkspaceFingerprintProbe) {
        self.probe = probe
    }

    func record(
        taskID: UUID,
        attemptID: UUID,
        workspacePath: String,
        evidence: [VerificationEvidence]
    ) {
        let scoped = evidence.filter { $0.taskID == taskID && $0.attemptID == attemptID }
        guard !scoped.isEmpty else { return }
        entries[taskID, default: []].append(contentsOf: scoped)
        workspacePaths[taskID] = workspacePath
    }

    func acceptanceEvidence(taskID: UUID) async throws -> TaskAcceptanceEvidence {
        guard let recorded = entries[taskID], !recorded.isEmpty, let workspacePath = workspacePaths[taskID] else {
            throw TaskEvidenceLedgerError.evidenceNotLoadedInThisProcess
        }
        guard let fingerprint = await probe.fingerprint(of: workspacePath) else {
            throw TaskEvidenceLedgerError.workspaceFingerprintUnavailable(path: workspacePath)
        }
        return TaskAcceptanceEvidence(evidence: recorded, currentFingerprint: fingerprint)
    }
}

enum TaskEvidenceLedgerError: LocalizedError {
    case evidenceNotLoadedInThisProcess
    case workspaceFingerprintUnavailable(path: String)

    var errorDescription: String? {
        switch self {
        case .evidenceNotLoadedInThisProcess:
            return
                "verification evidence was recorded by an earlier process and cannot be listed by this one yet"
        case .workspaceFingerprintUnavailable(let path):
            return "the owned workspace fingerprint at \(path) could not be read"
        }
    }
}

/// Güncel çalışma alanı revizyonunu, doğrulama yürütücüsünün kendi
/// parmak izi hesabıyla okur: tek isteğe bağlı adımlı bir tarif koşturulur ve
/// kaydedilen parmak izi alınır. Böylece parmak izi mantığı ikinci kez
/// yazılmaz.
private struct WorkspaceFingerprintProbe: Sendable {
    let runner: VerificationRunner

    func fingerprint(of workspacePath: String) async -> String? {
        let recipe = VerificationRecipe(
            name: "workspace-fingerprint-probe",
            version: VerificationRecipe.currentVersion,
            trustedSource: "app composition",
            steps: [
                VerificationStep(
                    name: "fingerprint",
                    executable: "/usr/bin/true",
                    arguments: [],
                    relativeWorkingDirectory: ".",
                    timeoutSeconds: 30,
                    required: false
                )
            ],
            skippedSteps: []
        )
        guard
            let entries = try? await runner.verify(
                recipe: recipe,
                workspace: URL(fileURLWithPath: workspacePath)
            )
        else {
            return nil
        }
        return entries.first?.workspaceFingerprint
    }
}
