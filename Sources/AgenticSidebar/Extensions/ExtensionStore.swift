import Foundation
import Observation

/// The app's view of what the agent can reach, and the one place that changes it.
///
/// It owns three things that must stay in step, which is why they are not three
/// stores: the registry on disk, what the managed OpenCode server has been told,
/// and what the composer may offer behind `@` and `/`.
///
/// Nothing here loads an extension into the model's context. The MCP servers the
/// user enables are registered by OpenCode from the configuration this store
/// writes; the ones that are merely *known* are silenced by tool pattern, which
/// is the difference between a list of installed servers and a bill the model
/// pays on every request.
@MainActor
@Observable
final class ExtensionStore {
    private(set) var registry: ExtensionRegistry
    /// Skills found on disk, including the ones OpenCode would refuse to load.
    private(set) var catalog: [DiscoveredSkill] = []
    /// Results of the last skills.sh search.
    private(set) var searchResults: [SkillsShEntry] = []
    /// Results of the last plugin catalogue search.
    private(set) var pluginCatalog: [PluginCatalogEntry] = []
    /// One line about what is happening, or what went wrong.
    private(set) var status: ExtensionStatus?
    private(set) var isWorking = false

    private let registryStore: ExtensionRegistryStore
    private let catalogSource: SkillsCatalogCache
    /// The registry as it was last written, so an unchanged discovery does not
    /// rewrite the file (and re-encode the whole thing) on every appearance.
    private var lastPersistedRegistry: ExtensionRegistry?
    private let globalConfig: GlobalOpenCodeConfigReader
    private let skillsSh: SkillsShClient
    private let npm: NPMRegistryClient
    private let installer: SkillInstaller
    /// Writes the snapshot into the running (or next) server, and restarts the
    /// agent when the user asks for it.
    private let applyConfiguration: @MainActor (ExtensionRuntimeSnapshot) async -> Void
    /// Set by the app once the OpenCode settings exist: restarting the managed
    /// agent is that screen's job, not this store's.
    @ObservationIgnored var restartAgent: @MainActor () async -> Void
    /// The running server's client, when there is one. A closure rather than the
    /// runtime itself: the server is started and stopped by the settings screen,
    /// and this store must not keep a client that outlives its server.
    private let clientProvider: @MainActor () async -> (any OpenCodeClientProtocol)?

    init(
        registryStore: ExtensionRegistryStore = .live(),
        catalog: SkillsCatalogCache = SkillsCatalogCache(catalog: .live()),
        globalConfig: GlobalOpenCodeConfigReader = .live(),
        skillsSh: SkillsShClient = SkillsShClient(),
        npm: NPMRegistryClient = NPMRegistryClient(),
        installer: SkillInstaller = SkillInstaller(),
        applyConfiguration: @escaping @MainActor (ExtensionRuntimeSnapshot) async -> Void,
        restartAgent: @escaping @MainActor () async -> Void = {},
        clientProvider: @escaping @MainActor () async -> (any OpenCodeClientProtocol)? = { nil }
    ) {
        self.registryStore = registryStore
        self.catalogSource = catalog
        self.globalConfig = globalConfig
        self.skillsSh = skillsSh
        self.npm = npm
        self.installer = installer
        self.applyConfiguration = applyConfiguration
        self.restartAgent = restartAgent
        self.clientProvider = clientProvider

        // The stored registry is loaded here rather than only in `refresh()`: the
        // snapshot the server asks for at start time has to be right the first
        // time, and a start that raced the first `refresh()` would hand the managed
        // server an empty extension list — which means the user's own MCP servers,
        // loaded from their `opencode.json`, would arrive in the context window
        // with nothing silencing them. Nothing is written from `init`.
        //
        // Merging the user's own configuration is part of that promise and is a
        // single small file, so it happens here. The *skill* scan does not: it
        // reads every `SKILL.md` on disk, so it belongs off the main actor, and the
        // app awaits `refresh()` before starting the server. Discovery only ever
        // *adds* the skills it finds to the stored records, so an empty catalog
        // for those few milliseconds changes nothing the server sees.
        let stored = registryStore.load()
        self.registry = ExtensionRegistry.discovered(
            from: stored,
            catalog: [],
            globalConfig: globalConfig
        )
        self.lastPersistedRegistry = stored
    }

    // MARK: - Reading

