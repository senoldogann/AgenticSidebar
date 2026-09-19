import Foundation
import XCTest

@testable import AgenticSidebar

/// Ayarlar sayfası düzeni: her kart kendi işinin menüsünde durur.
///
/// Çıta: sekmeler bölümlere eksiksiz dağılır, ajan davranışı AI sekmesinde,
/// gözlem Diagnostics sekmesinde, kart kromu ortaktır. Kaynak-içi denetimler
/// taşınan kartların eski evinde kopya bırakmadığını kilitler.
final class SettingsOrganizationTests: XCTestCase {
    func testEveryTabBelongsToExactlyOneSection() {
        let tabs = SettingsTab.allCases
        XCTAssertFalse(tabs.isEmpty)

        let sections = Dictionary(grouping: tabs, by: \.section)
        XCTAssertEqual(
            Set(sections.keys),
            Set(SettingsSection.allCases),
            "Her bölümde en az bir sekme olmalı, boş başlık dağınıklıktır"
        )
        XCTAssertEqual(
            sections.values.flatMap { $0 }.count,
            tabs.count,
            "Hiçbir sekme bölümsüz kalmamalı"
        )
    }

    func testSectionMapping() {
        XCTAssertEqual(SettingsTab.appearance.section, .workspace)
        XCTAssertEqual(SettingsTab.general.section, .workspace)
        XCTAssertEqual(SettingsTab.ai.section, .agent)
        XCTAssertEqual(SettingsTab.automation.section, .agent)
        XCTAssertEqual(SettingsTab.computerUse.section, .agent)
        XCTAssertEqual(SettingsTab.skills.section, .extensions)
        XCTAssertEqual(SettingsTab.mcp.section, .extensions)
        XCTAssertEqual(SettingsTab.plugins.section, .extensions)
        XCTAssertEqual(SettingsTab.diagnostics.section, .system)
    }

    func testInteractiveQuestionsLivesInAI() throws {
        let ai = try settingsSource(named: "SettingsAITab.swift")
        let general = try settingsSource(named: "SettingsGeneralTab.swift")

        XCTAssertTrue(
            ai.contains("interactiveQuestionsCard"),
            "Ajan sorusu davranışı AI sekmesinde olmalı"
        )
        XCTAssertFalse(
            general.contains("Interactive Questions"),
            "Genel sekmede ajan davranışı kartı kalmamalı"
        )
    }

    func testToolActivityLivesOnlyInDiagnostics() throws {
        let ai = try settingsSource(named: "SettingsAITab.swift")
        let diagnostics = try settingsSource(named: "SettingsDiagnosticsTab.swift")

        XCTAssertTrue(
            diagnostics.contains("toolDecisionLogCard"),
            "Araç gözlemi Diagnostics sekmesinde olmalı"
        )
        XCTAssertFalse(
            ai.contains("toolDecisionLogCard"),
            "AI sekmesinde ikinci gözlemci kalmamalı"
        )
    }

    func testDiagnosticsUsesSharedCardChrome() throws {
        let diagnostics = try settingsSource(named: "SettingsDiagnosticsTab.swift")

        XCTAssertTrue(
            diagnostics.contains("settingsCard("),
            "Diagnostics ortak kart kromunu kullanmalı"
        )
        XCTAssertFalse(
            diagnostics.contains("func diagnosticsCard"),
            "Sekmeye özel kart çerçevesi geri gelmemeli"
        )
        XCTAssertFalse(
            diagnostics.contains("struct DiagnosticsTabView"),
            "Diagnostics ayrı yapı değil, sekme içeriği olmalı"
        )
    }

    func testToolApprovalCopyDoesNotPromiseMidTurnPermissionChanges() throws {
        let ai = try settingsSource(named: "SettingsAITab.swift")
        XCTAssertTrue(
            ai.contains("Changes apply from the next turn."),
            "The Settings card must match the turn-scoped permission snapshot"
        )
        XCTAssertFalse(ai.contains("on its next tool call"))
        XCTAssertFalse(ai.contains("takes effect immediately"))
        for policy in ToolApprovalPolicy.allCases {
            XCTAssertTrue(policy.detail.contains("next turn"))
        }
    }

    private func settingsSource(named file: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source =
            testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AgenticSidebar/Views/Settings/\(file)")
        return try String(contentsOf: source, encoding: .utf8)
    }
}
