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

    private lazy var globalHotKeyController = GlobalHotKeyController { [weak self] in
        self?.mainWindowController.toggle()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        applyGlobalShortcut(.default)

        NSApp.activate()
        AppLog.lifecycle.info("Application launched with accessory activation policy")
    }

    /// Registers (or re-registers) the global show/hide shortcut. Registration is
    /// idempotent, so applying a stored preference on window appear is safe.
    func applyGlobalShortcut(_ spec: GlobalShortcutSpec) {
        do {
            try globalHotKeyController.register(spec)
            settingsStore?.globalShortcutError = nil
            AppLog.lifecycle.info(
                "Registered global shortcut with key code \(spec.keyCode, privacy: .public)"
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let managedShutdown else {
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
