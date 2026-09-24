import CoreGraphics
import CoreImage
import Foundation
import Observation
import ScreenCaptureKit

// MARK: - Pencere seçimi (saf çekirdek)

// `SCWindow`'un teste sokulabilir özeti: üretim eşlemesi
// `SimulatorWindowCapture.describe` ile yapılır.
struct SimulatorWindowInfo: Equatable, Sendable {
    let windowID: CGWindowID
    let ownerBundleID: String?
    let title: String?
    let isOnScreen: Bool
    let area: CGFloat
}

/// Seçili cihazı gösteren Simulator penceresini bulur.
///
/// Saf: ekran okumaz, yalnız verilen listeden seçer. Başlık cihaz adını
/// içerir ("iPhone 17", "iPhone 17 Pro - iOS 26.5"…); birden çok eşleşmede
/// en geniş pencere kazanır (ana cihaz penceresi, önizleme küçük resmine
/// karşı). Eşleşme yoksa `nil`: arayan `simctl` akışına düşer.
enum SimulatorWindowSelector {
    /// Pencereyi açan uygulamalar: Xcode 26 öncesi Simulator, sonrası DeviceHub.
    static let ownerBundleIDs: Set<String> = [
        "com.apple.iphonesimulator",
        "com.apple.dt.Devices",
        "com.apple.dt.DeviceHub",
    ]

    static func select(deviceName: String, windows: [SimulatorWindowInfo]) -> SimulatorWindowInfo? {
        let needle = deviceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            return nil
        }
        return
            windows
            .filter { window in
                guard window.isOnScreen, window.area > 0 else {
                    return false
                }
                guard let owner = window.ownerBundleID, ownerBundleIDs.contains(owner) else {
                    return false
                }
                guard let title = window.title?.lowercased(), title.contains(needle) else {
                    return false
                }
                return true
            }
            .max(by: { $0.area < $1.area })
    }
}

// MARK: - Akış evresi

/// Canlı pencere akışının durumu: `simctl` kareleri her durumda akmaya
/// devam eder, bu evre yalnız pencere akışının (12 fps) ne âlemde olduğunu
/// söyler. Akış ölürse panel sessizce `simctl`'e döner.
enum SimulatorLiveStreamPhase: Equatable, Sendable {
    case idle
    case starting
    case active
    /// Kullanıcı Ekran Kaydı iznini vermedi: panel izin düğmesi gösterir.
    case denied(message: String)
    /// Pencere yok ya da akış kurulamadı: `simctl` devralır.
    case unavailable(message: String)
}

// MARK: - Akış çıkışı

/// `SCStream` geri çağrılarını kare ve hata kapanışlarına indirger.
///
/// `SCStreamOutput` geri çağrıları yakalama kuyruğunda koşar; piksel
/// tamponu burada `CGImage`'e çevrilir, yalnız bitmiş kare yukarı verilir.
/// `CIContext` iş parçacığı güvenlidir, tek örnek paylaşılır.
final class SimulatorStreamSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let onFrame: @Sendable (CGImage) -> Void
    private let onError: @Sendable (Error) -> Void
    private let context = CIContext()

    init(onFrame: @escaping @Sendable (CGImage) -> Void, onError: @escaping @Sendable (Error) -> Void) {
        self.onFrame = onFrame
        self.onError = onError
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else {
            return
        }
        autoreleasepool {
            guard
                let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                let image = context.createCGImage(
                    CIImage(cvPixelBuffer: pixelBuffer),
                    from: CGRect(
                        origin: .zero, size: CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)))
                )
            else {
                return
            }
            onFrame(image)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error)
    }
}

// MARK: - Canlı pencere akışı

/// Seçili cihazın Simulator penceresini `SCStream` ile yakalar (~12 fps).
///
/// `simctl io screenshot` turun başına ~380 ms koyar ve akışı ~2 fps'e
/// kilitler; pencere akışı aynı görüntüyü pencere yöneticisinden alır,
/// dokunuşun karşılığı yarım saniyeden kısa sürede panele düşer. İzin
/// (`ComputerUseAppPermissionReading` ile aynı okuyucu) ya da pencere
/// yoksa akış kurulmaz ve `SimulatorService` `simctl` yolunda kalır.
@MainActor
@Observable
final class SimulatorLiveStream {
    private(set) var phase: SimulatorLiveStreamPhase = .idle
    private(set) var frame: CGImage?

    /// Saniyede hedef kare: akıcı kaydırma için 12, CPU için mütevazı.
    nonisolated static let framesPerSecond = 12
    /// Yakalama genişliği tavanı (piksel): cihaz penceresi daha genişse
    /// oran korunarak indirilir.
    nonisolated static let maximumFrameWidth = 900

    var isActive: Bool {
        phase == .active
    }

