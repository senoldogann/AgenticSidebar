import Foundation

/// What the app wants the managed OpenCode server to load, flattened out of the
/// registry so the server layer never has to know about skills.sh, GitHub or the
/// Settings screen.
struct ExtensionRuntimeSnapshot: Equatable, Sendable {
    /// The servers whose tools should reach the model.
    var mcpServers: [String: MCPDefinition]
    /// The servers the user switched off, with their definitions intact.
    ///
    /// Silencing a server's tools is not enough to keep it from costing anything:
    /// OpenCode starts every server it knows about, so an off server still became
    /// a node or python process at every backend launch. Declaring it
    /// `enabled: false` keeps it from being started at all.
    var disabledMCPServers: [String: MCPDefinition]
    /// `"<server>_*": false` for every known server the user did not enable —
    /// the tool that keeps an unused MCP server out of the context window.
    var silencedToolPatterns: [String: Bool]
    var plugins: [String]
    /// Skills switched off in the app; OpenCode hides them from the agent.
    var deniedSkills: [String]

    static let empty = ExtensionRuntimeSnapshot(
        mcpServers: [:],
        disabledMCPServers: [:],
        silencedToolPatterns: [:],
        plugins: [],
        deniedSkills: []
    )

    init(
        mcpServers: [String: MCPDefinition],
        disabledMCPServers: [String: MCPDefinition] = [:],
        silencedToolPatterns: [String: Bool],
        plugins: [String],
        deniedSkills: [String]
    ) {
        self.mcpServers = mcpServers
        self.disabledMCPServers = disabledMCPServers
        self.silencedToolPatterns = silencedToolPatterns
        self.plugins = plugins
        self.deniedSkills = deniedSkills
    }

    init(registry: ExtensionRegistry) {
        self.init(
            mcpServers: registry.enabledMCPDefinitions,
            disabledMCPServers: registry.disabledMCPDefinitions,
            silencedToolPatterns: registry.silencedMCPToolPatterns,
            plugins: registry.enabledPlugins.map(\.module),
            deniedSkills: registry.deniedSkillNames
        )
    }

    var isEmpty: Bool {
        mcpServers.isEmpty
            && disabledMCPServers.isEmpty
            && silencedToolPatterns.isEmpty
            && plugins.isEmpty
            && deniedSkills.isEmpty
    }
}

/// The single writer of the app's OpenCode configuration.
///
/// OpenCode merges this file into the user's own `opencode.json`, which is why
/// the app can configure the agent without ever editing someone else's file — and
/// why switching an extension off here has to be expressed as an override
/// (`tools` patterns, `permission.skill`) rather than as an absence.
enum ManagedOpenCodeConfiguration {
    static let fileName = "managed-config.json"
    static let schemaURL = "https://opencode.ai/config.json"
    static let planAgentName = "agenticsidebar-readonly"

    /// Where the configuration lives for a given managed directory.
    ///
    /// This path is also the app's launch fingerprint: it is handed to every
    /// server the app starts as `OPENCODE_CONFIG`, and that is how a leftover of
    /// ours is told apart from a server the user started themselves.
    static func fileURL(in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(fileName)
    }

