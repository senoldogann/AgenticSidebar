import AppKit
import SwiftUI

struct WindowLifecycleBridge: NSViewRepresentable {
    let windowController: MainWindowController
    let capturePrivacyController: CapturePrivacyController

    func makeNSView(context: Context) -> WindowObservationView {
        let view = WindowObservationView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: WindowObservationView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: WindowObservationView) {
        view.onWindowChange = { window in
            guard let window else {
                return
            }

            windowController.register(window)
            capturePrivacyController.configure(window: window)
        }
    }
}

final class WindowObservationView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

/// Sits as the window's delegate and converts the close button into a hide.
///
/// Keeping the window alive avoids a SwiftUI `WindowGroup` teardown which
/// would terminate the process (even though `applicationShouldTerminateAfterLastWindowClosed`
/// returns `false`, closing the *only* window can still trigger a quit path
/// depending on the macOS version and the `LSUIElement` flag).
@MainActor
final class HideOnCloseWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
