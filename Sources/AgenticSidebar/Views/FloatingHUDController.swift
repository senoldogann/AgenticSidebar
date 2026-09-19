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
/// Canlı bağlantı `FloatingHUDHostView` üzerinden kurulur: `AgenticSidebarApp`
/// oturum etkinliklerini geçirir, `HUDActivityMapper` son üç bilgisayar
/// adımına indirger.
@MainActor
final class FloatingHUDController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<HUDContentView>?

    /// Son uygulanan içerik + çerçeve + zaman: streaming sırasında her
    /// aktivite değişiminde senkron `setFrame`/`layoutIfNeeded` dayatması
    /// display-cycle ile çakışıyordu. Değişmeyen içerik no-op, hızlı
    /// değişimler 4Hz'e kısılır, pencere işlemi yalnız gerçekten değiştiyse
    /// yapılır.
    ///
    /// Satır üst sınırı `HUDActivityMapper.maximumItems` tek kaynağındadır.
    private var lastAppliedItems: [HUDActivityItem] = []
    private var lastAppliedFrame: NSRect?
    private var lastAppliedAt = Date.distantPast
    private var pendingItems: [HUDActivityItem]?
    private var throttleTask: Task<Void, Never>?
    private static let minimumUpdateInterval: Duration = .milliseconds(250)

    /// Son durumla pencereyi tazeler; liste boşsa gizler.
    func update(with items: [HUDActivityItem]) {
        let visible = Array(items.suffix(HUDActivityMapper.maximumItems))
        guard !visible.isEmpty else {
            throttleTask?.cancel()
            throttleTask = nil
            pendingItems = nil
            hide()
            lastAppliedItems = []
            lastAppliedFrame = nil
            return
        }
        guard visible != lastAppliedItems || visible != pendingItems else {
            return
        }
        if Date().timeIntervalSince(lastAppliedAt) < 0.25 {
            pendingItems = visible
            guard throttleTask == nil else {
                return
            }
            throttleTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.minimumUpdateInterval)
                guard let self, !Task.isCancelled else {
                    return
                }
                self.throttleTask = nil
                if let pending = self.pendingItems {
                    self.pendingItems = nil
                    self.apply(items: pending)
                }
            }
            return
        }
        pendingItems = nil
        apply(items: visible)
    }

    /// İçeriği ve (değiştiyse) çerçeveyi uygular; görünürlük yalnız gerektiğinde.
    private func apply(items: [HUDActivityItem]) {
        lastAppliedAt = Date()
        lastAppliedItems = items
        let panel = ensuredPanel()
        hostingView?.rootView = HUDContentView(items: items)
        if let frame = HUDContentView.preferredFrame(itemCount: items.count),
            frame != lastAppliedFrame
        {
            lastAppliedFrame = frame
            panel.setFrame(frame, display: false)
            panel.layoutIfNeeded()
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
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

        self.panel = panel
        return panel
    }
}

/// Bilgisayar adımlarını HUD satırlarına indirger.
///
/// Saf eşleme: yalnızca çalışan `.computer` adımları alınır, son üçü
/// gösterilir. Tamamlanan adım timeline'da kalır, HUD'da kalmaz; çalışan adım
/// yoksa liste boş döner ve panel gizlenir.
enum HUDActivityMapper {
    /// HUD'da tutulan en fazla satır. Denetleyici kesmesi ve çerçeve hesabı
    /// dahil tüm üst sınır okumalarının tek kaynağı budur.
    nonisolated static let maximumItems = 3

    static func items(from activities: [AgentActivity]) -> [HUDActivityItem] {
        let running = activities.filter { $0.kind == .computer && $0.phase == .running }
        return Array(running.suffix(maximumItems)).map { activity in
            HUDActivityItem(
                id: activity.id.rawValue,
                title: activity.title ?? "Computer",
                detail: activity.detail,
                isRunning: true
            )
        }
    }
}

/// Canlı HUD ana bilgisayarı: görünmezdir, yalnızca denetleyiciyi besler.
///
/// `AgentSession` dosyasına dokunmadan oturum durumundan beslenir: çağıran
/// `sessionService.state.activityGroups.flatMap(\.activities)` geçirir.
/// Boşken panel gizlenir, doluyken `orderFrontRegardless` ile odak çalmadan
/// gösterilir.
struct FloatingHUDHostView: View {
    let activities: [AgentActivity]

    @State private var controller = FloatingHUDController()

    private var items: [HUDActivityItem] {
        HUDActivityMapper.items(from: activities)
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                controller.update(with: items)
            }
            .onChange(of: activities) { _, _ in
                controller.update(with: items)
            }
            .onDisappear {
                controller.hide()
            }
    }
}

/// HUD içeriği; pencere denetleyiciden bağımsız, önizlenebilir SwiftUI görünümü.
struct HUDContentView: View {
    let items: [HUDActivityItem]

    /// Satır sayısına göre içerik boyutu. Sabit 96pt üç satırda son satırı
    /// kesiyordu; panel ve içerik aynı kaynaktan beslenir.
    nonisolated static func frameSize(itemCount: Int) -> NSSize {
        let rows = max(1, min(itemCount, HUDActivityMapper.maximumItems))
        return NSSize(width: 300, height: CGFloat(40 + rows * 20))
    }

    /// Ekranın sağ üst köşesi (menü çubuğunun altı).
    nonisolated static func preferredFrame(itemCount: Int) -> NSRect? {
        guard let screen = NSScreen.main else {
            return nil
        }
        let frame = screen.visibleFrame
        let size = frameSize(itemCount: itemCount)
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
        .frame(
            width: Self.frameSize(itemCount: items.count).width,
            height: Self.frameSize(itemCount: items.count).height,
            alignment: .topLeading
        )
    }
}
