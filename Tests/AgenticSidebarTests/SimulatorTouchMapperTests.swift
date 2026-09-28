import CoreGraphics
import XCTest

@testable import AgenticSidebar

final class SimulatorTouchMapperTests: XCTestCase {
    func testCenterMapsToHalf() {
        let point = SimulatorTouchMapper.normalized(
            location: CGPoint(x: 50, y: 100),
            in: CGSize(width: 100, height: 200)
        )

        XCTAssertEqual(point.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.5, accuracy: 0.0001)
    }

    func testOutsideIsClamped() {
        let point = SimulatorTouchMapper.normalized(
            location: CGPoint(x: -10, y: 250),
            in: CGSize(width: 100, height: 200)
        )

        XCTAssertEqual(point.x, 0, accuracy: 0.0001)
        XCTAssertEqual(point.y, 1, accuracy: 0.0001)
    }

    func testDegenerateSizeFallsToZero() {
        let empty = SimulatorTouchMapper.normalized(
            location: CGPoint(x: 10, y: 10),
            in: .zero
        )

        XCTAssertEqual(empty.x, 0, accuracy: 0.0001)
        XCTAssertEqual(empty.y, 0, accuracy: 0.0001)
    }

    func testNonFiniteLocationFallsToZero() {
        let point = SimulatorTouchMapper.normalized(
            location: CGPoint(x: CGFloat.nan, y: 10),
            in: CGSize(width: 100, height: 200)
        )

        XCTAssertEqual(point.x, 0, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.05, accuracy: 0.0001)
    }

    /// Bütün tanı durumları Türkçe + İngilizce tek iletide taşınır.
    func testDiagnosticsAreBilingual() {
        let cases: [SimulatorHIDDiagnostic] = [
            .noDeviceSelected,
            .deviceNotBooted(name: "iPhone 17 Pro"),
            .tvOSTouchUnsupported(runtimeName: "tvOS 26.5"),
            .keyboardSuppressedByDTUHID(detail: "dtuhidd etkin"),
        ]

        for diagnostic in cases {
            let message = SimulatorHIDTransportSelector.userMessage(for: diagnostic)
            XCTAssertFalse(message.isEmpty, "\(diagnostic)")
            XCTAssertTrue(message.contains(" / "), "çift dil ayracı yok: \(diagnostic)")
        }
    }

    /// tvOS reddi hedefi ve kumanda önerisini adlandırır.
    func testTVOSMessageNamesTargetAndRemote() {
        let message = SimulatorHIDTransportSelector.userMessage(
            for: SimulatorHIDDiagnostic.tvOSTouchUnsupported(runtimeName: "tvOS 26.5")
        )

        XCTAssertTrue(message.contains("tvOS"))
        XCTAssertTrue(message.contains("kumanda") || message.contains("remote"))
    }

    /// Açık olmayan cihaz iletisi cihaz adını ve başlatma önerisini taşır.
    func testNotBootedMessageNamesDevice() {
        let message = SimulatorHIDTransportSelector.userMessage(
            for: SimulatorHIDDiagnostic.deviceNotBooted(name: "iPhone 16")
        )

        XCTAssertTrue(message.contains("iPhone 16"))
    }

    /// Köprü hataları kimliği korur ve işlem önerir.
    func testBridgeErrorsStayActionable() {
        let cases: [SimulatorHIDBridge.BridgeError] = [
            .deviceNotFound(udid: "AAAA"),
            .deviceNotBooted(udid: "AAAA"),
            .frameworksUnavailable(detail: "SimulatorKit yok"),
            .clientUnavailable(detail: "istemci yok"),
            .sendFailed(detail: "ileti yok"),
        ]

        for error in cases {
            let message = SimulatorHIDTransportSelector.userMessage(for: error)
            XCTAssertTrue(message.contains(" / "), "\(error)")
            XCTAssertTrue(
                message.contains("yeniden") || message.contains("denetleyin") || message.contains("seç"),
                "işlem önerisi yok: \(error)"
            )
        }
    }

    /// Bilinmeyen hata bile ayrıntısıyla taşınır, asla boş dönülmez.
    func testUnknownErrorKeepsDetail() {
        struct OrnekHata: LocalizedError {
            var errorDescription: String? { "örnek arıza" }
        }

        let message = SimulatorHIDTransportSelector.userMessage(for: OrnekHata())

        XCTAssertTrue(message.contains("örnek arıza"))
        XCTAssertTrue(message.contains(" / "))
    }
}
