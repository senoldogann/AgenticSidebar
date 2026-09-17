import XCTest
@testable import AgenticSidebar

/// Sesle yazma Faz 0: kısmi sonuç birleştirme kuralları.
///
/// Çıta: kısmi sonuçlar artımlı eklenmez (tanıma revizyon gönderir), taban
/// taslak korunur, boşluklar teklenir. Donanım tarafı (`AVAudioEngine`,
/// `SFSpeechRecognizer`) bu kapsamda test edilmez.
final class SpeechDictationTests: XCTestCase {
    func testEmptyBaseTakesPartialAsIs() {
        var merger = DictationSegmentMerger()

        XCTAssertEqual(merger.merged(with: "  merhaba  "), "merhaba")
        XCTAssertEqual(merger.current, "merhaba")
    }

    func testPartialRevisesRatherThanAppends() {
        var merger = DictationSegmentMerger()

        merger.merged(with: "merhaba dün")
        XCTAssertEqual(merger.merged(with: "merhaba dünya"), "merhaba dünya")
    }

    func testBaseDraftIsPreservedWithSingleSpace() {
        var merger = DictationSegmentMerger(baseText: "Taslak metin  ")

        XCTAssertEqual(merger.merged(with: "  ek cümle"), "Taslak metin ek cümle")
    }

    func testEmptyPartialKeepsBase() {
        var merger = DictationSegmentMerger(baseText: "Taslak")

        XCTAssertEqual(merger.merged(with: "   "), "Taslak")
    }

    func testBothEmptyStaysEmpty() {
        var merger = DictationSegmentMerger()

        XCTAssertEqual(merger.merged(with: ""), "")
    }
}
