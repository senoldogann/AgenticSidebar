import AppKit
import XCTest
@testable import AgenticSidebar

/// Akan yanıtın her boşaltmada baştan dizilmemesi kuralının testleri.
///
/// Ölçüm: 4–27k karakterlik bir yanıt için tam yeniden dizgi 10–41 ms, tam
/// yerleşim 7–27 ms sürüyordu ve boşaltma aralığı 16–40 ms. Yani ana iş
/// parçacığı akış boyunca doyuyordu; kaydırma da bu yüzden takılıyordu. Buradaki
/// testler artık yalnız değişen kuyruğun yazıldığını ve sonucun **eski tam
/// yazıyla birebir aynı** olduğunu kanıtlar.
///
/// Karşılaştırma bilerek ham `attributedString` çıktısına değil, gerçek bir
/// metin deposuna tam yazılmış hâline yapılır: NSTextStorage paragraf ayırıcısına
/// paragraf stilini kendisi işler, o yüzden ham çıktıdan farklıdır — iki yazı
/// yolu da aynı sonucu vermelidir.
@MainActor
final class MarkdownRunIncrementalUpdateTests: XCTestCase {
    private let typography = MarkdownRunTypography.default

    func testAppendingABlockRewritesOnlyTheTail() {
        let textView = SelectableMarkdownTextView.makeTextView()
        let coordinator = SelectableMarkdownTextView.Coordinator()

        apply(blocks: [paragraph("bir"), paragraph("iki")], to: textView, coordinator)
        XCTAssertEqual(coordinator.fullRebuilds, 1)

        apply(blocks: [paragraph("bir"), paragraph("iki"), paragraph("üç")], to: textView, coordinator)

        XCTAssertEqual(coordinator.incrementalEdits, 1)
        XCTAssertEqual(coordinator.fullRebuilds, 1, "ikinci yazı baştan dizilmemeli")
        XCTAssertGreaterThan(coordinator.lastEdit.location, 0, "yalnız kuyruk yazılmalı")
    }

    func testIncrementalResultIsIdenticalToTheOldFullWrite() {
        let textView = SelectableMarkdownTextView.makeTextView()
        let coordinator = SelectableMarkdownTextView.Coordinator()

        var blocks: [MarkdownBlock] = []
        for index in 0..<6 {
            blocks.append(paragraph("paragraf \(index) — biraz daha uzun bir metin"))
            apply(blocks: blocks, to: textView, coordinator)

            XCTAssertEqual(
                textView.textStorage?.isEqual(to: reference(blocks, typography)),
                true,
                "\(index + 1) blokluk hâl tam yazıyla aynı olmalı"
            )
        }

        // İlk yazı baştan kurar; ikinci blok eklenirken korunacak bir önceki blok
        // yoktur ("son" olma sırası ilk bloktan başlar), kalan dördü ise yalnız
        // kuyruğu yazar.
        XCTAssertEqual(coordinator.incrementalEdits, 4)
    }

    /// Akışın asıl hâli: son paragrafa harf eklenir, öncekiler durur.
    func testGrowingTheLastParagraphAlsoMatchesTheFullWrite() {
        let textView = SelectableMarkdownTextView.makeTextView()
        let coordinator = SelectableMarkdownTextView.Coordinator()

        var growing = "başlangıç"
        apply(blocks: [paragraph("ilk"), paragraph("ikinci"), paragraph(growing)], to: textView, coordinator)
        let editsAfterFirstWrite = coordinator.incrementalEdits

        for _ in 0..<8 {
            growing += " ve biraz daha"
            let blocks = [paragraph("ilk"), paragraph("ikinci"), paragraph(growing)]
            apply(blocks: blocks, to: textView, coordinator)

            XCTAssertEqual(textView.textStorage?.isEqual(to: reference(blocks, typography)), true)
        }

        XCTAssertEqual(coordinator.incrementalEdits, editsAfterFirstWrite + 8)
    }

