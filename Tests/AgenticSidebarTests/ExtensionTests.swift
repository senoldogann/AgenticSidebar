import Foundation
import XCTest
@testable import AgenticSidebar

/// The extension layer: validating a skill before it is written, keeping the
/// context gate honest, and the two triggers the composer offers.
final class ExtensionManifestTests: XCTestCase {
    private let validManifest = """
    ---
    name: code-review
    description: Reviews a diff for correctness, not style.
    license: MIT
    metadata:
      author: someone
    ---

    Read the diff, then report only real defects.
    """

    func testAValidManifestParsesIntoNameDescriptionAndBody() throws {
        let manifest = try SkillManifestParser.parse(validManifest)

        XCTAssertEqual(manifest.name, "code-review")
        XCTAssertEqual(manifest.description, "Reviews a diff for correctness, not style.")
        XCTAssertEqual(manifest.license, "MIT")
        XCTAssertEqual(manifest.metadata["author"], "someone")
        XCTAssertTrue(manifest.body.hasPrefix("Read the diff"))
    }

    func testAManifestWithoutFrontmatterIsRejected() {
        XCTAssertThrowsError(try SkillManifestParser.parse("# Just a readme")) { error in
            XCTAssertEqual(error as? SkillManifestError, .missingFrontmatter)
        }
    }

    func testAManifestWithoutABodyIsRejected() {
        let empty = """
        ---
        name: code-review
        description: Something
        ---
        """

        XCTAssertThrowsError(try SkillManifestParser.parse(empty)) { error in
            XCTAssertEqual(error as? SkillManifestError, .emptyBody)
        }
    }

    func testOnlyLowercaseHyphenatedNamesAreAccepted() {
        XCTAssertTrue(SkillManifestParser.isValidName("code-review"))
        XCTAssertTrue(SkillManifestParser.isValidName("review2"))

        XCTAssertFalse(SkillManifestParser.isValidName("Code-Review"))
        XCTAssertFalse(SkillManifestParser.isValidName("-leading"))
        XCTAssertFalse(SkillManifestParser.isValidName("trailing-"))
        XCTAssertFalse(SkillManifestParser.isValidName("two--hyphens"))
        XCTAssertFalse(SkillManifestParser.isValidName("with space"))
        XCTAssertFalse(SkillManifestParser.isValidName(""))
    }

    /// OpenCode loads a skill only when the folder and the frontmatter agree, so
    /// the mismatch has to be caught at install time rather than silently.
    func testAFolderNameThatDisagreesWithTheManifestIsRejected() throws {
        let manifest = try SkillManifestParser.parse(validManifest)

        XCTAssertThrowsError(
            try SkillManifestParser.validate(manifest, directoryName: "other-folder")
        ) { error in
            XCTAssertEqual(
                error as? SkillManifestError,
                .directoryMismatch(directory: "other-folder", name: "code-review")
            )
        }

        XCTAssertNoThrow(
            try SkillManifestParser.validate(manifest, directoryName: "code-review")
        )
    }

    func testAnOverlongNameIsRejected() throws {
        let name = String(repeating: "a", count: SkillManifest.maximumNameLength + 1)
        let manifest = """
        ---
        name: \(name)
        description: Something
        ---

        Body
        """

        XCTAssertThrowsError(try SkillManifestParser.parse(manifest)) { error in
            XCTAssertEqual(error as? SkillManifestError, .nameTooLong)
        }
    }
}

final class ExtensionContextGateTests: XCTestCase {
    func testADisabledServerIsSilencedAndAnEnabledOneIsNot() {
        let registry = ExtensionRegistry(
            mcpServers: [
                makeMCP(name: "github", isEnabled: true),
                makeMCP(name: "notion", isEnabled: false),
                makeMCP(name: "user-own", isEnabled: false, isInherited: true)
            ]
        )

        XCTAssertEqual(registry.enabledMCPDefinitions.keys.sorted(), ["github"])
        XCTAssertEqual(
            registry.silencedMCPToolPatterns,
            ["notion_*": false, "user-own_*": false],
            "Every server the user did not turn on has to be silenced by name"
        )
    }

