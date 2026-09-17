import AppKit
import SwiftUI

/// HUD'da gösterilen tek satır; canlı bağlantı kurulana kadar çağrı tarafı
/// `AgentSession` durumundan bu yapılara indirger.
struct HUDActivityItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String?
    let isRunning: Bool

    init(id: String, title: String, detail: String? = nil, isRunning: Bool = true) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isRunning = isRunning
    }
}

/// Cam efektli yüzer durum penceresi.
///
/// Odak çalmaz (`nonactivatingPanel` + `orderFrontRegardless`, asla
/// `makeKeyAndOrderFront` yok) ve ekran yakalamaya girmez
/// (`sharingType = .none`): aksi halde agent'ın kendi gördüğü ekran
/// görüntüsünde belirip geri besleme döngüsüne neden olurdu.
///
/// Canlı veri bağlantısı ertelendi (`AgentSession` şu anda başka bir
/// çalışmanın kirli alanında): `update(with:)` hazır dikiştir; oturum
/// tarafında "current computer step" yayımlandığında bağlanır.
@MainActor
final class FloatingHUDController {
    /// HUD'da tutulan en fazla satır.
    nonisolated static let maximumItems = 3

    private var panel: NSPanel?
    private var hostingView: NSHostingView<HUDContentView>?

    /// Son durumla pencereyi tazeler; liste boşsa gizler.
    func update(with items: [HUDActivityItem]) {
        let visible = Array(items.suffix(Self.maximumItems))
        guard !visible.isEmpty else {
            hide()
            return
        }
        let panel = ensuredPanel()
        hostingView?.rootView = HUDContentView(items: visible)
        panel.layoutIfNeeded()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    // MARK: - Özel

    private func ensuredPanel() -> NSPanel {
        if let panel {
            return panel
        }
        let contentRect = NSRect(x: 0, y: 0, width: 300, height: 96)
        let panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.sharingType = .none
        panel.hidesOnDeactivate = false

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: HUDContentView(items: []))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        hostingView = hosting

        if let frame = HUDContentView.preferredFrame {
            panel.setFrame(frame, display: false)
        }
        self.panel = panel
        return panel
    }
}

/// HUD içeriği; pencere denetleyiciden bağımsız, önizlenebilir SwiftUI görünümü.
struct HUDContentView: View {
    let items: [HUDActivityItem]

    /// Ekranın sağ üst köşesi (menü çubuğunun altı).
    nonisolated static var preferredFrame: NSRect? {
        guard let screen = NSScreen.main else {
            return nil
        }
        let frame = screen.visibleFrame
        let size = NSSize(width: 300, height: 96)
        return NSRect(
            x: frame.maxX - size.width - 16,
            y: frame.maxY - size.height - 12,
            width: size.width,
            height: size.height
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AGENT")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(1.5)

            ForEach(items) { item in
                HStack(spacing: 6) {
                    Circle()
                        .fill(item.isRunning ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)

                    Text(item.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)

                    if let detail = item.detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 300, height: 96, alignment: .topLeading)
    }
}
