import Foundation
import XCTest

@testable import AgenticSidebar

/// Yan soru paneli genişlik/tema kilidi: kart besteciyle aynı kapta (820)
/// ve aynı dış dolguda durur, yüzeyi temadan okur. Düzen headless
/// ölçülemez; sözleşme kaynak yapısıyla kilitlenir
/// (`GoalPanelVisibilityTests` deseni).
final class SideQuestionPanelTests: XCTestCase {
    /// Kart besteciyle aynı kaptadır (820), aynı dış dolguyu kullanır ve
    /// bölmede ortalanır.
    func testPanelMatchesComposerWidth() throws {
        let source = try panelSource()

        XCTAssertTrue(
            source.contains(".frame(maxWidth: 820"),
            "Kart besteciyle aynı 820 kapağında durmalı"
        )
        XCTAssertTrue(
            source.contains("PaneResponsive.outerPadding(forWidth: paneWidth)"),
            "Kart besteciyle aynı dış dolguyu kullanmalı"
        )
        XCTAssertTrue(
            source.contains(".frame(maxWidth: .infinity, alignment: .center)"),
            "Kart bölmede ortalanmalı"
        )
    }

    /// Yüzey ve kenarlık temadan okunur; sabit siyah/beyaz opaklık kalmaz.
    func testPanelUsesThemeColors() throws {
        let source = try panelSource()

        XCTAssertTrue(
            source.contains("currentTheme.surface(isDark:"),
            "Panel yüzeyi temadan gelmeli"
        )
        XCTAssertTrue(
            source.contains("currentTheme.border(isDark:"),
            "Panel kenarlığı temadan gelmeli"
        )
        XCTAssertFalse(
            source.contains(".padding(.horizontal, 12)"),
            "Sabit 12pt dolgu besteci hizasını bozardı"
        )
    }

    // MARK: - Helpers

    private func panelSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source =
            testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AgenticSidebar/Views/SideQuestionPanelView.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }
}
