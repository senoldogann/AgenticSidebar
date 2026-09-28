import Foundation

/// The three things a user can add to the agent.
///
/// They are deliberately one concept with three shapes rather than three
/// features: all three are installed, listed, enabled and tagged the same way,
/// and the difference that matters — **how much of the model's context each one
/// costs** — is a property of the kind, not of the screen it lives on.
///
/// - A *skill* costs one line of context until it is used: OpenCode advertises
///   only its name and description and loads the body through its own `skill`
///   tool when the model asks for it.
/// - An *MCP server* costs the definitions of every tool it exposes for as long
///   as it is enabled, whether or not the model ever calls one.
/// - A *plugin* is code that runs inside the agent; it costs nothing by itself
///   but can add tools of its own.
enum ExtensionKind: String, Codable, Equatable, Sendable, CaseIterable {
    case mcp
    case plugin
    case skill

    var displayName: String {
        switch self {
        case .mcp: "MCP server"
        case .plugin: "Plugin"
        case .skill: "Skill"
        }
    }

    /// What enabling one of these does to the model's context window.
    var contextNote: String {
        switch self {
        case .mcp:
            "Every enabled server adds the description of each of its tools to every request."
        case .plugin:
            "Runs inside the agent. Costly only if the plugin adds tools of its own."
        case .skill:
            "Only the name and description are sent; the body is loaded when the agent uses it."
        }
    }

    /// Skills are the cheap kind, so the UI nudges the user towards them.
    var prefersLazyLoading: Bool {
        self == .skill
    }

    var symbolName: String {
        switch self {
        case .mcp: "server.rack"
        case .plugin: "puzzlepiece.extension"
        case .skill: "books.vertical"
        }
    }
}

/// Where an extension came from, kept so the UI can say so and so a re-install
/// can be offered later.
enum ExtensionSource: Codable, Equatable, Sendable {
    /// Typed in by hand in Settings.
    case manual
    /// A skills.sh entry, identified by its `source`/`name` pair.
    case skillsSh(source: String, skillID: String)
    /// A git repository the files were fetched from.
    case gitHub(repository: String)
    /// An npm module name, installed by the agent at startup.
    case npm(module: String)
    /// Tek tıkla katalog kartından kurulanlar (MCP/eklenti): kartın kimliği
    /// taşınır ki satır "elle eklendi" demesin, kart söylensin.
    case marketplace(id: String)

    var displayName: String {
        switch self {
        case .manual:
            "Added by hand"
        case .skillsSh(let source, _):
            "skills.sh · \(source)"
        case .gitHub(let repository):
            "github.com/\(repository)"
        case .npm(let module):
            "npm · \(module)"
        case .marketplace(let id):
            "Marketplace · \(id)"
        }
    }
}

enum MCPTransport: String, Codable, Equatable, Sendable {
    case local
    case remote
}

/// How OpenCode should authenticate against a remote MCP server.
///
/// OpenCode runs the OAuth flow itself, so the app only has to say whether it
/// should (`automatic`), must not (`disabled`, for API-key servers), or which
/// pre-registered client to use.
enum MCPOAuthPolicy: Codable, Equatable, Sendable {
    case automatic
    case disabled
    case registered(clientID: String, clientSecret: String?, scope: String?)

    var isEnabled: Bool {
        self != .disabled
    }
}

/// One MCP server as OpenCode needs to be told about it.
///
/// Mirrors the `mcp` entry of the OpenCode config. Kept as one type so the same
/// definition can be written into the config file, posted to the running server
/// (`POST /mcp`), and shown back to the user without three translations.
struct MCPDefinition: Codable, Equatable, Sendable {
    var transport: MCPTransport

    /// Local servers: the command and its arguments.
    var command: [String] = []
    /// Local servers: working directory, when it matters.
    var cwd: String?
    var environment: [String: String] = [:]

    /// Remote servers.
    var url: String?
    var headers: [String: String] = [:]
    var oauth: MCPOAuthPolicy = .automatic

    var timeoutMilliseconds: Int = 20_000

    /// A one-line summary for the list rows: the command, or the URL.
    var summary: String {
        switch transport {
        case .local:
            command.isEmpty ? "No command set" : command.joined(separator: " ")
        case .remote:
            url ?? "No URL set"
        }
    }

    /// Whether the definition can actually be sent to a server.
    var isRunnable: Bool {
        switch transport {
        case .local:
            return !command.isEmpty && !(command.first ?? "").isEmpty
        case .remote:
            guard let url, let components = URLComponents(string: url),
                let scheme = components.scheme?.lowercased(),
                let host = components.host?.lowercased(),
                components.user == nil
            else {
                return false
            }
            if scheme == "https", !host.isEmpty {
                return true
            }
            // Yalnız döngü adresinde düz http kabul edilir; konak tam
            // eşleşir (`http://localhost@evil.com` gibi userinfo oyunları
            // `hasPrefix` denetimini atlatırdı).
            return scheme == "http" && (host == "127.0.0.1" || host == "localhost" || host == "::1")
        }
    }