    func testAServerWithoutACommandIsNotRegistered() {
        let broken = MCPServerRecord(
            name: "broken",
            definition: MCPDefinition(transport: .local, command: []),
            isEnabled: true,
            source: .manual,
            isInherited: false,
            installedAt: Date()
        )

        let registry = ExtensionRegistry(mcpServers: [broken])

        XCTAssertTrue(registry.enabledMCPDefinitions.isEmpty)
        XCTAssertTrue(registry.silencedMCPToolPatterns.isEmpty)
    }

    func testADisabledSkillIsDeniedByName() {
        let registry = ExtensionRegistry(
            skills: [
                makeSkill(name: "code-review", isEnabled: true),
                makeSkill(name: "noisy", isEnabled: false)
            ]
        )

        XCTAssertEqual(registry.deniedSkillNames, ["noisy"])
        XCTAssertEqual(registry.enabledSkills.map(\.name), ["code-review"])
    }

    func testOnlyAnEnabledExtensionIsOfferedToTheComposer() {
        let registry = ExtensionRegistry(
            mcpServers: [makeMCP(name: "github", isEnabled: true), makeMCP(name: "notion", isEnabled: false)],
            plugins: [
                PluginRecord(
                    module: "opencode-plugin-foo",
                    isEnabled: true,
                    source: .npm(module: "opencode-plugin-foo"),
                    installedAt: Date(),
                    requiresTrust: true
                )
            ],
            skills: [makeSkill(name: "code-review", isEnabled: true), makeSkill(name: "noisy", isEnabled: false)]
        )

        XCTAssertEqual(
            registry.suggestions(matching: "").map(\.name).sorted(),
            ["code-review", "github", "opencode-plugin-foo"],
            "Offering something that cannot reach the model would be a lie"
        )

        // The query is matched against the name *and* the detail line, so an
        // MCP server or plugin can be found by what it does, not only by its name.
        XCTAssertEqual(registry.suggestions(matching: "-review").map(\.name), ["code-review"])
        XCTAssertEqual(registry.suggestions(matching: "nothing-here"), [])
    }

    func testPrefixMatchesSortBeforeSubstringMatches() {
        let registry = ExtensionRegistry(
            skills: [
                makeSkill(name: "deep-review", isEnabled: true),
                makeSkill(name: "review", isEnabled: true)
            ]
        )

        XCTAssertEqual(registry.suggestions(matching: "review").map(\.name), ["review", "deep-review"])
    }

    private func makeMCP(name: String, isEnabled: Bool, isInherited: Bool = false) -> MCPServerRecord {
        MCPServerRecord(
            name: name,
            definition: MCPDefinition(transport: .local, command: ["npx", name]),
            isEnabled: isEnabled,
            source: .manual,
            isInherited: isInherited,
            installedAt: Date()
        )
    }

    private func makeSkill(name: String, isEnabled: Bool) -> SkillRecord {
        SkillRecord(
            name: name,
            description: "Does \(name)",
            isEnabled: isEnabled,
            source: .manual,
            installedAt: Date(),
            path: "/tmp/\(name)/SKILL.md",
            isManaged: false
        )
    }
}

final class ManagedConfigurationTests: XCTestCase {
    func testDisabledSkillsAndServersAreExpressedAsOverrides() throws {
        let registry = ExtensionRegistry(
            mcpServers: [
                MCPServerRecord(
                    name: "github",
                    definition: MCPDefinition(
                        transport: .remote,
                        url: "https://example.com/mcp",
                        oauth: .automatic
                    ),
                    isEnabled: true,
                    source: .manual,
                    isInherited: false,
                    installedAt: Date()
                ),
                MCPServerRecord(
                    name: "notion",
                    definition: MCPDefinition(transport: .local, command: ["npx", "notion"]),
                    isEnabled: false,
                    source: .manual,
                    isInherited: true,
                    installedAt: Date()
                )
            ],
            plugins: [
                PluginRecord(
                    module: "opencode-plugin-foo",
                    isEnabled: true,
                    source: .npm(module: "opencode-plugin-foo"),
                    installedAt: Date(),
                    requiresTrust: true
                )
            ],
            skills: [makeSkill(name: "noisy", isEnabled: false)]
        )

        let rendered = ManagedOpenCodeConfiguration.rendered(
            instructionPaths: ["/tmp/instructions.md"],
            permissionRules: [JSONValue.Member("bash", .string("allow"))],
            extensions: ExtensionRuntimeSnapshot(registry: registry)
        )

        // The enabled server is registered, the disabled one only silenced.
        XCTAssertTrue(rendered.contains("\"github\""))
        XCTAssertTrue(rendered.contains("https://example.com/mcp"))
        XCTAssertFalse(rendered.contains("notion_\\*"), "Patterns are written literally")
        XCTAssertTrue(rendered.contains("\"notion_*\""))
        XCTAssertTrue(rendered.contains("\"opencode-plugin-foo\""))
        XCTAssertTrue(rendered.contains("\"skill\""))
        XCTAssertTrue(rendered.contains("\"noisy\""))
        XCTAssertTrue(rendered.contains("\"deny\""))
        // `false` is the value that switches a tool off.
        XCTAssertTrue(rendered.contains("false"))
        // A remote server that uses OpenCode's own OAuth flow must not be told
        // `oauth: true`; the key's absence is what starts it.
        XCTAssertFalse(rendered.contains("\"oauth\""))

        let decoded = try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        XCTAssertNotNil(decoded, "The generated configuration has to be valid JSON")
        XCTAssertEqual((decoded?["tools"] as? [String: Any])?["notion_*"] as? Bool, false)
    }

