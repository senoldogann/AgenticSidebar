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

    /// Başlık cihaz adıyla başlar ve ad orada biter: ardından ya hiçbir şey
    /// ya da bir ayırıcı (`-`, `–`, `—`, `(`, `:`, `·`) gelir. `contains`
    /// "iPhone 17" aramasında "iPhone 17 Pro" penceresini de yakalıyordu.
    /// Her iki taraf küçük harfle verilir. Saf karar.
    static func titleMatches(_ title: String, deviceName needle: String) -> Bool {
        guard title.hasPrefix(needle) else {
            return false
        }
        let rest = title.dropFirst(needle.count).trimmingCharacters(in: .whitespaces)
        guard let first = rest.first else {
            return true
        }
        return "-–—(:·|".contains(first)
    }

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
                guard let title = window.title?.lowercased(), titleMatches(title, deviceName: needle) else {
                    return false
                }
                return true
            }
            .max(by: { $0.area < $1.area })
    }

    /// Gizli pencere yedeği: küçültülmüş ya da başka Space'teki pencere
    /// `isOnScreen == false` gelir, yalnız ikinci denemede kullanılır.
    static func selectIncludingHidden(deviceName: String, windows: [SimulatorWindowInfo]) -> SimulatorWindowInfo? {
        let needle = deviceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            return nil
        }
        return
            windows
            .filter { window in
                guard window.area > 0 else {
                    return false
                }
                guard let owner = window.ownerBundleID, ownerBundleIDs.contains(owner) else {
                    return false
                }
                guard let title = window.title?.lowercased(), titleMatches(title, deviceName: needle) else {
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

/// Kama bekçisinin kararı: saf tutulur, `SCStream` yokken test edilir.
enum SimulatorLiveStreamWedgeDecision: Equatable, Sendable {
    case keep
    case restart
    case giveUp
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

// MARK: - Kare posta kutusu

/// Yakalama kuyruğundan gelen kareleri birleştirir: ana iş parçacığı meşgulse
/// her kare ayrı `MainActor` atlaması kuyruklamaz, yalnız en yenisi bekler.
///
/// Birikmiş atlamalar hem belleği şişirir (her biri tam boy `CGImage` tutar)
/// hem de ana iş parçacığı açılınca art arda dizilip düzeni boğar (yük altında
/// takılma + patlayan yerleşim turu). Posta kutusuyla panel her zaman en
/// güncel kareyi çizer; kaçırılan ara kare sessizce düşer.
///
/// Saf eşzamanlılık ilkelidir: kilit altında yalnız slot okunur/yazılır,
/// çizelgeleme kararı atomiktir. Doğrudan test edilir.
final class LiveFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CGImage?
    private var deliveryScheduled = false

    /// En yeni kareyi bırakır; teslimat planlı değilse `schedule` bir kez
    /// çağrılır. Art arda gelen kareler yalnız slotu tazeler. `schedule`
    /// eşzamanlı koşar (kaçmaz), o yüzden `self` yakalayabilir.
    func store(_ image: CGImage, schedule: () -> Void) {
        lock.lock()
        latest = image
        let shouldSchedule = !deliveryScheduled
        if shouldSchedule {
            deliveryScheduled = true
        }
        lock.unlock()
        if shouldSchedule {
            schedule()
        }
    }

    /// Bekleyen en yeni kareyi alır; plan bayrağını sıfırlar ki sonraki
    /// `store` yeniden çizelgelesin. Bekleyen yoksa `nil` döner.
    func take() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        let image = latest
        latest = nil
        deliveryScheduled = false
        return image
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

    /// Son canlı karenin zamanı: kama bekçisi 3 sn sessizliği buradan anlar.
    @ObservationIgnored
    private var lastFrameDate: Date?

    /// Kama sonrası tek yeniden başlatma denendi mi: ikinci takılmada
    /// `.unavailable` ile `simctl`'e düşülür.
    @ObservationIgnored
    private var didRestartAfterWedge = false

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

    /// Akış kuşağı: `run` görevinin hâlâ tuttuğu akışla `stop`'un bıraktığı
    /// akışın aynı teardown'u iki kez koşmaması için sayaçlanır.
    private var streamGeneration: UInt64 = 0

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        currentDeviceName = nil
        streamGeneration &+= 1
        lastFrameDate = nil
        didRestartAfterWedge = false
        // Akış `run` sonunda kapatılır; buradaki yakalama yalnız
        // pencereyi anında bırakır, görev sonu kalanı toplar.
        let captured = stream
        stream = nil
        sink = nil
        if let captured {
            // Miras görev: `stream` MainActor-durumudur, bağlamsız gövdeye
            // taşınması bölge-izolasyonunu bozar. Teardown hızlıdır;
            // asıl yarış kuşağı (`stop` vs `run` sonu) ile korunur.
            Task { [captured] in
                try? await captured.stopCapture()
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
        "Screen Recording is off for AgenticSidebar. Turn it on in System Settings ▸ Privacy & Security ▸ Screen Recording, then quit and reopen AgenticSidebar (macOS applies the grant on relaunch)."

    // MARK: - Akış döngüsü

    private func run(deviceName: String) async {
        // Bu turun kuşağı: `stop()`+`start()` araya girdiyse bu tur yeni turun
        // görev tutamacına, evresine ve akışına dokunmadan çekilir. Önceden
        // koşulsuz `streamTask = nil` yeni turun tutamacını siliyor, akış
        // izlenmeden (panel kapansa da) kayıtta kalıyordu.
        let runGeneration = streamGeneration
        // İzin önden denetlenir (`CGPreflight`, istem göstermez): Ekran Kaydı
        // yoksa paylaşılan pencere listesi boş döner, 20 sn'lik bekleme sahte
        // "pencere ekranda değil" üretir ve panel asla izin düğmesine
        // dönemezdi. Red hızlı ve doğru evreye düşer; kullanıcı tek tıkla
        // sistem istemini görür.
        guard permissionReader.permissions().screenCaptureAuthorized else {
            guard runGeneration == streamGeneration else {
                return
            }
            phase = .denied(message: Self.permissionHint)
            AppLog.panels.error(
                "Simulator live stream: Screen Recording is not granted, skipping the window wait"
            )
            streamTask = nil
            return
        }
        do {
            // Pencere boot/open ile aynı anda gelmez: DeviceHub saniyeler
            // sonra belirir, tek denemede vazgeçilirse akış hiç kurulamaz ve
            // panel kalıcı `simctl`'e (~2 fps) düşer. O yüzden pencere
            // görünene kadar beklenir.
            let windowID = try await Self.waitForWindow(deviceName: deviceName) {
                try await Self.findWindowID(deviceName: $0)
            }
            try await startStream(windowID: windowID, generation: runGeneration)
            guard runGeneration == streamGeneration else {
                return
            }
            phase = .active
            lastFrameDate = Date()
            didRestartAfterWedge = false
            // Akış kareleri `sink` üzerinden gelir; bu görev iptalin yanında
            // kama bekçisini de koşar (3 sn sessizlikte bir kez dener).
            await watchActiveStream(deviceName: deviceName)
            // Bu arada `stop()` koştuysa teardown onundur: çift
            // `stopCapture` yarışı olmaz, bayat görev sessizce çekilir.
            if runGeneration != streamGeneration {
                return
            }
        } catch is CancellationError {
            // Kapatma: evre `stop` tarafından zaten sıfırlandı.
        } catch {
            if Task.isCancelled || runGeneration != streamGeneration {
                return
            }
            phase = Self.phase(for: error)
            AppLog.panels.error(
                "Simulator live stream failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        guard runGeneration == streamGeneration else {
            return
        }
        if let captured = stream {
            stream = nil
            sink = nil
            try? await captured.stopCapture()
        } else {
            sink = nil
        }
        // `stopCapture` beklenirken `stop()`+`start()` araya girmiş olabilir:
        // yeni turun görev tutamacı silinmez.
        guard runGeneration == streamGeneration else {
            return
        }
        streamTask = nil
    }

    /// Kama bekçisi: `.active` evrede 3 sn kare gelmezse akış takılmış
    /// demektir, bir kez yeniden kurulur; yine sessizse `.unavailable`
    /// ile `simctl`'e düşülür. İptalde hemen çıkar.
    private func watchActiveStream(deviceName: String) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.wedgeCheckInterval)
            if Task.isCancelled {
                break
            }
            // Akış hatayla düştüyse (`noteStreamError` evreyi değiştirdi) bekçi
            // çekilir: `run` akışı söker ve görev tutamacını bırakır, böylece
            // "Retry stream" ve yeniden başlatma çalışır. Önceden döngü
            // sonsuza dek dönüyor, `start()` hiç yeniden kurmuyordu.
            guard phase == .active else {
                return
            }
            let secondsSince = Date().timeIntervalSince(lastFrameDate ?? Date())
            let decision = Self.wedgeDecision(
                phase: phase,
                secondsSinceFrame: secondsSince,
                didRestart: didRestartAfterWedge
            )
            switch decision {
            case .keep:
                continue
            case .restart:
                didRestartAfterWedge = true
                AppLog.panels.error("Simulator live stream stalled: restarting once")
                await restartStream(deviceName: deviceName)
                lastFrameDate = Date()
                if phase != .active {
                    return
                }
            case .giveUp:
                phase = .unavailable(message: Self.wedgeUnavailableMessage)
                AppLog.panels.error(
                    "Simulator live stream stalled: \(Self.wedgeUnavailableMessage, privacy: .public)"
                )
                return
            }
        }
    }

    /// Takılma sonrası tek yeniden kurulum: eski yakalama bırakılır,
    /// pencere yeniden bulunur (başka Space'e taşınmış olabilir) ve akış
    /// aynı kuşakta yeniden kurulur. Kurulamazsa evre düşer.
    private func restartStream(deviceName: String) async {
        let restartGeneration = streamGeneration
        if Task.isCancelled {
            return
        }
        if let captured = stream {
            stream = nil
            sink = nil
            try? await captured.stopCapture()
        } else {
            sink = nil
        }
        if Task.isCancelled {
            return
        }
        do {
            let windowID = try await Self.findWindowID(deviceName: deviceName)
            try await startStream(windowID: windowID, generation: restartGeneration)
            guard restartGeneration == streamGeneration else {
                return
            }
            phase = .active
        } catch {
            if Task.isCancelled || restartGeneration != streamGeneration {
                return
            }
            phase = Self.phase(for: error)
            AppLog.panels.error(
                "Simulator live stream restart failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Kama kararı saf tutulur: `SCStream` yokken test edilir.
    nonisolated static func wedgeDecision(
        phase: SimulatorLiveStreamPhase,
        secondsSinceFrame: TimeInterval?,
        didRestart: Bool
    ) -> SimulatorLiveStreamWedgeDecision {
        guard phase == .active else {
            return .keep
        }
        guard let secondsSinceFrame, secondsSinceFrame > wedgeTimeoutSeconds else {
            return .keep
        }
        if didRestart {
            return .giveUp
        }
        return .restart
    }

    /// Sessizlik eşiği: 3 sn kare yoksa kama sayılır.
    nonisolated static let wedgeTimeoutSeconds: TimeInterval = 3
    /// Bekçi yoklama aralığı: kapatma en geç 0.5 sn'de fark edilir.
    nonisolated static let wedgeCheckInterval: Duration = .milliseconds(500)
    /// Kama sonrası eylem iletisi: pencereyi açmaya yönlendirir.
    nonisolated static let wedgeUnavailableMessage =
        "The live stream stalled (no frames for 3s). Reopen the Simulator window or use Open window; until then frames come from simctl."

    private func startStream(windowID: CGWindowID, generation: UInt64) async throws {
        // Önce ekrandaki pencereler: küçültülmüş ya da başka Space'teki
        // pencere burada yoksa bir kez tüm pencerelerle denenir.
        let onScreenWindow = try await Self.captureWindow(windowID: windowID, onScreenOnly: true)
        let resolvedWindow: SCWindow?
        if let onScreenWindow {
            resolvedWindow = onScreenWindow
        } else {
            resolvedWindow = try await Self.captureWindow(windowID: windowID, onScreenOnly: false)
        }
        guard let window = resolvedWindow else {
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

        // Posta kutusu: yakalama kuyruğu 12 fps üretirken ana iş parçacığı
        // tıkanıksa her kare ayrı atlama kuyruklamaz; teslimat koştuğunda
        // yalnız en yenisi yayınlanır (birikme → takılma olmaz).
        let mailbox = LiveFrameMailbox()
        let sink = SimulatorStreamSink(
            onFrame: { [weak self] image in
                mailbox.store(image) {
                    Task { [weak self] in
                        await MainActor.run { [weak self] in
                            guard let self, let newest = mailbox.take() else {
                                return
                            }
                            self.noteLiveFrame(newest)
                        }
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
        // Pencere aranırken `stop()` koştuysa bu kuşak bitmiştir: yeni turun
        // akışının üzerine yazılmaz (yazılsaydı yeni akış sızardı).
        guard generation == streamGeneration else {
            throw CancellationError()
        }
        self.sink = sink
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        self.stream = stream
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()
        // Yakalama başlarken `stop()` koştuysa bu akışın sahibi kalmadı:
        // kendi elimizle durdurulur, yoksa panel kapansa da yakalama sürerdi.
        guard generation == streamGeneration else {
            try? await stream.stopCapture()
            throw CancellationError()
        }
    }

    private func noteLiveFrame(_ image: CGImage) {
        guard phase == .active || phase == .starting else {
            return
        }
        phase = .active
        lastFrameDate = Date()
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
    /// gelmezse son hatayı verir (arayan `simctl`'e düşer). İlk denemeler
    /// hızlı koşar, bütçe ~20 sn korunur.
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
                try? await Task.sleep(for: waitPause(attempt: attempt, basePause: pause))
            }
        }
        throw lastError ?? SimulatorLiveStreamError.windowGone
    }

    /// Bekleme aralığı: ilk denemeler hızlı başlar, gerisi seyrekleşir.
    nonisolated static func waitPause(attempt: Int, basePause: Duration) -> Duration {
        if attempt < windowWaitFastAttempts, basePause == windowWaitPause {
            return windowWaitFastPause
        }
        return basePause
    }

    /// Pencere bekleme bütçesi: ~20 sn (3 × 150 ms + 26 × 750 ms).
    nonisolated static let windowWaitAttempts = 29
    nonisolated static let windowWaitPause: Duration = .milliseconds(750)
    /// Hızlı başlangıç: ilk denemeler sık koşar, panel erken tutunur.
    nonisolated static let windowWaitFastAttempts = 3
    nonisolated static let windowWaitFastPause: Duration = .milliseconds(150)

    /// İki kademeli pencere çözümü: önce ekrandakiler, tutmazsa gizliler
    /// dahil. Saf tutulur, `SCStream` yokken test edilir.
    nonisolated static func resolveWindowID(
        deviceName: String,
        onScreenWindows: [SimulatorWindowInfo],
        allWindows: [SimulatorWindowInfo]
    ) -> CGWindowID? {
        if let match = SimulatorWindowSelector.select(deviceName: deviceName, windows: onScreenWindows) {
            return match.windowID
        }
        if let match = SimulatorWindowSelector.selectIncludingHidden(deviceName: deviceName, windows: allWindows) {
            return match.windowID
        }
        return nil
    }

    /// Paylaşılan içerikten cihaz penceresini seçer; yoksa pencereyi açma
    /// ipucuyla döner (servis `openDeviceWindow` ile arka planda açar).
    /// Önce ekrandakiler aranır, bulunamazsa bir kez tüm pencerelerle
    /// denenir (küçültülmüş ya da başka Space'teki pencere).
    private static func findWindowID(deviceName: String) async throws -> CGWindowID {
        let onScreen = try await fetchWindowInfos(onScreenOnly: true)
        if let match = SimulatorWindowSelector.select(deviceName: deviceName, windows: onScreen) {
            return match.windowID
        }
        let all = try await fetchWindowInfos(onScreenOnly: false)
        if let resolved = resolveWindowID(deviceName: deviceName, onScreenWindows: onScreen, allWindows: all) {
            return resolved
        }
        throw SimulatorLiveStreamError.noWindow(deviceName: deviceName)
    }

    /// Paylaşılan pencere listesini özetler: seçim saf katmanda koşar.
    private static func fetchWindowInfos(onScreenOnly: Bool) async throws -> [SimulatorWindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: onScreenOnly
        )
        return content.windows.map { window in
            SimulatorWindowInfo(
                windowID: window.windowID,
                ownerBundleID: window.owningApplication?.bundleIdentifier,
                title: window.title,
                isOnScreen: window.isOnScreen,
                area: window.frame.width * window.frame.height
            )
        }
    }

    /// Yakalanacak pencereyi kimliğiyle bulur: gizli pencere yedeğiyle.
    private static func captureWindow(windowID: CGWindowID, onScreenOnly: Bool) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: onScreenOnly
        )
        return content.windows.first(where: { $0.windowID == windowID })
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
