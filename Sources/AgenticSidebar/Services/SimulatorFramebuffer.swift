import CoreGraphics
import Darwin
import Foundation
import IOSurface
import ObjectiveC
import Synchronization

/// CoreSimulator ve SimulatorKit özel çerçevelerine ortak erişim.
///
/// Dokunma köprüsü (`SimulatorHIDBridge`) ve ekran okuyucu
/// (`SimulatorFramebufferStream`) aynı yükleme ve cihaz çözme yolunu
/// kullanır. Çerçeveler çalışma anında `dlopen` ile yüklenir; uygulama
/// onlara bağlanmaz, Xcode yoksa her çağrı açık bir hatayla düşer.
enum SimulatorPrivateFrameworks {
    enum FrameworkError: LocalizedError, Equatable {
        case unavailable(detail: String)

        var detail: String {
            switch self {
            case .unavailable(let detail): detail
            }
        }

        var errorDescription: String? {
            "Simulator frameworks could not be loaded: \(detail)"
        }
    }

    private typealias ContextGetter =
        @convention(c) (AnyObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>?) -> AnyObject?
    private typealias ErrorGetter =
        @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> AnyObject?

    private static let coreSimulatorPath = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"

    /// Yüklenmiş görüntüler: `dlopen` her çağrıda referans sayacını şişirmesin.
    private static let loadedHandles = Mutex<LoadedHandles>(LoadedHandles(coreSimulator: nil, simulatorKit: nil))

    private struct LoadedHandles: @unchecked Sendable {
        var coreSimulator: UnsafeMutableRawPointer?
        var simulatorKit: UnsafeMutableRawPointer?
    }

    /// Çözülmüş geliştirici dizini: `xcode-select` her kurulumda fork'lanmasın
    /// diye bir kez çözülür. `DEVELOPER_DIR` değişirse süreç yeniden başlar,
    /// o yüzden süreç-ömrü önbellek güvenlidir.
    private static let developerDirectoryCache = Mutex<String?>(nil)

    /// Etkin geliştirici dizini; `xcode-select` yoksa bilinen kurulum.
    static func developerDirectory() -> String {
        if let configured = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !configured.isEmpty {
            return configured
        }
        if let cached = developerDirectoryCache.withLock({ $0 }) {
            return cached
        }
        let resolved = queryDeveloperDirectory()
        developerDirectoryCache.withLock { $0 = resolved }
        return resolved
    }