    /// The permission rules do not depend on the extensions, and they do not
    /// depend on the approval level either: the level is applied at runtime, so the
    /// file the server reads is the same one whichever level is selected.
    func testAnEmptySnapshotWritesTheSchemaAndTheRoutedPermissionRules() throws {
        let rendered = ManagedOpenCodeConfiguration.rendered(
            instructionPaths: [],
            permissionRules: [],
            extensions: .empty
        )

        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        )

        XCTAssertEqual(decoded.keys.sorted(), ["$schema", "permission"])

        let permission = try XCTUnwrap(decoded["permission"] as? [String: Any])
        XCTAssertEqual(permission["*"] as? String, "ask")
        XCTAssertEqual(permission["bash"] as? String, "ask")
        XCTAssertEqual(permission["webfetch"] as? String, "ask")
        XCTAssertEqual(permission["external_directory"] as? String, "ask")
        XCTAssertEqual(permission["read"] as? String, "allow")

        // The level never appears in the file: writing it there is what used to
        // make changing it require a backend restart.
        XCTAssertNil(permission["fullAccess"])
        XCTAssertNil(permission["approveSafe"])
    }

    func testTheConfigurationIsWrittenWhereTheServerReadsIt() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try ManagedOpenCodeConfiguration.write(
            in: directory,
            instructionPaths: [],
            permissionRules: [],
            extensions: .empty
        )

        XCTAssertEqual(url.lastPathComponent, ManagedOpenCodeConfiguration.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    private func makeSkill(name: String, isEnabled: Bool) -> SkillRecord {
        SkillRecord(
            name: name,
            description: "Does \(name)",
            isEnabled: isEnabled,
            source: .manual,
            installedAt: Date(),
            path: "/tmp/\(name)/SKILL.md",
            isManaged: false
        )
    }
}

final class ExtensionTriggerTests: XCTestCase {
    func testAtOffersServersAndPluginsAndSlashOffersSkills() throws {
        let at = try XCTUnwrap(ExtensionTrigger.detected(in: "fix this @git"))
        XCTAssertEqual(at.kinds, [.mcp, .plugin])
        XCTAssertEqual(at.query, "git")

        let slash = try XCTUnwrap(ExtensionTrigger.detected(in: "review /code"))
        XCTAssertEqual(slash.kinds, [.skill])
        XCTAssertEqual(slash.query, "code")
    }

    func testTheTriggerHasToBeTheWordBeingTyped() {
        XCTAssertNil(
            ExtensionTrigger.detected(in: "mail me at foo@bar.com done"),
            "A word that is finished is not a trigger"
        )
        XCTAssertNil(ExtensionTrigger.detected(in: "2 / 3"))
        XCTAssertNil(ExtensionTrigger.detected(in: "no trigger here"))
        XCTAssertNil(ExtensionTrigger.detected(in: ""))
    }

    func testTheTriggerCarriesTheRangeItOccupies() throws {
        let text = "fix this @git"
        let trigger = try XCTUnwrap(ExtensionTrigger.detected(in: text))

        XCTAssertEqual(String(text[trigger.tokenRange]), "@git")
    }