    /// Builds the configuration OpenCode reads, with empty sections left out.
    ///
    /// No approval level is a parameter here. The permission rules are the same
    /// whichever level is selected (``ToolApprovalPolicy/routedPermissionRules``)
    /// because the level is applied at runtime, per request — writing it into the
    /// file is what used to make changing it require a backend restart. Adding a
    /// policy argument back would quietly reintroduce that freeze.
    static func value(
        instructionPaths: [String],
        permissionRules: [JSONValue.Member],
        extensions: ExtensionRuntimeSnapshot
    ) -> JSONValue {
        var members: [(String, JSONValue)] = [("$schema", .string(schemaURL))]

        // The routed rules come first and the caller's own rules follow them.
        // OpenCode keeps the **last** matching rule, so a tool family that brings
        // its own policy (computer use) is the one that decides for its own tools.
        var permission = ToolApprovalPolicy.routedPermissionRules + permissionRules
        if !extensions.deniedSkills.isEmpty {
            // One member, not two. A JSON object cannot carry the same key twice
            // and OpenCode's parser keeps the last `skill` it reads, so appending
            // a second one for the denials silently threw away the routed
            // `skill: "allow"` — every skill then fell through to the catch-all
            // and raised a prompt the app answered itself.
            //
            // The denials are written after the allow because the same "last rule
            // wins" rule applies inside the object: a skill the user switched off
            // has to outrank the blanket allow, not the other way round.
            permission.removeAll { $0.key == "skill" }
            permission.append(
                JSONValue.Member(
                    "skill",
                    .object(
                        [("*", JSONValue.string("allow"))]
                            + extensions.deniedSkills
                            .sorted()
                            .map { ($0, JSONValue.string("deny")) }
                    )
                )
            )
        }

        if !permission.isEmpty {
            members.append(
                (
                    "permission",
                    .object(
                        permission.map { JSONValue.Member($0.key, $0.value) }
                    )
                )
            )
        }

        if !instructionPaths.isEmpty {
            members.append(
                ("instructions", .array(instructionPaths.map(JSONValue.string)))
            )
        }

        // A name can only be registered once: an enabled server wins, and the
        // disabled map is only there for the ones the registry did not hand over
        // as enabled.
        let enabledNames = Set(extensions.mcpServers.keys)
        let mcp = JSONValue.object(
            (
                extensions.mcpServers.map { ($0.key, $0.value, true) }
                    + extensions.disabledMCPServers
                    .filter { !enabledNames.contains($0.key) }
                    .map { ($0.key, $0.value, false) }
            )
            .sorted { $0.0 < $1.0 }
            .map { JSONValue.Member($0.0, mcpValue($0.1, isEnabled: $0.2)) }
        )
        if !mcp.isEmptyCollection {
            members.append(("mcp", mcp))
        }

        let tools = JSONValue.object(
            extensions.silencedToolPatterns
                .sorted { $0.key < $1.key }
                .map { JSONValue.Member($0.key, JSONValue.bool($0.value)) }
        )
        if !tools.isEmptyCollection {
            members.append(("tools", tools))
        }

        if !extensions.plugins.isEmpty {
            members.append(
                ("plugin", .array(extensions.plugins.sorted().map(JSONValue.string)))
            )
        }

        // The plan agent is a backend-enforced tool boundary, not just a prompt.
        // A catch-all deny includes plugins, subagents, shell and computer use;
        // only known read-only capabilities are re-enabled for this agent.
        let readOnlyPermissions = JSONValue.object([
            JSONValue.Member("*", .string("deny")),
            JSONValue.Member("read", .string("allow")),
            JSONValue.Member("glob", .string("allow")),
            JSONValue.Member("grep", .string("allow")),
            JSONValue.Member("list", .string("allow")),
            JSONValue.Member("lsp", .string("allow")),
            JSONValue.Member("question", .string("allow")),
            JSONValue.Member("websearch", .string("allow"))
        ])
        members.append(("agent", .object([
            JSONValue.Member(planAgentName, .object([
                JSONValue.Member("description", .string("Read-only planning without file or host mutations")),
                JSONValue.Member("mode", .string("primary")),
                JSONValue.Member("permission", readOnlyPermissions)
            ]))
        ])))

        return .object(members)
    }

    static func rendered(
        instructionPaths: [String],
        permissionRules: [JSONValue.Member],
        extensions: ExtensionRuntimeSnapshot
    ) -> String {
        value(
            instructionPaths: instructionPaths,
            permissionRules: permissionRules,
            extensions: extensions
        )
        .rendered + "\n"
    }

    /// Writes the configuration into the managed working directory.
    @discardableResult
    static func write(
        in directoryURL: URL,
        instructionPaths: [String],
        permissionRules: [JSONValue.Member],
        extensions: ExtensionRuntimeSnapshot
    ) throws -> URL {
        let fileURL = fileURL(in: directoryURL)
        let contents = rendered(
            instructionPaths: instructionPaths,
            permissionRules: permissionRules,
            extensions: extensions
        )

        // A remote MCP server's auth headers and environment are copied into this
        // file by design, so it and the directory holding it are kept private
        // rather than left at the process umask's 0644/0755.
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        return fileURL
    }

    /// Bir MCP girdisi, çalışan sunucuya `POST /mcp` ile gönderilen yükün
    /// aynısından üretilir; ikisi birbirinden sapamaz.
    ///
    /// Kapalı bir girdi iskeletini (komut/URL/cwd/timeout) korur ve
    /// `enabled: false` ekler: iskelet girdiyi tek başına geçerli kılar (böylece
    /// uygulamanın hiç dokunmadığı, kullanıcının kendi yapılandırmasındaki aynı
    /// sunucuyu geçersiz kılar), bayrak ise OpenCode'un ardındaki süreci
    /// başlatmasını engeller. Sırlar dosyaya hiç ulaşmaz: önce tanım
    /// redakte edilir, sır anahtarları ise açıkça boş nesne olarak geri yazılır;
    /// böylece derin birleştirme yapan bir okuyucu, kullanıcının kendi
    /// dosyasındaki sırları bu girdinin altında yaşatamaz. Tam tanım kayıt
    /// defterinde durur; yeniden açma sırları oradan geri getirir.
    private static func mcpValue(
        _ definition: MCPDefinition,
        isEnabled: Bool = true
    ) -> JSONValue {
        let effective = isEnabled ? definition : definition.redactedForDisabled()
        let payload = JSONValue(encoding: effective.openCodePayload)
            ?? JSONValue.object([JSONValue.Member]())

        guard !isEnabled, case .object(var members) = payload else {
            return payload
        }

        members.removeAll { $0.key == "enabled" }
        members.append(JSONValue.Member("enabled", .bool(false)))
        members.removeAll { $0.key == "environment" }
        members.append(JSONValue.Member("environment", .object([JSONValue.Member]())))
        if effective.transport == .remote {
            members.removeAll { $0.key == "headers" }
            members.append(JSONValue.Member("headers", .object([JSONValue.Member]())))
        }
        return .object(members)
    }
}
