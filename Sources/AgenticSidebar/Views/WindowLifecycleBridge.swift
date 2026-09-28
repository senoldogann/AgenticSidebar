import AppKit
import SwiftUI

struct WindowLifecycleBridge: NSViewRepresentable {
    let windowController: MainWindowController
    let capturePrivacyController: CapturePrivacyController
    let stealthModeEnabled: Bool

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
            windowController.setStealthMode(stealthModeEnabled)
            capturePrivacyController.configure(window: window, stealthMode: stealthModeEnabled)
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

/// Sheet gibi sonradan doğan pencerelerin gizli moddan muaf kalmaması için
/// barındığı pencerenin paylaşım tipini ayarlar. Pencere görünüm ağacına
/// girdiğinde ve ayar değiştiğinde uygulanır.
struct WindowSharingConfigurator: NSViewRepresentable {
    let excludedFromCapture: Bool

    func makeNSView(context: Context) -> WindowSharingObservationView {
        let view = WindowSharingObservationView()
        view.excludedFromCapture = excludedFromCapture
        return view
    }

    func updateNSView(_ nsView: WindowSharingObservationView, context: Context) {
        nsView.excludedFromCapture = excludedFromCapture
        nsView.applyToWindow()
    }
}

final class WindowSharingObservationView: NSView {
    var excludedFromCapture: Bool = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyToWindow()
    }

    func applyToWindow() {
        guard let window else {
            return
        }

        let target: NSWindow.SharingType = excludedFromCapture ? .none : .readOnly
        window.sharingType = target
        for child in window.childWindows ?? [] {
            child.sharingType = target
        }
    }
}

/// Sits as the window's delegate and converts the close button into a hide.
///
/// Keeping the window alive avoids a SwiftUI `WindowGroup` teardown which
/// would terminate the process (even though `applicationShouldTerminateAfterLastWindowClosed`
/// returns `false`, closing the *only* window can still trigger a quit path
/// depending on the macOS version and the `LSUIElement` flag).
///
/// SwiftUI kendi sahne penceresine bir delege takar ve boyut, odak ve yaşam
/// döngüsü bildirimlerini oradan alır. Bu sınıf o delegenin yerini almaz,
/// önüne geçer: yalnız `windowShouldClose` burada yanıtlanır, geri kalan her
/// seçici Objective-C mesaj iletimiyle özgün delegeye gider.
@MainActor
final class HideOnCloseWindowDelegate: NSObject, NSWindowDelegate {
    /// Özgün (SwiftUI) delege. `NSWindow.delegate` zayıf tutulduğu için güçlü
    /// tutulur; vekil yaşadıkça hedef de yaşar. AppKit ileti sorgularını
    /// (`responds(to:)`, `forwardingTarget(for:)`) ana iş parçacığında yapar;
    /// değer yalnız kurulumda yazılır, sonra hiç değişmez.
    nonisolated(unsafe) private let forwardTarget: NSWindowDelegate?

    init(forwardingTo forwardTarget: NSWindowDelegate?) {
        self.forwardTarget = forwardTarget
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) {
            return true
        }
        return forwardTarget?.responds(to: aSelector) ?? false
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let forwardTarget, forwardTarget.responds(to: aSelector) {
            return forwardTarget
        }
        return super.forwardingTarget(for: aSelector)
    }
}