    func testAnEmptyQueryListsEverything() throws {
        let trigger = try XCTUnwrap(ExtensionTrigger.detected(in: "@"))

        XCTAssertEqual(trigger.query, "")
        XCTAssertEqual(String("@"[trigger.tokenRange]), "@")
    }
}

final class GitHubReferenceTests: XCTestCase {
    func testTheFormsAUserPastesAreAllAccepted() {
        XCTAssertEqual(
            GitHubRepositoryReference.parse("https://github.com/anthropics/skills")?.slug,
            "anthropics/skills"
        )
        XCTAssertEqual(
            GitHubRepositoryReference.parse("anthropics/skills.git")?.slug,
            "anthropics/skills"
        )

        let deep = GitHubRepositoryReference.parse("anthropics/skills/pdf")
        XCTAssertEqual(deep?.slug, "anthropics/skills")
        XCTAssertEqual(deep?.subpath, "pdf")

        XCTAssertNil(GitHubRepositoryReference.parse("just-a-word"))
        XCTAssertNil(GitHubRepositoryReference.parse("   "))
    }

    /// Repositories put skills in `skills/`, `.claude/skills/` or nowhere in
    /// particular, so the tree decides instead of a guess.
    func testTheShallowestFolderNamedAfterTheSkillWins() {
        let tree = [
            "docs/code-review/SKILL.md",
            "skills/code-review/SKILL.md",
            "README.md"
        ]

        XCTAssertEqual(
            GitHubSkillFetcher.skillFolder(named: "code-review", subpath: nil, in: tree),
            "skills/code-review"
        )
    }

    func testAnExplicitSubpathWinsOverTheNameSearch() {
        let tree = [
            "skills/code-review/SKILL.md",
            "plugins/other/code-review/SKILL.md"
        ]

        XCTAssertEqual(
            GitHubSkillFetcher.skillFolder(
                named: "code-review",
                subpath: "plugins/other/code-review",
                in: tree
            ),
            "plugins/other/code-review"
        )

        XCTAssertNil(
            GitHubSkillFetcher.skillFolder(named: "missing", subpath: nil, in: tree)
        )
    }

    func testATreeWithoutASkillFileFindsNothing() {
        XCTAssertNil(
            GitHubSkillFetcher.skillFolder(named: "code-review", subpath: nil, in: ["src/main.swift"])
        )
    }
}

final class SkillInstallerTests: XCTestCase {
    func testAPathThatEscapesTheSkillFolderIsRefused() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("skills/code-review")

        XCTAssertThrowsError(
            try SkillInstaller.resolvedURL(
                forRelativePath: "../../etc/passwd",
                in: destination
            )
        )
        XCTAssertThrowsError(
            try SkillInstaller.resolvedURL(forRelativePath: "/etc/passwd", in: destination)
        )

