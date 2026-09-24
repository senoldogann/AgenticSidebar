import AppKit
import CoreGraphics
import Foundation
import Observation
import ScreenCaptureKit

/// Bilgisayar kullanımının canlı görüntüsü: odaklı ekranın karelerini üretir.
///
/// Kare üretimi `SCScreenshotManager` iledir — yardımcının ekran görüntüsü
/// yoluyla aynı API ve aynı odaklı ekran seçimi. macOS yakalama iznini sorumlu
/// süreç adına verir; bu uygulama bilgisayar kullanımı için bu izni zaten
/// taşımak zorundadır (`ComputerUsePermission.screenRecording`), bu yüzden
/// panel ayrı bir izin istemez, yalnız var olanı sorgular.
///
/// Döngü yalnız panel görünürken ve bilgisayar turu sürerken koşar; kare
/// üretimi ana iş parçacığını bloklamaz (`SCScreenshotManager` asenkrondur,
/// boyut küçültme ile kare başına iş sınırlıdır).
@MainActor
@Observable
final class ComputerLiveCaptureService {
    /// Son yakalanan kare; `nil` iken panel boş durum ya da izin durumu gösterir.
    private(set) var frame: CGImage?
    /// Ajanın işaretçisi: yakalanan ekrana göre normalize konum (0..1).
    /// Kareden sistem imleci çıkarılır (`showsCursor = false`), yerine panel
    /// ajana özgü işareti çizer: izleyen, ajanın nereye baktığını ayırt eder.
    /// `nil` ise işaretçi bu ekranın dışındadır ya da henüz bilinmiyor.
    private(set) var pointerPosition: CGPoint?
    /// Döngü koşuyor mu? (panel görünür + tur sürüyor + izin var)
    private(set) var isRunning = false
    private(set) var isScreenRecordingGranted: Bool
    private(set) var isRequestingScreenRecording = false
    /// Son yakalama hatası; başarılı kare gelince temizlenir.
    private(set) var failureMessage: String?

    @ObservationIgnored
    private let permissionReader: any ComputerUseAppPermissionReading

    @ObservationIgnored
    private let frameInterval: Duration

    @ObservationIgnored
    private var captureTask: Task<Void, Never>?

    /// Son yakalamanın ekranı: işaretçi konumu buna göre normalize edilir.
    @ObservationIgnored
    private var lastDisplayID: CGDirectDisplayID?

    /// İşaretçi yoklaması kareden hızlıdır (120 ms): imleç akıcı gezer, ekran
    /// karesi aralıklı gelir.
    nonisolated static let pointerInterval: Duration = .milliseconds(120)

    /// Kare genişliği tavanı (piksel): panel en geniş hâlinde ~1200 pt, tam
    /// çözünürlüklü bir ekran karesi (ör. 3456 px) her turda boşuna işlenirdi.
    nonisolated static let maximumFrameWidth = 1440

    init(
        permissionReader: any ComputerUseAppPermissionReading = SystemComputerUseAppPermissionReader(),
        frameInterval: Duration = .milliseconds(900)
    ) {
        self.permissionReader = permissionReader
        self.frameInterval = frameInterval
        self.isScreenRecordingGranted = permissionReader.permissions().screenCaptureAuthorized
    }

    // MARK: - Yaşam döngüsü

    /// Panel görünür ve tur sürerken çağrılır; döngü zaten koşuyorsa no-op.
    func start() {
        guard captureTask == nil else {
            return
        }
        refreshPermission()
        guard isScreenRecordingGranted else {
            return
        }

        isRunning = true
        let interval = frameInterval
        let pointerTick = Self.pointerInterval
        captureTask = Task { [weak self] in
            // İlk turda kare hemen gelir (`sinceCapture = interval`).
            var sinceCapture = interval
            while !Task.isCancelled {
                self?.refreshPointerPosition()
                if sinceCapture >= interval {
                    await self?.captureOnce()
                    sinceCapture = .zero
                }
                try? await Task.sleep(for: pointerTick)
                sinceCapture += pointerTick
            }
        }
    }

    /// Panel kaybolunca ya da tur bitince çağrılır; kare üretimi durur, son
    /// kare elde kalır.
    func stop() {
        captureTask?.cancel()
        captureTask = nil
        isRunning = false
    }

    /// İzni tazeler; panel görünürken çağrılır, çünkü kullanıcı izni Sistem
    /// Ayarları'ndan panel açıkken de verebilir.
    func refreshPermission() {
        isScreenRecordingGranted = permissionReader.permissions().screenCaptureAuthorized
        if isScreenRecordingGranted {
            failureMessage = nil
        }
    }

