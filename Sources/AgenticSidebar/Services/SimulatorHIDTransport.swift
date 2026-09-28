import Foundation

/// Simülatör HID taşıma seçimi, hatı önbelleği ve kullanıcı iletileri.
///
/// Seçim saf dizge mantığıdır: Xcode / çalışma zamanı sürüm yazıları
/// parametre olarak girer, sonuç parametre olarak çıkar. Seçim sırasında
/// çerçeve yüklenmez (`dlopen` yok), bu yüzden açılış başına güvenle
/// çağrılır. Gerçek gönderim `SimulatorHIDBridge`'de kalır.
///
/// Kaynak kararlar:
/// - facebook/idb `FBSimulatorIndigoHIDTransport`: gönderimler aktörle
///   serileşir, eski klavye baskılanınca sessizce yazmak yerine yüksek
///   sesle hata verilir (`keyboardSuppressedByActiveDTUHIDD`).
/// - facebook/idb `e1044d1`: tvOS'ta dokunma sessiz yutulurdu; Indigo
///   taşıması Apple TV hedeflerde dokunuşu açıkça reddeder.
/// - serve-sim `HIDInjector`: `IndigoHIDMessageForMouseNSEvent` gerçek
///   imzası `(CGPoint*, CGPoint?, hedef, tip, NSSize, kenar)` olup
///   `NSSize(1, 1)` ve kenar `0` ile çağrılır.
/// - baguette `IOHIDDigitizerDispatch`: izlek-sayısallaştırıcı yolu 384
///   baytlık ebeveyn+çocuk ileti düzeni kurar, basınç (`tipPressure`) 0
///   taşınır; `trackpadDigitizer` bu hattın adıdır.
enum SimulatorHIDTransportKind: String, Equatable, Sendable {
    /// Eski Indigo fare-olayı hattı (`SimDeviceLegacyHIDClient`).
    case legacyIndigoMouse
    /// İzlek sayısallaştırıcısı hattı (IOHID ebeveyn+çocuk düzeni).
    case trackpadDigitizer
}

/// Dokunma yolunun kullanıcıya gösterilen tanı dili.
///
/// Her durumun `userMessage` karşılığı çift dillidir (Türkçe + İngilizce)
/// ve işlem önerir; sessiz yutma yoktur. `noteTouchResult` akışı bütün
/// hataları bu dile indirger.
enum SimulatorHIDDiagnostic: LocalizedError, Equatable {
    /// Dokunulacak cihaz seçilmedi.
    case noDeviceSelected
    /// Seçili cihaz açık değil.
    case deviceNotBooted(name: String)
    /// tvOS hedefte dokunma yok: dokunmatik ekran yoktur.
    case tvOSTouchUnsupported(runtimeName: String)
    /// Eski klavye servisi `dtuhidd` etkinken baskılanır (Xcode 27+).
    case keyboardSuppressedByDTUHID(detail: String)

    var errorDescription: String? {
        userMessage
    }

    /// Ekranda ve tanıda gösterilen çift dilli işlem önerisi.
    var userMessage: String {
        switch self {
        case .noDeviceSelected:
            "Dokunulacak simülatör seçili değil. Listeden bir cihaz seçin. / No simulator is selected for touch. Pick a device from the list."
        case .deviceNotBooted(let name):
            "“\(name)” açık değil. Cihazı başlatıp yeniden dokunun. / “\(name)” is not booted. Boot the device, then touch again."
        case .tvOSTouchUnsupported(let runtimeName):
            "tvOS hedeflerde dokunma desteklenmez (dokunmatik ekran yok, \(runtimeName)). Odağı kumanda tuşlarıyla taşıyın. / Touch input is not supported on tvOS targets (no touchscreen, \(runtimeName)). Move focus with the remote buttons instead."
        case .keyboardSuppressedByDTUHID(let detail):
            "Eski klavye servisi dtuhidd tarafından baskılanmış (\(detail)). Ekrandaki yazılım klavyesini açın ya da DTUHID yolunu kullanın. / The legacy keyboard service is suppressed by dtuhidd (\(detail)). Open the on-screen software keyboard or use the DTUHID path."
        }
    }
}