        let nested = try SkillInstaller.resolvedURL(
            forRelativePath: "scripts/run.sh",
            in: destination
        )
        XCTAssertTrue(nested.path.hasSuffix("skills/code-review/scripts/run.sh"))
    }

    func testAnInstalledSkillIsValidatedBeforeAnythingIsWritten() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let installer = SkillInstaller(
            rootDirectoryURL: directory,
            transport: StubExtensionTransport(responses: [:])
        )

        let fetched = FetchedSkill(
            name: "code-review",
            repository: "anthropics/skills",
            files: [
                FetchedSkillFile(
                    relativePath: "SKILL.md",
                    content: Data("no frontmatter here".utf8)
                )
            ]
        )

        XCTAssertThrowsError(try installer.install(fetched: fetched, source: .manual)) { error in
            XCTAssertEqual(error as? SkillManifestError, .missingFrontmatter)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("code-review").path),
            "A skill that fails validation must not leave a folder behind"
        )
    }

    func testAnInstalledSkillKeepsItsNameDescriptionAndFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let installer = SkillInstaller(
            rootDirectoryURL: directory,
            transport: StubExtensionTransport(responses: [:])
        )

        let fetched = FetchedSkill(
            name: "code-review",
            repository: "anthropics/skills",
            files: [
                FetchedSkillFile(
                    relativePath: "SKILL.md",
                    content: Data(
                        """
                        ---
                        name: code-review
                        description: Reviews a diff properly.
                        ---

                        Look for real defects.
                        """.utf8
                    )
                ),
                FetchedSkillFile(
                    relativePath: "scripts/run.sh",
                    content: Data("echo hi".utf8)
                )
            ]
        )

        let record = try installer.install(fetched: fetched, source: .manual)

        XCTAssertEqual(record.name, "code-review")
        XCTAssertEqual(record.description, "Reviews a diff properly.")
        XCTAssertTrue(record.isManaged)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("code-review/scripts/run.sh").path
            )
        )
    }

    /// A re-install must leave exactly one version on disk, and a *failed*
    /// re-install must leave the version that was already working.
    func testAReinstallReplacesThePreviousVersionAndAFailedOneLeavesItAlone() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let installer = SkillInstaller(
            rootDirectoryURL: directory,
            transport: StubExtensionTransport(responses: [:]) 
        )

        let versionOne = FetchedSkill(
            name: "code-review",
            repository: "anthropics/skills",
            files: [
                FetchedSkillFile(relativePath: "SKILL.md", content: Data(manifestData.utf8)),
                FetchedSkillFile(relativePath: "scripts/run.sh", content: Data("echo v1".utf8))
            ]
        )
        try installer.install(fetched: versionOne, source: .manual)

        let staleScript = directory.appendingPathComponent("code-review/scripts/run.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleScript.path))

        let versionTwo = FetchedSkill(
            name: "code-review",
            repository: "anthropics/skills",
            files: [
                FetchedSkillFile(relativePath: "SKILL.md", content: Data(manifestData.utf8)),
                FetchedSkillFile(relativePath: "reference.md", content: Data("v2".utf8))
            ]
        )
        try installer.install(fetched: versionTwo, source: .manual)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staleScript.path),
            "A file the new version does not ship must not survive the install"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("code-review/reference.md").path
            )
        )

        // Now a version whose second file escapes the skill directory: the write
        // fails halfway through, and the working version stays exactly as it was.
        let brokenVersion = FetchedSkill(
            name: "code-review",
            repository: "anthropics/skills",
            files: [
                FetchedSkillFile(relativePath: "SKILL.md", content: Data(manifestData.utf8)),
                FetchedSkillFile(relativePath: "../../../escape.md", content: Data("bad".utf8))
            ]
        )

        XCTAssertThrowsError(try installer.install(fetched: brokenVersion, source: .manual))

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("code-review/reference.md").path
            ),
            "A failed install must not touch the version that was working"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("escape.md").path)
        )

        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".staging-") }
        XCTAssertTrue(leftovers.isEmpty, "Staging directories are cleaned up: \(leftovers)")
    }

    private var manifestData: String {
        """
        ---
        name: code-review
        description: Reviews a diff properly.
        ---

        Look for real defects.
        """
    }

    func testAFullInstallFetchesTheTreeAndThenTheSkillFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let tree = """
        {"tree":[
          {"path":"skills/code-review/SKILL.md","type":"blob"},
          {"path":"skills/code-review/reference.md","type":"blob"}
        ]}
        """

        let manifest = """
        ---
        name: code-review
        description: Reviews a diff.
        ---

        Body
        """

        let transport = StubExtensionTransport(
            responses: [
                "https://api.github.com/repos/anthropics/skills/git/trees/HEAD?recursive=1":
                    Data(tree.utf8),
                "https://raw.githubusercontent.com/anthropics/skills/HEAD/skills/code-review/SKILL.md":
                    Data(manifest.utf8),
                "https://raw.githubusercontent.com/anthropics/skills/HEAD/skills/code-review/reference.md":
                    Data("reference".utf8)
            ]
        )

        let installer = SkillInstaller(
            rootDirectoryURL: directory,
            transport: transport
        )

        let record = try await installer.install(
            skillNamed: "code-review",
            from: XCTUnwrap(GitHubRepositoryReference.parse("anthropics/skills")),
            source: .manual
        )

        XCTAssertEqual(record.name, "code-review")
        let requested = await transport.requestedURLs()
        XCTAssertTrue(requested.contains { $0.contains("git/trees") })
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("code-review/reference.md").path
            )
        )
    }

    func testAMissingSkillFileIsReportedAsNotFound() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transport = StubExtensionTransport(
            responses: [
                "https://api.github.com/repos/anthropics/skills/git/trees/HEAD?recursive=1":
                    Data(#"{"tree":[{"path":"README.md","type":"blob"}]}"#.utf8)
            ]
        )

        let installer = SkillInstaller(rootDirectoryURL: directory, transport: transport)

        do {
            _ = try await installer.install(
                skillNamed: "code-review",
                from: XCTUnwrap(GitHubRepositoryReference.parse("anthropics/skills")),
                source: .manual
            )
            XCTFail("Expected the install to be refused")
        } catch {
            XCTAssertEqual(error as? ExtensionFetchError, .notFound)
        }
    }
}