    /// The payload OpenCode expects, with the empty optionals left out so the
    /// generated config stays readable.
    var openCodePayload: OpenCodeMCPServerConfig {
        OpenCodeMCPServerConfig(
            type: transport.rawValue,
            command: transport == .local ? command : [],
            environment: environment.isEmpty ? nil : environment,
            enabled: true,
            timeout: timeoutMilliseconds,
            url: transport == .remote ? url : nil,
            headers: transport == .remote && !headers.isEmpty ? headers : nil,
            cwd: transport == .local ? cwd : nil,
            oauth: openCodeOAuth
        )
    }

    /// `automatic` is the absence of the key: that is what tells OpenCode to run
    /// its own OAuth flow, so it must not be written as `true`.
    private var openCodeOAuth: OpenCodeMCPOAuthSetting? {
        guard transport == .remote else {
            return nil
        }

        switch oauth {
        case .automatic:
            return nil
        case .disabled:
            return .disabled
        case .registered(let clientID, let clientSecret, let scope):
            return .registered(
                clientID: clientID,
                clientSecret: clientSecret,
                scope: scope
            )
        }
    }

    /// Kapalı bir sunucunun yönetilen dosyadaki izdüşümü: komut/URL iskeleti
    /// korunur (aynı adlı kalıtılmış girdiyi geçersiz kılar), sırlar taşınmaz.
    ///
    /// Kayıt defteri tam tanımı saklar; kullanıcı sunucuyu yeniden açınca
    /// sırlar oradan geri gelir. Dosya 0600 olsa da çalışmayan bir girdide
    /// sır durmamalı.
    func redactedForDisabled() -> MCPDefinition {
        var copy = self
        copy.environment = [:]
        copy.headers = [:]
        if case .registered(let clientID, _, let scope) = copy.oauth {
            copy.oauth = .registered(clientID: clientID, clientSecret: nil, scope: scope)
        }
        return copy
    }
}

/// One MCP server the app knows about.
///
/// `isInherited` marks a server that is already configured in the user's own
/// `opencode.json`: the app never edits that file, it only decides whether the
/// server's tools reach the model.
struct MCPServerRecord: Codable, Equatable, Sendable, Identifiable {
    var name: String
    var definition: MCPDefinition
    var isEnabled: Bool
    var source: ExtensionSource
    var isInherited: Bool
    var installedAt: Date

    var id: String { name }
}

struct PluginRecord: Codable, Equatable, Sendable, Identifiable {
    /// The npm module name, or a path for a local plugin file.
    var module: String
    var isEnabled: Bool
    var source: ExtensionSource
    var installedAt: Date
    /// Plugins are code: the UI says so, and the user has to opt in.
    var requiresTrust: Bool

    var id: String { module }
    var name: String { module }
    /// Katalogdan tek tıkla kurulumda sabitlenen npm sürümü (`ad@1.2.3` →
    /// `1.2.3`). Aynı taban ad yeniden eklenirken pin farklıysa kurulum
    /// reddedilir; sessiz sürüm kayması olmaz. Eski kayıtlarda yoktur (`nil`),
    /// kodlanabilirlik geriye uyumludur.
    var pinnedVersion: String? = nil
}

struct SkillRecord: Codable, Equatable, Sendable, Identifiable {
    /// The directory name, which OpenCode requires to match the frontmatter
    /// `name`.
    var name: String
    /// The one line OpenCode sends to the model instead of the whole skill.
    var description: String
    var isEnabled: Bool
    var source: ExtensionSource
    var installedAt: Date
    /// Where the `SKILL.md` lives, so the body can be shown and the file opened.
    var path: String
    /// False for a skill the app did not install (one found in the user's own
    /// `~/.claude/skills` and friends): it can be listed and enabled, not moved.
    var isManaged: Bool
    /// Kurulum anında hesaplanan içerik özeti (SHA-256 hex). İlk kurulumda
    /// mühürlenir (TOFU); yeniden kurulumda beklenen değerle uyuşmazsa içerik
    /// yukarıda sessizce değişmiş demektir ve kurulum reddedilir. Eski
    /// kayıtlarda yoktur (`nil`), kodlanabilirlik geriye uyumludur.
    var expectedSHA256: String? = nil

    var id: String { name }
}

/// A tag the user attached to a message in the composer.
///
/// Carried on the `ChatMessage` so the transcript shows what a turn was allowed
/// to reach for, and so a queued prompt keeps its tags.
struct ExtensionTag: Codable, Equatable, Sendable, Identifiable, Hashable {
    let kind: ExtensionKind
    let name: String

    var id: String { "\(kind.rawValue):\(name)" }
}