/// Açılış başına taşıma seçen saf karar noktası.
///
/// Örnek üyesi yoktur; bütün girişler sürüm yazılarıdır, bu yüzden init
/// içinde `dlopen`/`Process` yan etkisi barındırmaz.
enum SimulatorHIDTransportSelector {
    /// Sayısallaştırıcı hattına geçilen Xcode ana sürümü: Xcode 27 ile
    /// gelen `dtuhidd` düzeni eski HID hattını değiştirdi (idb
    /// CoreSimulator-1155.4 notu, sim-use açılış-başı seçimi).
    nonisolated static let digitizerXcodeMajor = 27

    /// Xcode + çalışma zamanı yazılarına göre hattı seçer. tvOS her
    /// sürümde yüksek sesle reddedilir; bilinmeyen sürüm güvenli
    /// varsayılan olan eski hatta düşer.
    static func select(
        xcodeVersion: String,
        runtimeName: String?
    ) -> Result<SimulatorHIDTransportKind, SimulatorHIDDiagnostic> {
        if isTVOSRuntime(runtimeName) {
            return .failure(.tvOSTouchUnsupported(runtimeName: runtimeName ?? "-"))
        }
        guard let major = xcodeMajorVersion(xcodeVersion) else {
            return .success(.legacyIndigoMouse)
        }
        if major >= digitizerXcodeMajor {
            return .success(.trackpadDigitizer)
        }
        return .success(.legacyIndigoMouse)
    }

    /// Çalışma zamanı yazısının tvOS ailesinden olup olmadığı.
    /// `runtimeDisplayName` çıktısı (`tvOS 26.5`) ve ham kimlik
    /// (`…SimRuntime.tvOS-26-5`) ikisi de yakalanır.
    static func isTVOSRuntime(_ runtimeName: String?) -> Bool {
        guard let runtimeName, !runtimeName.isEmpty else {
            return false
        }
        return runtimeName.range(of: "tvos", options: .caseInsensitive) != nil
    }

    /// Sürüm yazısındaki ilk sayı öbeği: `26.2` → 26, `Xcode 26.1` → 26,
    /// `16.4` → 16. Sayı yoksa `nil`.
    static func xcodeMajorVersion(_ version: String) -> Int? {
        guard let digits = version.split(whereSeparator: { !$0.isNumber }).first else {
            return nil
        }
        return Int(digits)
    }

    /// Bu Xcode sürümünde eski klavye baskısı beklenir mi (Xcode 27+).
    /// Süreç ağacı gezilmez; yalnız sürüm eşiğine bakılır.
    static func isKeyboardSuppressionExpected(xcodeVersion: String) -> Bool {
        guard let major = xcodeMajorVersion(xcodeVersion) else {
            return false
        }
        return major >= digitizerXcodeMajor
    }

    /// Baskı bekleniyorsa yüksek sesli tanı hatası, değilse `nil`.
    static func keyboardErrorIfSuppressed(
        xcodeVersion: String,
        detail: String
    ) -> SimulatorHIDDiagnostic? {
        guard isKeyboardSuppressionExpected(xcodeVersion: xcodeVersion) else {
            return nil
        }
        return .keyboardSuppressedByDTUHID(detail: detail)
    }

    /// Geliştirici dizininin yanındaki `version.plist` okunur; süreç
    /// çalıştırılmaz, çerçeve yüklenmez. Dosya ya da anahtar yoksa `nil`.
    static func xcodeVersion(developerDirectory: String) -> String? {
        let plistURL = URL(fileURLWithPath: developerDirectory)
            .appendingPathComponent("../version.plist")
            .standardized
        guard
            let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let values = plist as? [String: Any],
            let version = values["CFBundleShortVersionString"] as? String,
            !version.isEmpty
        else {
            return nil
        }
        return version
    }

