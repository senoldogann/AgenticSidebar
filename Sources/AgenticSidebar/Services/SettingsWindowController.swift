import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var contentBuilder: (@MainActor () -> AnyView)?
    var isWindowOpen: Bool = false
    private var stealthModeEnabled: Bool = true

    /// Which tab the window shows and which card it scrolls to. Read by
    /// `SettingsView`, written by whoever opens the window.
    let navigation = SettingsNavigation()

    override init() {
        super.init()
    }

    func configure(contentBuilder: @escaping @MainActor () -> AnyView) {
        self.contentBuilder = contentBuilder
    }

    func setStealthMode(_ enabled: Bool) {
        stealthModeEnabled = enabled
        window?.sharingType = enabled ? .none : .readOnly
    }

    /// Opens the window without navigating to a specific tab or card.
    func show() {
        show(tab: nil, anchor: nil)
    }

    /// Opens the window on a specific tab.
    func show(tab: SettingsTab?) {
        show(tab: tab, anchor: nil)
    }

    /// Opens the window on a specific tab and card.
    func show(tab: SettingsTab?, anchor: SettingsAnchor?) {
        if tab != nil || anchor != nil {
            navigation.open(tab: tab ?? navigation.tab, anchor: anchor)
        }

        if let existing = window {
            if !existing.isVisible {
                existing.center()
            }
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
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
        newWindow.sharingType = stealthModeEnabled ? .none : .readOnly
        newWindow.center()

        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