extension Array where Element == ExtensionTag {
    /// What a tag costs the request: a few lines, for one turn only.
    ///
    /// This is the whole point of tagging. A tag does not load an extension —
    /// OpenCode has already done that from the generated configuration — it tells
    /// the model *which* of the things it can reach are relevant right now, and
    /// that it should not go shopping for the rest.
    var turnInstruction: String? {
        guard !isEmpty else {
            return nil
        }

        let lines = map { tag -> String in
            switch tag.kind {
            case .mcp:
                "- MCP server “\(tag.name)”: its tools are the right ones to use here."
            case .plugin:
                "- Plugin “\(tag.name)” is active; rely on the behaviour it adds."
            case .skill:
                "- Skill “\(tag.name)”: load it with the skill tool and follow it."
            }
        }

        return """
            The user tagged these extensions for this request:\n\n\
            \(lines.joined(separator: "\n"))\n\n\
            Use these. Do not reach for other installed extensions this turn.
            """
    }
}

/// What the composer can offer the user.
struct ExtensionSuggestion: Identifiable, Equatable, Sendable {
    let kind: ExtensionKind
    let name: String
    /// What the popup shows under the name — a description for skills, the
    /// command or URL for an MCP server.
    let detail: String

    var id: String { "\(kind.rawValue):\(name)" }

    var tag: ExtensionTag {
        ExtensionTag(kind: kind, name: name)
    }
}

// MARK: - Lane A7: pazar yeri kurulum güvenliği

/// Yerel MCP sunucusunun çalışma dizini ilkesi.
///
/// `cwd` önce sembolik bağlardan arındırılır (görünen yol değil gerçek hedef
/// denetlenir), sonra çalışma alanı ya da açık izin listesi altında mı diye
/// bakılır. Alan dışı dizin, sunucunun ajan yetkisiyle keyfi klasörde süreç
/// çalıştırması demektir; reddedilir. Kalıtılmış sunucular (kullanıcının kendi
/// `opencode.json` dosyasındakiler) listelenir ama düzenlenmez, bu denetim
/// onlara işlemez — yalnızca yeni eklemelere.
enum MCPWorkingDirectoryPolicy {
    /// Doğrulanmış `cwd`: boş girdi `nil` döner (kısıtlama yok, OpenCode'un
    /// kendi dizininde koşar). Başarısızlıkta reddin nedeni taşınır.
    static func validated(
        cwd raw: String?,
        serverName: String,
        workspaceRoot: URL,
        extraAllowedRoots: [URL] = []
    ) -> Result<String?, MCPWorkingDirectoryError> {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else {
            return .success(nil)
        }
        // Symlink çözülür: `cwd` görünen yol değil gerçek hedef üzerinden
        // denetlenir, yoksa bağ ile alan dışına kaçılırdı.
        let resolved = URL(fileURLWithPath: trimmed).resolvingSymlinksInPath().standardized.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return .failure(.notDirectory(path: trimmed))
        }
        // Bilgisayar kullanımı kendi proje dizininde koşar (`--root` ile
        // başlatılır); alan denetimi onu engellememelidir.
        if serverName == ComputerUseConfiguration.serverName {
            return .success(resolved)
        }
        let allowed = [workspaceRoot] + extraAllowedRoots
        let inside = allowed.contains { root in
            let canonical = root.resolvingSymlinksInPath().standardized.path
            let prefix = canonical.hasSuffix("/") ? canonical : canonical + "/"
            return resolved == canonical || resolved.hasPrefix(prefix)
        }
        guard inside else {
            return .failure(.outsideAllowedRoots(path: trimmed, resolved: resolved))
        }
        return .success(resolved)
    }
}

/// `cwd` reddinin nedeni; `message` durum satırına aynen yazılır.
enum MCPWorkingDirectoryError: Error, Equatable, Sendable {
    case notDirectory(path: String)
    case outsideAllowedRoots(path: String, resolved: String)

    var message: String {
        switch self {
        case .notDirectory(let path):
            "Çalışma dizini bulunamadı ya da dizin değil: \(path)"
        case .outsideAllowedRoots(let path, _):
            "Çalışma dizini çalışma alanı dışında: \(path). Sunucu yalnızca çalışma alanı ya da izinli dizinler altında koşabilir."
        }
    }
}

/// `scripts/` taşıdığı için beklemeye alınan beceri kurulumu.
///
/// Kurulum yarıda kesilmez, hiç yazılmaz; kullanıcı onaylayana (`confirm`) ya
/// da vazgeçene (`cancel`) kadar burada durur. Onay kartı
/// (`PermissionApprovalCenter`) bağlıysa soru oraya düşer, bağlı değilse durum
/// satırı ve bu kayıt açık onay yoludur.
struct PendingScriptApproval: Equatable, Sendable {
    /// Kurulacak becerinin klasör adı.
    let skillName: String
    /// Kartın gösterdiği kaynak (`owner/repo`).
    let repository: String
    /// Onaya sunulan çalıştırılabilir dosya listesi (`scripts/...`).
    let scriptPaths: [String]
    /// Kurulumda aranacak içerik özeti; `nil` ise ilk kurulum mühürler.
    let expectedSHA256: String?
    /// Onay sonrası kurulumun kaldığı yerden sürmesi için saklanır.
    let reference: GitHubRepositoryReference
    let source: ExtensionSource
}