    private static func queryDeveloperDirectory() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                return path
            }
        }
        return "/Applications/Xcode.app/Contents/Developer"
    }

    /// SimulatorKit görüntüsünü yükler (bir kez) ve tutamacını verir.
    /// `SimDisplay*` protokolleri yalnız bu görüntü yüklenince kayıtlı olur.
    static func loadSimulatorKit() throws -> UnsafeMutableRawPointer {
        if let handle = loadedHandles.withLock({ $0.simulatorKit }) {
            return handle
        }
        let developerDirectory = developerDirectory()
        let candidates = [
            "\(developerDirectory)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
            "\(developerDirectory)/../SharedFrameworks/SimulatorKit.framework/SimulatorKit",
            "/Applications/Xcode.app/Contents/SharedFrameworks/SimulatorKit.framework/SimulatorKit",
            "/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
        ]
        for candidate in candidates {
            if let handle = dlopen(candidate, RTLD_NOW) {
                loadedHandles.withLock { $0.simulatorKit = handle }
                return handle
            }
        }
        throw FrameworkError.unavailable(
            detail: dlerror().map { String(cString: $0) } ?? "SimulatorKit was not found"
        )
    }

    private static func loadCoreSimulator() throws {
        if loadedHandles.withLock({ $0.coreSimulator }) != nil {
            return
        }
        guard let handle = dlopen(coreSimulatorPath, RTLD_NOW) else {
            throw FrameworkError.unavailable(
                detail: dlerror().map { String(cString: $0) } ?? "CoreSimulator was not found"
            )
        }
        loadedHandles.withLock { $0.coreSimulator = handle }
    }

    /// CoreSimulator'ın servis bağlamından cihazı UDID ile bulur; cihaz yoksa
    /// `nil`. Hiçbir cihazda okunabilir UDID yoksa anahtar değişmiş demektir:
    /// "bulunamadı" diye sessiz geçilmez, açık hatayla düşülür.
    static func resolveDevice(udid: String) throws -> NSObject? {
        try loadCoreSimulator()
        guard let contextClass = NSClassFromString("SimServiceContext") else {
            throw FrameworkError.unavailable(detail: "SimServiceContext is missing")
        }

        let contextSelector = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard let contextMethod = class_getClassMethod(contextClass, contextSelector) else {
            throw FrameworkError.unavailable(detail: "sharedServiceContextForDeveloperDir: is missing")
        }
        let makeContext = unsafeBitCast(method_getImplementation(contextMethod), to: ContextGetter.self)
        var contextError: NSError?
        let context = makeContext(contextClass, contextSelector, developerDirectory() as NSString, &contextError)
        guard let context else {
            throw FrameworkError.unavailable(
                detail: contextError?.localizedDescription ?? "The service context could not be created"
            )
        }

        let setSelector = NSSelectorFromString("defaultDeviceSetWithError:")
        guard let setMethod = class_getInstanceMethod(type(of: context), setSelector) else {
            throw FrameworkError.unavailable(detail: "defaultDeviceSetWithError: is missing")
        }
        let makeSet = unsafeBitCast(method_getImplementation(setMethod), to: ErrorGetter.self)
        var setError: NSError?
        let deviceSet = makeSet(context, setSelector, &setError)
        guard let deviceSet else {
            throw FrameworkError.unavailable(
                detail: setError?.localizedDescription ?? "The device set could not be created"
            )
        }

        guard let devices = deviceSet.value(forKey: "devices") as? [AnyObject] else {
            throw FrameworkError.unavailable(detail: "SimDeviceSet has no readable devices key on this Xcode version")
        }
        guard !devices.isEmpty else {
            return nil
        }

        var sawReadableUDID = false
        for device in devices {
            guard
                let handle = device as? NSObject,
                let identifier = handle.value(forKey: "UDID") as? NSUUID
            else {
                continue
            }
            sawReadableUDID = true
            if identifier.uuidString.caseInsensitiveCompare(udid) == .orderedSame {
                return handle
            }
        }
        if !sawReadableUDID {
            throw FrameworkError.unavailable(detail: "SimDevice has no readable UDID key on this Xcode version")
        }
        return nil
    }

    /// CoreSimulator'ın `SimDeviceState` değeri KVC ile NSNumber'a köprülenir;
    /// 3 = booted. Seçici doğrudan çağrılırsa Swift enum'u nesne sanılıp
    /// çökülür, bu yüzden okuma KVC'den yapılır.
    static func isBooted(device: NSObject) -> Bool {
        guard let state = device.value(forKey: "state") as? NSNumber else {
            return false
        }
        return state.intValue == 3
    }
}

/// Açık simülatörün ana ekranını CoreSimulator framebuffer'ından okur.
///
/// Pencere yakalama (`SCStream`) yerine cihazın kendi ekran yüzeyi
/// (`IOSurface`) okunur: Simulator/DeviceHub penceresi, Ekran Kaydı izni ve
/// pencere kromu gerekmez; kare yalnız cihaz ekranıdır (dokunuş eşlemesi
/// doğrudan doğrudur) ve cihaz başsız (headless) açıkken de akar. Xcode 27'de
/// `Simulator.app` yoktur, pencere yakalama DeviceHub'ın tüm penceresini
/// (kenar çubuğu, araç çubukları) yakalıyordu.
///
/// Ekran tanımlayıcısı bir ROCK uzak vekilidir: KVC yakalanamaz istisna atar,
/// yöntemleri gerçek sınıfta görünmez. Çağrılar `objc_msgSend` imzalarıyla
/// yapılır; her seçicinin tip kodlaması çağrıdan önce protokol tanımıyla
/// karşılaştırılır — uymazsa yanlış kayıtla çağırıp süreci öldürmek yerine
/// açık hata atılır.
///
/// Hasar geri çağrısı ROCK'un kendi seri kuyruğunda gelir; kareler bu
/// sınıfın kuyruğunda birleştirilir (aynı anda tek dönüşüm) ve en fazla
/// `minimumFrameInterval` sıklıkla teslim edilir. Tüm değişken durum
/// `queue` ile korunur.
final class SimulatorFramebufferStream: @unchecked Sendable {
    enum StreamError: LocalizedError, Equatable {
        case frameworksUnavailable(detail: String)
        case deviceNotFound(udid: String)
        case deviceNotBooted(udid: String)
        case signatureMismatch(selector: String, expected: String, actual: String)
        case displayUnavailable(detail: String)
        case surfaceUnavailable(detail: String)
        /// Yüzey okunuyor ama kareye çevrilemiyor (desteklenmeyen piksel
        /// biçimi, kilit hatası); ilk karede anlaşılır ve kalıcıdır.
        case frameUnreadable(detail: String)

