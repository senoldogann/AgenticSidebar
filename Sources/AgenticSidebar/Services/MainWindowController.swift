import AppKit

@MainActor
final class MainWindowController {
    private weak var window: NSWindow?
    private var reopenAction: (() -> Void)?
    private let activateApplication: @MainActor () -> Void
    private var currentOpacity: Double = 0.95
    private var colorSchemeMode: ColorSchemeMode = .system

    // Retained strongly so the window delegate is not released.
    private var hideOnCloseDelegate: HideOnCloseWindowDelegate?

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

        let delegate = HideOnCloseWindowDelegate()
        hideOnCloseDelegate = delegate
        window.delegate = delegate

        applyOpacity(currentOpacity, to: window)
        window.appearance = colorSchemeMode.windowAppearance
    }

    func setOpacity(_ opacity: Double) {
        currentOpacity = opacity
        if let window {
            applyOpacity(opacity, to: window)
        }
    }

    /// Applies the stored appearance mode to the window.
    ///
    /// `.system` clears the override instead of writing the mode it currently
    /// resolves to: an explicit `NSAppearance` pins every AppKit-drawn surface,
    /// so the window would stop following later system switches.
    func setAppearance(_ mode: ColorSchemeMode) {
        colorSchemeMode = mode
        window?.appearance = mode.windowAppearance
    }

    private func applyOpacity(_ opacity: Double, to window: NSWindow) {
        let clamped = CGFloat(max(0.40, min(1.00, opacity)))
        window.alphaValue = clamped
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
