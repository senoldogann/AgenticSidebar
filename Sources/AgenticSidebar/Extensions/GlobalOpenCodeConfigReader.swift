import Foundation

/// Reads — never writes — the user's own OpenCode configuration.
///
/// The managed server merges that file with the app's, so every MCP server the
/// user configured for their terminal is also loaded for the sidebar's agent and
/// charges its tools to every request. The app cannot edit someone else's config
/// to stop that; it can only name the servers in its own configuration and
/// switch their tools off, which is what this reader exists for.
struct GlobalOpenCodeConfigReader: Sendable {
    let configURLs: [URL]

    /// `FileManager` is not `Sendable`, so the reader borrows the shared one
    /// rather than storing it; the URLs are what make it testable.
    private var fileManager: FileManager {
        .default
    }

    init(configURLs: [URL]) {
        self.configURLs = configURLs
    }

    static func live() -> GlobalOpenCodeConfigReader {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configDirectory = home.appendingPathComponent(".config/opencode", isDirectory: true)
        let altConfigDirectory = home.appendingPathComponent(".opencode", isDirectory: true)

        return GlobalOpenCodeConfigReader(
            configURLs: [
                configDirectory.appendingPathComponent("opencode.json"),
                configDirectory.appendingPathComponent("opencode.jsonc"),
                altConfigDirectory.appendingPathComponent("opencode.json"),
                altConfigDirectory.appendingPathComponent("opencode.jsonc"),
            ]
        )
    }

    /// Harici dosyada bulunan kurallar.
    ///
    /// Bu ham okumadır: dosyanın yazdığını aynen verir. Davranışa gerçekten
    /// etki eden kurallar için `effectiveGlobalPermissionOverrides(managedKeys:)`
    /// kullanılır — managed dosyanın karşılığı olan anahtarlar etkisizdir.
    /// `permission` tek biçim değildir: `"bash": "allow"` yanında
    /// `"bash": {"*": "allow"}` gibi desen-haritaları da yazılır. İkincisi
    /// eskiden sessizce atlanıyordu; uyarı kaybolurken ezme sürüyordu.
    /// Üst seviye `tools` haritası ve `agent.<ad>.permission` da aynı
    /// öncelikle uygulanır, o yüzden hepsi burada toplanır.
    struct GlobalPermissionOverride: Equatable, Sendable {
        let rules: [String: String]
        let complexPermissionKeys: [String]
        let toolRules: [String: String]
        let agentRules: [String: String]
        let sourceURL: URL

        var isEmpty: Bool {
            rules.isEmpty && complexPermissionKeys.isEmpty && toolRules.isEmpty && agentRules.isEmpty
        }

        /// Uyarı satırında gösterilecek tek satırlık özet.
        var displayText: String {
            var parts = rules.map { "\($0.key): \($0.value)" }
            parts += complexPermissionKeys.sorted().map { "\($0): (custom rules)" }
            parts += toolRules.map { "tools.\($0.key): \($0.value)" }
            parts += agentRules.map { "agent.\($0.key): \($0.value)" }
            return parts.sorted().joined(separator: ", ")
        }

        /// Managed dosyanın karşılığını yazdığı kuralları eleyip yalnız
        /// davranışa gerçekten etki edeni bırakır.
        func excluding(managedKeys: ManagedPermissionKeys) -> GlobalPermissionOverride {
            GlobalPermissionOverride(
                rules: rules.filter { !managedKeys.permission.contains($0.key) },
                complexPermissionKeys: complexPermissionKeys.filter {
                    !managedKeys.permission.contains($0)
                },
                toolRules: toolRules.filter { !managedKeys.tools.contains($0.key) },
                agentRules: agentRules.filter { !managedKeys.agents.contains($0.key) },
                sourceURL: sourceURL
            )
        }
    }

    /// Managed dosyanın (`OPENCODE_CONFIG`) karar verdiği izin anahtarları.
    ///
    /// Deneyle doğrulandı (opencode 1.18.31): `OPENCODE_CONFIG` dosyası ile
    /// kullanıcının genel dosyası birleştirilir ve çakışan anahtarda managed
    /// dosya kazanır. Bu yüzden genel dosyadaki bir kural, ancak managed
    /// dosyada karşılığı YOKSA davranışa etki eder; karşılığı varsa genel
    /// değer etkisizdir ve uyarıda yeri yoktur.
    struct ManagedPermissionKeys: Equatable, Sendable {
        var permission: Set<String>
        var tools: Set<String>
        /// `"ajanadı.anahtar"` biçiminde düzleştirilmiş ajan izin anahtarları.
        var agents: Set<String>

        static let empty = ManagedPermissionKeys(permission: [], tools: [], agents: [])
    }