        var errorDescription: String? {
            switch self {
            case .frameUnreadable(let detail):
                "The simulator framebuffer could not be converted to a frame: \(detail)"
            case .frameworksUnavailable(let detail):
                "Simulator frameworks could not be loaded: \(detail)"
            case .deviceNotFound(let udid):
                "No simulator device matches \(udid)."
            case .deviceNotBooted(let udid):
                "Simulator device \(udid) is not booted."
            case .signatureMismatch(let selector, let expected, let actual):
                "Unexpected type encoding for \(selector): expected \(expected), got \(actual)."
            case .displayUnavailable(let detail):
                "The simulator's main display could not be located: \(detail)"
            case .surfaceUnavailable(let detail):
                "The simulator framebuffer is unavailable: \(detail)"
            }
        }
    }

    private typealias ObjectGetter = @convention(c) (AnyObject, Selector) -> AnyObject?
    private typealias SizeGetter = @convention(c) (AnyObject, Selector) -> CGSize
    private typealias CallbackRegistrar = @convention(c) (AnyObject, Selector, NSUUID, AnyObject) -> Void
    private typealias CallbackUnregistrar = @convention(c) (AnyObject, Selector, NSUUID) -> Void
    /// Blok parametreleri nesne türlü olmalı: ROCK bloğu imzasına göre
    /// sıralar, gösterge türlü parametreli blok hiç çağrılmaz.
    private typealias DamageBlock = @convention(block) (AnyObject?) -> Void
    private typealias SurfacesChangeBlock = @convention(block) (AnyObject?, AnyObject?) -> Void

    private struct RequiredSignature {
        let protocolName: String
        let selector: String
        let encoding: String
    }

    /// Kullanılan seçiciler ve beklenen tip kodlamaları (Xcode 27'de ölçüldü).
    private static let requiredSignatures: [RequiredSignature] = [
        RequiredSignature(protocolName: "SimDisplayRenderable", selector: "displaySize", encoding: "{CGSize=dd}16@0:8"),
        RequiredSignature(
            protocolName: "SimDisplayRenderable",
            selector: "registerCallbackWithUUID:damageRectanglesCallback:",
            encoding: "v32@0:8@16@?24"
        ),
        RequiredSignature(
            protocolName: "SimDisplayRenderable",
            selector: "unregisterDamageRectanglesCallbackWithUUID:",
            encoding: "v24@0:8@16"
        ),
        RequiredSignature(
            protocolName: "SimDisplayIOSurfaceRenderable",
            selector: "framebufferSurface",
            encoding: "@16@0:8"
        ),
        RequiredSignature(
            protocolName: "SimDisplayIOSurfaceRenderable",
            selector: "registerCallbackWithUUID:ioSurfacesChangeCallback:",
            encoding: "v32@0:8@16@?24"
        ),
        RequiredSignature(
            protocolName: "SimDisplayIOSurfaceRenderable",
            selector: "unregisterIOSurfacesChangeCallbackWithUUID:",
            encoding: "v24@0:8@16"
        ),
    ]

    /// En sık kare teslimi (~30 fps): panel için akıcıdır; 60 fps her karede
    /// ana iş parçacığındaki görüntü yenilemesini ikiye katlardı.
    static let minimumFrameIntervalNanoseconds: UInt64 = 33_000_000

