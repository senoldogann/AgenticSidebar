import AppKit
import XCTest
@testable import AgenticSidebar

/// Bilgisayar adımı verisi: tür eşleme, başlık detayı, onay detayı ve HUD.
///
/// Çıta: pointer/klavye adımları `.computer` türüne düşer (jenerik anahtar ya
/// da komut satırına değil), başlık koordinat/tuş kombinasyonunu taşır, onay
/// diyaloğu detayı koordinatı düşürmez, HUD boşken gizlenir.
final class ComputerActivityTests: XCTestCase {
    // MARK: - Tür eşleme

    func testComputerToolsMapToComputerKind() {
        let tools = [
            "chatgpt-system_computer_click",
            "chatgpt-system_computer_run",
            "chatgpt-system_computer_observe",
            "click",
            "drag",
            "scroll",
            "press_key",
            "type_text",
            "screenshot",
            "focus_app",
        ]
        for tool in tools {
            let kind = ProviderActivityDescriptor.sanitizedTool(
                id: ProviderActivityID("x"),
                toolName: tool
            ).kind
            XCTAssertEqual(kind, .computer, "araç: \(tool)")
        }
    }

    func testNonComputerToolsKeepTheirKind() {
        XCTAssertEqual(
            ProviderActivityDescriptor.sanitizedTool(id: ProviderActivityID("x"), toolName: "bash").kind,
            .command
        )
        XCTAssertEqual(
            ProviderActivityDescriptor.sanitizedTool(id: ProviderActivityID("x"), toolName: "read").kind,
            .read
        )
        XCTAssertEqual(
            ProviderActivityDescriptor.sanitizedTool(id: ProviderActivityID("x"), toolName: "run_tests").kind,
            .command
        )
    }

    // MARK: - Başlık ve detay

    func testClickTitleCarriesCoordinates() {
        let (title, _) = ComputerActivityTitle.titleAndDetail(
            tool: "chatgpt-system_computer_click",
            input: ["x": 412, "y": 208]
        )
        XCTAssertEqual(title, "Click (412, 208)")
    }

    func testDoubleCoordinatesAcceptFloatingNumbers() {
        let (title, _) = ComputerActivityTitle.titleAndDetail(
            tool: "click",
            input: ["x": 412.0, "y": 208.5]
        )
        XCTAssertEqual(title, "Click (412, 208.5)")
    }

    func testPressKeyTitleCarriesCombo() {
        let (title, _) = ComputerActivityTitle.titleAndDetail(
            tool: "press_key",
            input: ["key": "c", "modifiers": ["command"]]
        )
        XCTAssertEqual(title, "Press Command+C")
    }

    func testTypeTitlePreviewsFirstLine() {
        let (title, _) = ComputerActivityTitle.titleAndDetail(
            tool: "type_text",
            input: ["text": "merhaba dünya\nikinci satır"]
        )
        XCTAssertEqual(title, "Type “merhaba dünya”")
    }

    func testFocusTitleNamesAppInDetail() {
        let (title, detail) = ComputerActivityTitle.titleAndDetail(
            tool: "focus_app",
            input: ["bundleIdentifier": "com.apple.Safari"]
        )
        XCTAssertEqual(title, "Focus com.apple.Safari")
        XCTAssertEqual(detail, "com.apple.Safari")
    }

    func testMissingCoordinatesDegradeGracefully() {
        let (title, _) = ComputerActivityTitle.titleAndDetail(tool: "click", input: [:])
        XCTAssertEqual(title, "Click …")
    }

    // MARK: - Normalizer yönlendirmesi

    func testNormalizerRoutesComputerKind() {
        let (title, _) = OpenCodeStreamNormalizer.computerTitleAndDetail(
            tool: "chatgpt-system_computer_click",
            input: ["x": 1, "y": 2]
        )
        XCTAssertEqual(title, "Click (1, 2)")
    }

    // MARK: - Onay detayı

    func testPermissionDetailKeepsCoordinatesForComputerTools() {
        let detail = OpenCodePermissionRequest.detail(
            from: ["x": 412, "y": 208],
            toolName: "chatgpt-system_computer_click"
        )
        XCTAssertTrue(detail?.contains("Click (412, 208)") == true)
    }

    func testPermissionDetailWithoutToolNameKeepsLegacyBehavior() {
        XCTAssertNil(OpenCodePermissionRequest.detail(from: [:]))
        XCTAssertEqual(
            OpenCodePermissionRequest.detail(from: ["command": "ls"]),
            "command: ls"
        )
    }

    // MARK: - HUD

    @MainActor
    func testHUDHidesWhenEmptyAndShowsItems() {
        _ = NSApplication.shared
        let hud = FloatingHUDController()

        hud.update(with: [])
        XCTAssertFalse(hud.isVisible)

        hud.update(with: [HUDActivityItem(id: "1", title: "Click (412, 208)")])
        XCTAssertTrue(hud.isVisible)

        hud.hide()
        XCTAssertFalse(hud.isVisible)
    }
}