    func testAChangeInTheMiddleRewritesFromThatBlockOnward() {
        let textView = SelectableMarkdownTextView.makeTextView()
        let coordinator = SelectableMarkdownTextView.Coordinator()

        apply(
            blocks: [paragraph("bir"), paragraph("iki"), paragraph("üç"), paragraph("dört")],
            to: textView,
            coordinator
        )

        let blocks = [paragraph("bir"), paragraph("iki değişti"), paragraph("üç"), paragraph("dört")]
        apply(blocks: blocks, to: textView, coordinator)

        XCTAssertEqual(textView.textStorage?.isEqual(to: reference(blocks, typography)), true)
        XCTAssertGreaterThan(coordinator.lastEdit.location, 0)
        XCTAssertLessThan(
            coordinator.lastEdit.location,
            textView.string.count,
            "ortadaki blok değişti: ne baştan ne de boş bir aralık yazılmalı"
        )
    }

    func testATypographyChangeRebuildsEverything() {
        let textView = SelectableMarkdownTextView.makeTextView()
        let coordinator = SelectableMarkdownTextView.Coordinator()
        let blocks = [paragraph("bir"), paragraph("iki"), paragraph("üç")]

        apply(blocks: blocks, to: textView, coordinator)

        let other = MarkdownRunTypography(fontFamily: .serif, pointSize: 15, lineSpacing: 4)
        SelectableMarkdownTextView.apply(
            blocks: blocks,
            typography: other,
            to: textView,
            coordinator: coordinator
        )

        XCTAssertEqual(coordinator.fullRebuilds, 2)
        XCTAssertEqual(coordinator.lastEdit.location, 0)
        XCTAssertEqual(textView.textStorage?.isEqual(to: reference(blocks, other)), true)
    }

    func testAnUnchangedRunIsNotTouched() {
        let textView = SelectableMarkdownTextView.makeTextView()
        let coordinator = SelectableMarkdownTextView.Coordinator()
        let blocks = [paragraph("bir"), paragraph("iki"), paragraph("üç")]

        apply(blocks: blocks, to: textView, coordinator)
        let edits = coordinator.incrementalEdits
        let rebuilds = coordinator.fullRebuilds

        apply(blocks: blocks, to: textView, coordinator)

        XCTAssertEqual(coordinator.incrementalEdits, edits)
        XCTAssertEqual(coordinator.fullRebuilds, rebuilds)
    }

    /// Bir akışta seçim kaybolmasın: kuyruk büyürken önceki paragraftaki seçim
    /// yerinde kalır. Eski `setAttributedString` her boşaltmada onu siliyordu.
    func testASelectionInAnEarlierParagraphSurvivesAGrowingTail() {
        let textView = SelectableMarkdownTextView.makeTextView()
        let coordinator = SelectableMarkdownTextView.Coordinator()

        let blocks = [paragraph("seçilecek metin"), paragraph("kuyruk"), paragraph("son")]
        apply(blocks: blocks, to: textView, coordinator)

        let storage = textView.textStorage
        storage?.addAttribute(
            .backgroundColor,
            value: NSColor.selectedTextBackgroundColor,
            range: NSRange(location: 0, length: 3)
        )

        apply(
            blocks: [paragraph("seçilecek metin"), paragraph("kuyruk büyüdü"), paragraph("son")],
            to: textView,
            coordinator
        )

        XCTAssertEqual(
            textView.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor,
            NSColor.selectedTextBackgroundColor
        )
    }

    // MARK: - Helpers

    private func apply(
        blocks: [MarkdownBlock],
        to textView: NSTextView,
        _ coordinator: SelectableMarkdownTextView.Coordinator
    ) {
        SelectableMarkdownTextView.apply(
            blocks: blocks,
            typography: typography,
            to: textView,
            coordinator: coordinator
        )
    }

    /// Eski yazı yolu: her şeyi baştan kurup depoya tek seferde yazmak.
    private func reference(
        _ blocks: [MarkdownBlock],
        _ typography: MarkdownRunTypography
    ) -> NSTextStorage {
        let textView = SelectableMarkdownTextView.makeTextView()
        textView.textStorage?.setAttributedString(
            MarkdownTextRunBuilder.attributedString(blocks: blocks, typography: typography)
        )
        return textView.textStorage ?? NSTextStorage()
    }

    private func paragraph(_ content: String) -> MarkdownBlock {
        .paragraph(id: content, content: content)
    }
}