    private let queue = DispatchQueue(label: "com.dogan.AgenticSidebar.simulator-framebuffer", qos: .userInitiated)

    /// Kuyrukla korunan durum.
    private var descriptor: NSObject?
    private var surface: IOSurface?
    private var damageUUID = NSUUID()
    private var surfacesUUID = NSUUID()
    /// Her başlat/durdur turunda artar: eski turun geç gelen geri çağrısı
    /// yeni turun karesini ya da bitiş bildirimini tetiklemez.
    private var generation: UInt64 = 0
    private var frameScheduled = false
    /// Son kare dönüşümü düştü mü: günlük yalnız ilk düşmede yazılır, hasar
    /// geri çağrısı başına (saniyede 30 kez) değil.
    private var lastFrameFailed = false
    private var lastDeliveryNanoseconds: UInt64 = 0
    private var maximumPixelSize = 1400
    private var onFrame: (@Sendable (CGImage) -> Void)?
    private var onEnded: (@Sendable () -> Void)?

    /// `objc_msgSend` adresi (RTLD_DEFAULT = -2); bulunamazsa akış başlamaz.
    private static func messageSend() throws -> UnsafeMutableRawPointer {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else {
            throw StreamError.frameworksUnavailable(detail: "objc_msgSend could not be resolved")
        }
        return symbol
    }

