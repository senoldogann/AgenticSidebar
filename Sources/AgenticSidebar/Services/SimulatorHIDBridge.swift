import CoreGraphics
import Darwin
import Foundation
import Synchronization

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
    /// Tel düzeni facebook/idb `PrivateHeaders/SimulatorApp/Indigo.h` ile
    /// aynıdır: tek yüklü ileti 0xC0 (192) bayt, ikinci yük 0xC0 ofsetinde.
    /// Bu yüzden aşağıdaki sabitlerin hiçbiri değiştirilmedi.
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
        static let touchTarget: UInt32 = 0x32
        static let touchDown: UInt32 = 0x1
        static let touchUp: UInt32 = 0x2
        static let payloadField1: UInt32 = 0x0000_000b
    }

    private let queue = DispatchQueue(label: "com.dogan.AgenticSidebar.simulator-hid")

    /// Kuyrukla korunan durum.
    private var clients: [String: AnyObject] = [:]
    private var simulatorKitHandle: UnsafeMutableRawPointer?
    private var mouseMessageFunction: MouseMessageFunction?
    /// Başarısız kurulumların süreli önbelleği: 30 sn dolmadan aynı cihaza
    /// yeniden kurulum denenmez, süre dolunca yeniden denemeye açılır.
    private var failedAttachments = SimulatorHIDFailureCache()
    /// Birleştirilmiş taşıma turu sürüyor mu; sürerken gelen taşıma
    /// cihaz başına bekler (yalnız her cihazın en yenisi). Sözlük yapısı
    /// iki cihazın koordinatlarının birbirine karışmasını önler.
    private var moveInFlight = false
    private var pendingMoves: [String: (x: Double, y: Double)] = [:]
    /// Birleşen turda yutulan çağrıların tamamlanmaları: tur bitince hepsi
    /// son sonuçla çağrılır, hiçbir çağıran yanıtsız kalmaz.
    private var pendingMoveCompletions: [(Result<Void, Error>) -> Void] = []

    /// `IndigoHIDMessageForMouseNSEvent` gerçek C imzası 6 argümanlıdır:
    /// `(CGPoint*, CGPoint*, hedef, olayTipi, NSSize, kenar)`. Kaynak:
    /// serve-sim `HIDInjector` (`g_mouse_fn(&pt, NULL, 0x32, ns_type,
    /// screen, 0)` çağrısı) ve baguette 7-arg ABI çözümü (kenar baytı
    /// `NSSize` çiftiyle birlikte taşınır). Eski 5-arg `Bool` kuyruklu
    /// imza yığını kaydırıp tanımsız davranışa yol açardı.
    private typealias MouseMessageFunction =
        @convention(c) (
            UnsafeMutablePointer<CGPoint>,
            UnsafeMutablePointer<CGPoint>?,
            UInt32,
            UInt32,
            CGSize,
            UInt32
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

    // MARK: - Genel arayüz

    /// Teslim tamamlaması: cihaz bir dokunuşu reddederse hata günlüğe düşer
    /// ve önbellekteki istemci bırakılır; bir sonraki dokunuş bağlantıyı
    /// yeniden kurar. Önceki boş blok düşen dokunuşları görünmez kılıyordu.
    /// Blok `queue` üzerinde çağrılır (tamamlama kuyruğu odur), istemci
    /// sözlüğüne erişim o yüzden güvenlidir.
    /// Yalnız hatayı veren istemci bırakılır: geç gelen hata, arada yeniden
    /// kurulmuş taze istemciyi silmez.
    private func deliveryCompletion(udid: String, client: AnyObject) -> @convention(block) (NSError?) -> Void {
        { [weak self, weak client] error in
            guard let error else {
                return
            }
            AppLog.panels.error(
                "Simulator touch delivery failed: \(error.localizedDescription, privacy: .public)"
            )
            guard let self, let client, self.clients[udid] === client else {
                return
            }
            self.clients.removeValue(forKey: udid)
        }
    }

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
    ///
    /// Tutma süresi kuyruğu bloklamaz: `down` sonrası `up` 45 ms gecikmeyle
    /// aynı kuyruğa zamanlanır, arada gelen başka cihaz olayları işler.
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
            queue.asyncAfter(deadline: .now() + 0.045) { [self] in
                let up = sendTouch(udid: udid, xRatio: xRatio, yRatio: yRatio, down: false)
                DispatchQueue.main.async { completion(up) }
            }
        }
    }

    /// Sürükleme taşıma olayı: yüksek frekanslı `pressMoveTo` akışında kuyruk
    /// şişmesin diye cihaz başına birleştirilir. Gönderim sürerken gelen
    /// taşıma kuyruğa dizilmez, yalnız o cihazın en yenisi bekler; tur
    /// bitince o koşar. Her çağıranın tamamlanması tur sonunda son sonuçla
    /// çağrılır. Parmak basılı kaldığı için taşıma her zaman `down`
    /// gönderir (`touch` ile aynı). `touch`/`tap`/`release` her zaman
    /// birebir koşar, buradan geçmez.
    func move(
        udid: String,
        xRatio: Double,
        yRatio: Double,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        queue.async { [self] in
            if moveInFlight {
                pendingMoves[udid] = (x: xRatio, y: yRatio)
                pendingMoveCompletions.append(completion)
                return
            }
            moveInFlight = true
            var current: (udid: String, x: Double, y: Double)? = (udid: udid, x: xRatio, y: yRatio)
            var waiting: [(Result<Void, Error>) -> Void] = [completion]
            var lastResult: Result<Void, Error> = .success(())
            while let job = current {
                lastResult = sendTouch(udid: job.udid, xRatio: job.x, yRatio: job.y, down: true)
                if let next = pendingMoves.removeValue(forKey: job.udid) {
                    current = (udid: job.udid, x: next.x, y: next.y)
                } else if let otherKey = pendingMoves.keys.first, let other = pendingMoves.removeValue(forKey: otherKey) {
                    current = (udid: otherKey, x: other.x, y: other.y)
                } else {
                    current = nil
                }
            }
            moveInFlight = false
            waiting.append(contentsOf: pendingMoveCompletions)
            pendingMoveCompletions.removeAll()
            let result = lastResult
            let callbacks = waiting
            DispatchQueue.main.async {
                for callback in callbacks {
                    callback(result)
                }
            }
        }
    }

    /// Cihaz kapanınca ya da seçim değişince istemciyi bırakır.
    func detach(udid: String) {
        queue.async { [self] in
            clients.removeValue(forKey: udid)
            failedAttachments.removeFailure(udid: udid)
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
                CGSize(width: 1, height: 1),
                0
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
                    deliveryCompletion(udid: udid, client: resolvedClient)
                )
                return .success(())
            }
        }

        // 2) Class method dene (bazı SDK sürümlerinde class method olmuş)
        let clientClass: AnyClass? = object_getClass(resolvedClient)
        if let cls = clientClass, cls.responds(to: selector) {
            // Class method IMP'sini al ve class objesiyle çağır
            if let method = class_getClassMethod(cls, selector),
                Self.isSendMessageSignatureValid(method)
            {
                let imp = unsafeBitCast(method_getImplementation(method), to: ClientSendFunction.self)
                imp(
                    cls,
                    selector,
                    message,
                    true,
                    queue,
                    deliveryCompletion(udid: udid, client: resolvedClient)
                )
                return .success(())
            }
        }

        // Hiçbiri yok: bu cihaz için HID devre dışı, bir sonraki dokunuşta
        // yeniden denenir (attachClient tekrar çalışır).
        free(message)
        clients.removeValue(forKey: udid)
        failedAttachments.recordFailure(
            udid: udid,
            detail: "sendWithMessage: unavailable (instance & class)",
            at: Date()
        )
        return .failure(BridgeError.clientUnavailable(detail: "sendWithMessage: unavailable on this SimulatorKit version"))
    }

    private func sendFunction(on client: AnyObject) -> ClientSendFunction? {
        let selector = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
        guard let method = class_getInstanceMethod(type(of: client), selector) else {
            return nil
        }
        // İmza doğrulaması: `unsafeBitCast` ile çağrılan IMP'nin aritesi
        // ve parametre türleri tutmazsa süreç `EXC_BAD_ACCESS` ile ölür ve
        // Swift'te ObjC istisnası yakalanamaz. Beklenen şekil
        // `self + _cmd + 4 parametre` (gösterge, bayrak, kuyruk, blok) ve
        // `void` dönüşüdür; uymayan sürümde dokunuş graceful-disable olur.
        guard Self.isSendMessageSignatureValid(method) else {
            return nil
        }
        return unsafeBitCast(method_getImplementation(method), to: ClientSendFunction.self)
    }

    /// `sendWithMessage:freeWhenDone:completionQueue:completion:` imzasının
    /// beklenen şekilde olduğunu doğrular: arite yetmez, çünkü ObjC
    /// istisnası Swift'te yakalanamaz ve `unsafeBitCast` ile çağrılan
    /// uymayan IMP süreci `EXC_BAD_ACCESS` ile öldürür. Bu yüzden dönüş
    /// (`void`) ve her parametrenin tür kodu da denetlenir: ileti göstergesi,
    /// bayrak (`B`, eski çalışmalarda `c`), kuyruk nesnesi, tamamlama bloğu.
    /// Uymayan sürümde dokunuş graceful-disable olur, süreç yaşamaz sorunu
    /// yaşamaz.
    static func isSendMessageSignatureValid(_ method: Method) -> Bool {
        // self, _cmd + message, freeWhenDone, completionQueue, completion.
        guard method_getNumberOfArguments(method) == 6 else {
            return false
        }
        guard returnType(of: method) == "v" else {
            return false
        }
        guard let message = argumentType(of: method, at: 2), message.hasPrefix("^") else {
            return false
        }
        guard let flag = argumentType(of: method, at: 3), flag == "B" || flag == "c" else {
            return false
        }
        guard let queue = argumentType(of: method, at: 4), queue.hasPrefix("@") else {
            return false
        }
        guard let completion = argumentType(of: method, at: 5), completion.hasPrefix("@") else {
            return false
        }
        return true
    }

    /// `initWithDevice:error:` imzasını doğrular: (self, _cmd, cihaz
    /// nesnesi, hata-çıkış göstergesi) → nesne. Gönderim yolundakiyle aynı
    /// gerekçe: doğrulamasız `unsafeBitCast` süreci öldürür.
    static func isInitWithDeviceSignatureValid(_ method: Method) -> Bool {
        guard method_getNumberOfArguments(method) == 4 else {
            return false
        }
        // Nesne dönüş `@"SınıfAdı"` diye kodlanabilir; önek yeterlidir.
        guard returnType(of: method).hasPrefix("@") else {
            return false
        }
        guard let device = argumentType(of: method, at: 2), device.hasPrefix("@") else {
            return false
        }
        guard let errorOut = argumentType(of: method, at: 3), errorOut.hasPrefix("^") else {
            return false
        }
        return true
    }

    /// Yöntemin dönüş tür kodunu okur.
    private static func returnType(of method: Method) -> String {
        var code = [CChar](repeating: 0, count: 32)
        method_getReturnType(method, &code, code.count)
        return code.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                return ""
            }
            return String(cString: base)
        }
    }

    /// Yöntemin verilen sıradaki parametresinin tür kodunu okur; sınıf adı
    /// eki (`@"NSString"`) ve blok işareti (`@?`) olduğu gibi taşınır,
    /// çağıran önekle karşılaştırır.
    private static func argumentType(of method: Method, at index: UInt32) -> String? {
        guard let raw = method_copyArgumentType(method, index) else {
            return nil
        }
        defer { free(UnsafeMutableRawPointer(raw)) }
        return String(cString: raw)
    }

    // MARK: - İstemci kurulumu

    private func client(for udid: String) -> Result<AnyObject, Error> {
        if let existing = clients[udid] {
            return .success(existing)
        }
        // Taze kayıt varken kurulum denenmez; 30 sn dolmuşsa kayıt yok
        // sayılır ve kurulum yeniden denenir.
        if let failure = failedAttachments.failure(forUDID: udid, now: Date()) {
            return .failure(BridgeError.clientUnavailable(detail: failure))
        }
        do {
            let created = try attachClient(udid: udid)
            clients[udid] = created
            failedAttachments.removeFailure(udid: udid)
            return .success(created)
        } catch {
            failedAttachments.recordFailure(udid: udid, detail: error.localizedDescription, at: Date())
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
        // Kurulum IMP'si de bitcast ile çağrılır; imza uymazsa süreç ölür.
        // Gönderim yoluyla aynı kural burada da uygulanır.
        guard Self.isInitWithDeviceSignatureValid(method) else {
            throw BridgeError.clientUnavailable(
                detail: "initWithDevice:error: has an unexpected signature on this SimulatorKit version"
            )
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

        let handle: UnsafeMutableRawPointer
        do {
            handle = try SimulatorPrivateFrameworks.loadSimulatorKit()
        } catch let error as SimulatorPrivateFrameworks.FrameworkError {
            throw BridgeError.frameworksUnavailable(detail: error.detail)
        }

        guard
            let symbol = dlsym(handle, "IndigoHIDMessageForMouseNSEvent")
        else {
            throw BridgeError.frameworksUnavailable(detail: "IndigoHIDMessageForMouseNSEvent is missing")
        }
        // Sembolün gerçekten SimulatorKit görüntüsünden geldiği doğrulanır:
        // araya giren (interpose) ya da yanlış çerçeveden gelen aynı adlı
        // sembol, 6-arg çağrı düzenini bozup tanımsız davranışa yol açardı.
        var info = Dl_info(dli_fname: nil, dli_fbase: nil, dli_sname: nil, dli_saddr: nil)
        let imagePath: String
        if dladdr(symbol, &info) != 0, let fname = info.dli_fname {
            imagePath = String(cString: fname)
        } else {
            imagePath = ""
        }
        guard imagePath.contains("SimulatorKit") else {
            throw BridgeError.frameworksUnavailable(
                detail: "IndigoHIDMessageForMouseNSEvent resolved outside SimulatorKit (\(imagePath))"
            )
        }
        simulatorKitHandle = handle
        mouseMessageFunction = unsafeBitCast(symbol, to: MouseMessageFunction.self)
    }

    /// CoreSimulator'ın servis bağlamından cihazı UDID ile bulur (ortak yükleyici).
    private func resolveDevice(udid: String) throws -> AnyObject? {
        do {
            return try SimulatorPrivateFrameworks.resolveDevice(udid: udid)
        } catch let error as SimulatorPrivateFrameworks.FrameworkError {
            throw BridgeError.frameworksUnavailable(detail: error.detail)
        }
    }

    private func isBooted(device: AnyObject) -> Bool {
        guard let handle = device as? NSObject else {
            return false
        }
        return SimulatorPrivateFrameworks.isBooted(device: handle)
    }

    /// Oranı 0..1 aralığına kırpar; NaN ve sonsuz sıfıra düşer.
    private func clampedRatio(_ value: Double) -> Double {
        guard value.isFinite else {
            return 0
        }
        return min(1, max(0, value))
    }
}