    /// macOS'un izin istemesini sağlar; yanıt geldiğinde durum tazelenir ve
    /// izin verildiyse döngü kendiliğinden başlar.
    func requestScreenRecording() {
        guard !isRequestingScreenRecording else {
            return
        }
        isRequestingScreenRecording = true
        AppLog.panels.info("Computer live view: asking macOS for Screen Recording")

        Task { [weak self] in
            let granted = await self?.permissionReader.requestScreenRecording() ?? false
            guard let self else {
                return
            }
            self.isRequestingScreenRecording = false
            self.isScreenRecordingGranted = granted
            AppLog.panels.info(
                "Computer live view: the Screen Recording request came back as \(granted ? "granted" : "not granted yet", privacy: .public)"
            )
        }
    }

    // MARK: - Kare üretimi

    private func captureOnce() async {
        let displayID = Self.focusedDisplayID()
        do {
            let captured = try await ComputerDisplayCapture.captureFocusedDisplay(preferredDisplayID: displayID)
            frame = captured.image
            lastDisplayID = captured.displayID
            failureMessage = nil
            refreshPointerPosition()
        } catch {
            // Ekran uyurken ya da izin yeni kaldırıldığında görülen olağan
            // durum: döngü ölmez, son kare kalır, durum satırı söyler.
            failureMessage = "The screen could not be captured right now."
            AppLog.panels.error(
                "Computer live view capture failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Sistem işaretçisinin konumunu yakalanan ekrana normalize eder.
    ///
    /// macOS'ta sentetik olaylar tek bir fiziksel işaretçiyi sürer; ajana
    /// ayrı bir sanal imleç verilemez. Bu yüzden konum, o an fiziksel imlecin
    /// olduğu yerdir: tur sürerken imleci süren ajandır. İşaretçi bu ekranın
    /// dışındaysa konum temizlenir.
    private func refreshPointerPosition() {
        guard
            let displayID = lastDisplayID,
            let location = CGEvent(source: nil)?.location
        else {
            pointerPosition = nil
            return
        }
        pointerPosition = Self.normalizedPointerPosition(location, displayID: displayID)
    }

    nonisolated static func normalizedPointerPosition(
        _ location: CGPoint,
        displayID: CGDirectDisplayID
    ) -> CGPoint? {
        Self.normalize(location, in: CGDisplayBounds(displayID))
    }

    /// Ekran sınırlarına göre normalize eder. Sınırlar dışarıda verilen test
    /// edilebilir saf çekirdektir; üretimde sınır `CGDisplayBounds` ile gelir.
    nonisolated static func normalize(_ location: CGPoint, in bounds: CGRect) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }
        let x = (location.x - bounds.minX) / bounds.width
        let y = (location.y - bounds.minY) / bounds.height
        guard x >= 0, x <= 1, y >= 0, y <= 1 else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    /// `NSScreen.main` ana iş parçacığında okunur: tuş penceresini taşıyan
    /// ekran, yardımcının da yakaladığı ekrandır.
    private static func focusedDisplayID() -> CGDirectDisplayID? {
        guard
            let number = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber
        else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}

// MARK: - Ekran yakalama (saf yardımcı)

enum ComputerDisplayCaptureError: Error, LocalizedError, Equatable, Sendable {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            "No display is available to capture"
        }
    }
}

enum ComputerDisplayCapture {
    /// Yakalanan kare ve ait olduğu ekran.
    struct CapturedFrame: Sendable {
        let image: CGImage
        let displayID: CGDirectDisplayID
    }

    /// Odaklı ekranı (yoksa ana ekranı) yakalar. Uygulamanın kendi pencereleri
    /// dışarıda bırakılır: panel kendi görüntüsünü gösterip sonsuz aynaya
    /// dönüşmez. Sistem imleci kareye çizilmez: panel ajanın kendi imleç
    /// işaretini konumun üstüne koyar.
    nonisolated static func captureFocusedDisplay(preferredDisplayID: CGDirectDisplayID?) async throws -> CapturedFrame {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        guard
            let display = selectDisplay(
                from: content.displays,
                preferred: preferredDisplayID,
                mainDisplayID: CGMainDisplayID()
            )
        else {
            throw ComputerDisplayCaptureError.noDisplay
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        let ownApplications = content.applications.filter { application in
            guard let ownBundleID else {
                return false
            }
            return application.bundleIdentifier == ownBundleID
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplications,
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        let scale = min(
            1,
            Double(ComputerLiveCaptureService.maximumFrameWidth) / Double(max(display.width, 1))
        )
        configuration.width = Int((Double(display.width) * scale).rounded())
        configuration.height = Int((Double(display.height) * scale).rounded())
        configuration.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return CapturedFrame(image: image, displayID: display.displayID)
    }

    /// Odaklı ekran varsa o, yoksa ana ekran, o da yoksa ilk ekran.
    nonisolated static func selectDisplay(
        from displays: [SCDisplay],
        preferred: CGDirectDisplayID?,
        mainDisplayID: CGDirectDisplayID
    ) -> SCDisplay? {
        if let preferred, let match = displays.first(where: { $0.displayID == preferred }) {
            return match
        }
        if let main = displays.first(where: { $0.displayID == mainDisplayID }) {
            return main
        }
        return displays.first
    }
}