    /// Akışı başlatır; ilk kare hemen teslim edilir (durgun ekranda hasar
    /// geri çağrısı hiç gelmez). Cihaz kapanınca `onEnded` bir kez çağrılır.
    func start(
        udid: String,
        maximumPixelSize: Int,
        onFrame: @escaping @Sendable (CGImage) -> Void,
        onEnded: @escaping @Sendable () -> Void
    ) async throws {
        // İptal bayrağı kuyruk bloğunda okunur: arayan görev iptal edildiyse
        // (cihaz değişti, panel kapandı) `stop()` bu bloktan önce kuyruğa
        // girmiş olabilir; kayıt yapılmadan çıkılır, sahipsiz akış kalmaz.
        let cancellation = StartCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        try startOnQueue(
                            udid: udid,
                            maximumPixelSize: maximumPixelSize,
                            onFrame: onFrame,
                            onEnded: onEnded
                        )
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// `start` görevinin iptal edildiğini kuyruk bloğuna taşır.
    private final class StartCancellation: Sendable {
        private let state = Mutex(false)

        var isCancelled: Bool {
            state.withLock { $0 }
        }

        func cancel() {
            state.withLock { $0 = true }
        }
    }

    /// Geri çağrıları bırakır; bekleyen kare teslim edilmez.
    func stop() {
        queue.async { [self] in
            stopOnQueue(unregister: true)
        }
    }

    private func startOnQueue(
        udid: String,
        maximumPixelSize: Int,
        onFrame: @escaping @Sendable (CGImage) -> Void,
        onEnded: @escaping @Sendable () -> Void
    ) throws {
        stopOnQueue(unregister: true)

        do {
            _ = try SimulatorPrivateFrameworks.loadSimulatorKit()
        } catch let error as SimulatorPrivateFrameworks.FrameworkError {
            throw StreamError.frameworksUnavailable(detail: error.detail)
        }
        try Self.verifySignatures()

        let resolved: NSObject?
        do {
            resolved = try SimulatorPrivateFrameworks.resolveDevice(udid: udid)
        } catch let error as SimulatorPrivateFrameworks.FrameworkError {
            throw StreamError.frameworksUnavailable(detail: error.detail)
        }
        guard let device = resolved else {
            throw StreamError.deviceNotFound(udid: udid)
        }
        guard SimulatorPrivateFrameworks.isBooted(device: device) else {
            throw StreamError.deviceNotBooted(udid: udid)
        }

        let displayDescriptor = try Self.mainDisplayDescriptor(of: device)
        let displaySurface = try Self.framebufferSurface(of: displayDescriptor)
        let send = try Self.messageSend()
        // İlk kare kayıttan önce çevrilir: çevrilemiyorsa akış "başladı"
        // denip panel boş bırakılmaz, hata arayana döner ve yedek yol devreye
        // girer. Durgun ekranda hasar geri çağrısı gelmediği için bu kare
        // aynı zamanda panelin ilk görüntüsüdür.
        let firstFrame: CGImage
        do {
            firstFrame = try SimulatorFramebufferImage.downscaledImage(
                from: displaySurface,
                maximumPixelSize: maximumPixelSize
            )
        } catch {
            throw StreamError.frameUnreadable(detail: error.localizedDescription)
        }

        generation &+= 1
        let currentGeneration = generation
        descriptor = displayDescriptor
        surface = displaySurface
        self.maximumPixelSize = maximumPixelSize
        self.onFrame = onFrame
        self.onEnded = onEnded
        damageUUID = NSUUID()
        surfacesUUID = NSUUID()

        let damageBlock: DamageBlock = { [weak self] _ in
            self?.queue.async { [weak self] in
                self?.scheduleFrame(generation: currentGeneration)
            }
        }
        let surfacesBlock: SurfacesChangeBlock = { [weak self] unmasked, _ in
            let replacement = unmasked as? IOSurface
            self?.queue.async { [weak self] in
                self?.handleSurfacesChange(replacement, generation: currentGeneration)
            }
        }
        let register = unsafeBitCast(send, to: CallbackRegistrar.self)
        register(
            displayDescriptor,
            NSSelectorFromString("registerCallbackWithUUID:damageRectanglesCallback:"),
            damageUUID,
            unsafeBitCast(damageBlock, to: AnyObject.self)
        )
        register(
            displayDescriptor,
            NSSelectorFromString("registerCallbackWithUUID:ioSurfacesChangeCallback:"),
            surfacesUUID,
            unsafeBitCast(surfacesBlock, to: AnyObject.self)
        )

        lastFrameFailed = false
        lastDeliveryNanoseconds = DispatchTime.now().uptimeNanoseconds
        onFrame(firstFrame)
    }

    private func stopOnQueue(unregister: Bool) {
        generation &+= 1
        if unregister, let descriptor, let send = try? Self.messageSend() {
            let unregisterCallback = unsafeBitCast(send, to: CallbackUnregistrar.self)
            unregisterCallback(
                descriptor,
                NSSelectorFromString("unregisterDamageRectanglesCallbackWithUUID:"),
                damageUUID
            )
            unregisterCallback(
                descriptor,
                NSSelectorFromString("unregisterIOSurfacesChangeCallbackWithUUID:"),
                surfacesUUID
            )
        }
        descriptor = nil
        surface = nil
        frameScheduled = false
        onFrame = nil
        onEnded = nil
    }

    /// Hasar bildirimi: sürerken gelenler tek kareye iner, teslim aralığı
    /// `minimumFrameIntervalNanoseconds` altına düşmez.
    private func scheduleFrame(generation scheduledGeneration: UInt64) {
        guard scheduledGeneration == generation, !frameScheduled else {
            return
        }
        frameScheduled = true
        let now = DispatchTime.now().uptimeNanoseconds
        let earliest = lastDeliveryNanoseconds + Self.minimumFrameIntervalNanoseconds
        let deadline = DispatchTime(uptimeNanoseconds: max(now, earliest))
        queue.asyncAfter(deadline: deadline) { [weak self] in
            // Eski kuşağın zamanlayıcısı yeni kuşağın planını sıfırlamaz.
            guard let self, scheduledGeneration == self.generation else {
                return
            }
            self.frameScheduled = false
            self.deliverFrame(generation: scheduledGeneration)
        }
    }

    private func deliverFrame(generation deliveredGeneration: UInt64) {
        guard deliveredGeneration == generation, let surface, let onFrame else {
            return
        }
        lastDeliveryNanoseconds = DispatchTime.now().uptimeNanoseconds
        do {
            let image = try SimulatorFramebufferImage.downscaledImage(
                from: surface,
                maximumPixelSize: maximumPixelSize
            )
            lastFrameFailed = false
            onFrame(image)
        } catch {
            if !lastFrameFailed {
                AppLog.panels.error(
                    "Simulator framebuffer frame dropped: \(error.localizedDescription, privacy: .public)"
                )
            }
            lastFrameFailed = true
        }
    }

    /// Yüzey değişti: yeni yüzeyle sürer; `nil` cihazın kapandığı demektir,
    /// vekil ölüdür (kaydı silmeye çalışılmaz) ve akış biter.
    private func handleSurfacesChange(_ replacement: IOSurface?, generation changedGeneration: UInt64) {
        guard changedGeneration == generation else {
            return
        }
        guard let replacement else {
            let ended = onEnded
            stopOnQueue(unregister: false)
            ended?()
            return
        }
        surface = replacement
        scheduleFrame(generation: changedGeneration)
    }

    /// Bu Xcode'da framebuffer okunabilir mi: SimulatorKit yüklenir ve
    /// kullanılan seçicilerin imzaları doğrulanır; cihaz gerekmez. `dlopen`
    /// ilk çağrıda yüz milisaniyeler sürebildiği için ayrık görevde koşar.
    static func isSupportedOnCurrentToolchain() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            do {
                _ = try SimulatorPrivateFrameworks.loadSimulatorKit()
                try verifySignatures()
                return true
            } catch {
                return false
            }
        }.value
    }

    // MARK: - Keşif

    private static func verifySignatures() throws {
        for signature in requiredSignatures {
            guard let proto = NSProtocolFromString(signature.protocolName) else {
                throw StreamError.signatureMismatch(
                    selector: signature.selector,
                    expected: signature.encoding,
                    actual: "<\(signature.protocolName) is not registered>"
                )
            }
            let description = protocol_getMethodDescription(
                proto,
                NSSelectorFromString(signature.selector),
                true,
                true
            )
            guard let types = description.types else {
                throw StreamError.signatureMismatch(
                    selector: signature.selector,
                    expected: signature.encoding,
                    actual: "<missing>"
                )
            }
            let actual = String(cString: types)
            guard actual == signature.encoding else {
                throw StreamError.signatureMismatch(
                    selector: signature.selector,
                    expected: signature.encoding,
                    actual: actual
                )
            }
        }
    }

    /// `device.io.ioPorts` içinden iki `SimDisplay` protokolüne de uyan ve
    /// `displaySize`'ı cihazın ana ekran piksel boyutuna eşit olan port.
    /// Xcode 27'de `displayClass` yok; birden çok ekran portu görünür, ana
    /// ekran dışındakiler 0×0 bildirir. Sıra garanti değildir.
    private static func mainDisplayDescriptor(of device: NSObject) throws -> NSObject {
        guard let io = device.value(forKey: "io") as? NSObject else {
            throw StreamError.displayUnavailable(detail: "SimDevice.io is nil")
        }
        guard let ports = io.value(forKey: "ioPorts") as? [NSObject] else {
            throw StreamError.displayUnavailable(detail: "SimDeviceIOClient.ioPorts is unreadable")
        }
        guard
            let renderable = NSProtocolFromString("SimDisplayRenderable"),
            let surfaceRenderable = NSProtocolFromString("SimDisplayIOSurfaceRenderable")
        else {
            throw StreamError.displayUnavailable(detail: "SimDisplay protocols are not registered")
        }
        guard
            let deviceType = device.value(forKey: "deviceType") as? NSObject,
            let sizeValue = deviceType.value(forKey: "mainScreenSize") as? NSValue
        else {
            throw StreamError.displayUnavailable(detail: "deviceType.mainScreenSize is unreadable")
        }
        let expected = sizeValue.sizeValue
        let send = try messageSend()
        let objectGetter = unsafeBitCast(send, to: ObjectGetter.self)
        let sizeGetter = unsafeBitCast(send, to: SizeGetter.self)
        let descriptorSelector = NSSelectorFromString("descriptor")
        var seenSizes: [String] = []
        for port in ports {
            guard port.responds(to: descriptorSelector),
                let candidate = objectGetter(port, descriptorSelector) as? NSObject,
                candidate.conforms(to: renderable),
                candidate.conforms(to: surfaceRenderable)
            else {
                continue
            }
            let size = sizeGetter(candidate, NSSelectorFromString("displaySize"))
            seenSizes.append("\(Int(size.width))x\(Int(size.height))")
            if size == expected {
                return candidate
            }
        }
        throw StreamError.displayUnavailable(
            detail:
                "no display reports \(Int(expected.width))x\(Int(expected.height)); saw [\(seenSizes.joined(separator: ", "))]"
        )
    }

    private static func framebufferSurface(of descriptor: NSObject) throws -> IOSurface {
        let getter = unsafeBitCast(try messageSend(), to: ObjectGetter.self)
        guard let object = getter(descriptor, NSSelectorFromString("framebufferSurface")) else {
            throw StreamError.surfaceUnavailable(detail: "framebufferSurface returned nil")
        }
        guard let surface = object as? IOSurface else {
            throw StreamError.surfaceUnavailable(detail: "framebufferSurface returned \(type(of: object))")
        }
        return surface
    }
}

