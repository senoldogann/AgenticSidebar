import Foundation
import XCTest

@testable import AgenticSidebar

/// Hedef paneli görünürlük kilidi: boşken ipucu satırı çizilmez, koşu
/// varken (aktif/duraklatılmış/kapatılmayı bekleyen bitmiş ya da diskten
/// devam edilebilir) görünür. Düzen headless ölçülemez; genişlik sözleşmesi
/// kaynak yapısıyla kilitlenir (`QueuedPromptsStripTests` deseni).
@MainActor
final class GoalPanelVisibilityTests: XCTestCase {
    /// Taze orkestratörde koşu yoktur: panel çizilmez.
    func testFreshOrchestratorHasNoVisiblePanel() {
        let orchestrator = GoalOrchestrator()

        XCTAssertFalse(orchestrator.hasVisiblePanel, "Koşu yokken panel görünmemeli")
    }

    /// Başlatılan hedef paneli açar.
    func testStartedGoalShowsPanel() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()

        let accepted = orchestrator.start(
            objective: "Pencere opaklığı kaydıcısı",
            sessionID: UUID(),
            speedMode: .normal,
            mode: .build,
            workingDirectory: package,
            bridge: session.bridge(),
            storeURL: nil
        )

        XCTAssertTrue(accepted, "Hedef başlamalı")
        XCTAssertTrue(orchestrator.hasVisiblePanel, "Koşu varken panel görünmeli")
    }

    /// Kapatılan (dismiss) hedef paneli kaldırır.
    func testDismissedGoalHidesPanel() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        _ = orchestrator.start(
            objective: "Pencere opaklığı kaydıcısı",
            sessionID: UUID(),
            speedMode: .normal,
            mode: .build,
            workingDirectory: package,
            bridge: session.bridge(),
            storeURL: nil
        )

        orchestrator.dismiss()

        XCTAssertFalse(orchestrator.hasVisiblePanel, "Kapatılan hedeften sonra panel görünmemeli")
    }

    /// Gövde boşken dal çizmez: ipucu satırı ve üçüncü `else` yoktur.
    func testPanelBodyHasNoIdleBranch() throws {
        let source = try panelSource()

        XCTAssertFalse(
            source.contains("idleRow"),
            "Boş ipucu satırı kalkmalı; panel yalnız koşu varken çizilir"
        )
        XCTAssertFalse(
            source.contains("Type /goal followed by"),
            "Kalıcı ipucu metni kalmamalı"
        )
    }

    /// Kart besteciyle aynı kaptadır (820) ve aynı dış dolguyu kullanır:
    /// sol/sağ kenarlar giriş kutusuyla hizalanır.
    func testPanelCardMatchesComposerWidth() throws {
        let source = try panelSource()
        let card = cardBody(from: source)

        XCTAssertTrue(
            card.contains(".frame(maxWidth: 820"),
            "Kart besteciyle aynı 820 kapağında durmalı"
        )
        XCTAssertTrue(
            card.contains("PaneResponsive.outerPadding(forWidth: paneWidth)"),
            "Kart besteciyle aynı dış dolguyu kullanmalı"
        )
        XCTAssertTrue(
            card.contains(".frame(maxWidth: .infinity, alignment: .center)"),
            "Kart bölmede ortalanmalı"
        )
    }

    // MARK: - Helpers

    private func packageDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "// swift-tools-version: 6.0".write(
            to: dir.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        return dir
    }

    /// `card` hesaplanan özelliğin gövdesi: imzasından dosya sonuna kadar —
    /// genişlik zinciri bu aralıktadır.
    private func cardBody(from source: String) -> String {
        guard let start = source.range(of: "private func card<Content: View>") else {
            XCTFail("card gövdesi bulunamadı")
            return ""
        }
        return String(source[start.lowerBound...])
    }

    private func panelSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source =
            testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AgenticSidebar/Views/GoalPanelView.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }
}
