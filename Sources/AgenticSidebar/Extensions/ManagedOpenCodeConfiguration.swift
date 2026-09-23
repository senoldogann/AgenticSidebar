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
/// OpenCode bu dosyayı kullanıcının kendi `opencode.json` dosyasıyla birleştirir
/// ve çakışan anahtarda BU dosya kazanır (opencode 1.18.31'de `debug config`
/// ile doğrulandı: managed `bash: ask` + genel `bash: allow` = efektif `ask`).
/// Bu yüzden uygulama başkasının dosyasına dokunmadan ajanı yapılandırır; bir
/// uzantıyı kapatmak da yoklukla değil ezici kuralla (`tools` desenleri,
/// `permission.skill`) anlatılır. Uyarı eşiği için önemli sonuç: genel
/// dosyadaki bir kural, ancak burada karşılığı YOKSA davranışa etki eder.
enum ManagedOpenCodeConfiguration {
    static let fileName = "managed-config.json"
    static let schemaURL = "https://opencode.ai/config.json"
    /// Bu uygulamanın davranışını doğruladığı OpenCode sürümü: izin/araç
    /// şeması bu sürümde sabitlendi (`debug config` ile doğrulandı). Çalışan
    /// sürücü farklıysa başlatma engellenmez, yalnızca uyarı kaydedilir
    /// (`validateRuntimeVersion`).
    static let expectedOpenCodeVersion = "1.18.31"
    static let planAgentName = "agenticsidebar-readonly"
    /// Salt-okunur birincil ajanın analiz delegasyonu için tek hedefi:
    /// yazma yetkisi olmayan araştırma alt-ajanı.
    static let researchAgentName = "agenticsidebar-research"

    /// Where the configuration lives for a given managed directory.
    ///
    /// This path is also the app's launch fingerprint: it is handed to every
    /// server the app starts as `OPENCODE_CONFIG`, and that is how a leftover of
    /// ours is told apart from a server the user started themselves.
    static func fileURL(in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(fileName)
    }

    /// Çalışan OpenCode sürücüsünün beklenen sürümle uyuşup uyuşmadığını
    /// denetler. Uyuşmazlık yalnızca uyarı olarak kaydedilir: eski/yeni bir
    /// sürücüyle açılışı engellemek, kullanıcıyı çalışamaz bırakır; ama
    /// sessizce geçmek de şema kaymalarını teşhis edilemez yapar.
    ///
    /// - Returns: Sürümler uyuşuyorsa `true`.
    @discardableResult
    static func validateRuntimeVersion(_ actual: String?) -> Bool {
        guard let actual, !actual.isEmpty else {
            AppLog.openCode.error(
                "OpenCode version is unreadable; expected \(expectedOpenCodeVersion, privacy: .public)"
            )
            return false
        }
        guard actual == expectedOpenCodeVersion else {
            AppLog.openCode.warning(
                "OpenCode version mismatch: expected \(expectedOpenCodeVersion, privacy: .public), running \(actual, privacy: .public)"
            )
            return false
        }
        return true
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
            (extensions.mcpServers.map { ($0.key, $0.value, true) }
                + extensions.disabledMCPServers
                .filter { !enabledNames.contains($0.key) }
                .map { ($0.key, $0.value, false) })
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

        // The plan/review/exam/ask agent is a backend-enforced tool boundary, not just
        // a prompt. A catch-all deny blocks file mutations, shell and computer
        // use: read-only modes must propose, inspect and research — never mutate,
        // not even through shell. `edit`/`write`/`patch`/`multiedit`/`bash` stay
        // denied via `*` on purpose.
        // `task` asks so every delegation surfaces as an approval request: the
        // primary agent's description names the read-only research subagent below
        // as the sole delegation target, and the app auto-approves only that
        // target — any other target (a model disobeying the directive and
        // spawning a writable subagent) is rejected instead of running silently.
        // That subagent itself denies `task`, so no chain can reach a writable
        // agent. (OpenCode cannot scope `task` to one subagent at the config
        // level; scoping is enforced by the app's approval layer, which sees
        // the delegation target.)
        // `external_directory` is allowed so attachments and out-of-project
        // sources can be read during review; writes stay impossible because every
        // mutation tool above is denied.
        var primaryMembers = readOnlyBaseMembers(taskRule: "ask")
        primaryMembers.append(skillMember(deniedSkills: extensions.deniedSkills))
        let readOnlyPermissions = JSONValue.object(primaryMembers)
        var researchMembers = readOnlyBaseMembers(taskRule: "deny")
        researchMembers.append(skillMember(deniedSkills: extensions.deniedSkills))
        let researchPermissions = JSONValue.object(researchMembers)
        members.append(
            (
                "agent",
                .object([
                    JSONValue.Member(
                        planAgentName,
                        .object([
                            JSONValue.Member(
                                "description",
                                .string(
                                    "Read-only planning, review, exam and ask without file or host mutations; analysis may only be delegated to \(researchAgentName)"
                                )),
                            JSONValue.Member("mode", .string("primary")),
                            JSONValue.Member("permission", readOnlyPermissions),
                        ])),
                    JSONValue.Member(
                        researchAgentName,
                        .object([
                            JSONValue.Member(
                                "description",
                                .string(
                                    "Read-only research subagent for analysis delegation; cannot mutate files or spawn further subagents")),
                            JSONValue.Member("mode", .string("subagent")),
                            JSONValue.Member("permission", researchPermissions),
                        ])),
                ])
            ))

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

    /// The shared read-only tool boundary. Only `taskRule` differs: the primary
    /// read-only agent asks on delegation (the app approves only the research
    /// subagent below), the research subagent denies (no delegation chains into
    /// writable agents).
    private static func readOnlyBaseMembers(taskRule: String) -> [JSONValue.Member] {
        [
            JSONValue.Member("*", .string("deny")),
            JSONValue.Member("read", .string("allow")),
            JSONValue.Member("glob", .string("allow")),
            JSONValue.Member("grep", .string("allow")),
            JSONValue.Member("list", .string("allow")),
            JSONValue.Member("lsp", .string("allow")),
            JSONValue.Member("question", .string("allow")),
            JSONValue.Member("websearch", .string("allow")),
            // Salt-okunur turda ağ ve proje-dışı okuma onaydan geçer:
            // `allow` olsaydı keyfi beceri içeriği ve dış kaynaklar
            // sorulmadan tura girerdi.
            JSONValue.Member("webfetch", .string("ask")),
            JSONValue.Member("todowrite", .string("allow")),
            JSONValue.Member("task", .string(taskRule)),
            JSONValue.Member("external_directory", .string("ask")),
        ]
    }

    /// Tek `skill` üyesi: JSON nesnesi aynı anahtarı iki kez taşıyamaz ve
    /// OpenCode okuduğu son `skill` anahtarını tutar; battaniye izinle
    /// kapatmalar bu yüzden tek üyede birleşir (önce izin, sonra retler —
    /// içeride de son kural kazanır).
    private static func skillMember(deniedSkills: [String]) -> JSONValue.Member {
        // Salt-okunur ajanlarda battaniye `ask`: beceri, tura keyfi
        // içerik/talimat taşıyabildiği için onaysız yüklenmez.
        if deniedSkills.isEmpty {
            return JSONValue.Member("skill", .string("ask"))
        }
        return JSONValue.Member(
            "skill",
            .object(
                [("*", JSONValue.string("ask"))]
                    + deniedSkills
                    .sorted()
                    .map { ($0, JSONValue.string("deny")) }
            )
        )
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
        let payload =
            JSONValue(encoding: effective.openCodePayload)
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
