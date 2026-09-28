import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Observation

// MARK: - Cihaz modeli

/// `xcrun simctl` ile bulunan bir simülatör cihazı.
struct SimulatorDevice: Identifiable, Equatable, Sendable {
    /// Cihazın UDID'i; `simctl` komutlarında kimlik olarak kullanılır.
    let id: String
    let name: String
    let runtimeName: String
    /// `simctl`'in durum metni: "Booted", "Shutdown", "Booting"…
    let state: String

    var isBooted: Bool {
        state == "Booted"
    }
}

/// `simctl list devices available --json` çıktısını cihazlara indirger.
///
/// Saf: dosya okumaz, süreç çalıştırmaz; bu yüzden testte doğrudan beslenir.
enum SimulatorDeviceListParser {
    private struct ListPayload: Decodable {
        struct Entry: Decodable {
            let udid: String
            let name: String
            let state: String
            let isAvailable: Bool?
            let deviceTypeIdentifier: String?
        }

        let devices: [String: [Entry]]
    }

    /// Yalnız kullanılabilir iPhone cihazları döner; koşan cihazlar başta,
    /// sonra yeni çalışma zamanı, sonra ad sırasıyla.
    static func devices(fromJSON data: Data) -> [SimulatorDevice] {
        guard let payload = try? JSONDecoder().decode(ListPayload.self, from: data) else {
            return []
        }

        var result: [SimulatorDevice] = []
        for (runtimeIdentifier, entries) in payload.devices {
            let runtimeName = runtimeDisplayName(fromIdentifier: runtimeIdentifier)
            for entry in entries {
                guard entry.isAvailable ?? true else {
                    continue
                }
                let isPhone =
                    entry.deviceTypeIdentifier?.contains("iPhone")
                    ?? entry.name.contains("iPhone")
                guard isPhone else {
                    continue
                }
                result.append(
                    SimulatorDevice(
                        id: entry.udid,
                        name: entry.name,
                        runtimeName: runtimeName,
                        state: entry.state
                    )
                )
            }
        }

        return result.sorted { lhs, rhs in
            if lhs.isBooted != rhs.isBooted {
                return lhs.isBooted
            }
            if lhs.runtimeName != rhs.runtimeName {
                return lhs.runtimeName > rhs.runtimeName
            }
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            return lhs.id < rhs.id
        }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-5` → `iOS 26.5`.
    static func runtimeDisplayName(fromIdentifier identifier: String) -> String {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard identifier.hasPrefix(prefix) else {
            return identifier
        }
        let raw = String(identifier.dropFirst(prefix.count))
        guard let dash = raw.firstIndex(of: "-") else {
            return raw
        }
        let family = String(raw[..<dash])
        let version = raw[raw.index(after: dash)...].replacingOccurrences(of: "-", with: ".")
        return "\(family) \(version)"
    }
}

// MARK: - Komut koşucusu

/// Tek bir `simctl` çağrısının sonucu.
struct SimulatorCommandResult: Equatable, Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    var didSucceed: Bool {
        exitCode == 0
    }

    /// `simctl` hata metninden kullanıcıya gösterilecek satır: ilk boş
    /// olmayan satır, yoksa çıkış kodu.
    var failureMessage: String {
        let line =
            standardError
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return line?.trimmingCharacters(in: .whitespaces) ?? "simctl exited with status \(exitCode)"
    }
}

/// `xcrun simctl` çalıştırır. Enjekte edilebilir: servis süreç başlatmadan
/// test edilebilsin.
protocol SimulatorCommandRunning: Sendable {
    func run(arguments: [String], timeout: TimeInterval) async -> SimulatorCommandResult
}

/// Gerçek koşucu: çıktıyı boru yerine geçici dosyalara yazar.
///
/// Boru kullanılmaz çünkü `simctl list --json` çıktısı boru tamponundan büyük
/// olabilir ve okuyucu beklemediğinde çocuk tıkanır; dosyaya yazan çocuk
/// tıkanamaz. Zaman aşımında süreç önce SIGTERM, sonra SIGKILL ile kesilir.
struct SystemSimulatorCommandRunner: SimulatorCommandRunning {
    static let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")

    func run(arguments: [String], timeout: TimeInterval) async -> SimulatorCommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: Self.runSynchronously(arguments: arguments, timeout: timeout)
                )
            }
        }
    }

    private static func runSynchronously(
        arguments: [String],
        timeout: TimeInterval
    ) -> SimulatorCommandResult {
        guard FileManager.default.isExecutableFile(atPath: xcrunURL.path) else {
            return SimulatorCommandResult(
                exitCode: 127,
                standardOutput: "",
                standardError: "xcrun was not found at \(xcrunURL.path)"
            )
        }

        let process = Process()
        process.executableURL = xcrunURL
        process.arguments = ["simctl"] + arguments
        process.standardInput = FileHandle.nullDevice

        let directory = FileManager.default.temporaryDirectory
        let stdoutURL = directory.appendingPathComponent("simctl-\(UUID().uuidString)-out.txt")
        let stderrURL = directory.appendingPathComponent("simctl-\(UUID().uuidString)-err.txt")
        guard
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil),
            let stdoutHandle = try? FileHandle(forWritingTo: stdoutURL),
            let stderrHandle = try? FileHandle(forWritingTo: stderrURL)
        else {
            return SimulatorCommandResult(
                exitCode: 127,
                standardOutput: "",
                standardError: "simctl output files could not be created"
            )
        }
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSemaphore.signal() }

        do {
            try process.run()
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            removeFile(at: stdoutURL)
            removeFile(at: stderrURL)
            return SimulatorCommandResult(
                exitCode: 127,
                standardOutput: "",
                standardError: "simctl could not be launched: \(error.localizedDescription)"
            )
        }

        var didTimeOut = false
        if exitSemaphore.wait(timeout: .now() + timeout) == .timedOut {
            didTimeOut = true
            process.terminate()
            if exitSemaphore.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSemaphore.wait(timeout: .now() + 2)
            }
        }

        try? stdoutHandle.close()
        try? stderrHandle.close()
        let standardOutput = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let standardError = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        removeFile(at: stdoutURL)
        removeFile(at: stderrURL)

        if didTimeOut {
            return SimulatorCommandResult(
                exitCode: 124,
                standardOutput: standardOutput,
                standardError: "simctl did not finish within \(Int(timeout))s"
            )
        }
        return SimulatorCommandResult(
            exitCode: process.terminationStatus,
            standardOutput: standardOutput,
            standardError: standardError
        )
    }

    private static func removeFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Ekran görüntüsü çözücü

enum SimulatorScreenshotDecoder {
    /// JPEG'i panelde gösterilecek boyuta indirerek çözer: cihaz kareleri
    /// 1206×2622 gelir, tam çözünürlük her turda boşuna çözülürdü.
    nonisolated static func downscaledImage(atPath path: String, maximumPixelSize: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - Servis

/// Paneldeki dokunma konumunu cihazın normalize koordinatına (0..1) indirger.
///
/// Saf: görüntü boyu panelden, konum hareketten gelir; aralık dışı değerler
/// cihaza gitmeden kırpılır, geçersiz boy sıfıra düşer.
enum SimulatorTouchMapper {
    static func normalized(location: CGPoint, in size: CGSize) -> (x: Double, y: Double) {
        (ratio(location.x, extent: size.width), ratio(location.y, extent: size.height))
    }

    private static func ratio(_ value: CGFloat, extent: CGFloat) -> Double {
        guard extent > 0, value.isFinite else {
            return 0
        }
        return min(1, max(0, Double(value / extent)))
    }
}

/// Sağ paneldeki iOS Simülatörü sekmesinin durumu: cihaz listesi, seçim,
/// açma/kapatma ve canlı görüntü.
///
/// Görüntü `simctl io screenshot` ile alınır — bu yol ekran kaydı izni
/// istemez, cihazın kendi çerçeve tamponunu okur. Yakalama yalnız panel
/// görünürken ve seçili cihaz açıkken koşar.
@MainActor
@Observable
final class SimulatorService {
    enum Phase: Equatable, Sendable {
        /// Henüz taranmadı.
        case idle
        case scanning
        case ready
        /// `simctl` kullanılamıyor: Xcode seçili değil, komut düştü…
        case unavailable(message: String)
    }

    /// Yeniden denenecek dokunuşun türü: sürükleme, bitiş noktasında
    /// indir-kaldır çiftiyle tekrarlanır, tap'e indirgenmez.
    private enum TouchReplayKind {
        case tap
        case drag
    }

    private(set) var phase: Phase = .idle
    private(set) var devices: [SimulatorDevice] = []
    private(set) var selectedDeviceID: String?
    private(set) var frame: CGImage?
    private(set) var isPolling = false
    /// Açma/kapatma süren cihazlar; düğmeler bu sırada bekleme gösterir.
    private(set) var busyDeviceIDs: Set<String> = []
    /// Son işlem hatası; başarılı işlemde temizlenir.
    private(set) var failureMessage: String?
    /// Son dokunuşun köprü hatası; hatasızken `nil`. Rozet ve tanı buradan
    /// beslenir, `failureMessage` genel işlem hatası olarak kalır.
    private(set) var lastHIDError: String?

    /// Son HID hatasının yeniden deneme jetonu; her başarısız dokunuşta
    /// yenilenir. Görünüm yeniden deneme düğmesini bu jetonla birlikte
    /// `retryLastTouch` çağrısına bağlar.
    private(set) var retryToken = UUID()

    /// Açılış başına seçilen HID hattı; seçim yerleşip cihaz açılınca
    /// güncellenir, tanı ve A3 katmanı buradan okur.
    private(set) var hidTransport: SimulatorHIDTransportKind = .legacyIndigoMouse
    /// Toolchain sürümü okunamadığında konan uyarı; tanı özetine ve ilk
    /// dokunuş hatasına düşer. Sessiz legacy varsayımı böyle görünür olur.
    private(set) var hidTransportNote: String?

    /// Kareler cihazın kendi ekran yüzeyinden (framebuffer) akıyor mu. Açıkken
    /// ne pencere akışı ne `simctl` turu koşar; rozet ve çerçeve buna bakar.
    private(set) var isFramebufferActive = false

    /// Dokunma köprüsü son dokunuşta hata vermediyse hazır sayılır.
    var hidReady: Bool {
        lastHIDError == nil
    }

    @ObservationIgnored
    private let commandRunner: any SimulatorCommandRunning

    @ObservationIgnored
    private let pollInterval: Duration

    @ObservationIgnored
    private var pollTask: Task<Void, Never>?
    /// Turun yakaladığı cihaz.
    @ObservationIgnored
    private var pollingDeviceID: String?

    /// Dokunuş sonrası tetiklenen erken kare; normal turun uykusunu bölmez,
    /// yalnız araya bir kare sokar.
    @ObservationIgnored
    private var quickRefreshTask: Task<Void, Never>?

    /// `simctl io screenshot` turu sürerken yeni tur başlatılmaz: üst üste
    /// binen süreçler hem CPU'yu şişirir hem kare sırasını bozar.
    @ObservationIgnored
    private var frameInFlight = false

    /// Tur uçuşurken gelen dokunuş-sonrası yenileme isteği: düşürülmez,
    /// tur bitince tek kare olarak koşar. En yavaş anda (uzun `simctl` turu)
    /// dokunma geri bildiriminin kaybolması böyle önlenir.
    @ObservationIgnored
    private var needsRefreshAfterFlight = false

    /// Yayınlanan karelerin sıra numarası: çözme yakalamayla çakışık koştuğu
    /// için yavaş biten eski kare yeniyi ezemez, sessizce düşer.
    @ObservationIgnored
    private var frameSequence: UInt64 = 0

    /// Uygulama içi dokunuşları cihaza taşıyan Indigo HID köprüsü.
    @ObservationIgnored
    private let touchBridge = SimulatorHIDBridge()

    /// Son dokunuşun türü ve normalize koordinatı; yeniden deneme buradan
    /// beslenir. Sürükleme tap olarak değil, indir-kaldır çiftiyle tekrar
    /// gönderilir; yanlış jest gönderilmez.
    @ObservationIgnored
    private var lastTouchRequest: (kind: TouchReplayKind, x: Double, y: Double)?

    /// Çözülmüş geliştirici dizini önbelleği: tanı her karede istense bile
    /// `xcode-select` yalnız bir kez, ana iş parçacığı dışında fork'lanır.
    @ObservationIgnored
    private var cachedXcodePath: String?
    /// Toolchain sürüm yazısı önbelleği: `version.plist` her seçimde değil
    /// bir kez okunur.
    @ObservationIgnored
    private var cachedXcodeVersion: String?
    /// Arka planda yol çözümü sürüyor mu; aynı anda tek çözüm koşar.
    @ObservationIgnored
    private var resolvingXcodePath = false

    /// Günlüğe yazılan son tanı özeti; değişim günlüğü burayla kıyaslanır.
    @ObservationIgnored
    private var lastReportedDiagnostics: SimulatorDiagnostics?

    /// Cihaz penceresinin canlı akışı (~12 fps): aktifken `simctl` turu
    /// durur, işlemci ve pil korunur. Akış kurulamazsa (izin/pencere yok)
    /// servis sessizce `simctl` yolunda kalır. Framebuffer akışı kurulamazsa
    /// devreye giren yedektir.
    let liveStream: SimulatorLiveStream

    /// Cihaz ekranını doğrudan CoreSimulator yüzeyinden okuyan birincil akış
    /// (~30 fps, pencere ve Ekran Kaydı izni gerektirmez).
    @ObservationIgnored
    private let framebuffer = SimulatorFramebufferStream()
    /// Framebuffer akışının kurulduğu (ya da kurulmakta olduğu) cihaz.
    @ObservationIgnored
    private var framebufferDeviceID: String?
    @ObservationIgnored
    private var framebufferStartTask: Task<Void, Never>?
    /// Framebuffer'ın kalıcı olarak kurulamadığı cihazlar (çerçeve ya da imza
    /// uyumsuz): bunlarda doğrudan yedek yol kullanılır, her seçimde yeniden
    /// denenip günlük doldurulmaz.
    @ObservationIgnored
    private var framebufferUnsupportedDeviceIDs: Set<String> = []

    /// Framebuffer karesinin uzun kenar tavanı (piksel): panelin Retina
    /// boyunu karşılar, dönüşüm ~ms düzeyinde kalır.
    nonisolated static let maximumLiveFramePixelSize = 1400
    /// Açılışın hemen ardından ekran portları birkaç saniye hazır olmaz;
    /// framebuffer bu kadar deneme boyunca (2 sn arayla) yeniden kurulur,
    /// arada yedek yol kare gösterir.
    nonisolated static let framebufferStartAttempts = 8

    /// Cihaz karesi çözünürlük tavanı (piksel): bellek ve çözme maliyeti
    /// için 768 yeterlidir, panel boyunu aşmaz.
    nonisolated static let maximumFramePixelSize = 768
    nonisolated static let listTimeout: TimeInterval = 20
    nonisolated static let actionTimeout: TimeInterval = 90
    nonisolated static let screenshotTimeout: TimeInterval = 30
    /// Kaçıncı ardışık yakalama hatasında cihaz durumu yeniden okunur.
    nonisolated static let deviceStateRecheckFailureCount = 2

    init(
        commandRunner: any SimulatorCommandRunning = SystemSimulatorCommandRunner(),
        // Kare ~380 ms sürer (`simctl`'in kendi maliyeti); tur aralığı yalnız
        // nefes payıdır. 800 ms uyku akışı ~1 fps'e kilitlerdi, bu değerle
        // yakalama art arda koşar (~2 fps).
        pollInterval: Duration = .milliseconds(120),
        liveStream: SimulatorLiveStream = SimulatorLiveStream()
    ) {
        self.commandRunner = commandRunner
        self.pollInterval = pollInterval
        self.liveStream = liveStream
        // Akış karesi turu beklemez: gelir gelmez yayınlanır.
        liveStream.onFrame = { [weak self] image in
            Task { @MainActor [weak self] in
                self?.noteLiveFrame(image)
            }
        }
    }

    var selectedDevice: SimulatorDevice? {
        guard let selectedDeviceID else {
            return nil
        }
        return devices.first { $0.id == selectedDeviceID }
    }

    // MARK: - Panel yaşam döngüsü

    /// Panel göründü: liste boşsa taranır, seçili cihaz açıksa akış başlar.
    func panelAppeared() {
        if devices.isEmpty, phase != .scanning {
            Task { await refreshDevices() }
        }
        syncPolling()
    }

    /// Panel kayboldu: kare üretimi durur, seçim korunur.
    func panelDisappeared() {
        quickRefreshTask?.cancel()
        quickRefreshTask = nil
        quickRefreshChain = 0
        needsRefreshAfterFlight = false
        stopFramebuffer()
        stopPolling()
    }

    // MARK: - Cihaz listesi

    func refreshDevices() async {
        guard phase != .scanning else {
            return
        }
        phase = .scanning

        let result = await commandRunner.run(
            arguments: ["list", "devices", "available", "--json"],
            timeout: Self.listTimeout
        )
        guard result.didSucceed else {
            phase = .unavailable(message: result.failureMessage)
            AppLog.panels.error(
                "Simulator device list failed: \(result.failureMessage, privacy: .public)"
            )
            return
        }

        let parsed = SimulatorDeviceListParser.devices(
            fromJSON: Data(result.standardOutput.utf8)
        )
        devices = parsed
        phase = .ready

        // Cihaz önyükleme turu değişmiş olabilir: eski HID istemcisi ölü
        // oturuma aittir, sonraki dokunuşta yeniden kurulması için bırakılır.
        if let selectedDeviceID {
            touchBridge.detach(udid: selectedDeviceID)
        }

        if let selectedDeviceID, parsed.contains(where: { $0.id == selectedDeviceID }) {
            // Seçim duruyor.
        } else {
            selectedDeviceID =
                parsed.first(where: \.isBooted)?.id
                ?? parsed.first?.id
        }
        updateHIDTransport()
        reportDiagnosticsIfChanged()
        syncPolling()
    }

    func select(deviceID: String) {
        guard devices.contains(where: { $0.id == deviceID }) else {
            return
        }
        selectedDeviceID = deviceID
        frame = nil
        failureMessage = nil
        lastHIDError = nil
        updateHIDTransport()
        reportDiagnosticsIfChanged()
        syncPolling()
    }

    /// Canlı akışın karesi: `simctl` çözmesi beklenmez, doğrudan yayınlanır.
    /// Sıra numarası `simctl` yoluna aittir; akış karesi her zaman en yenidir.
    func noteLiveFrame(_ image: CGImage) {
        guard liveStream.isActive else {
            return
        }
        frame = image
        failureMessage = nil
        reportDiagnosticsIfChanged()
    }

    /// Paneldeki izin düğmesi: macOS istemini gösterir, izin verilirse akış
    /// seçili cihazda kendiliğinden başlar.
    func requestLiveStreamAccess() {
        liveStream.requestAccess()
    }

    /// Canlı akışı seçili cihazda yeniden kurar: önce bırakır, sonra aynı
    /// pencere adıyla başlatır. Pencere kapalıysa ya da başka Space'teyse
    /// akış yine `unavailable` düşer ve bildirimdeki "Open window" yolu
    /// kullanılır; sessiz döngüye girmez, tek denemedir.
    func retryLiveStream() {
        guard let name = selectedDevice?.name else {
            return
        }
        liveStream.stop()
        liveStream.start(deviceName: name)
    }

    // MARK: - Açma / kapatma

    /// Cihazı açar. Panel yolu pencereyle açar (`headless: false`): `simctl
    /// boot` pencereye ihtiyaç duymaz ama canlı akış (`SCStream`) penceresiz
    /// tutunamaz; pencere arka planda açılır (`activates = false`), odak
    /// AgenticSidebar'da kalır. Penceresiz boot yalnız API düzeyinde
    /// mümkündür, panel onu kullanmaz — yoksa akış kalıcı `simctl`'e
    /// (~2 fps) düşer ve kullanıcı nedenini göremezdi.
    func boot(deviceID: String, headless: Bool = true) async {
        guard let device = devices.first(where: { $0.id == deviceID }), !device.isBooted else {
            return
        }
        guard !busyDeviceIDs.contains(deviceID) else {
            return
        }
        busyDeviceIDs.insert(deviceID)
        defer { busyDeviceIDs.remove(deviceID) }

        AppLog.panels.info("Booting simulator device \(device.name, privacy: .public)")
        let result = await commandRunner.run(
            arguments: ["boot", deviceID],
            timeout: Self.actionTimeout
        )
        // Zaten açık cihazı yeniden açmak hata değildir: `simctl` 149 ile
        // "Unable to boot device in current state: Booted" der.
        let alreadyBooted = result.standardError.contains("current state: Booted")
        guard result.didSucceed || alreadyBooted else {
            failureMessage = result.failureMessage
            AppLog.panels.error(
                "Simulator boot failed: \(result.failureMessage, privacy: .public)"
            )
            return
        }

        failureMessage = nil
        // Açılış tamamlanmadan tükenen geçici denemeler cihazı kalıcı yedeğe
        // itmesin: kullanıcı yeniden açınca framebuffer yeniden denenir.
        framebufferUnsupportedDeviceIDs.remove(deviceID)
        // Ekran framebuffer'dan okunabiliyorsa pencere açılmaz: kare
        // penceresiz akar, DeviceHub'ın kapanırken cihazı kapatması ve
        // açılıştaki dokunuş kayıpları devre dışı kalır.
        if !headless, await !SimulatorFramebufferStream.isSupportedOnCurrentToolchain() {
            openDeviceWindow()
        }
        await refreshDevices()
    }

    func shutdown(deviceID: String) async {
        guard let device = devices.first(where: { $0.id == deviceID }), device.isBooted else {
            return
        }
        guard !busyDeviceIDs.contains(deviceID) else {
            return
        }
        busyDeviceIDs.insert(deviceID)
        defer { busyDeviceIDs.remove(deviceID) }

        AppLog.panels.info("Shutting down simulator device \(device.name, privacy: .public)")
        let result = await commandRunner.run(
            arguments: ["shutdown", deviceID],
            timeout: Self.actionTimeout
        )
        guard result.didSucceed else {
            failureMessage = result.failureMessage
            AppLog.panels.error(
                "Simulator shutdown failed: \(result.failureMessage, privacy: .public)"
            )
            return
        }

        failureMessage = nil
        frame = nil
        touchBridge.detach(udid: deviceID)
        await refreshDevices()
    }

    /// Cihazı gösteren uygulamayı açar: Xcode 26 ve öncesinde Simulator
    /// (`…/Developer/Applications/Simulator.app`), Xcode 27+ ile DeviceHub
    /// (`com.apple.dt.Devices`).
    ///
    /// Sıra bilinçlidir: önce seçili toolchain'in Simulator.app'i yoldan
    /// denenir — LaunchServices Xcode 27'de `com.apple.iphonesimulator`'ı
    /// çözemez (`nil` döner), kayıt araması yalnız yedek olur. İki Xcode yan
    /// yanayken yanlış toolchain'in penceresi açılmaz.
    ///
    /// Açma doğrulanır: `openApplication` sessiz düşerse kullanıcı boşuna
    /// beklemez, `failureMessage` hangi adımın tutmadığını söyler.
    /// `activate` yalnız açık kullanıcı isteğinde (`Open window` düğmesi)
    /// doğrudur: pencere öne ve bu Space'e gelir, canlı akış gizli pencere
    /// kovalamaz. Otomatik yolda (`boot`) odak çalınmaz.
    func openDeviceWindow(activate: Bool = false) {
        let simulatorAppURL = URL(
            fileURLWithPath: (resolvedXcodePath as NSString)
                .appendingPathComponent("Applications/Simulator.app")
        )
        let registered: [(bundleIdentifier: String, url: URL)] = [
            "com.apple.iphonesimulator",
            "com.apple.dt.Devices",
            "com.apple.dt.DeviceHub",
        ].compactMap { bundleIdentifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier).map {
                (bundleIdentifier, $0)
            }
        }
        guard
            let host = Self.pickWindowHost(
                simulatorAppURL: FileManager.default.fileExists(atPath: simulatorAppURL.path)
                    ? simulatorAppURL : nil,
                registered: registered
            )
        else {
            failureMessage = "Neither Simulator nor DeviceHub was found; install Xcode."
            AppLog.panels.error("No simulator window application was found to open")
            return
        }
        AppLog.panels.info(
            "Opening simulator window host \(host.bundleIdentifier, privacy: .public)"
        )
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        configuration.hides = false
        NSWorkspace.shared.openApplication(at: host.url, configuration: configuration)
        // Elle "Open window" yolu: akış ölmüş olabilir (pencere kapalıydı),
        // pencere gelince akış bekleme döngüsüyle kendiliğinden tutunur.
        // İzin yoksa akış beklemez, doğrudan izin evresine düşer.
        if !isFramebufferActive, windowCaptureShowsDeviceScreen, let name = selectedDevice?.name {
            liveStream.start(deviceName: name)
        }
        verifyWindowHostRunning(bundleIdentifier: host.bundleIdentifier, activate: activate)
    }

