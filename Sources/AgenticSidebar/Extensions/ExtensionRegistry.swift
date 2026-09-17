import Foundation

/// Everything the user has installed, and whether it is allowed to reach the
/// model.
///
/// This is the app's own book, not OpenCode's: OpenCode is told only about the
/// *active* part of it. Keeping the full picture here is what makes it possible
/// to list an extension, explain what it would cost, and leave it switched off
/// without deleting anything.
struct ExtensionRegistry: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var mcpServers: [MCPServerRecord]
    var plugins: [PluginRecord]
    var skills: [SkillRecord]

    init(
        version: Int = ExtensionRegistry.currentVersion,
        mcpServers: [MCPServerRecord] = [],
        plugins: [PluginRecord] = [],
        skills: [SkillRecord] = []
    ) {
        self.version = version
        self.mcpServers = mcpServers
        self.plugins = plugins
        self.skills = skills
    }

    // MARK: - Queries

    var enabledMCPServers: [MCPServerRecord] {
        mcpServers.filter(\.isEnabled)
    }

    var enabledPlugins: [PluginRecord] {
        plugins.filter(\.isEnabled)
    }

    var enabledSkills: [SkillRecord] {
        skills.filter(\.isEnabled)
    }

    /// The MCP servers whose tools should reach the model.
    var enabledMCPDefinitions: [String: MCPDefinition] {
        enabledMCPServers.reduce(into: [:]) { result, record in
            guard record.definition.isRunnable else {
                return
            }
            result[record.name] = record.definition
        }
    }

    /// The MCP servers that are switched off, definitions and all.
    ///
    /// They are handed to the configuration so it can declare them
    /// `enabled: false`. Without that, OpenCode starts every server it knows about
    /// — the tools being silenced keeps them out of the context window but not out
    /// of memory, so an unused server was still a node or python process at every
    /// launch.
    var disabledMCPDefinitions: [String: MCPDefinition] {
        mcpServers
            .filter { !$0.isEnabled && $0.definition.isRunnable }
            .reduce(into: [:]) { result, record in
                result[record.name] = record.definition
            }
    }

    /// Tool patterns that switch off every known-but-inactive MCP server.
    ///
    /// This is the context gate. OpenCode registers an MCP server's tools whether
    /// or not the model ever calls one, so a server the user did not turn on has
    /// to be silenced by name — including one inherited from their own
    /// `opencode.json`, which the app never edits.
    var silencedMCPToolPatterns: [String: Bool] {
        mcpServers
            .filter { !$0.isEnabled }
            .reduce(into: [:]) { result, record in
                result["\(record.name)_*"] = false
            }
    }

    /// Skills the user switched off.
    ///
    /// OpenCode hides a denied skill from the agent entirely, which is how a
    /// skill that lives in the user's own `~/.claude/skills` can be quieted
    /// without touching their files.
    var deniedSkillNames: [String] {
        skills.filter { !$0.isEnabled }.map(\.name)
    }

    /// What the composer can offer behind `@` and `/`.
    ///
    /// Only active extensions are listed: offering something that cannot reach
    /// the model would be a lie, and the point of the tag is that it does.
    func suggestions(matching query: String) -> [ExtensionSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()

        let candidates: [ExtensionSuggestion] =
            enabledMCPServers.map {
                ExtensionSuggestion(
                    kind: .mcp,
                    name: $0.name,
                    detail: $0.definition.summary
                )
            }
            + enabledPlugins.map {
                ExtensionSuggestion(kind: .plugin, name: $0.module, detail: $0.source.displayName)
            }
            + enabledSkills.map {
                ExtensionSuggestion(kind: .skill, name: $0.name, detail: $0.description)
            }

        guard !trimmed.isEmpty else {
            return candidates
        }

        return candidates
            .filter {
                $0.name.lowercased().contains(trimmed)
                    || $0.detail.lowercased().contains(trimmed)
            }
            .sorted { left, right in
                let leftPrefix = left.name.lowercased().hasPrefix(trimmed)
                let rightPrefix = right.name.lowercased().hasPrefix(trimmed)

                if leftPrefix != rightPrefix {
                    return leftPrefix
                }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    /// A summary of what the next request will carry, for the Settings header.
    var contextSummary: ContextSummary {
        ContextSummary(
            knownMCPServers: mcpServers.count,
            activeMCPServers: enabledMCPServers.count,
            activePlugins: enabledPlugins.count,
            installedSkills: skills.count,
            activeSkills: enabledSkills.count
        )
    }

    struct ContextSummary: Equatable, Sendable {
        let knownMCPServers: Int
        let activeMCPServers: Int
        let activePlugins: Int
        let installedSkills: Int
        let activeSkills: Int
    }

    // MARK: - Mutation

    /// The registry as it looks after looking at the machine.
    ///
    /// A pure function of (what is stored, what is on disk, what the user's own
    /// configuration says) so it can run from `init` as well as from a refresh:
    /// the first server start must see the same picture as the fifth.
    ///
    /// Servers the user configured for their terminal are listed but never
    /// edited, and arrive switched **off** — the app's whole point is that an
    /// unused server costs nothing.
    static func discovered(
        from stored: ExtensionRegistry,
        catalog: [DiscoveredSkill],
        globalConfig: GlobalOpenCodeConfigReader
    ) -> ExtensionRegistry {
        var updated = stored
        updated.removeInheritedMCPServers()

        for (name, definition) in globalConfig.mcpServers() {
            updated.upsert(
                mcpServer: MCPServerRecord(
                    name: name,
                    definition: definition,
                    isEnabled: false,
                    source: .manual,
                    isInherited: true,
                    installedAt: stored.mcpServers.first { $0.name == name }?.installedAt
                        ?? Date()
                )
            )
        }

        for plugin in globalConfig.pluginModules() {
            updated.upsert(
                plugin: PluginRecord(
                    module: plugin,
                    isEnabled: true,
                    source: .manual,
                    installedAt: stored.plugins.first { $0.module == plugin }?.installedAt
                        ?? Date(),
                    requiresTrust: true
                )
            )
        }

        for skill in catalog where skill.isLoadable {
            let known = stored.skills.first { $0.name == skill.name }

            updated.upsert(
                skill: SkillRecord(
                    name: skill.name,
                    description: skill.description ?? "",
                    isEnabled: known?.isEnabled ?? true,
                    source: known?.source ?? .manual,
                    installedAt: known?.installedAt ?? Date(),
                    path: skill.path,
                    isManaged: skill.isManaged
                )
            )
        }

        return updated
    }

    mutating func upsert(mcpServer record: MCPServerRecord) {
        if let index = mcpServers.firstIndex(where: { $0.name == record.name }) {
            // The user's choice survives a rediscovery of the same server.
            var updated = record
            updated.isEnabled = mcpServers[index].isEnabled
            mcpServers[index] = updated
        } else {
            mcpServers.append(record)
        }
    }

    mutating func upsert(plugin record: PluginRecord) {
        if let index = plugins.firstIndex(where: { $0.module == record.module }) {
            var updated = record
            updated.isEnabled = plugins[index].isEnabled
            plugins[index] = updated
        } else {
            plugins.append(record)
        }
    }

    mutating func upsert(skill record: SkillRecord) {
        if let index = skills.firstIndex(where: { $0.name == record.name }) {
            var updated = record
            updated.isEnabled = skills[index].isEnabled
            skills[index] = updated
        } else {
            skills.append(record)
        }
    }

    mutating func setMCPEnabled(_ name: String, _ isEnabled: Bool) {
        guard let index = mcpServers.firstIndex(where: { $0.name == name }) else {
            return
        }
        mcpServers[index].isEnabled = isEnabled
    }

    mutating func setPluginEnabled(_ module: String, _ isEnabled: Bool) {
        guard let index = plugins.firstIndex(where: { $0.module == module }) else {
            return
        }
        plugins[index].isEnabled = isEnabled
    }

    mutating func setSkillEnabled(_ name: String, _ isEnabled: Bool) {
        guard let index = skills.firstIndex(where: { $0.name == name }) else {
            return
        }
        skills[index].isEnabled = isEnabled
    }

    mutating func removeMCP(named name: String) {
        mcpServers.removeAll { $0.name == name }
    }

    mutating func removePlugin(module: String) {
        plugins.removeAll { $0.module == module }
    }

    mutating func removeSkill(named name: String) {
        skills.removeAll { $0.name == name }
    }

    /// Forgets every server the app did not install itself, so a rediscovery
    /// starts from the user's own configuration again.
    mutating func removeInheritedMCPServers() {
        mcpServers.removeAll(where: \.isInherited)
    }
}

/// JSON persistence for the extension registry.
///
/// Written atomically next to the managed OpenCode configuration, in the same
/// application-support folder the app already owns. A damaged file is kept
/// aside rather than discarded: the user can still see what they had.
struct ExtensionRegistryStore: Sendable {
    let fileURL: URL

    private var fileManager: FileManager {
        .default
    }

    static func live() -> ExtensionRegistryStore {
        ExtensionRegistryStore(
            fileURL: ManagedOpenCodeServerManager.managedWorkingDirectoryURL()
                .appendingPathComponent("extensions-registry.json")
        )
    }

    /// Returns the stored registry, or an empty one when there is nothing usable.
    func load() -> ExtensionRegistry {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return ExtensionRegistry()
        }

        guard let data = fileManager.contents(atPath: fileURL.path) else {
            AppLog.extensions.error("Extension registry is unreadable; starting empty")
            // Same policy as every other unusable file here: keep it aside, so the
            // next save cannot irreversibly replace something recoverable.
            moveAside()
            return ExtensionRegistry()
        }

        do {
            let registry = try Self.decoder.decode(ExtensionRegistry.self, from: data)
            guard registry.version <= ExtensionRegistry.currentVersion else {
                AppLog.extensions.error(
                    "Extension registry was written by a newer version; starting empty"
                )
                return ExtensionRegistry()
            }
            return registry
        } catch {
            AppLog.extensions.error(
                "Extension registry could not be decoded; keeping it aside"
            )
            moveAside()
            return ExtensionRegistry()
        }
    }

    func save(_ registry: ExtensionRegistry) {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try Self.encoder.encode(registry)
            try data.write(to: fileURL, options: .atomic)
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            AppLog.extensions.error(
                "Extension registry could not be written: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func moveAside() {
        let damagedURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("corrupt.json")

        try? fileManager.removeItem(at: damagedURL)
        try? fileManager.moveItem(at: fileURL, to: damagedURL)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
