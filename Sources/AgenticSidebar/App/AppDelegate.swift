import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let mainWindowController = MainWindowController()
    let capturePrivacyController = CapturePrivacyController()

    var managedShutdown: (@MainActor () async -> Void)?
    var terminationReply: @MainActor (NSApplication, Bool) -> Void = { application, shouldTerminate in
        application.reply(toApplicationShouldTerminate: shouldTerminate)
    }

    private var terminationTask: Task<Void, Never>?

    private let logger = Logger(
        subsystem: AppIdentity.bundleIdentifier,
        category: "AppLifecycle"
    )

    private lazy var globalHotKeyController = GlobalHotKeyController { [weak self] in
        self?.mainWindowController.toggle()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            try globalHotKeyController.register()
            logger.info("Registered global Command-B shortcut")
        } catch {
            logger.error("Failed to register global Command-B shortcut: \(error.localizedDescription, privacy: .public)")
        }

        NSApp.activate()
        logger.info("Application launched with accessory activation policy")
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
                await managedShutdown()
                guard let self else {
                    return
                }
                self.terminationReply(sender, true)
            }
        }

        return .terminateLater
    }
}
