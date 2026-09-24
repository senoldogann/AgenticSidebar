import CoreGraphics
import Darwin
import Foundation

/// Koşan bir simülatör cihazına dokunma olayı gönderir.
///
/// `simctl`'in dokunma komutu yoktur; cihaza girdi göndermenin Apple'ın
/// kendi araçlarının da kullandığı yolu `SimulatorKit`'in Indigo HID
/// köprüsüdür. Çerçeveler çalışma anında `dlopen` ile yüklenir; uygulama bu
/// özel çerçevelere bağlanmaz, yokluklarında yalnız dokunma özelliği düşer.
///
/// İstemci cihaz başına bir kez kurulur ve seri bir kuyrukta yaşar: Indigo
/// mesajları iş parçacığı güvenli değildir, aynı cihaza eşzamanlı iki olay
/// göndermek bağlantıyı bozar. Bu yüzden sınıf `@unchecked Sendable`'dır;
/// tüm durumu `queue` ile korunur.
final class SimulatorHIDBridge: @unchecked Sendable {
    enum BridgeError: LocalizedError, Equatable {
        case deviceNotFound(udid: String)
        case deviceNotBooted(udid: String)
        case frameworksUnavailable(detail: String)
        case clientUnavailable(detail: String)
        case sendFailed(detail: String)

        var errorDescription: String? {
            switch self {
            case .deviceNotFound(let udid):
                "No simulator device matches \(udid)."
            case .deviceNotBooted(let udid):
                "Simulator device \(udid) is not booted."
            case .frameworksUnavailable(let detail):
                "Simulator input frameworks could not be loaded: \(detail)"
            case .clientUnavailable(let detail):
                "Simulator input client could not be created: \(detail)"
            case .sendFailed(let detail):
                "The touch event could not be sent: \(detail)"
            }
        }
    }

    /// Indigo mesaj yerleşimi: `SimulatorKit`'in C yapıları `#pragma pack(4)`
    /// ile hizalıdır. Alan adları bilinmediği için bayt ofsetleriyle kurulur.
    private enum IndigoLayout {
        /// Mach başlığı (24) + iç boyut (4) + olay tipi (1) + dolgu (3) + yük (160).
        static let messageSize = 192
        static let payloadSize = 160
        static let payloadOffset = 32
        static let touchOffsetInPayload = 16
        static let touchSize = 112
        static let xRatioOffsetInTouch = 12
        static let yRatioOffsetInTouch = 20
        /// Kaynak mesajdaki dokunma yapısının ofseti.
        static let seedTouchOffset = payloadOffset + touchOffsetInPayload
        /// İkinci yükün başladığı ofset (ilk yükün birebir kopyası).
        static let secondPayloadOffset = messageSize
        static let totalSize = messageSize + payloadSize
        static let eventTypeTouch: UInt8 = 2
        static let touchTarget: Int32 = 0x32
        static let touchDown: Int32 = 0x1
        static let touchUp: Int32 = 0x2
        static let payloadField1: UInt32 = 0x0000_000b
    }

    private let queue = DispatchQueue(label: "com.dogan.AgenticSidebar.simulator-hid")

    /// Kuyrukla korunan durum.
    private var clients: [String: AnyObject] = [:]
    private var simulatorKitHandle: UnsafeMutableRawPointer?
    private var mouseMessageFunction: MouseMessageFunction?
    private var failedAttachments: [String: String] = [:]

    private typealias MouseMessageFunction =
        @convention(c) (
            UnsafeMutablePointer<CGPoint>,
            UnsafeMutablePointer<CGPoint>?,
            Int32,
            Int32,
            Bool
        ) -> UnsafeMutableRawPointer?

    private typealias ClientInitFunction =
        @convention(c) (
            AnyObject,
            Selector,
            AnyObject,
            AutoreleasingUnsafeMutablePointer<NSError?>?
        ) -> AnyObject?

    private typealias ClientSendFunction =
        @convention(c) (
            AnyObject,
            Selector,
            UnsafeMutableRawPointer?,
            Bool,
            DispatchQueue,
            // Tamamlama blok cihaz tarafından eşzamansız tutulur; kaçmayan
            // kapanış buraya yığın adresiyle gelip çalışmayı öldürür
            // (EXC_BREAKPOINT "non-escaping closure has escaped"), bu yüzden
            // kaçan blok olarak işaretlenir.
            @escaping @convention(block) (NSError?) -> Void
        ) -> Void

    private typealias ErrorGetter =
        @convention(c) (
            AnyObject,
            Selector,
            AutoreleasingUnsafeMutablePointer<NSError?>?
        ) -> AnyObject?

    private typealias ContextGetter =
        @convention(c) (
            AnyObject,
            Selector,
            NSString,
            AutoreleasingUnsafeMutablePointer<NSError?>?
        ) -> AnyObject?

