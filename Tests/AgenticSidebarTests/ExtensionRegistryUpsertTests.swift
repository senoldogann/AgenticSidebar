import Foundation
import XCTest

@testable import AgenticSidebar

/// Aynı adlı kayıt birleşme kuralları: kullanıcının kurulumu (komut + sırlar)
/// kalıtılmış gölgeyle ezilmemeli.
///
/// Çıta: marketten anahtarla kurulan sunucu her keşifte yaşamalı (context7
/// API anahtarı kaybı), kalıtılmış düğme seçimi `refresh()` sonrası korunmalı.
final class ExtensionRegistryUpsertTests: XCTestCase {
    private func manualRecord(
        env: [String: String] = ["CONTEXT7_API_KEY": "gizli"],
        isEnabled: Bool = true
    ) -> MCPServerRecord {
        MCPServerRecord(
            name: "context7",
            definition: MCPDefinition(
                transport: .local,
                command: ["npx", "-y", "@upstash/context7-mcp"],
                environment: env
            ),
            isEnabled: isEnabled,
            source: .manual,
            isInherited: false,
            installedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func inheritedRecord(isEnabled: Bool = false) -> MCPServerRecord {
        MCPServerRecord(
            name: "context7",
            definition: MCPDefinition(
                transport: .remote,
                url: "https://mcp.context7.com/mcp"
            ),
            isEnabled: isEnabled,
            source: .manual,
            isInherited: true,
            installedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
    }

    /// Keşif, kalıtılmış gölgeyi kullanıcının kaydının üstüne yazmamalı:
    /// komut, sırlar, kaynak ve açık/kapalı seçim korunur.
    func testManualRecordSurvivesInheritedRediscovery() {
        var registry = ExtensionRegistry(mcpServers: [manualRecord()])

        registry.upsert(mcpServer: inheritedRecord())

        XCTAssertEqual(registry.mcpServers.count, 1)
        let kept = registry.mcpServers[0]
        XCTAssertFalse(kept.isInherited)
        XCTAssertTrue(kept.isEnabled)
        XCTAssertEqual(kept.definition.command, ["npx", "-y", "@upstash/context7-mcp"])
        XCTAssertEqual(kept.definition.environment, ["CONTEXT7_API_KEY": "gizli"])
        XCTAssertEqual(kept.source, .manual)
    }

    /// Elle ekleme kalıtılmış gölgeyi devirir: tanım ve seçim kullanıcınındır.
    func testManualAddWinsOverInheritedShadow() {
        var registry = ExtensionRegistry(mcpServers: [inheritedRecord()])

        registry.upsert(mcpServer: manualRecord())

        XCTAssertEqual(registry.mcpServers.count, 1)
        let kept = registry.mcpServers[0]
        XCTAssertFalse(kept.isInherited)
        XCTAssertTrue(kept.isEnabled)
        XCTAssertEqual(kept.definition.environment, ["CONTEXT7_API_KEY": "gizli"])
    }

    /// Aynı kökten taze tanım seçimi korur, tanımı günceller.
    func testSameOriginRefreshKeepsToggleButUpdatesDefinition() {
        var registry = ExtensionRegistry(mcpServers: [inheritedRecord(isEnabled: true)])
        var refreshed = inheritedRecord()
        refreshed.definition.timeoutMilliseconds = 45_000

        registry.upsert(mcpServer: refreshed)

        XCTAssertEqual(registry.mcpServers.count, 1)
        XCTAssertTrue(registry.mcpServers[0].isEnabled)
        XCTAssertEqual(registry.mcpServers[0].definition.timeoutMilliseconds, 45_000)
    }

    /// Kalıtılmış sunucuyu açmak `refresh()` ile geri alınmamalı: saklı seçim
    /// yeniden kurulan satıra taşınır.
    func testInheritedToggleSurvivesRefresh() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-upsert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("opencode.json")
        try Data(
            #"{"mcp":{"strix":{"type":"remote","url":"https://example.com/mcp"}}}"#.utf8
        ).write(to: configURL)
        let globalConfig = GlobalOpenCodeConfigReader(configURLs: [configURL])

        var stored = ExtensionRegistry.discovered(
            from: ExtensionRegistry(),
            catalog: [],
            globalConfig: globalConfig
        )
        XCTAssertEqual(stored.mcpServers.first?.isEnabled, false)

        stored.setMCPEnabled("strix", true)

        let refreshed = ExtensionRegistry.discovered(
            from: stored,
            catalog: [],
            globalConfig: globalConfig
        )

        XCTAssertEqual(refreshed.mcpServers.map(\.name), ["strix"])
        XCTAssertEqual(
            refreshed.mcpServers.first?.isEnabled,
            true,
            "Kullanıcının açtığı kalıtılmış sunucu keşifte kapanmamalı"
        )
    }
}
