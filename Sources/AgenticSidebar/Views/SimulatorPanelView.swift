import SwiftUI

/// Sağ paneldeki iOS Simülatörü sekmesi: cihaz seçilir, açılır ve cihazın
/// ekranı uygulamanın içinde izlenir.
///
/// Görüntü önce cihazın kendi ekran yüzeyinden (CoreSimulator framebuffer,
/// ~30 fps, pencere ve izin gerektirmez) gelir; kurulamazsa `SimulatorService`
/// pencere akışına (`SCStream`, yalnız Simulator.app) ve `simctl` karelerine
/// düşer. Panel yalnız görünürken akış koşar. Dokunma ve sürükleme görüntünün
/// üstünden cihaza gider (Indigo HID); yazı için "Open window" cihazı
/// gösteren uygulamayı (Simulator/DeviceHub) öne getirir.
struct SimulatorPanelView: View {
    let service: SimulatorService
    let preset: AppThemePreset
    let isDark: Bool
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .opacity(0.4)

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(preset.surface(isDark: isDark).opacity(0.96))
        .onAppear {
            service.panelAppeared()
        }
        .onDisappear {
            service.panelDisappeared()
        }
    }

    // MARK: - Başlık

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .help(statusHelp)

            Text("iOS Simulator")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.primary)

            if let device = service.selectedDevice {
                Text("\(device.name) · \(device.runtimeName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            deviceMenu

            if isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 20, height: 20)
            }

            Button {
                Task { await service.refreshDevices() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .interactiveHoverCircle()
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .disabled(service.phase == .scanning)
            .help("Refresh the device list")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .interactiveHoverCircle()
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Close the simulator panel")
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
    }

    private var deviceMenu: some View {
        Menu {
            ForEach(service.devices) { device in
                Button {
                    service.select(deviceID: device.id)
                } label: {
                    if device.id == service.selectedDeviceID {
                        Label(deviceLabel(device), systemImage: "checkmark")
                    } else {
                        Text(deviceLabel(device))
                    }
                }
            }
        } label: {
            Text(service.selectedDevice?.name ?? "Choose device")
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(service.devices.isEmpty)
        .help("Choose which simulator device to show")
    }

    private func deviceLabel(_ device: SimulatorDevice) -> String {
        "\(device.name) · \(device.runtimeName)\(device.isBooted ? " · On" : "")"
    }

    // MARK: - İçerik

    @ViewBuilder
    private var content: some View {
        switch service.phase {
        case .idle, .scanning:
            centeredNotice(
                icon: nil,
                title: "Looking for simulator devices…",
                detail: "The list comes from Xcode's `simctl`."
            )
        case .unavailable(let message):
            centeredNotice(
                icon: "exclamationmark.triangle",
                title: "Simulator tools are unavailable",
                detail: message
            )
        case .ready:
            if service.devices.isEmpty {
                centeredNotice(
                    icon: "iphone.slash",
                    title: "No iPhone simulators",
                    detail: "Create one in Xcode (Window ▸ Devices and Simulators) and refresh."
                )
            } else if let device = service.selectedDevice, !device.isBooted {
                bootState(device: device)
            } else {
                liveSurface
            }
        }
    }

    /// Cihaz kapalı: kare yok, açma düğmesi önde.
    private func bootState(device: SimulatorDevice) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)

            Text("\(device.name) is shut down")
                .font(.system(size: 12.5, weight: .semibold))

            Text("Boot it to see its screen here. The first boot takes a while; the view appears on its own.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            bootButton(device: device)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var liveSurface: some View {
        VStack(spacing: 0) {
            ZStack {
                if let frame = service.frame {
                    iPhoneDeviceFrame(frame: frame)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .accessibilityLabel("Live view of the iOS Simulator screen. Tap and drag to interact.")
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Waiting for the first frame…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            streamFallbackNotice

            Divider()
                .opacity(0.4)

            footer
        }
    }

    /// Canlı akış tutunamadığında nedenini çerçevenin altında gösterir:
    /// daha önce bu ileti yalnız yardım balonundaydı, kullanıcı `simctl`
    /// rozetini görüp sebebini öğrenemiyordu. Yanında tek denemelik
    /// yeniden kurma düğmesi durur; pencere kapalıysa "Open window" yolu
    /// footer'dadır.
    @ViewBuilder
    private var streamFallbackNotice: some View {
        if !service.isFramebufferActive,
            case .unavailable(let message) = service.liveStream.phase,
            service.selectedDevice?.isBooted == true
        {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Button {
                    service.retryLiveStream()
                } label: {
                    Label("Retry stream", systemImage: "arrow.counterclockwise.circle")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .pointingHandCursor()
                .help("Try attaching the live window stream again")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
    }

    /// Gerçek iPhone görünümü: titanyum çerçeve, yan düğmeler, Dynamic Island
    /// ve ana ekran göstergesiyle cihaz karesini sarar.
    ///
    /// Dokunma katmanı ekran görüntüsünün üstündedir; çerçeve ve ada
    /// tıklanamaz (`allowsHitTesting(false)`), bu yüzden normalize koordinat
    /// hep ekran oranına göre bölünür.
    ///
    /// `.drawingGroup()` ile tek bir Metal katmanına rasterize edilir:
    /// kare değiştiğinde SwiftUI layout ağacını yeniden hesaplamaz, GPU'da
    /// yalnız piksel değişimi kalır. Bu, ~12 fps canlı akışta layout thrashing
    /// (örn. 200+ `NSView _layoutSubtreeWithOldSize:` çerçevesi) engeller.
    private func iPhoneDeviceFrame(frame: CGImage) -> some View {
        // Framebuffer karesi cihazın gerçek ekranıdır: Dynamic Island ve ana
        // ekran göstergesini iOS kendisi çizer. Taklit kapsüller yalnız
        // `simctl`/pencere karelerinde çizilir; yoksa ikişer görünürlerdi.
        let drawsHardwareChrome = !service.isFramebufferActive
        return ZStack {
            Image(decorative: frame, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
                .overlay {
                    SimulatorTouchSurface(
                        onPressDown: { service.pressDownAt(normalizedX: $0, normalizedY: $1) },
                        onPressMove: { service.pressMoveTo(normalizedX: $0, normalizedY: $1) },
                        onPressUp: { service.pressUpAt(normalizedX: $0, normalizedY: $1) }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
                }
                .overlay(alignment: .top) {
                    if drawsHardwareChrome {
                        Capsule()
                            .fill(Color.black)
                            .frame(width: 92, height: 26)
                            .padding(.top, 12)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottom) {
                    if drawsHardwareChrome {
                        Capsule()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 112, height: 4.5)
                            .padding(.bottom, 9)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(11)
        .background {
            RoundedRectangle(cornerRadius: 50, style: .continuous)
                .fill(Color(white: 0.09))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 50, style: .continuous)
                .stroke(Color(white: 0.32), lineWidth: 1.5)
        }
        .overlay(alignment: .leading) {
            VStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(white: 0.25))
                    .frame(width: 3, height: 26)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(white: 0.25))
                    .frame(width: 3, height: 48)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(white: 0.25))
                    .frame(width: 3, height: 48)
            }
            .offset(x: -13.5)
            .padding(.bottom, 120)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(white: 0.25))
                .frame(width: 3, height: 72)
                .offset(x: 13.5)
                .padding(.bottom, 60)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .drawingGroup()
    }

    private var footer: some View {
        HStack(spacing: 8) {
            liveBadge

            Text("Tap and drag directly on the screen; hold the button in Open window for typing.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if let device = service.selectedDevice {
                bootButton(device: device)
                retryTouchButton
                openWindowButton
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Akış ve dokunma rozetleri: canlı akış aktifken yeşil "Canlı", izin
    /// yoksa izin düğmesi, `simctl` yolundayken kare hızı notu; köprü
    /// hatasındayken dokunma rozeti ayrıca belirir. Dördünün yardım metni
    /// farklıdır, kullanıcı hangi yolun neden devrede olduğunu görür.
    @ViewBuilder
    private var liveBadge: some View {
        streamBadge
        hidBadge
    }

    /// Pencere akışının rozeti: canlı akış aktifken yeşil "Canlı", izin
    /// yoksa izin düğmesi, `simctl` yolundayken kare hızı notu.
    ///
    /// `Equatable` conformance sayesinde phase aynı kaldığında View kimliği
    /// değişmez, aniden yeniden render olmaz. Bu, canlı akış başladığında/
    /// bittiğinde tek seferlik geçişe indirger.
    @ViewBuilder
    private var streamBadge: some View {
        let phase = service.liveStream.phase
        let isBooted = service.selectedDevice?.isBooted == true

        if service.isFramebufferActive {
            Label("Canlı · 30 fps", systemImage: "bolt.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.green)
                .help(
                    "The device screen is read directly from the simulator (~30 fps); no window or Screen Recording permission is needed."
                )
        } else {
            windowStreamBadge(phase: phase, isBooted: isBooted)
        }
    }

    @ViewBuilder
    private func windowStreamBadge(phase: SimulatorLiveStreamPhase, isBooted: Bool) -> some View {
        switch phase {
        case .active:
            Label("Canlı", systemImage: "bolt.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.green)
                .help("Live window stream (~12 fps)")
        case .denied:
            Button {
                service.requestLiveStreamAccess()
            } label: {
                Label("Ekran Kaydı", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .pointingHandCursor()
            .help("Grant Screen Recording for a fluid live stream; until then frames come from simctl.")
        case .idle, .starting, .unavailable:
            if isBooted {
                Label("simctl · ~1 fps", systemImage: "camera.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help(
                        "The direct screen stream is not available with this Xcode, so frames come from simctl (about 1 fps)."
                    )
            } else {
                EmptyView()
            }
        }
    }

    /// Dokunma köprüsü rozeti: son dokunuş düştüyse belirir, hatayı ve
    /// yeniden deneme yolunu gösterir. Akış rozetinden bağımsızdır, ikisi
    /// yan yana durabilir.
    @ViewBuilder
    private var hidBadge: some View {
        if !service.hidReady {
            Label("Dokunma kapalı", systemImage: "hand.raised.slash")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.orange)
                .help(
                    "The last touch could not be sent\(service.lastHIDError.map { ": \($0)" } ?? ""). The device session may have changed; use Retry touch to send it again."
                )
        }
    }

    /// Son dokunuş düştüyse görünen düğme: aynı koordinata tek dokunuşu
    /// tekrar gönderir, ölmüş köprü istemcisinin yeniden kurulmasını tetikler.
    @ViewBuilder
    private var retryTouchButton: some View {
        if service.failureMessage != nil {
            Button {
                service.retryLastTouch()
            } label: {
                Label("Retry touch", systemImage: "arrow.counterclockwise.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointingHandCursor()
            .help(
                "Send the last touch again\(service.failureMessage.map { " (last error: \($0))" } ?? "")"
            )
        }
    }

    @ViewBuilder
    private func bootButton(device: SimulatorDevice) -> some View {
        if device.isBooted {
            Button {
                Task { await service.shutdown(deviceID: device.id) }
            } label: {
                Label("Shut down", systemImage: "stop.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointingHandCursor()
            .disabled(service.busyDeviceIDs.contains(device.id))
            .help("Shut the simulator device down")
        } else {
            Button {
                Task { await service.boot(deviceID: device.id, headless: false) }
            } label: {
                Label("Boot", systemImage: "play.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .pointingHandCursor()
            .disabled(service.busyDeviceIDs.contains(device.id))
            .help("Boot the simulator device; its screen appears here without opening a simulator window")
        }
    }

    private var openWindowButton: some View {
        Button {
            // Açık istek: pencere öne ve bu Space'e gelir, akış gizli
            // pencere kovalamaz.
            service.openDeviceWindow(activate: true)
        } label: {
            Label("Open window", systemImage: "macwindow.on.rectangle")
                .font(.system(size: 11))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .pointingHandCursor()
        .help("Bring the simulator window forward for direct interaction")
    }

    private func centeredNotice(icon: String?, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            Text(title)
                .font(.system(size: 12.5, weight: .semibold))

            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if let failureMessage = service.failureMessage {
                Text(failureMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    // MARK: - Durum

    private var isBusy: Bool {
        service.selectedDevice.map { service.busyDeviceIDs.contains($0.id) } ?? false
    }

    private var statusColor: Color {
        guard let device = service.selectedDevice else {
            return Color.secondary.opacity(0.5)
        }
        if service.busyDeviceIDs.contains(device.id) {
            return Color.orange
        }
        return device.isBooted ? Color.green.opacity(0.85) : Color.secondary.opacity(0.5)
    }

    private var statusHelp: String {
        guard let device = service.selectedDevice else {
            return "No device selected"
        }
        return device.isBooted ? "The device is running" : "The device is shut down"
    }
}
