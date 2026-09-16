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

    var displayName: String {
        switch self {
        case .manual:
            "Added by hand"
        case let .skillsSh(source, _):
            "skills.sh · \(source)"
        case let .gitHub(repository):
            "github.com/\(repository)"
        case let .npm(module):
            "npm · \(module)"
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
            !command.isEmpty && !(command.first ?? "").isEmpty
        case .remote:
            (url?.hasPrefix("http") ?? false)
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
        case let .registered(clientID, clientSecret, scope):
            return .registered(
                clientID: clientID,
                clientSecret: clientSecret,
                scope: scope
            )
        }
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
