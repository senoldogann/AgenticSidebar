import Foundation
import XCTest

@testable import AgenticSidebar

/// Bildirim gövdesi: önizleme açıksa ilk 160 karakter taşınır, kapalıysa veya
/// alıntı yoksa genel metin kullanılır. Alıntı Bildirim Merkezi'nde (kilit
/// ekranı dahil) kalıcı durduğu için hassas oturumlar kapatılabilmelidir.
final class SessionNotificationBodyTests: XCTestCase {
    func testPreviewIsIncludedWhenEnabled() {
        XCTAssertEqual(
            SessionNotificationService.body(
                previewText: "yanıt metni",
                sessionTitle: "Oturum",
                includePreview: true
            ),
            "yanıt metni"
        )
    }

    func testPreviewIsTruncatedTo160Characters() {
        let long = String(repeating: "x", count: 200)
        let body = SessionNotificationService.body(
            previewText: long,
            sessionTitle: "Oturum",
            includePreview: true
        )
        XCTAssertEqual(body.count, 160)
    }

    func testDisabledPreviewFallsBackToGenericText() {
        XCTAssertEqual(
            SessionNotificationService.body(
                previewText: "gizli yanıt",
                sessionTitle: "Oturum",
                includePreview: false
            ),
            "Agent finished working on Oturum."
        )
    }

    func testMissingPreviewFallsBackToGenericText() {
        XCTAssertEqual(
            SessionNotificationService.body(
                previewText: nil,
                sessionTitle: "Oturum",
                includePreview: true
            ),
            "Agent finished working on Oturum."
        )
        XCTAssertEqual(
            SessionNotificationService.body(
                previewText: "",
                sessionTitle: "Oturum",
                includePreview: true
            ),
            "Agent finished working on Oturum."
        )
    }
}