    @ObservationIgnored
    private let permissionReader: any ComputerUseAppPermissionReading

    @ObservationIgnored
    private var stream: SCStream?

    @ObservationIgnored
    private var sink: SimulatorStreamSink?

    @ObservationIgnored
    private var streamTask: Task<Void, Never>?

    @ObservationIgnored
    private var currentDeviceName: String?

    /// Yeni kare geldiğinde çağrılır; `SimulatorService` buraya kendini takar
    /// ve kareyi `simctl` sırasını beklemeden yayınlar.
    @ObservationIgnored
    var onFrame: (@Sendable (CGImage) -> Void)?

    init(permissionReader: any ComputerUseAppPermissionReading = SystemComputerUseAppPermissionReader()) {
        self.permissionReader = permissionReader
    }

    /// Cihaz penceresinin akışını başlatır; aynı cihaz zaten akıyorsa no-op,
    /// başka cihaza geçildiyse akış yeni pencerede yeniden kurulur.
    func start(deviceName: String) {
        let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        if trimmed == currentDeviceName, streamTask != nil {
            return
        }
        stop()
        currentDeviceName = trimmed
        phase = .starting
        streamTask = Task { [weak self] in
            await self?.run(deviceName: trimmed)
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        currentDeviceName = nil
        // Akış `run` sonunda kapatılır; buradaki yakalama yalnız
        // pencereyi anında bırakır, görev sonu kalanı toplar.
        let captured = stream
        stream = nil
        sink = nil
        if captured != nil {
            Task {
                try? await captured?.stopCapture()
            }
        }
        if phase == .active || phase == .starting {
            phase = .idle
        }
        frame = nil
    }

    /// macOS'un Ekran Kaydı istemini gösterir; izin verilirse akış
    /// kendiliğinden başlar (paneldeki izin düğmesi burayı çağırır).
    func requestAccess() {
        guard currentDeviceName != nil else {
            return
        }
        AppLog.panels.info("Simulator live stream: asking macOS for Screen Recording")
        Task { [weak self] in
            let granted = await self?.permissionReader.requestScreenRecording() ?? false
            guard let self else {
                return
            }
            AppLog.panels.info(
                "Simulator live stream: the Screen Recording request came back as \(granted ? "granted" : "not granted yet", privacy: .public)"
            )
            if granted, let name = self.currentDeviceName {
                self.start(deviceName: name)
            } else if !granted {
                self.phase = .denied(message: Self.permissionHint)
            }
        }
    }

    nonisolated static let permissionHint =
        "Screen Recording is off for AgenticSidebar. Turn it on in System Settings ▸ Privacy & Security ▸ Screen Recording, then reopen the panel."

    // MARK: - Akış döngüsü

    private func run(deviceName: String) async {
        do {
            // Pencere boot/open ile aynı anda gelmez: DeviceHub saniyeler
            // sonra belirir, tek denemede vazgeçilirse akış hiç kurulamaz ve
            // panel kalıcı `simctl`'e (~2 fps) düşer. O yüzden pencere
            // görünene kadar beklenir.
            let windowID = try await Self.waitForWindow(deviceName: deviceName) {
                try await Self.findWindowID(deviceName: $0)
            }
            try await startStream(windowID: windowID)
            phase = .active
            // Akış kareleri `sink` üzerinden gelir; bu görev yalnız iptali
            // bekler (pencere kapanırsa `didStopWithError` evreyi düşürür).
            await Self.waitForCancellation()
        } catch is CancellationError {
            // Kapatma: evre `stop` tarafından zaten sıfırlandı.
        } catch {
            if Task.isCancelled {
                return
            }
            phase = Self.phase(for: error)
            AppLog.panels.error(
                "Simulator live stream failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        if let captured = stream {
            stream = nil
            sink = nil
            try? await captured.stopCapture()
        } else {
            sink = nil
        }
        streamTask = nil
    }

    /// İptal gelene kadar yarım saniyelik uykularla bekler: kapatma en geç
    /// 0.5 sn'de fark edilir, görev askıda sızıntı yapmaz.
    private nonisolated static func waitForCancellation() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func startStream(windowID: CGWindowID) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw SimulatorLiveStreamError.windowGone
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = min(1, Double(Self.maximumFrameWidth) / max(window.frame.width, 1))
        // Çift piksel: tek genişlik/yükseklik bazı biçimlerde akışı kurdurtmaz.
        configuration.width = Self.evenPixel((window.frame.width * scale).rounded())
        configuration.height = Self.evenPixel((window.frame.height * scale).rounded())
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(Self.framesPerSecond)
        )
        configuration.showsCursor = false
        configuration.capturesAudio = false
        // Derin kuyruk kareleri biriktirip gecikmeyi büyütür; canlı dokunuşun
        // karşılığı için sığ kuyruk yeterlidir.
        configuration.queueDepth = 2

        let sink = SimulatorStreamSink(
            onFrame: { [weak self] image in
                Task { [weak self] in
                    await MainActor.run { [weak self] in
                        self?.noteLiveFrame(image)
                    }
                }
            },
            onError: { [weak self] error in
                Task { [weak self] in
                    await MainActor.run { [weak self] in
                        self?.noteStreamError(error)
                    }
                }
            }
        )
        self.sink = sink
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        self.stream = stream
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()
    }