    /// Pencere açan uygulamayı seçer: seçili toolchain'in Simulator.app'i
    /// (yoldan doğrulanmış) varsa o kazanır, yoksa kayıtlı kimliklerden ilki
    /// alınır, hiçbiri yoksa `nil` döner. Saf: ekran okumaz, süreç açmaz.
    nonisolated static func pickWindowHost(
        simulatorAppURL: URL?,
        registered: [(bundleIdentifier: String, url: URL)]
    ) -> (bundleIdentifier: String, url: URL)? {
        if let simulatorAppURL {
            return ("com.apple.iphonesimulator", simulatorAppURL)
        }
        return registered.first
    }

    /// Açılan uygulamanın gerçekten koştuğunu doğrular: ~6 sn içinde
    /// belirmezse yüksek sesle düşülür. `activate` istenmişse pencere öne ve
    /// bu Space'e getirilir (gizli/başka Space'teki pencereyi akış
    /// yakalayamazdı).
    private func verifyWindowHostRunning(bundleIdentifier: String, activate: Bool) {
        Task { [weak self] in
            var launched: NSRunningApplication?
            for _ in 0..<24 {
                try? await Task.sleep(for: .milliseconds(250))
                guard self != nil else {
                    return
                }
                launched = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleIdentifier == bundleIdentifier
                })
                if launched != nil {
                    break
                }
            }
            guard let self else {
                return
            }
            guard let app = launched else {
                self.failureMessage =
                    "Simülatör penceresi açılamadı (\(bundleIdentifier)). Xcode kurulu mu denetleyin. / The simulator window host (\(bundleIdentifier)) did not start; check that Xcode is installed."
                AppLog.panels.error(
                    "Simulator window host \(bundleIdentifier, privacy: .public) did not start after open"
                )
                return
            }
            if activate {
                _ = app.activate()
            }
        }
    }

    // MARK: - Canlı görüntü

    /// Üst üste düşen `simctl` turu: geri çekilme buradan beslenir.
    @ObservationIgnored
    private var consecutiveScreenshotFailures = 0

    /// Seçili cihaz açıksa akışı başlatır; değilse durdurup çerçeveyi bırakır.
    /// Canlı pencere akışı da burada başlar: pencere bulunur ve izin varsa
    /// kareler akıştan gelir, `simctl` turu beklemeye geçer.
    private func syncPolling() {
        guard let device = selectedDevice, device.isBooted else {
            stopFramebuffer()
            liveStream.stop()
            stopPolling()
            frame = nil
            // Kapalı cihaz bir sonraki açılışta framebuffer'ı yeniden dener.
            if let selectedDeviceID {
                framebufferUnsupportedDeviceIDs.remove(selectedDeviceID)
            }
            return
        }
        if framebufferUnsupportedDeviceIDs.contains(device.id) {
            // Önceki cihazın framebuffer akışı sürüyorsa bırakılır; yoksa
            // `isFramebufferActive` doğru kalır ve yedek yolun kareleri
            // yayınlanmaz (panel boş kalırdı).
            stopFramebuffer()
            startFallbackCapture(device: device)
        } else {
            startFramebuffer(device: device)
        }
    }

    /// Yedek yol: pencere akışı (yalnız cihaz ekranını gösteren Simulator.app
    /// penceresinde) ve `simctl` turu.
    private func startFallbackCapture(device: SimulatorDevice) {
        if windowCaptureShowsDeviceScreen {
            liveStream.start(deviceName: device.name)
        }
        startPolling(deviceID: device.id)
    }

    /// Pencere akışı cihaz ekranını yalnız Simulator.app'te verir. Xcode 27+
    /// DeviceHub penceresi kenar çubuğu ve araç çubuklarıyla birlikte
    /// yakalanır; kare sıkışır ve dokunuşlar yanlış noktaya düşer.
    private var windowCaptureShowsDeviceScreen: Bool {
        FileManager.default.fileExists(
            atPath: (resolvedXcodePath as NSString).appendingPathComponent("Applications/Simulator.app")
        )
    }

    /// Birincil akışı seçili cihazda kurar; aynı cihaz için kuruluyorsa
    /// dokunmaz. Açılıştan hemen sonra ekran portları hazır olmayabilir:
    /// geçici hatada 2 sn arayla yeniden denenir, bu sürede yedek yol kare
    /// gösterir. Çerçeve ya da imza uyumsuzluğu kalıcıdır; cihaz yedek yola
    /// bırakılır.
    private func startFramebuffer(device: SimulatorDevice) {
        guard framebufferDeviceID != device.id else {
            return
        }
        stopFramebuffer()
        framebufferDeviceID = device.id
        let deviceID = device.id
        let stream = framebuffer
        // Kareler posta kutusundan geçer: ana iş parçacığı tıkanıksa 30 fps'lik
        // her kare ayrı bir görev olarak birikmez, yalnız en yenisi yayınlanır.
        let mailbox = LiveFrameMailbox()
        framebufferStartTask = Task { [weak self] in
            var lastError: Error?
            for attempt in 0..<Self.framebufferStartAttempts {
                do {
                    try await stream.start(
                        udid: deviceID,
                        maximumPixelSize: Self.maximumLiveFramePixelSize,
                        onFrame: { [weak self] image in
                            mailbox.store(image) {
                                Task { @MainActor [weak self] in
                                    guard let newest = mailbox.take() else {
                                        return
                                    }
                                    self?.noteFramebufferFrame(newest, deviceID: deviceID)
                                }
                            }
                        },
                        onEnded: { [weak self] in
                            Task { @MainActor [weak self] in
                                self?.framebufferEnded(deviceID: deviceID)
                            }
                        }
                    )
                    return
                } catch {
                    lastError = error
                    guard let self, self.framebufferDeviceID == deviceID, !Task.isCancelled else {
                        return
                    }
                    if attempt == 0, let current = self.selectedDevice, current.id == deviceID {
                        self.startFallbackCapture(device: current)
                    }
                    if Self.isPermanentFramebufferFailure(error) {
                        break
                    }
                }
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
            guard let self, self.framebufferDeviceID == deviceID else {
                return
            }
            self.framebufferDeviceID = nil
            self.framebufferUnsupportedDeviceIDs.insert(deviceID)
            AppLog.panels.error(
                "Simulator framebuffer unavailable; using the fallback capture: \(lastError?.localizedDescription ?? "unknown", privacy: .public)"
            )
        }
    }

    nonisolated static func isPermanentFramebufferFailure(_ error: Error) -> Bool {
        switch error as? SimulatorFramebufferStream.StreamError {
        case .frameworksUnavailable, .signatureMismatch, .frameUnreadable:
            return true
        case .deviceNotFound, .deviceNotBooted, .displayUnavailable, .surfaceUnavailable, nil:
            return false
        }
    }

    private func stopFramebuffer() {
        framebufferStartTask?.cancel()
        framebufferStartTask = nil
        if framebufferDeviceID != nil {
            framebuffer.stop()
        }
        framebufferDeviceID = nil
        isFramebufferActive = false
    }

    /// Framebuffer karesi: ilk kare geldiğinde yedek yol susturulur.
    private func noteFramebufferFrame(_ image: CGImage, deviceID: String) {
        guard framebufferDeviceID == deviceID, selectedDeviceID == deviceID else {
            return
        }
        if !isFramebufferActive {
            isFramebufferActive = true
            stopPolling()
        }
        frame = image
        failureMessage = nil
        reportDiagnosticsIfChanged()
    }

    /// Cihaz kapandı (yüzey düştü): liste tazelenir, panel açma ekranına döner.
    private func framebufferEnded(deviceID: String) {
        guard framebufferDeviceID == deviceID else {
            return
        }
        framebufferDeviceID = nil
        isFramebufferActive = false
        frame = nil
        touchBridge.detach(udid: deviceID)
        Task { [weak self] in
            await self?.refreshDevices()
        }
    }

    private func startPolling(deviceID: String) {
        // Tur cihaza bağlıdır: seçim değiştiyse eski cihazın turu durur,
        // yoksa panel eski cihazın karelerini göstermeyi sürdürürdü.
        if pollTask != nil, pollingDeviceID == deviceID {
            return
        }
        pollTask?.cancel()
        pollTask = nil
        pollingDeviceID = deviceID
        isPolling = true
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce(deviceID: deviceID)
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        pollingDeviceID = nil
        isPolling = false
        liveStream.stop()
    }

    /// Tek kare: canlı akış aktifken `simctl` çalıştırılmaz — pencere akışı
    /// zaten ~12 fps verir, üstüne tur binerse CPU boşa yanar. Akış yoksa
    /// eski yol koşar: yakalama bitince çözme beklenmez, arka planda koşar.
    /// Döngü hemen sonraki yakalamaya geçer; çözme (~50 ms) kritik yoldan
    /// çıkar, kare hızı `simctl`'in kendi süresine (~380 ms) dayanır.
    /// Üst üste düşen tur geri çekilir (0.5 sn → 2 sn → 5 sn), günlük
    /// ilk ve her 10. düşmede yazılır.
    private func pollOnce(deviceID: String) async {
        guard !liveStream.isActive, !isFramebufferActive else {
            return
        }
        guard !frameInFlight else {
            // Tur bitince tek kare koşar: dokunuşun karşılığı en yavaş anda
            // bile en fazla bir tur gecikir, sessizce düşmez.
            needsRefreshAfterFlight = true
            return
        }
        frameInFlight = true

        frameSequence += 1
        let sequence = frameSequence
        let path = Self.screenshotPath(deviceID: deviceID, sequence: sequence)
        let result = await commandRunner.run(
            arguments: ["io", deviceID, "screenshot", "--type=jpeg", path],
            timeout: Self.screenshotTimeout
        )
        guard result.didSucceed else {
            consecutiveScreenshotFailures += 1
            let failureCount = consecutiveScreenshotFailures
            failureMessage = result.failureMessage
            removeFile(atPath: path)
            if Self.shouldLogScreenshotFailure(failureCount: failureCount) {
                AppLog.panels.error(
                    "Simulator screenshot failed (\(failureCount)): \(result.failureMessage, privacy: .public)"
                )
            }
            // Üst üste düşen yakalama çoğu zaman cihazın kapandığını gösterir
            // (DeviceHub kapanırken cihazları kapatır): liste tazelenir,
            // panel ölü cihaza 30 sn'lik turlar atmak yerine açma ekranına döner.
            if failureCount == Self.deviceStateRecheckFailureCount {
                Task { [weak self] in
                    await self?.refreshDevices()
                }
            }
            // Geri çekilme uçuş bayrağı dışında bekler: bayrak altında
            // tutulursa (5 sn'ye kadar) dokunuş yenilemeleri birleşip hiç
            // ateşlenmez, panel bayat kareye çakılı kalırdı.
            endFlight(deviceID: deviceID)
            try? await Task.sleep(for: Self.screenshotBackoffDelay(failureCount: failureCount))
            return
        }
        consecutiveScreenshotFailures = 0
        endFlight(deviceID: deviceID)

        let maximumPixelSize = Self.maximumFramePixelSize
        Task.detached(priority: .utility) { [weak self] in
            let image = SimulatorScreenshotDecoder.downscaledImage(
                atPath: path,
                maximumPixelSize: maximumPixelSize
            )
            try? FileManager.default.removeItem(atPath: path)
            await MainActor.run { [weak self] in
                self?.publishFrame(image, sequence: sequence)
            }
        }
    }

    /// Uçuş bayrağını bırakır; tur sürerken biriken yenileme isteğini tek
    /// kare olarak koşar. Başarı ve başarısızlık çıkışları buradan geçer,
    /// geri çekilme uykusu bayrak bırakıldıktan sonra başlar.
    private func endFlight(deviceID: String) {
        frameInFlight = false
        if needsRefreshAfterFlight {
            needsRefreshAfterFlight = false
            // Kuyrukta biriken istek tek kareye iner: bayrak sıfırlandı,
            // bu tur yalnız bir kez kendini tekrarlar.
            Task { [weak self] in await self?.pollOnce(deviceID: deviceID) }
        }
    }

    /// Düşen tur için bekleme: ilk düşmede kısa, sürerse seyrekleşir.
    nonisolated static func screenshotBackoffDelay(failureCount: Int) -> Duration {
        if failureCount <= 0 {
            return .milliseconds(0)
        }
        if failureCount == 1 {
            return .milliseconds(500)
        }
        if failureCount == 2 {
            return .seconds(2)
        }
        return .seconds(5)
    }

    /// Günlük seyrekliği: ilk düşme ve her 10. düşme yazılır.
    nonisolated static func shouldLogScreenshotFailure(failureCount: Int) -> Bool {
        if failureCount <= 0 {
            return false
        }
        if failureCount == 1 {
            return true
        }
        return failureCount % 10 == 0
    }

    /// Çözülen kareyi yalnız en yeniyse yayınlar: yavaş biten eski kare
    /// ekranı geriye saramaz.
    private func publishFrame(_ image: CGImage?, sequence: UInt64) {
        // Framebuffer devreye girdiyse uçuştaki `simctl` karesi daha eskidir;
        // canlı karenin üstüne yazılmaz.
        guard sequence == frameSequence, !isFramebufferActive else {
            return
        }
        guard let image else {
            failureMessage = "The simulator screenshot could not be decoded."
            return
        }
        frame = image
        failureMessage = nil
    }

    private func removeFile(atPath path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Dokunma

    /// Canlı görüntüdeki konumu normalize koordinata çevirip cihaza dokunur.
    ///
    /// Koordinatlar görüntü oranına göredir (0..1); panel gerçek cihaz
    /// çözünürlüğünü bilmez, oranlar Indigo'nun beklediği biçimdir.
    func tapAt(normalizedX: Double, normalizedY: Double) {
        let target = validatedTouchTarget()
        switch target {
        case .failure(let error):
            noteTouchResult(.failure(error))
            return
        case .success(let deviceID):
            lastTouchRequest = (kind: .tap, x: normalizedX, y: normalizedY)
            touchBridge.tap(udid: deviceID, xRatio: normalizedX, yRatio: normalizedY) { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.noteTouchResult(result)
                }
            }
        }
    }

    /// Sürüklemenin başlangıcı: parmağı indirir.
    func pressDownAt(normalizedX: Double, normalizedY: Double) {
        let target = validatedTouchTarget()
        switch target {
        case .failure(let error):
            noteTouchResult(.failure(error))
            return
        case .success(let deviceID):
            lastTouchRequest = (kind: .drag, x: normalizedX, y: normalizedY)
            touchBridge.touch(udid: deviceID, xRatio: normalizedX, yRatio: normalizedY) { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.noteTouchResult(result)
                }
            }
        }
    }

    /// Sürükleme sürerken: parmak basılıyken yeni konuma taşınır.
    /// Taşıma köprüde birleştirilir; kuyruk, sürükleme olay seliyle şişmez.
    func pressMoveTo(normalizedX: Double, normalizedY: Double) {
        let target = validatedTouchTarget()
        switch target {
        case .failure(let error):
            noteTouchResult(.failure(error))
            return
        case .success(let deviceID):
            touchBridge.move(udid: deviceID, xRatio: normalizedX, yRatio: normalizedY) { [weak self] result in
                // Başarı sessizdir; yalnız hata tanıya düşer ki sürükleme
                // akışı hızlı yenileme fırtınası koparmasın.
                if case .failure = result {
                    Task { @MainActor [weak self] in
                        self?.noteTouchResult(result)
                    }
                }
            }
        }
    }

    /// Sürüklemenin sonu: parmağı kaldırır.
    func pressUpAt(normalizedX: Double, normalizedY: Double) {
        let target = validatedTouchTarget()
        switch target {
        case .failure(let error):
            noteTouchResult(.failure(error))
            return
        case .success(let deviceID):
            lastTouchRequest = (kind: .drag, x: normalizedX, y: normalizedY)
            touchBridge.release(udid: deviceID, xRatio: normalizedX, yRatio: normalizedY) { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.noteTouchResult(result)
                }
            }
        }
    }

    /// Son dokunuşu türüne göre tekrar gönderir: tap aynen, sürükleme bitiş
    /// noktasında indir-kaldır çiftiyle. Köprü istemcisi ölmüşse yeniden
    /// kurulması böyle tetiklenir. Dokunuş yoksa sessizce geçilir.
    func retryLastTouch() {
        guard let lastTouchRequest else {
            return
        }
        switch lastTouchRequest.kind {
        case .tap:
            tapAt(normalizedX: lastTouchRequest.x, normalizedY: lastTouchRequest.y)
        case .drag:
            pressDownAt(normalizedX: lastTouchRequest.x, normalizedY: lastTouchRequest.y)
            pressUpAt(normalizedX: lastTouchRequest.x, normalizedY: lastTouchRequest.y)
        }
    }

    /// Dokunuş yalnız açık ve seçili cihaza gider; seçim yoksa, cihaz
    /// kapalıysa ya da tvOS hedefse yüksek sesli tanıyla reddedilir.
    /// tvOS denetimi cihaz açık olsa da koşar: açık bir Apple TV
    /// hedefe dokunuş göndermek sessiz yutulurdu (idb `e1044d1`).
    private func validatedTouchTarget() -> Result<String, Error> {
        guard let device = selectedDevice else {
            return .failure(SimulatorHIDDiagnostic.noDeviceSelected)
        }
        if SimulatorHIDTransportSelector.isTVOSRuntime(device.runtimeName) {
            return .failure(
                SimulatorHIDDiagnostic.tvOSTouchUnsupported(runtimeName: device.runtimeName)
            )
        }
        guard device.isBooted else {
            return .failure(SimulatorHIDDiagnostic.deviceNotBooted(name: device.name))
        }
        return .success(device.id)
    }

    /// Açılış başına HID hattını seçer: cihaz listesi ya da seçim
    /// yerleştikçe seçili ve açık cihazın çalışma zamanıyla
    /// `SimulatorHIDTransportSelector` koşar. tvOS reddi burada hatta
    /// değil, dokunuş anında `validatedTouchTarget` içinde verilir.
    /// Sürüm okunamazsa sessiz legacy varsayımı yapılmaz: uyarı nota
    /// yazılır ve bir kez günlüğe düşer, dokunma tutmazsa kullanıcı
    /// `xcode-select` yolunu denetler.
    private func updateHIDTransport() {
        guard let device = selectedDevice, device.isBooted else {
            hidTransport = .legacyIndigoMouse
            hidTransportNote = nil
            return
        }
        let version: String? = {
            if let cachedXcodeVersion {
                return cachedXcodeVersion
            }
            let read = SimulatorHIDTransportSelector.xcodeVersion(
                developerDirectory: resolvedXcodePath
            )
            cachedXcodeVersion = read
            return read
        }()
        guard let version, !version.isEmpty else {
            hidTransport = .legacyIndigoMouse
            if hidTransportNote == nil {
                AppLog.panels.error(
                    "Simulator HID transport: toolchain version is unreadable, legacy assumed"
                )
            }
            hidTransportNote =
                "Toolchain sürümü okunamadı; legacy varsayıldı. Dokunma tutmazsa xcode-select yolunu denetleyin."
            return
        }
        switch SimulatorHIDTransportSelector.select(
            xcodeVersion: version,
            runtimeName: device.runtimeName
        ) {
        case .success(let kind):
            hidTransport = kind
            hidTransportNote = nil
        case .failure:
            hidTransport = .legacyIndigoMouse
            hidTransportNote = nil
        }
    }

    private func noteTouchResult(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            failureMessage = nil
            lastHIDError = nil
            reportDiagnosticsIfChanged()
            // Dokunuşun görsel karşılığı bir sonraki turu beklemez: dokunuş
            // ~50 ms'de cihaza varır, 250 ms sonra araya bir kare sokulur.
            requestQuickRefresh()
        case .failure(let error):
            // Sessiz dal yoktur: her hata çift dilli işlem önerisine
            // indirgenir, tanı özetine ve günlüğe aynen yazılır.
            let message = SimulatorHIDTransportSelector.userMessage(for: error)
            failureMessage = message
            lastHIDError = message
            retryToken = UUID()
            reportDiagnosticsIfChanged()
            AppLog.panels.error(
                "Simulator touch failed: \(message, privacy: .public)"
            )
        }
    }

    // MARK: - Tanı

    /// Panelin o anki durum özeti; aktör sınırından kopyayla geçer.
    var diagnostics: SimulatorDiagnostics {
        let device = selectedDevice
        return SimulatorDiagnostics(
            booted: device?.isBooted ?? false,
            windowFound: liveStream.isActive,
            streamPhase: SimulatorDiagnostics.phaseName(for: liveStream.phase),
            hidReady: hidReady,
            lastHIDError: lastHIDError,
            xcodePath: resolvedXcodePath,
            runtime: device?.runtimeName ?? "-",
            transportNote: hidTransportNote
        )
    }

    /// Özet değiştiyse tek satır günler; aynı durum tekrar yazılmaz.
    func reportDiagnosticsIfChanged() {
        lastReportedDiagnostics = diagnostics.logIfChanged(since: lastReportedDiagnostics)
    }

    /// Önbellekli geliştirici dizini: ilk okuma ana iş parçacığını tutmaz.
    /// Önbellek boşsa anında güvenli yedeğe düşülür (`DEVELOPER_DIR` ya da
    /// bilinen kurulum) ve gerçek çözüm arka planda doldurulur; süreç
    /// fork'u (`xcode-select`) hiçbir zaman MainActor'da koşmaz.
    private var resolvedXcodePath: String {
        if let cachedXcodePath {
            return cachedXcodePath
        }
        fillXcodePathInBackground()
        if let configured = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !configured.isEmpty {
            return configured
        }
        return "/Applications/Xcode.app/Contents/Developer"
    }

    /// `xcode-select` çözümünü arka plana atar: aynı anda tek çözüm koşar,
    /// bitince tanı tazelenir.
    private func fillXcodePathInBackground() {
        guard !resolvingXcodePath else {
            return
        }
        resolvingXcodePath = true
        Task.detached(priority: .utility) {
            let resolved = SimulatorDiagnostics.resolvedXcodePath()
            await MainActor.run { [weak self] in
                self?.cachedXcodePath = resolved
                self?.resolvingXcodePath = false
                self?.reportDiagnosticsIfChanged()
            }
        }
    }

    /// Normal turun dışında tek kare ister; üst üste dokunuşlarda yalnız son
    /// istek koşar, tur çalışmıyorsa (panel kapalı/kapalı cihaz) hiçbir şey yapmaz.
    /// `simctl` yolunda (~2 fps) tek kare dokunuşun karşılığını göstermeye
    /// yetmez: zincir üç kareye kadar uzar (250 ms + 2×350 ms), canlı akış
    /// aktifse ilk kareden sonra durur. Panel kapanınca zincir sıfırlanır.
    private func requestQuickRefresh() {
        guard pollTask != nil, let deviceID = selectedDeviceID else {
            return
        }
        quickRefreshChain = Self.quickRefreshChainLength
        scheduleQuickRefresh(deviceID: deviceID, after: .milliseconds(250))
    }

    /// Dokunuş sonrası en fazla zincir boyu: art arda dokunuşta sayaç
    /// baştan kurulur, kuyruk şişmez.
    nonisolated static let quickRefreshChainLength = 3

    /// Kalan dokunuş-sonrası yenileme sayısı; panel kapanışında sıfırlanır.
    @ObservationIgnored
    private var quickRefreshChain = 0

    /// Zincirin bir halkası: bekle, tek kare koş, `simctl` yolundaysan ve
    /// hak kaldıysa bir sonrakini kur. Canlı akış aktifken `pollOnce`
    /// zaten no-op döner, zincir kendiliğinden söner.
    private func scheduleQuickRefresh(deviceID: String, after delay: Duration) {
        quickRefreshTask?.cancel()
        quickRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else {
                return
            }
            await self?.pollOnce(deviceID: deviceID)
            guard let self, !Task.isCancelled else {
                return
            }
            self.quickRefreshChain -= 1
            if self.quickRefreshChain > 0, !self.liveStream.isActive {
                self.scheduleQuickRefresh(deviceID: deviceID, after: .milliseconds(350))
            } else {
                self.quickRefreshChain = 0
            }
        }
    }

    /// Her kare kendi dosyasına yazar: çözme yakalamayla çakışık koştuğu
    /// için sabit dosya adı bir sonraki kare tarafından ezilirdi.
    nonisolated static func screenshotPath(deviceID: String, sequence: UInt64) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agentic-sidebar-simulator-\(deviceID)-\(sequence).jpg")
            .path
    }
}