/// Framebuffer yüzeyini panelde gösterilecek küçültülmüş görüntüye çevirir.
///
/// Yüzey simülatörle paylaşılır ve tek tamponludur: salt-okuma kilidi
/// altında, kopya olmadan doğrudan küçük bağlama çizilir (tek geçiş).
/// Satır sonu dolgusu (`bytesPerRow` genişlik×4'ten büyüktür) korunur, yoksa
/// görüntü kayardı. Renk uzayı Display P3'tür.
enum SimulatorFramebufferImage {
    enum ConversionError: LocalizedError, Equatable {
        case unsupportedPixelFormat(OSType)
        case lockFailed(status: Int32)
        case imageCreationFailed(detail: String)

        var errorDescription: String? {
            switch self {
            case .unsupportedPixelFormat(let format):
                "The framebuffer pixel format 0x\(String(format, radix: 16)) is not BGRA."
            case .lockFailed(let status):
                "IOSurfaceLock failed with status \(status)."
            case .imageCreationFailed(let detail):
                "The frame image could not be created: \(detail)"
            }
        }
    }

    struct PixelSize: Equatable, Sendable {
        let width: Int
        let height: Int
    }

    static let bgraPixelFormat: OSType = 0x4247_5241

    /// Hedef boyut: uzun kenar `maximumPixelSize`'ı aşmaz, oran korunur,
    /// büyütme yapılmaz. Saf hesap.
    static func targetSize(width: Int, height: Int, maximumPixelSize: Int) -> PixelSize {
        let longest = max(width, height)
        guard longest > maximumPixelSize, longest > 0 else {
            return PixelSize(width: width, height: height)
        }
        let scale = Double(maximumPixelSize) / Double(longest)
        return PixelSize(
            width: max(1, Int((Double(width) * scale).rounded())),
            height: max(1, Int((Double(height) * scale).rounded()))
        )
    }

