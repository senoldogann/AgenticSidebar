import AppKit

@MainActor
final class MainWindowController {
    private weak var window: NSWindow?
    private var reopenAction: (() -> Void)?
    private let activateApplication: @MainActor () -> Void

    init(
        activateApplication: @escaping @MainActor () -> Void = {
            NSApp.activate()
        }
    ) {
        self.activateApplication = activateApplication
    }

    func register(_ window: NSWindow) {
        self.window = window
        window.isReleasedWhenClosed = false
    }

    func setReopenAction(_ action: @escaping () -> Void) {
        reopenAction = action
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            reopenAction?()
        }

        activateApplication()
    }

    func hide() {
        window?.orderOut(nil)
    }

    func toggle() {
        if window?.isVisible == true {
            hide()
        } else {
            show()
        }
    }
}
