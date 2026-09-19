import Foundation
import XCTest

@testable import AgenticSidebar

/// Kuyruk satırı taşma kilidi: uzun metin sabit düğmeleri panel dışına
/// itemez. Düzen headless ölçülemez; sözleşme kaynak yapısıyla kilitlenir
/// (repo önceliği: `testTextEditorIsIdentifiedBySession` deseni).
final class QueuedPromptsStripTests: XCTestCase {
    /// Özet satırındaki metin satırın esnek elemanıdır: kalan genişliği alır,
    /// sığmayanı kuyruktan kırpar, tek satırda kalır.
    func testPromptTextIsTheFlexibleTruncatedElement() throws {
        let source = try stripSource()
        let summary = summaryBody(from: source)

        XCTAssertTrue(
            summary.contains("Text(prompt.text)"),
            "Satır kuyruktaki mesaj metnini göstermeli"
        )
        XCTAssertTrue(
            summary.contains(".lineLimit(1)"),
            "Metin tek satırda kalmalı"
        )
        XCTAssertTrue(
            summary.contains(".truncationMode(.tail)"),
            "Taşan metin kuyruktan kırpılmalı"
        )
        XCTAssertTrue(
            summary.contains(".frame(maxWidth: .infinity"),
            "Metin kalan genişliği almalı, sabit düğmeler ideallerini korumalı"
        )
    }

    /// Metinle düğmeler arasında esneklik için yarışan `Spacer` olmamalı:
    /// iki açgözlü eleman genişliği bölüşür, metin yine taşar.
    func testNoCompetingSpacerBetweenTextAndButtons() throws {
        let source = try stripSource()
        let summary = summaryBody(from: source)

        XCTAssertFalse(
            summary.contains("Spacer("),
            "Metin zaten sonsuz genişliğe yayılıyor; ikinci esnek eleman taşmayı geri getirir"
        )
    }

    // MARK: - Helpers

    /// `summary` hesaplanan özelliğin gövdesi: ilk `Text(prompt.text)`
    /// satırından dosya sonuna kadar — satır ve düğmeler bu aralıktadır.
    private func summaryBody(from source: String) -> String {
        guard let start = source.range(of: "Text(prompt.text)") else {
            XCTFail("summary satırı bulunamadı")
            return ""
        }
        return String(source[start.lowerBound...])
    }

    private func stripSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source =
            testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AgenticSidebar/Views/QueuedPromptsStrip.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }
}