final class SkillsShClientTests: XCTestCase {
    func testTheDirectoryPayloadIsDecoded() throws {
        let payload = """
        {"skills":[
          {"id":"mattpocock/skills/code-review","skillID":"code-review","name":"code-review","installs":1234,"source":"mattpocock/skills"}
        ]}
        """

        let entries = try SkillsShClient.decode(Data(payload.utf8))

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, "mattpocock/skills/code-review")
        XCTAssertEqual(entries.first?.source, "mattpocock/skills")
        XCTAssertFalse(entries.first?.installsText.isEmpty ?? true)
    }

    func testAnUnreadablePayloadIsReportedInsteadOfCrashing() {
        XCTAssertThrowsError(try SkillsShClient.decode(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? ExtensionFetchError, .badResponse)
        }
    }
}

final class PluginCatalogTests: XCTestCase {
    func testTheNPMRegistryPayloadIsDecoded() throws {
        // `\\n` inside the JSON is an escape the decoder resolves, not a literal
        // newline: the payload has to be valid JSON before it can be tested.
        let payload = """
        {"objects":[
          {"package":{"name":"opencode-plugin-foo","description":"A  plugin\\nfor foo","version":"1.2.3","links":{"npm":"https://npmjs.com/x","homepage":"https://example.com"}}}
        ]}
        """

        let entries = try NPMRegistryClient.decode(Data(payload.utf8))

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.name, "opencode-plugin-foo")
        XCTAssertEqual(entries.first?.version, "1.2.3")
        XCTAssertEqual(entries.first?.homepage, "https://example.com")
        XCTAssertFalse(
            entries.first?.description.contains("\n") ?? true,
            "A multi-line description must not break the row"
        )
    }

    func testAnUnreadableCatalogResponseIsReported() {
        XCTAssertThrowsError(try NPMRegistryClient.decode(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? ExtensionFetchError, .badResponse)
        }
    }

    func testAPackageWithoutALinkStillDecodes() throws {
        let payload = #"{"objects":[{"package":{"name":"x","version":"1.0.0"}}]}"#

        let entries = try NPMRegistryClient.decode(Data(payload.utf8))

        XCTAssertEqual(entries.first?.name, "x")
        XCTAssertNil(entries.first?.homepage)
        XCTAssertEqual(entries.first?.description, "")
    }
}

@MainActor
final class PluginMarkTests: XCTestCase {
    func testTheInitialsSkipTheNoiseEveryPluginShares() {
        XCTAssertEqual(PluginMark.initials(for: "opencode-plugin-github"), "GI")
        XCTAssertEqual(PluginMark.initials(for: "@scope/opencode-plugin-skills"), "SK")
        XCTAssertEqual(PluginMark.initials(for: "@scope/thing"), "TH")
        XCTAssertEqual(PluginMark.initials(for: "my-plugin"), "MY")
    }

    func testSomethingUnreadableStillGetsAMark() {
        XCTAssertEqual(PluginMark.initials(for: "---"), "?")
        XCTAssertFalse(PluginMark.initials(for: "opencode").isEmpty)
    }
}

final class ProviderResponseDiagnosticsTests: XCTestCase {
    override func tearDown() {
        ProviderResponseDiagnostics.shared.reset()
        super.tearDown()
    }

    func testASnippetIsOneBoundedLine() {
        let body = "{\n  \"error\": {\n    \"message\": \"nope\"\n  }\n}"

        let snippet = ProviderResponseDiagnostics.snippet(from: body)

        XCTAssertFalse(snippet.contains("\n"))
        XCTAssertTrue(snippet.contains("nope"))
    }

    func testALongBodyIsTruncated() {
        let snippet = ProviderResponseDiagnostics.snippet(
            from: String(repeating: "a", count: 5_000)
        )

        XCTAssertLessThanOrEqual(
            snippet.count,
            ProviderResponseDiagnostics.maximumSnippetLength + 1
        )
        XCTAssertTrue(snippet.hasSuffix("…"))
    }

