import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var contentBuilder: (@MainActor () -> AnyView)?
    var isWindowOpen: Bool = false

    override init() {
        super.init()
    }

    func configure(contentBuilder: @escaping @MainActor () -> AnyView) {
        self.contentBuilder = contentBuilder
    }

    func show() {
        if let existing = window {
            if !existing.isVisible {
                existing.center()
            }
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            isWindowOpen = true
            return
        }

        guard let contentBuilder else {
            return
        }

        let content = contentBuilder()
        let hostingController = NSHostingController(rootView: content)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Settings"
        newWindow.titleVisibility = .hidden
        newWindow.titlebarAppearsTransparent = true
        newWindow.isMovableByWindowBackground = true
        newWindow.minSize = NSSize(width: 800, height: 600)
        newWindow.isReleasedWhenClosed = false
        newWindow.contentViewController = hostingController
        newWindow.delegate = self
        newWindow.center()

        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
        isWindowOpen = true
    }

    func hide() {
        window?.orderOut(nil)
        isWindowOpen = false
    }

    func close() {
        window?.close()
        window = nil
        isWindowOpen = false
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
            self.isWindowOpen = false
        }
    }
}
