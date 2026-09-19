import Foundation
import XCTest

@testable import AgenticSidebar

/// Sesle yazma Faz 0: kısmi sonuç birleştirme kuralları + tanıma sonucu
/// yönlendirmesi.
///
/// Çıta: kısmi sonuçlar artımlı eklenmez (tanıma revizyon gönderir), taban
/// taslak korunur, boşluklar teklenir. Donanım tarafı (`AVAudioEngine`,
/// `SFSpeechRecognizer`) bu kapsamda çalıştırılmaz; çerçeve kuyruğundan
/// gelen sonucun nesil kapısı ve bitiş akışı `handleRecognitionResult`
/// üzerinden doğrudan test edilir.
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

    /// Tanıma penceresi sıfırlanırsa (yeni cümle) önceki cümle korunur:
    /// konuşulan bölümün besteciden silinmesi veri kaybıydı.
    func testResetPartialAppendsInsteadOfDeleting() {
        var merger = DictationSegmentMerger()

        merger.merged(with: "ilk cümle bitti")
        XCTAssertEqual(
            merger.merged(with: "ikinci cümle başladı"),
            "ilk cümle bitti ikinci cümle başladı"
        )
    }

    /// Yeni cümle önceki metnin önekiyle başlasa bile silinmez.
    func testResetWithSharedOpeningWordDoesNotDelete() {
        var merger = DictationSegmentMerger()

        merger.merged(with: "bugün hava güzel")
        XCTAssertEqual(
            merger.merged(with: "bugün"),
            "bugün hava güzel bugün"
        )
    }

    /// Aynı cümlenin ortadan düzeltmesi yerine konur, eklenmez.
    func testMidSentenceCorrectionRevises() {
        var merger = DictationSegmentMerger()

        merger.merged(with: "merhaba dün")
        XCTAssertEqual(merger.merged(with: "merhaba gün"), "merhaba gün")
    }

    /// Büyük harf ve noktalama revizyonu yeni cümle değildir, ikilemez.
    func testCapitalizationRevisionDoesNotDuplicate() {
        var merger = DictationSegmentMerger()

        merger.merged(with: "hava güzel")
        XCTAssertEqual(merger.merged(with: "Hava güzel."), "Hava güzel.")
    }

    /// Taban taslak, sıfırlanan cümlelerle de korunur.
    func testBaseDraftSurvivesResetPartials() {
        var merger = DictationSegmentMerger(baseText: "Not: ")

        merger.merged(with: "ilk cümle")
        XCTAssertEqual(
            merger.merged(with: "ikinci cümle"),
            "Not: ilk cümle ikinci cümle"
        )
    }

    func testSessionGuardKeepsPartialsInStartingSession() {
        let started = UUID()

        XCTAssertTrue(
            DictationSessionGuard.shouldApplyPartial(
                startedSessionID: started,
                currentSessionID: started
            ))
        XCTAssertFalse(
            DictationSessionGuard.shouldApplyPartial(
                startedSessionID: started,
                currentSessionID: UUID()
            ))
    }

    /// Stopping an unused service must never initialize the microphone input.
    /// CoreAudio can block indefinitely while binding an unavailable device.
    @MainActor
    func testStoppingWithoutStartingDoesNotInitializeMicrophoneInput() {
        let service = SpeechDictationService(recognizer: nil)
        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(service.stop(), "")
        XCTAssertFalse(service.isRecording)
    }

    /// Güncel neslin sonucu kısmi metni iletir, bitiş bayrağı göstergi
    /// kapatmayı tetikler ve geri çağrılar temizlenir.
    @MainActor
    func testRecognitionResultDeliversPartialThenEnds() {
        let service = SpeechDictationService(recognizer: nil)
        var partials: [String] = []
        var endedCount = 0
        service.partialHandler = { partials.append($0) }
        service.endedHandler = { endedCount += 1 }

        service.handleRecognitionResult(text: "merhaba", finished: false, generation: 0)
        XCTAssertEqual(partials, ["merhaba"])
        XCTAssertEqual(endedCount, 0)

        service.handleRecognitionResult(text: "merhaba dünya", finished: true, generation: 0)
        XCTAssertEqual(partials, ["merhaba", "merhaba dünya"])
        XCTAssertEqual(endedCount, 1)
        XCTAssertNil(service.partialHandler)
        XCTAssertNil(service.endedHandler)
    }

    /// Bayat neslin geç gelen sonucu (iptal edilmiş kaydın kuyrukta kalmış
    /// geri çağrısı) yok sayılır: metin akmaz, bitiş tetiklenmez.
    @MainActor
    func testStaleRecognitionResultIsIgnored() {
        let service = SpeechDictationService(recognizer: nil)
        var partials: [String] = []
        var endedCount = 0
        service.partialHandler = { partials.append($0) }
        service.endedHandler = { endedCount += 1 }

        service.handleRecognitionResult(text: "eski kayıt", finished: true, generation: 999)

        XCTAssertTrue(partials.isEmpty)
        XCTAssertEqual(endedCount, 0)
    }
}