    static func downscaledImage(from surface: IOSurface, maximumPixelSize: Int) throws -> CGImage {
        let pixelFormat = IOSurfaceGetPixelFormat(surface)
        guard pixelFormat == bgraPixelFormat else {
            throw ConversionError.unsupportedPixelFormat(pixelFormat)
        }
        let lockStatus = IOSurfaceLock(surface, .readOnly, nil)
        guard lockStatus == kIOReturnSuccess else {
            throw ConversionError.lockFailed(status: lockStatus)
        }
        defer {
            IOSurfaceUnlock(surface, .readOnly, nil)
        }

        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
            let provider = CGDataProvider(
                dataInfo: nil,
                data: IOSurfaceGetBaseAddress(surface),
                size: bytesPerRow * height,
                releaseData: { _, _, _ in }
            ),
            let source = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            throw ConversionError.imageCreationFailed(detail: "the surface could not be wrapped")
        }

        let target = targetSize(width: width, height: height, maximumPixelSize: maximumPixelSize)
        guard
            let context = CGContext(
                data: nil,
                width: target.width,
                height: target.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            )
        else {
            throw ConversionError.imageCreationFailed(detail: "the \(target.width)x\(target.height) context")
        }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        guard let image = context.makeImage() else {
            throw ConversionError.imageCreationFailed(detail: "makeImage returned nil")
        }
        return image
    }
}
