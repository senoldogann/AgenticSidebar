import Foundation
import XCTest

@testable import AgenticSidebar

/// Harici izin uyarısının yanlış pozitif vermemesi.
///
/// Managed dosyanın (`OPENCODE_CONFIG`) karşılığını yazdığı anahtarlar
/// etkisizdir (opencode 1.18.31'de `debug config` ile doğrulandı); uyarı
/// yalnız managed dosyada karşılığı olmayan kurallarda görünmelidir.
final class GlobalPermissionOverrideTests: XCTestCase {
    func testOverriddenRulesProduceNoWarning() throws {
        let directory = try makeOverrideTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = try writeOverrideConfig(
            #"{"permission":{"read":"allow","bash":"allow","edit":"allow","glob":"allow","grep":"allow","list":"allow","external_directory":"allow","todowrite":"allow","webfetch":"allow","websearch":"allow"}}"#,
            in: directory
        )

        let reader = GlobalOpenCodeConfigReader(configURLs: [configURL])
        let managed = GlobalOpenCodeConfigReader.ManagedPermissionKeys(
            permission: [
                "*", "read", "bash", "edit", "glob", "grep", "list", "lsp",
                "question", "todowrite", "webfetch", "websearch",
                "external_directory", "task", "doom_loop",
            ],
            tools: [],
            agents: []
        )

        XCTAssertNil(reader.effectiveGlobalPermissionOverrides(managedKeys: managed))
    }

    func testUncoveredRuleIsKept() throws {
        let directory = try makeOverrideTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = try writeOverrideConfig(
            #"{"permission":{"bash":"allow","mystery_tool":"allow"}}"#,
            in: directory
        )

        let reader = GlobalOpenCodeConfigReader(configURLs: [configURL])
        let managed = GlobalOpenCodeConfigReader.ManagedPermissionKeys(
            permission: ["bash"],
            tools: [],
            agents: []
        )

        let override = try XCTUnwrap(reader.effectiveGlobalPermissionOverrides(managedKeys: managed))
        XCTAssertEqual(override.rules, ["mystery_tool": "allow"])
    }

    func testComplexKeysFollowPresence() throws {
        let directory = try makeOverrideTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = try writeOverrideConfig(
            #"{"permission":{"bash":{"custom":"allow"},"grep":"allow"}}"#,
            in: directory
        )

        let reader = GlobalOpenCodeConfigReader(configURLs: [configURL])
        let withoutBash = GlobalOpenCodeConfigReader.ManagedPermissionKeys(
            permission: ["grep"],
            tools: [],
            agents: []
        )
        let withBash = GlobalOpenCodeConfigReader.ManagedPermissionKeys(
            permission: ["bash", "grep"],
            tools: [],
            agents: []
        )

        let kept = try XCTUnwrap(reader.effectiveGlobalPermissionOverrides(managedKeys: withoutBash))
        XCTAssertEqual(kept.complexPermissionKeys, ["bash"])
        XCTAssertTrue(kept.rules.isEmpty)
        XCTAssertNil(reader.effectiveGlobalPermissionOverrides(managedKeys: withBash))
    }

    func testToolAndAgentRulesFollowPresence() throws {
        let directory = try makeOverrideTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = try writeOverrideConfig(
            #"{"tools":{"some_*":"allow"},"agent":{"other-agent":{"permission":{"bash":"allow"}}}}"#,
            in: directory
        )

        let reader = GlobalOpenCodeConfigReader(configURLs: [configURL])
        let empty = GlobalOpenCodeConfigReader.ManagedPermissionKeys.empty
        let covered = GlobalOpenCodeConfigReader.ManagedPermissionKeys(
            permission: [],
            tools: ["some_*"],
            agents: ["other-agent.bash"]
        )

        let kept = try XCTUnwrap(reader.effectiveGlobalPermissionOverrides(managedKeys: empty))
        XCTAssertEqual(kept.toolRules, ["some_*": "allow"])
        XCTAssertEqual(kept.agentRules, ["other-agent.bash": "allow"])
        XCTAssertNil(reader.effectiveGlobalPermissionOverrides(managedKeys: covered))
    }

    func testMissingManagedFileKeepsEverything() throws {
        let directory = try makeOverrideTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = try writeOverrideConfig(
            #"{"permission":{"bash":"allow"}}"#,
            in: directory
        )

        let missing = directory.appendingPathComponent("yok.json", isDirectory: false)
        let keys = GlobalOpenCodeConfigReader.managedKeys(at: missing, fileManager: FileManager.default)
        XCTAssertEqual(keys, GlobalOpenCodeConfigReader.ManagedPermissionKeys.empty)

        let reader = GlobalOpenCodeConfigReader(configURLs: [configURL])
        let override = try XCTUnwrap(reader.effectiveGlobalPermissionOverrides(managedKeys: keys))
        XCTAssertEqual(override.rules, ["bash": "allow"])
    }

    func testEmptyGlobalFileShowsNoWarning() throws {
        let directory = try makeOverrideTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = try writeOverrideConfig(
            #"{"$schema":"https://opencode.ai/config.json"}"#,
            in: directory
        )

        let reader = GlobalOpenCodeConfigReader(configURLs: [configURL])
        XCTAssertNil(
            reader.effectiveGlobalPermissionOverrides(
                managedKeys: GlobalOpenCodeConfigReader.ManagedPermissionKeys.empty
            )
        )
    }

    func testManagedKeysParsing() {
        let object: [String: Any] = [
            "permission": ["bash": "ask", "read": "allow"],
            "tools": ["github_*": false],
            "agent": [
                "build": ["permission": ["bash": "ask"]],
                "plain": "sözlük-değil",
            ],
        ]

        let keys = GlobalOpenCodeConfigReader.managedKeys(from: object)

        XCTAssertEqual(keys.permission, ["bash", "read"])
        XCTAssertEqual(keys.tools, ["github_*"])
        XCTAssertEqual(keys.agents, ["build.bash"])
    }

    private func makeOverrideTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("permission-override-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeOverrideConfig(_ text: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("opencode.json", isDirectory: false)
        try Data(text.utf8).write(to: url)
        return url
    }
}