    /// Permission rules declared in the user's global configuration files,
    /// along with the file URL they were read from.
    func globalPermissionOverrides() -> GlobalPermissionOverride? {
        for url in configURLs {
            guard
                fileManager.fileExists(atPath: url.path),
                let raw = try? String(contentsOf: url, encoding: .utf8),
                let object = Self.decodeObject(raw)
            else {
                continue
            }

            var rules: [String: String] = [:]
            var complexKeys: [String] = []
            if let permissions = object["permission"] as? [String: Any] {
                for (key, value) in permissions {
                    if let str = value as? String {
                        rules[key] = str
                    } else if let boolVal = value as? Bool {
                        rules[key] = boolVal ? "allow" : "deny"
                    } else {
                        complexKeys.append(key)
                    }
                }
            }

            var toolRules: [String: String] = [:]
            if let tools = object["tools"] as? [String: Any] {
                for (key, value) in tools {
                    if let str = value as? String {
                        toolRules[key] = str
                    } else if let boolVal = value as? Bool {
                        toolRules[key] = boolVal ? "allow" : "deny"
                    } else {
                        toolRules[key] = "custom"
                    }
                }
            }

            var agentRules: [String: String] = [:]
            if let agents = object["agent"] as? [String: Any] {
                for (agentName, agentValue) in agents {
                    guard let agentObject = agentValue as? [String: Any] else {
                        continue
                    }
                    let permissionMap = agentObject["permission"] as? [String: Any] ?? [:]
                    for (key, value) in permissionMap {
                        if let str = value as? String {
                            agentRules["\(agentName).\(key)"] = str
                        } else if let boolVal = value as? Bool {
                            agentRules["\(agentName).\(key)"] = boolVal ? "allow" : "deny"
                        } else {
                            agentRules["\(agentName).\(key)"] = "custom"
                        }
                    }
                }
            }

            let override = GlobalPermissionOverride(
                rules: rules,
                complexPermissionKeys: complexKeys.sorted(),
                toolRules: toolRules,
                agentRules: agentRules,
                sourceURL: url
            )
            if !override.isEmpty {
                return override
            }
        }
        return nil
    }

    /// Davranışa gerçekten etki eden harici kurallar.
    ///
    /// Managed dosyanın karşılığını yazdığı anahtarlar elenir; geriye kalan
    /// yoksa `nil` döner ve çağıran uyarı göstermez. Managed dosya okunamazsa
    /// anahtar kümesi boş sayılır, yani her kural eskisi gibi gösterilir
    /// (güvenli yöne açık: yanlış suskunluk yok).
    func effectiveGlobalPermissionOverrides(
        managedKeys: ManagedPermissionKeys
    ) -> GlobalPermissionOverride? {
        guard let override = globalPermissionOverrides() else {
            return nil
        }
        let filtered = override.excluding(managedKeys: managedKeys)
        return filtered.isEmpty ? nil : filtered
    }

    /// Managed yapılandırma dosyasının karar verdiği anahtarlar.
    ///
    /// Dosya yoksa ya da okunamazsa boş küme döner; çağıran o durumda her
    /// harici kuralı gösterir.
    static func managedKeys(
        at url: URL,
        fileManager: FileManager
    ) -> ManagedPermissionKeys {
        guard
            fileManager.fileExists(atPath: url.path),
            let raw = try? String(contentsOf: url, encoding: .utf8),
            let object = decodeObject(raw)
        else {
            return .empty
        }
        return managedKeys(from: object)
    }

    /// Çözümlenmiş bir yapılandırma nesnesinden anahtar kümeleri çıkarır.
    static func managedKeys(from object: [String: Any]) -> ManagedPermissionKeys {
        var permission = Set<String>()
        if let map = object["permission"] as? [String: Any] {
            permission = Set(map.keys)
        }
        var tools = Set<String>()
        if let map = object["tools"] as? [String: Any] {
            tools = Set(map.keys)
        }
        var agents = Set<String>()
        if let agentMap = object["agent"] as? [String: Any] {
            for (agentName, agentValue) in agentMap {
                guard let agentObject = agentValue as? [String: Any] else {
                    continue
                }
                let permissionMap = agentObject["permission"] as? [String: Any] ?? [:]
                for key in permissionMap.keys {
                    agents.insert("\(agentName).\(key)")
                }
            }
        }
        return ManagedPermissionKeys(permission: permission, tools: tools, agents: agents)
    }

    /// The `mcp` map of the user's configuration, keyed by server name.
    func mcpServers() -> [String: MCPDefinition] {
        guard
            let url = configURLs.first(where: { fileManager.fileExists(atPath: $0.path) }),
            let raw = try? String(contentsOf: url, encoding: .utf8),
            let object = Self.decodeObject(raw),
            let mcp = object["mcp"] as? [String: Any]
        else {
            return [:]
        }

        return mcp.reduce(into: [:]) { result, entry in
            guard let definition = Self.definition(from: entry.value) else {
                return
            }
            result[entry.key] = definition
        }
    }