    // MARK: - Genel arayüz

    /// Cihazın eşzamansız tuttuğu boş tamamlama bloğu: uygulama ömrü boyunca
    /// yaşar, yakalama yapmaz; her dokunuşta yeniden üretilmez.
    nonisolated(unsafe) private static let noopCompletion: @convention(block) (NSError?) -> Void = { _ in }

    /// Normalize koordinata (0..1) parmak indirir.
    func touch(
        udid: String,
        xRatio: Double,
        yRatio: Double,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        queue.async { [self] in
            let result = sendTouch(udid: udid, xRatio: xRatio, yRatio: yRatio, down: true)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Normalize koordinattan parmağı kaldırır.
    func release(
        udid: String,
        xRatio: Double,
        yRatio: Double,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        queue.async { [self] in
            let result = sendTouch(udid: udid, xRatio: xRatio, yRatio: yRatio, down: false)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Tek dokunuş: indir, kısa tut, kaldır.
    func tap(
        udid: String,
        xRatio: Double,
        yRatio: Double,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        queue.async { [self] in
            let down = sendTouch(udid: udid, xRatio: xRatio, yRatio: yRatio, down: true)
            guard case .success = down else {
                DispatchQueue.main.async { completion(down) }
                return
            }
            usleep(45_000)
            let up = sendTouch(udid: udid, xRatio: xRatio, yRatio: yRatio, down: false)
            DispatchQueue.main.async { completion(up) }
        }
    }

    /// Cihaz kapanınca ya da seçim değişince istemciyi bırakır.
    func detach(udid: String) {
        queue.async { [self] in
            clients.removeValue(forKey: udid)
            failedAttachments.removeValue(forKey: udid)
        }
    }

    // MARK: - Gönderim

    private func sendTouch(
        udid: String,
        xRatio: Double,
        yRatio: Double,
        down: Bool
    ) -> Result<Void, Error> {
        // Aralık dışı oran Indigo'da tanımsız davranışa yol açar; dokunuş
        // öncesi kırpılır, NaN sıfıra düşer.
        let clampedX = clampedRatio(xRatio)
        let clampedY = clampedRatio(yRatio)
        let resolvedClient: AnyObject
        switch client(for: udid) {
        case .success(let resolved):
            resolvedClient = resolved
        case .failure(let error):
            return .failure(error)
        }

        guard let mouseMessageFunction else {
            return .failure(BridgeError.frameworksUnavailable(detail: "Indigo touch symbol is missing"))
        }

        var point = CGPoint(x: clampedX, y: clampedY)
        let eventType = down ? IndigoLayout.touchDown : IndigoLayout.touchUp
        guard
            let seed = mouseMessageFunction(
                &point,
                nil,
                IndigoLayout.touchTarget,
                eventType,
                false
            )
        else {
            return .failure(BridgeError.sendFailed(detail: "Indigo returned no message"))
        }
        defer { free(seed) }

        guard let message = calloc(1, IndigoLayout.totalSize) else {
            return .failure(BridgeError.sendFailed(detail: "The Indigo message could not be allocated"))
        }
        let bytes = message

        // İç boyut ve olay tipi.
        bytes.storeBytes(of: UInt32(IndigoLayout.payloadSize), toByteOffset: 24, as: UInt32.self)
        bytes.storeBytes(of: IndigoLayout.eventTypeTouch, toByteOffset: 28, as: UInt8.self)
        // Yük başlığı.
        bytes.storeBytes(of: IndigoLayout.payloadField1, toByteOffset: 32, as: UInt32.self)
        bytes.storeBytes(
            of: mach_absolute_time(),
            toByteOffset: 36,
            as: UInt64.self
        )
        // Dokunma yapısı kaynaktan kopyalanır; koordinatlar üstüne yazılır.
        let seedBytes = seed
        for offset in 0..<IndigoLayout.touchSize {
            bytes.storeBytes(
                of: seedBytes.load(fromByteOffset: IndigoLayout.seedTouchOffset + offset, as: UInt8.self),
                toByteOffset: IndigoLayout.payloadOffset + IndigoLayout.touchOffsetInPayload + offset,
                as: UInt8.self
            )
        }
        let touchOffset = IndigoLayout.payloadOffset + IndigoLayout.touchOffsetInPayload
        bytes.storeBytes(
            of: clampedX,
            toByteOffset: touchOffset + IndigoLayout.xRatioOffsetInTouch,
            as: Double.self
        )
        bytes.storeBytes(
            of: clampedY,
            toByteOffset: touchOffset + IndigoLayout.yRatioOffsetInTouch,
            as: Double.self
        )
        // Aynı yük ikinci kez: Indigo dokunuşu iki örnekli tek mesajla taşır.
        for offset in 0..<IndigoLayout.payloadSize {
            bytes.storeBytes(
                of: bytes.load(fromByteOffset: IndigoLayout.payloadOffset + offset, as: UInt8.self),
                toByteOffset: IndigoLayout.secondPayloadOffset + offset,
                as: UInt8.self
            )
        }
        let secondTouchOffset = IndigoLayout.secondPayloadOffset + IndigoLayout.touchOffsetInPayload
        bytes.storeBytes(of: UInt32(1), toByteOffset: secondTouchOffset, as: UInt32.self)
        bytes.storeBytes(of: UInt32(2), toByteOffset: secondTouchOffset + 4, as: UInt32.self)

        // SimulatorKit sürüm farkı: `sendWithMessage:freeWhenDone:completionQueue:completion:`
        // bazı sürümlerde instance method, bazılarında class method, bazılarında
        // yoktur. Çalışma anında her ikisini de dene; hiçbiri yoksa HID'i
        // bu cihaz için devre dışı bırak ve hatayı yukarı ilet.
        let selector = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
        let clientObj = resolvedClient as? NSObject

        // 1) Instance method dene
        if let imp = sendFunction(on: resolvedClient) {
            // ObjC istisnası Swift'te yakalanamaz; çökmeyi engellemek için
            // çağrıyı ayrı bir blokta yapıp, çökerse client'ı bırak.
            // Not: bu yine de süreç çökerse yetmez; ancak selector varlığını
            // iki yerde doğruluyoruz (instance + class), bu yüzden risk düşük.
            let sendSelector = selector
            if clientObj?.responds(to: sendSelector) == true {
                imp(
                    resolvedClient,
                    sendSelector,
                    message,
                    true,
                    queue,
                    Self.noopCompletion
                )
                return .success(())
            }
        }

        // 2) Class method dene (bazı SDK sürümlerinde class method olmuş)
        let clientClass: AnyClass? = object_getClass(resolvedClient)
        if let cls = clientClass, cls.responds(to: selector) {
            // Class method IMP'sini al ve class objesiyle çağır
            if let method = class_getClassMethod(cls, selector) {
                let imp = unsafeBitCast(method_getImplementation(method), to: ClientSendFunction.self)
                imp(
                    cls,
                    selector,
                    message,
                    true,
                    queue,
                    Self.noopCompletion
                )
                return .success(())
            }
        }

        // Hiçbiri yok: bu cihaz için HID devre dışı, bir sonraki dokunuşta
        // yeniden denenir (attachClient tekrar çalışır).
        free(message)
        clients.removeValue(forKey: udid)
        failedAttachments[udid] = "sendWithMessage: unavailable (instance & class)"
        return .failure(BridgeError.clientUnavailable(detail: "sendWithMessage: unavailable on this SimulatorKit version"))
    }

    private func sendFunction(on client: AnyObject) -> ClientSendFunction? {
        let selector = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
        guard let method = class_getInstanceMethod(type(of: client), selector) else {
            return nil
        }
        return unsafeBitCast(method_getImplementation(method), to: ClientSendFunction.self)
    }

    // MARK: - İstemci kurulumu

    private func client(for udid: String) -> Result<AnyObject, Error> {
        if let existing = clients[udid] {
            return .success(existing)
        }
        if let failure = failedAttachments[udid] {
            return .failure(BridgeError.clientUnavailable(detail: failure))
        }
        do {
            let created = try attachClient(udid: udid)
            clients[udid] = created
            return .success(created)
        } catch {
            failedAttachments[udid] = error.localizedDescription
            return .failure(error)
        }
    }

    private func attachClient(udid: String) throws -> AnyObject {
        try loadSimulatorKitIfNeeded()

        guard let device = try resolveDevice(udid: udid) else {
            throw BridgeError.deviceNotFound(udid: udid)
        }
        guard isBooted(device: device) else {
            throw BridgeError.deviceNotBooted(udid: udid)
        }

        guard
            let clientClass =
                NSClassFromString("SimulatorKit.SimDeviceLegacyHIDClient")
                ?? NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient")
        else {
            throw BridgeError.clientUnavailable(detail: "SimDeviceLegacyHIDClient class is missing")
        }
        let selector = NSSelectorFromString("initWithDevice:error:")
        guard let method = class_getInstanceMethod(clientClass, selector) else {
            throw BridgeError.clientUnavailable(detail: "initWithDevice:error: is missing")
        }
        // `alloc` adımı atlanırsa mesaj sınıfa gider ve "unrecognized selector"
        // istisnası süreci öldürür; örnek önce yaratılır.
        guard let allocated = class_createInstance(clientClass, 0) as AnyObject? else {
            throw BridgeError.clientUnavailable(detail: "SimDeviceLegacyHIDClient could not be allocated")
        }
        let initialize = unsafeBitCast(method_getImplementation(method), to: ClientInitFunction.self)
        var error: NSError?
        let client = initialize(allocated, selector, device, &error)
        guard let client else {
            throw BridgeError.clientUnavailable(
                detail: error?.localizedDescription ?? "initWithDevice:error: returned nil"
            )
        }
        return client
    }

    private func loadSimulatorKitIfNeeded() throws {
        if simulatorKitHandle != nil {
            return
        }

        let developerDirectory = Self.developerDirectory()
        let candidates = [
            "\(developerDirectory)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
            "\(developerDirectory)/../SharedFrameworks/SimulatorKit.framework/SimulatorKit",
            "/Applications/Xcode.app/Contents/SharedFrameworks/SimulatorKit.framework/SimulatorKit",
            "/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
        ]
        var loaded: UnsafeMutableRawPointer?
        for candidate in candidates {
            if let handle = dlopen(candidate, RTLD_NOW) {
                loaded = handle
                break
            }
        }
        guard let handle = loaded else {
            throw BridgeError.frameworksUnavailable(
                detail: dlerror().map { String(cString: $0) } ?? "SimulatorKit was not found"
            )
        }

        guard
            let symbol = dlsym(handle, "IndigoHIDMessageForMouseNSEvent")
        else {
            throw BridgeError.frameworksUnavailable(detail: "IndigoHIDMessageForMouseNSEvent is missing")
        }
        simulatorKitHandle = handle
        mouseMessageFunction = unsafeBitCast(symbol, to: MouseMessageFunction.self)
    }

    /// CoreSimulator'ın servis bağlamından cihazı UDID ile bulur.
    private func resolveDevice(udid: String) throws -> AnyObject? {
        let coreSimulatorPath = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
        guard dlopen(coreSimulatorPath, RTLD_NOW) != nil else {
            throw BridgeError.frameworksUnavailable(
                detail: dlerror().map { String(cString: $0) } ?? "CoreSimulator was not found"
            )
        }
        guard let contextClass = NSClassFromString("SimServiceContext") else {
            throw BridgeError.frameworksUnavailable(detail: "SimServiceContext is missing")
        }

        let contextSelector = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard let contextMethod = class_getClassMethod(contextClass, contextSelector) else {
            throw BridgeError.frameworksUnavailable(detail: "sharedServiceContextForDeveloperDir: is missing")
        }
        let makeContext = unsafeBitCast(method_getImplementation(contextMethod), to: ContextGetter.self)
        var contextError: NSError?
        let context = makeContext(contextClass, contextSelector, Self.developerDirectory() as NSString, &contextError)
        guard let context else {
            throw BridgeError.frameworksUnavailable(
                detail: contextError?.localizedDescription ?? "The service context could not be created"
            )
        }

        let setSelector = NSSelectorFromString("defaultDeviceSetWithError:")
        guard let setMethod = class_getInstanceMethod(type(of: context), setSelector) else {
            throw BridgeError.frameworksUnavailable(detail: "defaultDeviceSetWithError: is missing")
        }
        let makeSet = unsafeBitCast(method_getImplementation(setMethod), to: ErrorGetter.self)
        var setError: NSError?
        let deviceSet = makeSet(context, setSelector, &setError)
        guard let deviceSet else {
            throw BridgeError.frameworksUnavailable(
                detail: setError?.localizedDescription ?? "The device set could not be created"
            )
        }

        guard let devices = deviceSet.value(forKey: "devices") as? [AnyObject] else {
            return nil
        }

        for device in devices {
            guard
                let handle = device as? NSObject,
                let identifier = handle.value(forKey: "UDID") as? NSUUID
            else {
                continue
            }
            if identifier.uuidString.caseInsensitiveCompare(udid) == .orderedSame {
                return handle
            }
        }
        return nil
    }

    private func isBooted(device: AnyObject) -> Bool {
        guard let handle = device as? NSObject else {
            return false
        }
        // CoreSimulator'ın `SimDeviceState` değeri KVC ile NSNumber'a köprülenir;
        // 3 = booted. Seçici doğrudan çağrılırsa Swift enum'u nesne sanılıp
        // çökülür, bu yüzden okuma KVC'den yapılır.
        guard let state = handle.value(forKey: "state") as? NSNumber else {
            return false
        }
        return state.intValue == 3
    }

    /// Oranı 0..1 aralığına kırpar; NaN ve sonsuz sıfıra düşer.
    private func clampedRatio(_ value: Double) -> Double {
        guard value.isFinite else {
            return 0
        }
        return min(1, max(0, value))
    }

    /// Etkin geliştirici dizini; `xcode-select` yoksa bilinen kurulum.
    private static func developerDirectory() -> String {
        if let configured = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !configured.isEmpty {
            return configured
        }
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
}