    /// The point of the side channel: the error the user reads names what came
    /// back instead of only saying that it could not be read.
    func testTheRecordedResponseReachesTheUserFacingMessage() {
        ProviderResponseDiagnostics.shared.reset()
        ProviderResponseDiagnostics.shared.record(
            provider: "OpenCode",
            statusCode: 400,
            body: #"{"error":{"message":"invalid model"}}"#
        )

        let message = AgentSessionError.unexpectedBackendResponse.message

        XCTAssertTrue(message.contains("HTTP 400"))
        XCTAssertTrue(message.contains("invalid model"))
    }
}

final class ExtensionTagInstructionTests: XCTestCase {
    func testAnUntaggedTurnSendsNoInstruction() {
        XCTAssertNil([ExtensionTag]().turnInstruction)
    }

    func testTagsAreNamedAndTheTurnIsToldNotToWander() throws {
        let instruction = try XCTUnwrap(
            [
                ExtensionTag(kind: .mcp, name: "github"),
                ExtensionTag(kind: .skill, name: "code-review")
            ].turnInstruction
        )

        XCTAssertTrue(instruction.contains("github"))
        XCTAssertTrue(instruction.contains("code-review"))
        XCTAssertTrue(instruction.contains("Do not reach for other installed extensions"))
        XCTAssertLessThan(
            instruction.count,
            600,
            "The tag has to cost a couple of lines, not a tool schema"
        )
    }

    func testTheModeAndSpeedInstructionsStillSurviveAlongsideTags() throws {
        let combined = try XCTUnwrap(
            AgentMode.plan.instructions(
                speedMode: .fast,
                extensionContext: [ExtensionTag(kind: .skill, name: "code-review")].turnInstruction
            )
        )

        XCTAssertTrue(combined.contains("PLAN MODE"))
        XCTAssertTrue(combined.contains("code-review"))
    }
}

final class ExtensionStoreTests: XCTestCase {
    @MainActor
    func testAddingAServerPersistsItAndEnablesIt() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = makeStore(directory: directory)

        XCTAssertTrue(
            store.addMCPServer(
                name: "github",
                definition: MCPDefinition(
                    transport: .remote,
                    url: "https://example.com/mcp"
                )
            )
        )

        XCTAssertEqual(store.registry.enabledMCPDefinitions.keys.sorted(), ["github"])
        XCTAssertEqual(store.contextSummary.activeMCPServers, 1)

        let reloaded = ExtensionRegistryStore(
            fileURL: directory.appendingPathComponent("extensions-registry.json")
        ).load()

