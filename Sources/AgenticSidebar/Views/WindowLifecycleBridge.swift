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
