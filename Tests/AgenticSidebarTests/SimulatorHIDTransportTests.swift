import Foundation
import XCTest

@testable import AgenticSidebar

/// HID taşıma seçimi, sürüm ayrıştırma, süreli hata önbelleği ve Xcode
/// sürüm okuma testleri. Seçim saf dizge mantığıdır; çerçeve yüklenmez,
/// bu yüzden bütün durumlar gerçek simülatörsüz doğrulanır.
final class SimulatorHIDTransportTests: XCTestCase {
    /// Xcode 26 dokunuşu eski Indigo fare hattından gönderir.
    func testLegacySelectedOnXcode26() {
        let result = SimulatorHIDTransportSelector.select(
            xcodeVersion: "26.2",
            runtimeName: "iOS 26.5"
        )

        XCTAssertEqual(try? result.get(), .legacyIndigoMouse)
    }

    /// Xcode 27 sayısallaştırıcı hattını seçer.
    func testDigitizerSelectedOnXcode27() {
        let result = SimulatorHIDTransportSelector.select(
            xcodeVersion: "27.0",
            runtimeName: "iOS 27.0"
        )

        XCTAssertEqual(try? result.get(), .trackpadDigitizer)
    }

    /// Bilinmeyen sürüm güvenli varsayılan olan eski hatta düşer.
    func testUnknownVersionFallsBackToLegacy() {
        for version in ["", "beta", "  "] {
            let result = SimulatorHIDTransportSelector.select(
                xcodeVersion: version,
                runtimeName: "iOS 26.5"
            )
            XCTAssertEqual(try? result.get(), .legacyIndigoMouse, "sürüm: \(version)")
        }
    }

    /// tvOS her Xcode sürümünde yüksek sesle reddedilir.
    func testTVOSRejectedLoudlyOnEveryXcode() {
        for version in ["26.2", "27.0", ""] {
            let result = SimulatorHIDTransportSelector.select(
                xcodeVersion: version,
                runtimeName: "tvOS 26.5"
            )
            guard case .failure(let diagnostic) = result else {
                return XCTFail("tvOS reddedilmedi, sürüm: \(version)")
            }
            XCTAssertEqual(
                diagnostic,
                .tvOSTouchUnsupported(runtimeName: "tvOS 26.5")
            )
            XCTAssertTrue(diagnostic.errorDescription?.contains("tvOS") == true)
        }
    }

    /// tvOS tanılama hem görünen adı hem ham kimliği yakalar.
    func testTVOSDetectionForms() {
        XCTAssertTrue(SimulatorHIDTransportSelector.isTVOSRuntime("tvOS 26.5"))
        XCTAssertTrue(SimulatorHIDTransportSelector.isTVOSRuntime("TVOS 27.0"))
        XCTAssertTrue(
            SimulatorHIDTransportSelector.isTVOSRuntime(
                "com.apple.CoreSimulator.SimRuntime.tvOS-26-5"
            )
        )
        XCTAssertFalse(SimulatorHIDTransportSelector.isTVOSRuntime("iOS 26.5"))
        XCTAssertFalse(SimulatorHIDTransportSelector.isTVOSRuntime("watchOS 26.5"))
        XCTAssertFalse(SimulatorHIDTransportSelector.isTVOSRuntime(nil))
        XCTAssertFalse(SimulatorHIDTransportSelector.isTVOSRuntime(""))
    }

    /// Ana sürüm ayrıştırma: noktalı, önekli ve eski numaralandırma.
    func testMajorVersionParsing() {
        XCTAssertEqual(SimulatorHIDTransportSelector.xcodeMajorVersion("26.2"), 26)
        XCTAssertEqual(SimulatorHIDTransportSelector.xcodeMajorVersion("Xcode 26.1"), 26)
        XCTAssertEqual(SimulatorHIDTransportSelector.xcodeMajorVersion("16.4"), 16)
        XCTAssertEqual(SimulatorHIDTransportSelector.xcodeMajorVersion("27.0"), 27)
        XCTAssertNil(SimulatorHIDTransportSelector.xcodeMajorVersion(""))
        XCTAssertNil(SimulatorHIDTransportSelector.xcodeMajorVersion("beta"))
    }

    /// Klavye baskısı yalnız Xcode 27+ sürümünde beklenir.
    func testKeyboardSuppressionExpectedOnlyOn27() {
        XCTAssertTrue(
            SimulatorHIDTransportSelector.isKeyboardSuppressionExpected(xcodeVersion: "27.0")
        )
        XCTAssertTrue(
            SimulatorHIDTransportSelector.isKeyboardSuppressionExpected(xcodeVersion: "28.1")
        )
        XCTAssertFalse(
            SimulatorHIDTransportSelector.isKeyboardSuppressionExpected(xcodeVersion: "26.2")
        )
        XCTAssertFalse(
            SimulatorHIDTransportSelector.isKeyboardSuppressionExpected(xcodeVersion: "")
        )
    }

    /// Baskı yardımcısı 27'de tanı üretir, 26'da `nil` döner.
    func testKeyboardErrorHelper() {
        let suppressed = SimulatorHIDTransportSelector.keyboardErrorIfSuppressed(
            xcodeVersion: "27.0",
            detail: "dtuhidd etkin"
        )
        XCTAssertEqual(suppressed, .keyboardSuppressedByDTUHID(detail: "dtuhidd etkin"))

        XCTAssertNil(
            SimulatorHIDTransportSelector.keyboardErrorIfSuppressed(
                xcodeVersion: "26.2",
                detail: "dtuhidd etkin"
            )
        )
    }