    private func noteLiveFrame(_ image: CGImage) {
        guard phase == .active || phase == .starting else {
            return
        }
        phase = .active
        frame = image
        onFrame?(image)
    }

    private func noteStreamError(_ error: Error) {
        guard phase == .active || phase == .starting else {
            return
        }
        phase = Self.phase(for: error)
        AppLog.panels.error(
            "Simulator live stream stopped: \(error.localizedDescription, privacy: .public)"
        )
    }

    /// Cihaz penceresini bekler: DeviceHub boot'tan saniyeler sonra belirir.
    ///
    /// Saf çekirdek enjekte edilir (`findWindow`), böylece bekleme mantığı
    /// ekran okumadan test edilir. İptalde hemen çıkar; pencere hiç
    /// gelmezse son hatayı verir (arayan `simctl`'e düşer).
    nonisolated static func waitForWindow(
        deviceName: String,
        attempts: Int = SimulatorLiveStream.windowWaitAttempts,
        pause: Duration = SimulatorLiveStream.windowWaitPause,
        findWindow: @Sendable (String) async throws -> CGWindowID
    ) async throws -> CGWindowID {
        var lastError: Error?
        for attempt in 0..<max(1, attempts) {
            try Task.checkCancellation()
            do {
                return try await findWindow(deviceName)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            if attempt + 1 < max(1, attempts) {
                try? await Task.sleep(for: pause)
            }
        }
        throw lastError ?? SimulatorLiveStreamError.windowGone
    }

    /// Pencere bekleme bütçesi: ~20 sn (DeviceHub açılışı + ilk boyama).
    nonisolated static let windowWaitAttempts = 26
    nonisolated static let windowWaitPause: Duration = .milliseconds(750)

    /// Paylaşılan içerikten cihaz penceresini seçer; yoksa pencereyi açma
    /// ipucuyla döner (servis `openDeviceWindow` ile arka planda açar).
    private static func findWindowID(deviceName: String) async throws -> CGWindowID {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let infos = content.windows.map { window in
            SimulatorWindowInfo(
                windowID: window.windowID,
                ownerBundleID: window.owningApplication?.bundleIdentifier,
                title: window.title,
                isOnScreen: window.isOnScreen,
                area: window.frame.width * window.frame.height
            )
        }
        guard let match = SimulatorWindowSelector.select(deviceName: deviceName, windows: infos) else {
            throw SimulatorLiveStreamError.noWindow(deviceName: deviceName)
        }
        return match.windowID
    }

    /// İzin reddi ile diğer arızaları ayırır: reddde ayar ipucu, diğerinde
    /// pencere ipucu gösterilir. Kodun yanında ileti de okunur; SDK'nın hata
    /// kodu sürümler arasında kayarsa red yine yakalanır.
    nonisolated static func phase(for error: Error) -> SimulatorLiveStreamPhase {
        let nsError = error as NSError
        let detail =
            (nsError.localizedDescription + " "
            + (nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String ?? "")).lowercased()
        let mentionsDenial =
            detail.contains("denied") || detail.contains("not authorized")
            || detail.contains("permission") || detail.contains("tcc")
        if nsError.code == -3801
            || (nsError.domain.contains("ScreenCaptureKit") && mentionsDenial)
        {
            return .denied(message: permissionHint)
        }
        if let streamError = error as? SimulatorLiveStreamError {
            return .unavailable(message: streamError.errorDescription ?? error.localizedDescription)
        }
        return .unavailable(message: error.localizedDescription)
    }

    /// Akış boyutu her zaman çift piksel olur.
    nonisolated static func evenPixel(_ value: CGFloat) -> Int {
        max(2, (Int(value) / 2) * 2)
    }
}

// MARK: - Hatalar

enum SimulatorLiveStreamError: Error, LocalizedError, Equatable, Sendable {
    /// Cihaz penceresi ekranda değil: kullanıcı pencereyi açmalı.
    case noWindow(deviceName: String)
    /// Pencere seçimle yakalama arasında kapandı.
    case windowGone

    var errorDescription: String? {
        switch self {
        case .noWindow(let deviceName):
            "The “\(deviceName)” Simulator window is not on screen. Open the device window to start the live stream; until then frames come from simctl."
        case .windowGone:
            "The Simulator window closed. Reopen it to resume the live stream."
        }
    }
}