    /// Her hatayı çift dilli işlem önerisine indirger; bilinmeyen hata
    /// bile ayrıntısıyla taşınır, asla boş iletime düşmez.
    static func userMessage(for error: Error) -> String {
        if let diagnostic = error as? SimulatorHIDDiagnostic {
            return diagnostic.userMessage
        }
        if let bridgeError = error as? SimulatorHIDBridge.BridgeError {
            return userMessage(forBridgeError: bridgeError)
        }
        let detail = error.localizedDescription
        return "Dokunma gönderilemedi: \(detail). Yeniden deneyin; sürerse simülatörü yeniden başlatın. "
            + "/ Touch could not be sent: \(detail). Retry; reboot the simulator if it persists."
    }

    /// Köprü hatalarının çift dilli karşılıkları.
    private static func userMessage(forBridgeError error: SimulatorHIDBridge.BridgeError) -> String {
        switch error {
        case .deviceNotFound(let udid):
            "Simülatör cihazı bulunamadı (\(udid)). Listeyi yenileyip cihazı yeniden seçin. / No simulator device matches \(udid). Refresh the list and reselect the device."
        case .deviceNotBooted(let udid):
            "Simülatör cihazı açık değil (\(udid)). Cihazı başlatıp yeniden deneyin. / Simulator device \(udid) is not booted. Boot the device and retry."
        case .frameworksUnavailable(let detail):
            "Simülatör giriş çerçeveleri yüklenemedi (\(detail)). Xcode kurulu mu, xcode-select doğru mu denetleyin. / Simulator input frameworks could not be loaded (\(detail)). Check that Xcode is installed and xcode-select points at it."
        case .clientUnavailable(let detail):
            "Simülatör giriş istemcisi kurulamadı (\(detail)). Simülatörü yeniden başlatıp dokunmayı tekrar deneyin. / Simulator input client could not be created (\(detail)). Reboot the simulator and retry the touch."
        case .sendFailed(let detail):
            "Dokunma olayı gönderilemedi (\(detail)). Yeniden deneyin; sürerse simülatörü yeniden başlatın. / The touch event could not be sent (\(detail)). Retry; reboot the simulator if it persists."
        }
    }
}

/// Başarısız HID kurulumlarının süreli önbelleği.
///
/// Sonsuz kara liste yerine 30 saniyelik nefes payı verir: hata anı
/// saklanır, 30 saniye dolmadan aynı cihaza yeniden kurulum denenmez,
/// süre dolunca sessizce değil yeniden denemeyle dönülür. Köprünün seri
/// kuyruğu dışarıdan korunur; bu yapı yalnız kayıt tutar.
struct SimulatorHIDFailureCache: Sendable {
    /// Tek cihazın başarısızlık kaydı.
    struct Entry: Equatable, Sendable {
        /// Kullanıcıya gösterilen ayrıntı.
        let detail: String
        /// Başarısızlığın görüldüğü an.
        let failedAt: Date
    }

    /// Yeniden deneme aralığı: 30 saniyeyi aşan kayıt eskir.
    nonisolated static let retryInterval: TimeInterval = 30

    private var entries: [String: Entry] = [:]

    /// Kayıt taze ise ayrıntıyı döner (yeniden deneme); eskimiş ya da
    /// yoksa `nil` döner (kurulum denenir).
    func failure(forUDID udid: String, now: Date) -> String? {
        guard let entry = entries[udid] else {
            return nil
        }
        guard !Self.shouldRetry(failedAt: entry.failedAt, now: now) else {
            return nil
        }
        return entry.detail
    }

    /// Başarısızlığı anıyla birlikte yazar.
    mutating func recordFailure(udid: String, detail: String, at date: Date) {
        entries[udid] = Entry(detail: detail, failedAt: date)
    }

    /// Kaydı siler: cihaz kapanınca ya da seçim değişince çağrılır.
    mutating func removeFailure(udid: String) {
        entries.removeValue(forKey: udid)
    }

    /// 30 saniyeden eski kayıt yeniden denemeye açılır.
    static func shouldRetry(failedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(failedAt) > retryInterval
    }
}