    /// Taze kayıt kurulumu engeller, 30 sn dolunca yeniden denemeye açar.
    func testFailureCacheThrottlesThenRetries() {
        var cache = SimulatorHIDFailureCache()
        let failedAt = Date(timeIntervalSince1970: 1_000_000)

        cache.recordFailure(udid: "AAAA", detail: "kurulum düştü", at: failedAt)

        XCTAssertEqual(
            cache.failure(forUDID: "AAAA", now: failedAt.addingTimeInterval(10)),
            "kurulum düştü"
        )
        // Sınır dahili: tam 30. saniyede hâlâ kısıtlı.
        XCTAssertEqual(
            cache.failure(forUDID: "AAAA", now: failedAt.addingTimeInterval(30)),
            "kurulum düştü"
        )
        // 30 sn aşılınca kayıt yok sayılır, kurulum yeniden denenir.
        XCTAssertNil(cache.failure(forUDID: "AAAA", now: failedAt.addingTimeInterval(31)))
    }

    /// Bilinmeyen cihaz ve silinmiş kayıt kurulumu engellemez.
    func testFailureCacheMissAndRemove() {
        var cache = SimulatorHIDFailureCache()
        let now = Date(timeIntervalSince1970: 2_000_000)

        XCTAssertNil(cache.failure(forUDID: "YOK", now: now))

        cache.recordFailure(udid: "BBBB", detail: "hata", at: now)
        cache.removeFailure(udid: "BBBB")

        XCTAssertNil(cache.failure(forUDID: "BBBB", now: now))
    }

    /// Yeniden deneme eşiği: 30 sn ve altı kısıtlı, üstü serbest.
    func testRetryThreshold() {
        let failedAt = Date(timeIntervalSince1970: 3_000_000)

        XCTAssertFalse(
            SimulatorHIDFailureCache.shouldRetry(
                failedAt: failedAt,
                now: failedAt.addingTimeInterval(30)
            )
        )
        XCTAssertTrue(
            SimulatorHIDFailureCache.shouldRetry(
                failedAt: failedAt,
                now: failedAt.addingTimeInterval(30.001)
            )
        )
    }

    /// Yeniden deneme aralığı şeritte kararlaştırılan 30 saniyedir.
    func testRetryIntervalIsThirtySeconds() {
        XCTAssertEqual(SimulatorHIDFailureCache.retryInterval, 30)
    }

    /// Xcode sürümü `version.plist` dosyasından okunur; süreç yok.
    func testXcodeVersionReadsPlist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hid-transport-\(UUID().uuidString)")
        let plistURL = root.appendingPathComponent("version.plist")
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleShortVersionString</key>
                <string>26.2</string>
            </dict>
            </plist>
            """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        // `developerDirectory` karşılığı `…/Developer` dizinidir; sürüm
        // dosyası onun bir üstündedir.
        let developerDirectory = root.appendingPathComponent("Developer").path

        XCTAssertEqual(
            SimulatorHIDTransportSelector.xcodeVersion(developerDirectory: developerDirectory),
            "26.2"
        )
    }

    /// Dosya yoksa sürüm `nil` döner, seçim eski hatta düşer.
    func testXcodeVersionMissingPlistYieldsNil() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("hid-yok-\(UUID().uuidString)")
            .appendingPathComponent("Developer").path

        XCTAssertNil(
            SimulatorHIDTransportSelector.xcodeVersion(developerDirectory: missing)
        )
    }
}

// MARK: - IMP imza doğrulayıcılar

/// Doğrulayıcıların gerçek ObjC çalışmasıyla sınanması için prob sınıfı:
/// `make` kurulum-imzasını (nesne, gösterge → nesne),
/// `send` gönderim-imzasını (gösterge, bayrak, kuyruk, blok → void) taşır.
private final class SignatureProbe: NSObject {
    @objc func make(device: AnyObject, error: NSErrorPointer) -> AnyObject? {
        device
    }

    @objc func send(
        message: UnsafeMutableRawPointer?,
        free: Bool,
        queue: NSObject,
        completion: @escaping (NSError?) -> Void
    ) {
        completion(nil)
    }
}

extension SimulatorHIDTransportTests {
    /// Kurulum doğrulayıcı tam şekli kabul eder, gönderim şeklini reddeder.
    func testInitSignatureAcceptsExactShape() {
        let selector = NSSelectorFromString("makeWithDevice:error:")
        guard let method = class_getInstanceMethod(SignatureProbe.self, selector) else {
            return XCTFail("prob kurulum yöntemi bulunamadı")
        }
        XCTAssertTrue(SimulatorHIDBridge.isInitWithDeviceSignatureValid(method))
        XCTAssertFalse(SimulatorHIDBridge.isSendMessageSignatureValid(method))
    }

    /// Gönderim doğrulayıcı tam şekli kabul eder, kurulum şeklini reddeder.
    func testSendSignatureAcceptsExactShape() {
        let selector = NSSelectorFromString("sendWithMessage:free:queue:completion:")
        guard let method = class_getInstanceMethod(SignatureProbe.self, selector) else {
            return XCTFail("prob gönderim yöntemi bulunamadı")
        }
        XCTAssertTrue(SimulatorHIDBridge.isSendMessageSignatureValid(method))
        XCTAssertFalse(SimulatorHIDBridge.isInitWithDeviceSignatureValid(method))
    }

    /// Yabancı şekiller (yanlış arite) iki doğrulayıcıdan da geçemez.
    func testValidatorsRejectForeignShapes() {
        let selector = NSSelectorFromString("description")
        guard let method = class_getInstanceMethod(NSObject.self, selector) else {
            return XCTFail("description yöntemi bulunamadı")
        }
        XCTAssertFalse(SimulatorHIDBridge.isInitWithDeviceSignatureValid(method))
        XCTAssertFalse(SimulatorHIDBridge.isSendMessageSignatureValid(method))
    }
}
