import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let mainWindowController = MainWindowController()
    let settingsWindowController = SettingsWindowController()
    let capturePrivacyController = CapturePrivacyController()

    var managedShutdown: (@MainActor () async -> Void)?
    var terminationReply: @MainActor (NSApplication, Bool) -> Void = { application, shouldTerminate in
        application.reply(toApplicationShouldTerminate: shouldTerminate)
    }

    /// Kısayol kaydının sonucunun yazılacağı yer; App tarafından bağlanır.
    weak var settingsStore: SettingsStore?

    /// Kapanışın beklenebileceği en uzun süre. Adımların her biri kendi başına
    /// sınırlı; ama tek bir adımın takılması uygulamayı kapatılamaz hâle
    /// getirmemeli.
    static let shutdownDeadline = Duration.seconds(3)

    private var terminationTask: Task<Void, Never>?
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private var hangWatchdogTask: Task<Void, Never>?

    private lazy var globalHotKeyController = GlobalHotKeyController { [weak self] in
        self?.mainWindowController.toggle()
    }

    /// Snap Context bağlantısı; `AgenticSidebarApp` kurup atar (tek ertelenen adım).
    ///
    /// Atama `didSet` üzerinden kısayolu kaydeder, çünkü atama anı
    /// `applicationDidFinishLaunching` sırasına göre belirsizdir: hangisi önce
    /// koşarsa koşsun kayıt yapılır, ikisi de koşarsa kayıt yenilenir.
    var snapCoordinator: ContextSnapCoordinator? {
        didSet {
            applySnapShortcut()
        }
    }

    private lazy var snapHotKeyController = GlobalHotKeyController(
        action: { [weak self] in
            self?.snapCoordinator?.handleSnapHotKey()
        }, hotKeyID: 2)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        CrashReporter.install()
        hangWatchdogTask = MainThreadHangWatchdog.start()
        applyGlobalShortcut(launchShortcut)
        applySnapShortcut()
        installTerminationSignalHandlers()

        NSApp.activate(ignoringOtherApps: true)
        mainWindowController.show()
        AppLog.lifecycle.info("Application launched with accessory activation policy (Dock-less)")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainWindowController.show()
        }
        return true
    }

    /// Runs the managed shutdown when the process is asked to end by signal.
    ///
    /// `applicationShouldTerminate` only runs for a *graceful* quit. A signal —
    /// `pkill` from the development script, a logout, `kill` from anywhere — ends
    /// the process without AppKit being consulted at all, so the OpenCode server
    /// and its MCP children stayed alive with nobody left to stop them. Thirty-six
    /// orphaned servers were found on this machine, all started this way.
    ///
    /// A dispatch source rather than a signal handler function: the handler has to
    /// be async-signal-safe, and starting tasks and awaiting cleanups is not.
    private func installTerminationSignalHandlers() {
        for number in [SIGTERM, SIGINT] {
            // The source only delivers a signal that is not handled by the default
            // disposition, which would otherwise terminate us first.
            signal(number, SIG_IGN)

            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                self?.handleTerminationSignal()
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    private func handleTerminationSignal() {
        guard terminationTask == nil else {
            return
        }

        terminationTask = Task { @MainActor [weak self] in
            if let managedShutdown = self?.managedShutdown {
                _ = await Self.runShutdown(managedShutdown)
            }

            AppLog.lifecycle.info("Termination signal handled; exiting")
            exit(EXIT_SUCCESS)
        }
    }

    /// The shortcut registered at launch: the **stored** choice, never the
    /// built-in default.
    ///
    /// Registering `.default` here used to clobber the user's preference. The
    /// window applies the stored spec as it appears, and when the built-in default
    /// became a different chord (⇧⌘B, see ``GlobalShortcutSpec/default``) this later
    /// registration silently replaced it — the window had already registered ⌘B,
    /// and the launch path then unregistered it and took ⇧⌘B instead. The chosen
    /// shortcut stopped working, and nothing said why.
    var launchShortcut: GlobalShortcutSpec {
        settingsStore?.globalShortcutChoice.spec ?? .default
    }

    /// Registers (or re-registers) the global show/hide shortcut. Registration is
    /// idempotent, so applying a stored preference on window appear is safe.
    func applyGlobalShortcut(_ spec: GlobalShortcutSpec) {
        do {
            try globalHotKeyController.register(spec)
            settingsStore?.globalShortcutError = nil
            // The modifiers are logged as well: when a stored choice was replaced
            // by the built-in default, ⌘B and ⇧⌘B were indistinguishable in this
            // line, which is exactly why the regression went unnoticed.
            AppLog.lifecycle.info(
                "Registered global shortcut with key code \(spec.keyCode, privacy: .public) and modifiers \(spec.modifiers, privacy: .public)"
            )
        } catch {
            // Sessiz bir başarısızlık, hiç çalışmayan bir kısayolun etkin
            // görünmesi demekti; neden Ayarlar ekranında gösterilir.
            let name = settingsStore?.globalShortcutChoice.displayName ?? "The shortcut"
            settingsStore?.globalShortcutError =
                "\(name) could not be registered — another app already owns it. Pick a different shortcut."
            AppLog.lifecycle.error(
                "Failed to register the global shortcut: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Snap Context (⇧⌘D) kısayolunu kaydeder. Koordinatör henüz atanmamışsa
    /// sessizce atlanır; atama `didSet` üzerinden yeniden dener.
    func applySnapShortcut() {
        guard snapCoordinator != nil else {
            return
        }
        do {
            try snapHotKeyController.register(.contextSnap)
            AppLog.lifecycle.info("Registered Snap Context shortcut (⇧⌘D)")
        } catch {
            AppLog.lifecycle.error(
                "Failed to register the Snap Context shortcut: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let managedShutdown else {
            hangWatchdogTask?.cancel()
            hangWatchdogTask = nil
            CrashReporter.markCleanExit()
            return .terminateNow
        }

        if terminationTask == nil {
            terminationTask = Task { @MainActor [weak self] in
                let finished = await Self.runShutdown(managedShutdown)
                if !finished {
                    AppLog.lifecycle.error(
                        "Managed shutdown did not finish within \(Self.shutdownDeadline.components.seconds, privacy: .public)s; terminating anyway"
                    )
                }

                guard let self else {
                    return
                }
                self.hangWatchdogTask?.cancel()
                self.hangWatchdogTask = nil
                CrashReporter.markCleanExit()
                self.terminationReply(sender, true)
            }
        }

        return .terminateLater
    }

    /// Kapanışı bir son tarihle çalıştırır.
    ///
    /// Sonuç `true` ise temizlik kendi başına bitti; `false` ise süre doldu ve
    /// uygulama yine de kapanıyor. Kapatmak kullanıcının kararıdır: yanıt vermeyen
    /// bir pencere bırakmak, tek bir adımın tamamlanmamasından daha kötüdür.
    ///
    /// Yarış bir görev grubu yerine tek noktadan sonuçlanan bir kapı ile kurulur:
    /// `withTaskGroup` içinde `@MainActor` bir kapanış Swift 6.3'te bölge tabanlı
    /// yalıtım denetleyicisini takıyor.
    static func runShutdown(
        _ shutdown: @escaping @MainActor () async -> Void,
        deadline: Duration = AppDelegate.shutdownDeadline
    ) async -> Bool {
        let gate = ShutdownGate()

        let work = Task { @MainActor in
            await shutdown()
            await gate.complete(true)
        }

        let timeout = Task {
            try? await Task.sleep(for: deadline)
            await gate.complete(false)
        }

        let finished = await gate.wait()
        timeout.cancel()
        if !finished {
            work.cancel()
        }

        return finished
    }
}

/// Kapanış yarışının tek sefer sonuçlanmasını sağlar: iki taraf da bitişi
/// bildirebilir, `wait()` yalnızca ilk geleni döndürür.
private actor ShutdownGate {
    private var decided: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func complete(_ value: Bool) {
        guard decided == nil else {
            return
        }

        decided = value
        continuation?.resume(returning: value)
        continuation = nil
    }

    func wait() async -> Bool {
        if let decided {
            return decided
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}