        XCTAssertEqual(reloaded.mcpServers.map(\.name), ["github"])
    }

    @MainActor
    func testAServerWithoutATargetIsRefused() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = makeStore(directory: directory)

        XCTAssertFalse(
            store.addMCPServer(name: "broken", definition: MCPDefinition(transport: .local))
        )
        XCTAssertTrue(store.registry.mcpServers.isEmpty)
        XCTAssertEqual(store.status?.isFailure, true)
    }

    @MainActor
    func testDisablingAServerKeepsItListedAndSilencesIt() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = makeStore(directory: directory)
        _ = store.addMCPServer(
            name: "github",
            definition: MCPDefinition(transport: .remote, url: "https://example.com/mcp")
        )

        store.setMCPEnabled("github", false)

        XCTAssertEqual(store.registry.mcpServers.count, 1, "Switching off is not deleting")
        XCTAssertEqual(store.registry.silencedMCPToolPatterns, ["github_*": false])
        XCTAssertEqual(store.runtimeSnapshot.mcpServers.count, 0)
    }

    /// The user's own `opencode.json` servers reach the agent unless the app says
    /// otherwise, and the app can only say so by silencing them.
    func testInheritedServersAreListedButSwitchedOff() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let configURL = directory.appendingPathComponent("opencode.json")
        try Data(
            #"{"mcp":{"github":{"type":"remote","url":"https://example.com/mcp"}}}"#.utf8
        ).write(to: configURL)

        let registry = ExtensionRegistry.discovered(
            from: ExtensionRegistry(),
            catalog: [],
            globalConfig: GlobalOpenCodeConfigReader(configURLs: [configURL])
        )

        XCTAssertEqual(registry.mcpServers.map(\.name), ["github"])
        XCTAssertEqual(registry.mcpServers.first?.isInherited, true)
        XCTAssertEqual(
            registry.mcpServers.first?.isEnabled,
            false,
            "A server the user configured for their terminal must not be charged to every request"
        )
        XCTAssertEqual(registry.silencedMCPToolPatterns, ["github_*": false])
        XCTAssertTrue(registry.enabledMCPDefinitions.isEmpty)
    }

    /// The regression this pins: the server asks for the snapshot when it
    /// starts, which can be before the first `refresh()` — and a start that saw
    /// an empty picture loaded the user's own MCP servers with nothing silencing
    /// them.
    @MainActor
    func testDiscoveryHasAlreadyHappenedBeforeTheFirstServerStart() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let configURL = directory.appendingPathComponent("opencode.json")
        try Data(
            #"{"mcp":{"github":{"type":"remote","url":"https://example.com/mcp"}}}"#.utf8
        ).write(to: configURL)

        let store = ExtensionStore(
            registryStore: ExtensionRegistryStore(
                fileURL: directory.appendingPathComponent("extensions-registry.json")
            ),
            catalog: SkillsCatalogCache(catalog: SkillsCatalog(roots: [])),
            globalConfig: GlobalOpenCodeConfigReader(configURLs: [configURL]),
            applyConfiguration: { _ in }
        )

        XCTAssertEqual(
            store.runtimeSnapshot.silencedToolPatterns,
            ["github_*": false],
            "The snapshot must be complete before any refresh, because start may come first"
        )
        XCTAssertTrue(store.runtimeSnapshot.mcpServers.isEmpty)
    }

    @MainActor
    func testANewerRegistryIsIgnoredInsteadOfCrashingTheApp() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("extensions-registry.json")
        try Data(#"{"version":99,"mcpServers":[],"plugins":[],"skills":[]}"#.utf8)
            .write(to: fileURL)

        XCTAssertTrue(ExtensionRegistryStore(fileURL: fileURL).load().mcpServers.isEmpty)
    }

    @MainActor
    func testTheSnapshotHandedToTheAgentMatchesTheRegistry() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var applied: ExtensionRuntimeSnapshot?
        let store = ExtensionStore(
            registryStore: ExtensionRegistryStore(
                fileURL: directory.appendingPathComponent("extensions-registry.json")
            ),
            catalog: SkillsCatalogCache(catalog: SkillsCatalog(roots: [])),
            globalConfig: GlobalOpenCodeConfigReader(configURLs: []),
            applyConfiguration: { snapshot in applied = snapshot }
        )

        _ = store.addMCPServer(
            name: "github",
            definition: MCPDefinition(transport: .remote, url: "https://example.com/mcp")
        )
        await store.applyToAgent()

        XCTAssertEqual(applied?.mcpServers.keys.sorted(), ["github"])
    }

    /// Hermetic: no skills on this Mac and no user configuration are read, so a
    /// developer's own `opencode.json` cannot change what these tests assert.
    @MainActor
    private func makeStore(directory: URL) -> ExtensionStore {
        ExtensionStore(
            registryStore: ExtensionRegistryStore(
                fileURL: directory.appendingPathComponent("extensions-registry.json")
            ),
            catalog: SkillsCatalogCache(catalog: SkillsCatalog(roots: [])),
            globalConfig: GlobalOpenCodeConfigReader(configURLs: []),
            applyConfiguration: { _ in }
        )
    }
}

/// Answers the fetcher from a dictionary, and records what was asked for.
///
/// An actor rather than a locked class: the fetcher is called from concurrent
/// tasks, and the recorder has to be safe without blocking a cooperative thread.
actor StubExtensionTransport: ExtensionHTTPTransport {
    private let responses: [String: Data]
    private var requested: [String] = []

    init(responses: [String: Data]) {
        self.responses = responses
    }

    func requestedURLs() -> [String] {
        requested
    }

    func get(_ url: URL, headers: [String: String]) async throws -> ExtensionHTTPResponse {
        requested.append(url.absoluteString)

        guard let data = responses[url.absoluteString] else {
            throw ExtensionFetchError.notFound
        }

        return ExtensionHTTPResponse(statusCode: 200, data: data)
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgenticSidebarTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