    var contextSummary: ExtensionRegistry.ContextSummary {
        registry.contextSummary
    }

    /// Skills the app installed that are no longer on disk, so the list can say
    /// so instead of showing a row that does nothing.
    var missingManagedSkills: [SkillRecord] {
        let onDisk = Set(catalog.map(\.name))
        return registry.skills.filter { $0.isManaged && !onDisk.contains($0.name) }
    }

    /// Everything the composer offers for a trigger character.
    func suggestions(for kind: ExtensionKind, matching query: String) -> [ExtensionSuggestion] {
        registry.suggestions(matching: query).filter { $0.kind == kind }
    }

    /// The tags a turn may carry, in the order the popup shows them.
    var tagSuggestions: [ExtensionSuggestion] {
        registry.suggestions(matching: "")
    }

    // MARK: - Loading

    /// Reads the registry, rediscovers what is on disk, and tells the server
    /// what to load. Cheap enough to call on every appearance.
    func refresh() async {
        registry = registryStore.load()
        lastPersistedRegistry = registry
        await discover()
        await applyToAgent()
    }

    /// Re-reads the user's own configuration and the skills on disk.
    ///
    /// Servers the user configured for their terminal are listed but never
    /// edited: the app only decides whether their tools reach the model.
    ///
    /// The scan and the parse happen off the main actor, and the registry is only
    /// rewritten when discovery actually changed something.
    func discover() async {
        let scanned = await catalogSource.scan()
        catalog = scanned
        registry = ExtensionRegistry.discovered(
            from: registry,
            catalog: scanned,
            globalConfig: globalConfig
        )
        persistIfChanged()
    }

    /// Writes the configuration the server loads and hands the same snapshot to
    /// the server manager, so a restart picks it up without another write.
    func applyToAgent() async {
        await applyConfiguration(runtimeSnapshot)
    }

    var runtimeSnapshot: ExtensionRuntimeSnapshot {
        ExtensionRuntimeSnapshot(registry: registry)
    }

    /// Restarts the managed agent so a configuration change takes effect now.
    func restart() async {
        isWorking = true
        defer { isWorking = false }

        persist()
        await applyConfiguration(runtimeSnapshot)
        await restartAgent()
        status = .info("Agent restarted with the current extensions.")
    }

    // MARK: - MCP servers

    @discardableResult
    func addMCPServer(
        name: String,
        definition: MCPDefinition,
        source: ExtensionSource = .manual
    ) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, definition.isRunnable else {
            status = .failure(
                definition.isRunnable
                    ? "An MCP server needs a name."
                    : "An MCP server needs a command or an https URL."
            )
            return false
        }
        // Kabuk meta karakterleri komut tanımında yasaktır: sunucu doğrudan
        // çalıştırılır, kabuk üzerinden değil.
        if definition.transport == .local {
            let forbidden: Set<Character> = [";", "&", "|", ">", "<", "`", "$", "(", ")", "{", "}", "\\", "\n", "\r"]
            let joined = definition.command.joined(separator: " ")
            if joined.contains(where: { forbidden.contains($0) }) {
                status = .failure("Komut kabuk işleci içeremez; tek çalıştırılabilir ve argümanları yazın.")
                return false
            }
        }

        guard !registry.mcpServers.contains(where: { $0.name == trimmed && !$0.isInherited })
        else {
            status = .failure("“\(trimmed)” is already installed.")
            return false
        }