    /// The `plugin` entries of the user's configuration.
    ///
    /// Listed for information only: an array cannot be overridden entry by
    /// entry, so a plugin the user put in their own config is always on.
    func pluginModules() -> [String] {
        guard
            let url = configURLs.first(where: { fileManager.fileExists(atPath: $0.path) }),
            let raw = try? String(contentsOf: url, encoding: .utf8),
            let object = Self.decodeObject(raw),
            let plugins = object["plugin"] as? [Any]
        else {
            return []
        }

        return plugins.compactMap { $0 as? String }
    }

    /// One `mcp` entry as the app models it.
    static func definition(from raw: Any) -> MCPDefinition? {
        guard let object = raw as? [String: Any] else {
            return nil
        }

        let command = (object["command"] as? [Any])?.compactMap { $0 as? String } ?? []
        let url = object["url"] as? String
        let declaredType = object["type"] as? String

        let transport: MCPTransport
        switch declaredType {
        case "remote":
            transport = .remote
        case "local":
            transport = .local
        default:
            transport = url != nil && command.isEmpty ? .remote : .local
        }

        return MCPDefinition(
            transport: transport,
            command: command,
            cwd: object["cwd"] as? String,
            environment: (object["environment"] as? [String: Any])?
                .compactMapValues { $0 as? String } ?? [:],
            url: url,
            headers: (object["headers"] as? [String: Any])?
                .compactMapValues { $0 as? String } ?? [:],
            oauth: oauthPolicy(from: object["oauth"]),
            timeoutMilliseconds: object["timeout"] as? Int ?? 20_000
        )
    }

    private static func oauthPolicy(from raw: Any?) -> MCPOAuthPolicy {
        guard let raw else {
            return .automatic
        }

        if let enabled = raw as? Bool {
            return enabled ? .automatic : .disabled
        }

        guard let object = raw as? [String: Any] else {
            return .automatic
        }

        guard let clientID = object["clientId"] as? String, !clientID.isEmpty else {
            return .automatic
        }

        return .registered(
            clientID: clientID,
            clientSecret: object["clientSecret"] as? String,
            scope: object["scope"] as? String
        )
    }

    private static func decodeObject(_ raw: String) -> [String: Any]? {
        guard
            let data = JSONCCommentStripper.strip(raw).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return object
    }
}

/// Removes the two things JSONC allows that `JSONSerialization` does not:
/// comments and trailing commas.
///
/// A hand-rolled scanner rather than a regular expression, because `//` inside a
/// string is a URL, not a comment, and treating it as one would corrupt the very
/// configuration this reads.
enum JSONCCommentStripper {
    static func strip(_ raw: String) -> String {
        var output = ""
        var isInsideString = false
        var isEscaping = false
        var index = raw.startIndex

        while index < raw.endIndex {
            let character = raw[index]
            let nextIndex = raw.index(after: index)
            let nextCharacter = nextIndex < raw.endIndex ? raw[nextIndex] : nil

            if isInsideString {
                output.append(character)
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInsideString = false
                }
                index = nextIndex
                continue
            }

            if character == "\"" {
                isInsideString = true
                output.append(character)
                index = nextIndex
                continue
            }

            if character == "/", nextCharacter == "/" {
                while index < raw.endIndex, raw[index] != "\n" {
                    index = raw.index(after: index)
                }
                continue
            }

            if character == "/", nextCharacter == "*" {
                index = raw.index(after: nextIndex)
                while index < raw.endIndex {
                    let current = raw[index]
                    let following =
                        raw.index(after: index) < raw.endIndex
                        ? raw[raw.index(after: index)]
                        : nil
                    if current == "*", following == "/" {
                        index = raw.index(after: raw.index(after: index))
                        break
                    }
                    index = raw.index(after: index)
                }
                continue
            }

            output.append(character)
            index = nextIndex
        }

        return removeTrailingCommas(from: output)
    }

    /// `{"a": 1,}` is valid JSONC and invalid JSON.
    private static func removeTrailingCommas(from raw: String) -> String {
        var output = ""
        var isInsideString = false
        var isEscaping = false

        for character in raw {
            if isInsideString {
                output.append(character)
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInsideString = false
                }
                continue
            }

            if character == "\"" {
                isInsideString = true
                output.append(character)
                continue
            }

            if character == "}" || character == "]" {
                while let last = output.last, last.isWhitespace {
                    output.removeLast()
                }
                if output.last == "," {
                    output.removeLast()
                }
            }

            output.append(character)
        }

        return output
    }
}
