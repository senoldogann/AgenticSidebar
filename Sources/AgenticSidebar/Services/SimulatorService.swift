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

    private(set) var phase: Phase = .idle
    private(set) var devices: [SimulatorDevice] = []
    private(set) var selectedDeviceID: String?
    private(set) var frame: CGImage?
    private(set) var isPolling = false
    /// Açma/kapatma süren cihazlar; düğmeler bu sırada bekleme gösterir.
    private(set) var busyDeviceIDs: Set<String> = []
    /// Son işlem hatası; başarılı işlemde temizlenir.
    private(set) var failureMessage: String?

    @ObservationIgnored
    private let commandRunner: any SimulatorCommandRunning

    @ObservationIgnored
    private let pollInterval: Duration

    @ObservationIgnored
    private var pollTask: Task<Void, Never>?

    /// Dokunuş sonrası tetiklenen erken kare; normal turun uykusunu bölmez,
    /// yalnız araya bir kare sokar.
    @ObservationIgnored
    private var quickRefreshTask: Task<Void, Never>?

    /// `simctl io screenshot` turu sürerken yeni tur başlatılmaz: üst üste
    /// binen süreçler hem CPU'yu şişirir hem kare sırasını bozar.
    @ObservationIgnored
    private var frameInFlight = false

    /// Yayınlanan karelerin sıra numarası: çözme yakalamayla çakışık koştuğu
    /// için yavaş biten eski kare yeniyi ezemez, sessizce düşer.
    @ObservationIgnored
    private var frameSequence: UInt64 = 0

    /// Uygulama içi dokunuşları cihaza taşıyan Indigo HID köprüsü.
    @ObservationIgnored
    private let touchBridge = SimulatorHIDBridge()

    /// Cihaz penceresinin canlı akışı (~12 fps): aktifken `simctl` turu
    /// durur, işlemci ve pil korunur. Akış kurulamazsa (izin/pencere yok)
    /// servis sessizce `simctl` yolunda kalır.
    let liveStream: SimulatorLiveStream

    /// Cihaz karesi çözünürlük tavanı (piksel).
    nonisolated static let maximumFramePixelSize = 1000
    nonisolated static let listTimeout: TimeInterval = 20
    nonisolated static let actionTimeout: TimeInterval = 90
    nonisolated static let screenshotTimeout: TimeInterval = 30

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
        syncPolling()
    }

    func select(deviceID: String) {
        guard devices.contains(where: { $0.id == deviceID }) else {
            return
        }
        selectedDeviceID = deviceID
        frame = nil
        failureMessage = nil
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
    }

    /// Paneldeki izin düğmesi: macOS istemini gösterir, izin verilirse akış
    /// seçili cihazda kendiliğinden başlar.
    func requestLiveStreamAccess() {
        liveStream.requestAccess()
    }

    // MARK: - Açma / kapatma

    func boot(deviceID: String) async {
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
        openDeviceWindow()
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

    /// Cihazı gösteren uygulamayı arka planda açar: Xcode 26'da DeviceHub,
    /// öncesinde Simulator. Pencere öne getirilmez (`activates = false`),
    /// odak AgenticSidebar'da kalır; pencere yalnız canlı akışın (`SCStream`)
    /// yakalayacağı kaynak diye gerekir. Uygulama içi görüntü bundan
    /// bağımsızdır; cihaza doğrudan dokunmak isteyen "Open window"u kullanır.
    func openDeviceWindow() {
        let bundleIdentifiers = ["com.apple.iphonesimulator", "com.apple.dt.Devices"]
        for bundleIdentifier in bundleIdentifiers {
            guard
                let url = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: bundleIdentifier
                )
            else {
                continue
            }
            let configuration = NSWorkspace.OpenConfiguration()
            // Odak çalınmaz: pencere arkada belirir, kullanıcı panelde kalır.
            configuration.activates = false
            configuration.hides = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            // Elle "Open window" yolu: akış ölmüş olabilir (pencere kapalıydı),
            // pencere gelince akış bekleme döngüsüyle kendiliğinden tutunur.
            if let name = selectedDevice?.name {
                liveStream.start(deviceName: name)
            }
            return
        }
        failureMessage = "Neither Simulator nor DeviceHub was found; install Xcode."
        AppLog.panels.error("No simulator window application was found to open")
    }

    // MARK: - Canlı görüntü

    /// Seçili cihaz açıksa akışı başlatır; değilse durdurup çerçeveyi bırakır.
    /// Canlı pencere akışı da burada başlar: pencere bulunur ve izin varsa
    /// kareler akıştan gelir, `simctl` turu beklemeye geçer.
    private func syncPolling() {
        guard let device = selectedDevice, device.isBooted else {
            liveStream.stop()
            stopPolling()
            frame = nil
            return
        }
        liveStream.start(deviceName: device.name)
        startPolling(deviceID: device.id)
    }

    private func startPolling(deviceID: String) {
        guard pollTask == nil else {
            return
        }
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
        isPolling = false
        liveStream.stop()
    }

    /// Tek kare: canlı akış aktifken `simctl` çalıştırılmaz — pencere akışı
    /// zaten ~12 fps verir, üstüne tur binerse CPU boşa yanar. Akış yoksa
    /// eski yol koşar: yakalama bitince çözme beklenmez, arka planda koşar.
    /// Döngü hemen sonraki yakalamaya geçer; çözme (~50 ms) kritik yoldan
    /// çıkar, kare hızı `simctl`'in kendi süresine (~380 ms) dayanır.
    private func pollOnce(deviceID: String) async {
        guard !liveStream.isActive else {
            return
        }
        guard !frameInFlight else {
            return
        }
        frameInFlight = true
        defer { frameInFlight = false }

        frameSequence += 1
        let sequence = frameSequence
        let path = Self.screenshotPath(deviceID: deviceID, sequence: sequence)
        let result = await commandRunner.run(
            arguments: ["io", deviceID, "screenshot", "--type=jpeg", path],
            timeout: Self.screenshotTimeout
        )
        guard result.didSucceed else {
            failureMessage = result.failureMessage
            removeFile(atPath: path)
            return
        }

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

    /// Çözülen kareyi yalnız en yeniyse yayınlar: yavaş biten eski kare
    /// ekranı geriye saramaz.
    private func publishFrame(_ image: CGImage?, sequence: UInt64) {
        guard sequence == frameSequence else {
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
        guard let deviceID = touchTarget else {
            return
        }
        touchBridge.tap(udid: deviceID, xRatio: normalizedX, yRatio: normalizedY) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.noteTouchResult(result)
            }
        }
    }

    /// Sürüklemenin başlangıcı: parmağı indirir.
    func pressDownAt(normalizedX: Double, normalizedY: Double) {
        guard let deviceID = touchTarget else {
            return
        }
        touchBridge.touch(udid: deviceID, xRatio: normalizedX, yRatio: normalizedY) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.noteTouchResult(result)
            }
        }
    }

    /// Sürükleme sürerken: parmak basılıyken yeni konuma taşınır.
    func pressMoveTo(normalizedX: Double, normalizedY: Double) {
        guard let deviceID = touchTarget else {
            return
        }
        touchBridge.touch(udid: deviceID, xRatio: normalizedX, yRatio: normalizedY) { _ in }
    }

    /// Sürüklemenin sonu: parmağı kaldırır.
    func pressUpAt(normalizedX: Double, normalizedY: Double) {
        guard let deviceID = touchTarget else {
            return
        }
        touchBridge.release(udid: deviceID, xRatio: normalizedX, yRatio: normalizedY) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.noteTouchResult(result)
            }
        }
    }

    /// Dokunuş yalnız açık ve seçili cihaza gider; aralık dışı koordinat
    /// kaydırılmaz, reddedilir.
    private var touchTarget: String? {
        guard let device = selectedDevice, device.isBooted else {
            return nil
        }
        return device.id
    }

    private func noteTouchResult(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            failureMessage = nil
            // Dokunuşun görsel karşılığı bir sonraki turu beklemez: dokunuş
            // ~50 ms'de cihaza varır, 250 ms sonra araya bir kare sokulur.
            requestQuickRefresh()
        case .failure(let error):
            failureMessage = error.localizedDescription
            AppLog.panels.error(
                "Simulator touch failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Normal turun dışında tek kare ister; üst üste dokunuşlarda yalnız son
    /// istek koşar, tur çalışmıyorsa (panel kapalı/kapalı cihaz) hiçbir şey yapmaz.
    private func requestQuickRefresh() {
        guard pollTask != nil, let deviceID = selectedDeviceID else {
            return
        }
        quickRefreshTask?.cancel()
        quickRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else {
                return
            }
            await self?.pollOnce(deviceID: deviceID)
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