        registry.upsert(
            mcpServer: MCPServerRecord(
                name: trimmed,
                definition: definition,
                isEnabled: true,
                source: source,
                isInherited: false,
                installedAt: Date()
            )
        )
        persist()
        Task {
            await applyToAgent()
            if let client = await currentClient() {
                do {
                    _ = try await client.addMCPServer(name: trimmed, config: definition.openCodePayload)
                    status = .info("“\(trimmed)” added and loaded into agent.")
                } catch {
                    status = .info("“\(trimmed)” added. Restart the agent if needed to connect.")
                }
            } else {
                status = .info("“\(trimmed)” added. Will load when agent starts.")
            }
        }
        return true
    }

    func setMCPEnabled(_ name: String, _ isEnabled: Bool) {
        registry.setMCPEnabled(name, isEnabled)
        persist()
        Task {
            await applyToAgent()
            if let client = await currentClient() {
                if isEnabled {
                    if let record = registry.mcpServers.first(where: { $0.name == name }) {
                        _ = try? await client.addMCPServer(name: name, config: record.definition.openCodePayload)
                    }
                } else {
                    try? await client.disconnectMCPServer(name: name)
                }
            }
            status = .info(
                isEnabled
                    ? "“\(name)” enabled."
                    : "“\(name)” silenced."
            )
        }
    }

    func removeMCPServer(named name: String) {
        registry.removeMCP(named: name)
        persist()
        Task {
            await applyToAgent()
            if let client = await currentClient() {
                try? await client.disconnectMCPServer(name: name)
            }
            status = .info("“\(name)” removed.")
        }
    }

    /// What OpenCode says about each server it knows: connected, failed, or
    /// still needing an authorization the app has not been given yet.
    func mcpServerStatuses() async -> [String: OpenCodeMCPServerStatus] {
        guard let client = await currentClient() else {
            return [:]
        }

        return (try? await client.mcpServerStatuses()) ?? [:]
    }

    /// Asks OpenCode to start the OAuth flow for a remote server and hands back
    /// the page to open. The app never sees the token: OpenCode stores it.
    func authorizationURL(for name: String) async -> URL? {
        guard let client = await currentClient() else {
            status = .failure("Start the agent before authorizing “\(name)”.")
            return nil
        }

        do {
            let url = try await client.startMCPAuthorization(name: name)
            if url == nil {
                status = .info("“\(name)” did not ask for an authorization.")
            }
            return url
        } catch {
            status = .failure("“\(name)” could not start its authorization flow.")
            return nil
        }
    }

    func completeAuthorization(for name: String, code: String) async {
        guard
            let client = await currentClient(),
            !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            status = .failure("The authorization code is empty.")
            return
        }

        do {
            try await client.completeMCPAuthorization(name: name, code: code)
            status = .info("“\(name)” is authorized.")
        } catch {
            status = .failure("“\(name)” rejected that code.")
        }
    }

    // MARK: - Plugins

    @discardableResult
    func addPlugin(module: String, source: ExtensionSource = .manual) -> Bool {
        let trimmed = module.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = .failure("A plugin needs an npm module name or a file path.")
            return false
        }

        guard !registry.plugins.contains(where: { $0.module == trimmed }) else {
            status = .failure("“\(trimmed)” is already installed.")
            return false
        }

        registry.upsert(
            plugin: PluginRecord(
                module: trimmed,
                isEnabled: true,
                source: source,
                installedAt: Date(),
                requiresTrust: true
            )
        )
        persist()
        Task {
            await applyToAgent()
        }
        status = .info("“\(trimmed)” added. Restart the agent to load it.")
        return true
    }

    /// Fills the plugin catalogue. An empty query lists what the ecosystem
    /// publishes by default, so the screen is never an empty text field.
    func searchPlugins(_ query: String) async {
        isWorking = true
        defer { isWorking = false }

        do {
            pluginCatalog = try await npm.search(query)
            status =
                pluginCatalog.isEmpty
                ? .info("npm has nothing matching “\(query)”")
                : .info("\(pluginCatalog.count) plugins found.")
        } catch let error as ExtensionFetchError {
            pluginCatalog = []
            status = .failure(error.message)
        } catch {
            pluginCatalog = []
            status = .failure("npm could not be reached.")
        }
    }

    func setPluginEnabled(_ module: String, _ isEnabled: Bool) {
        registry.setPluginEnabled(module, isEnabled)
        persist()
        Task {
            await applyToAgent()
        }
        status = .info(
            isEnabled
                ? "“\(module)” will run on the next agent start."
                : "“\(module)” will not run."
        )
    }

    func removePlugin(module: String) {
        registry.removePlugin(module: module)
        persist()
        Task {
            await applyToAgent()
        }
        status = .info("“\(module)” removed.")
    }

    // MARK: - Skills

    func searchSkills(_ query: String) async {
        isWorking = true
        defer { isWorking = false }

        do {
            searchResults = try await skillsSh.search(query)
            status =
                searchResults.isEmpty
                ? .info("skills.sh has nothing matching “\(query)”.")
                : .info("\(searchResults.count) skills found.")
        } catch let error as ExtensionFetchError {
            searchResults = []
            status = .failure(error.message)
        } catch {
            searchResults = []
            status = .failure("skills.sh could not be reached.")
        }
    }

    /// Installs one directory of a repository and registers it, validating the
    /// manifest first so a skill OpenCode would refuse never lands on disk.
    func installSkill(named name: String, from repository: String) async {
        guard let reference = GitHubRepositoryReference.parse(repository) else {
            status = .failure("“\(repository)” is not an owner/repository pair.")
            return
        }

        isWorking = true
        defer { isWorking = false }

        let source = ExtensionSource.gitHub(repository: reference.slug)
        let record = await install(
            skillNamed: name,
            from: reference,
            source: source
        )
        await applyToAgent()
        status = record.map { .info("“\($0.name)” installed.") }
    }

    /// Installs the skill a skills.sh entry points at.
    func installSkill(entry: SkillsShEntry) async {
        let parts = entry.id.split(separator: "/").map(String.init)
        let repository: String
        let subpath: String?

        if parts.count >= 3 {
            repository = parts[0] + "/" + parts[1]
            let folder = parts[2...].joined(separator: "/")
            subpath = folder + "/" + entry.skillID
        } else {
            repository = entry.source
            subpath = nil
        }

        let text = subpath.map { repository + "/" + $0 } ?? repository
        guard let reference = GitHubRepositoryReference.parse(text) else {
            status = .failure("skills.sh entry “\(entry.id)” could not be read.")
            return
        }

        isWorking = true
        defer { isWorking = false }

        let record = await install(
            skillNamed: entry.skillID,
            from: reference,
            source: .skillsSh(source: entry.source, skillID: entry.skillID)
        )
        await applyToAgent()
        status = record.map { .info("“\($0.name)” installed from skills.sh.") }
    }

    func setSkillEnabled(_ name: String, _ isEnabled: Bool) {
        registry.setSkillEnabled(name, isEnabled)
        persist()
        Task {
            await applyToAgent()
        }
        status = .info(
            isEnabled
                ? "The agent will see “\(name)” again."
                : "“\(name)” is hidden from the agent."
        )
    }

    /// Deletes a skill the app installed. A skill the user keeps on their own
    /// disk is switched off instead of dropped from the list — dropping it would
    /// only last until the next discovery, and the files are not the app's to
    /// delete.
    func removeSkill(named name: String) async {
        guard let record = registry.skills.first(where: { $0.name == name }) else {
            return
        }

        guard record.isManaged else {
            setSkillEnabled(name, false)
            status = .info(
                "“\(name)” is hidden from the agent. Its files are your own, so they stay."
            )
            return
        }

        do {
            try installer.remove(skillNamed: name)
        } catch {
            status = .failure("“\(name)” could not be deleted.")
            return
        }

        registry.removeSkill(named: name)
        persist()
        await discover()
        await applyToAgent()
        status = .info("“\(name)” deleted.")
    }

    private func install(
        skillNamed name: String,
        from reference: GitHubRepositoryReference,
        source: ExtensionSource
    ) async -> SkillRecord? {
        do {
            let record = try await installer.install(
                skillNamed: name,
                from: reference,
                source: source
            )
            registry.upsert(skill: record)
            persist()
            await discover()
            return record
        } catch let error as SkillManifestError {
            status = .failure(error.message)
        } catch let error as ExtensionFetchError {
            status = .failure(error.message)
        } catch {
            status = .failure("“\(name)” could not be installed.")
        }

        return nil
    }

    // MARK: - Persistence

    private func persist() {
        registryStore.save(registry)
        lastPersistedRegistry = registry
    }

    /// Writes only when discovery produced a different registry.
    ///
    /// `ExtensionRegistry` is `Equatable` and the discovered dates are carried over
    /// from the stored record, so an unchanged library compares equal — and then a
    /// full JSON encode plus an atomic write is skipped.
    private func persistIfChanged() {
        guard registry != lastPersistedRegistry else {
            return
        }

        persist()
    }

    private func currentClient() async -> (any OpenCodeClientProtocol)? {
        await clientProvider()
    }
}

/// One line of feedback for the settings screen.
enum ExtensionStatus: Equatable, Sendable {
    case info(String)
    case failure(String)

    var message: String {
        switch self {
        case .info(let message), .failure(let message):
            message
        }
    }

    var isFailure: Bool {
        if case .failure = self {
            return true
        }
        return false
    }
}
