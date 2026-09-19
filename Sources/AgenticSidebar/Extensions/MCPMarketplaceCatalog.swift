import Foundation

enum MCPMarketplaceCategory: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case development = "Development"
    case database = "Database"
    case webSearch = "Web & Search"
    case productivity = "Productivity"
    case system = "System"

    var id: String { rawValue }
}

struct MCPMarketplaceEntry: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let displayName: String
    let summary: String
    let publisher: String
    let category: MCPMarketplaceCategory
    let iconName: String
    /// The command a local server is started with. Empty for a remote one.
    let command: [String]
    let environmentKeys: [String]
    /// Set for a hosted server the agent connects to over HTTP instead of
    /// spawning. OpenCode runs the authorization flow for these itself, which the
    /// MCP tab surfaces as "Authorize".
    let url: String?
    let documentationURL: String?

    var isRemote: Bool { url != nil }

    /// What the card shows under the summary: the command, or the endpoint.
    var installSummary: String {
        url ?? command.joined(separator: " ")
    }

    func createDefinition() -> MCPDefinition {
        if let url {
            return MCPDefinition(
                transport: .remote,
                command: [],
                cwd: nil,
                environment: [:],
                url: url,
                headers: [:],
                oauth: .automatic,
                timeoutMilliseconds: 30_000
            )
        }

        var env: [String: String] = [:]
        for key in environmentKeys {
            env[key] = ""
        }
        return MCPDefinition(
            transport: .local,
            command: command,
            cwd: nil,
            environment: env,
            url: nil,
            headers: [:],
            oauth: .automatic,
            timeoutMilliseconds: 30_000
        )
    }
}

enum MCPMarketplaceCatalog {
    /// Every entry resolves: an npm or PyPI package that is published and not
    /// archived, or a hosted endpoint that answers. The previous list had three
    /// npm names that never existed (`server-fetch`, `server-sqlite`,
    /// `server-sentry`) and four more the upstream project had retired, so
    /// "Add to Agent" recorded servers OpenCode could only fail to start.
    static let entries: [MCPMarketplaceEntry] = [
        MCPMarketplaceEntry(
            id: "github",
            name: "github",
            displayName: "GitHub MCP",
            summary: "Search repositories, read source, inspect pull requests and manage issues.",
            publisher: "GitHub",
            category: .development,
            iconName: "chevron.left.forwardslash.chevron.right",
            command: [],
            environmentKeys: [],
            url: "https://api.githubcopilot.com/mcp/",
            documentationURL: "https://github.com/github/github-mcp-server"
        ),
        MCPMarketplaceEntry(
            id: "context7",
            name: "context7",
            displayName: "Context7 Docs",
            summary: "Up-to-date documentation and code examples for libraries and frameworks.",
            publisher: "Upstash",
            category: .development,
            iconName: "book.closed.fill",
            command: ["npx", "-y", "@upstash/context7-mcp"],
            environmentKeys: ["CONTEXT7_API_KEY"],
            url: nil,
            documentationURL: "https://github.com/upstash/context7"
        ),
        MCPMarketplaceEntry(
            id: "sentry",
            name: "sentry",
            displayName: "Sentry MCP",
            summary: "Query error traces, exception reports and production crash telemetry.",
            publisher: "Sentry",
            category: .development,
            iconName: "exclamationmark.triangle.fill",
            command: [],
            environmentKeys: [],
            url: "https://mcp.sentry.dev/mcp",
            documentationURL: "https://docs.sentry.io/product/sentry-mcp/"
        ),
        MCPMarketplaceEntry(
            id: "postgres",
            name: "postgres",
            displayName: "PostgreSQL MCP",
            summary: "Schema inspection, index tuning and analytical SQL against a Postgres database.",
            publisher: "Crystal DBA",
            category: .database,
            iconName: "cylinder.split.1x2",
            command: ["uvx", "postgres-mcp", "--access-mode=restricted"],
            environmentKeys: ["DATABASE_URI"],
            url: nil,
            documentationURL: "https://github.com/crystaldba/postgres-mcp"
        ),
        MCPMarketplaceEntry(
            id: "sqlite",
            name: "sqlite",
            displayName: "SQLite MCP",
            summary: "Inspect and query local SQLite database files, schemas and table records.",
            publisher: "ModelContextProtocol",
            category: .database,
            iconName: "internaldrive",
            command: ["uvx", "mcp-server-sqlite", "--db-path", "./database.db"],
            environmentKeys: [],
            url: nil,
            documentationURL: "https://pypi.org/project/mcp-server-sqlite/"
        ),
        MCPMarketplaceEntry(
            id: "filesystem",
            name: "filesystem",
            displayName: "Filesystem MCP",
            summary: "Directory exploration, file reading and controlled disk operations.",
            publisher: "ModelContextProtocol",
            category: .system,
            iconName: "folder.fill",
            command: ["npx", "-y", "@modelcontextprotocol/server-filesystem", "."],
            environmentKeys: [],
            url: nil,
            documentationURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem"
        ),
        MCPMarketplaceEntry(
            id: "fetch",
            name: "fetch",
            displayName: "Web Fetch MCP",
            summary: "Fetches web pages and documentation and converts them into clean Markdown.",
            publisher: "ModelContextProtocol",
            category: .webSearch,
            iconName: "arrow.down.doc.fill",
            command: ["uvx", "mcp-server-fetch"],
            environmentKeys: [],
            url: nil,
            documentationURL: "https://pypi.org/project/mcp-server-fetch/"
        ),
        MCPMarketplaceEntry(
            id: "brave-search",
            name: "brave-search",
            displayName: "Brave Search MCP",
            summary: "Web, news and local search through the Brave Search API.",
            publisher: "Brave",
            category: .webSearch,
            iconName: "magnifyingglass",
            command: ["npx", "-y", "@brave/brave-search-mcp-server", "--transport", "stdio"],
            environmentKeys: ["BRAVE_API_KEY"],
            url: nil,
            documentationURL: "https://github.com/brave/brave-search-mcp-server"
        ),
        MCPMarketplaceEntry(
            id: "playwright",
            name: "playwright",
            displayName: "Playwright Browser MCP",
            summary: "Drives a real browser: navigation, form filling, screenshots and assertions.",
            publisher: "Microsoft",
            category: .webSearch,
            iconName: "globe",
            command: ["npx", "-y", "@playwright/mcp"],
            environmentKeys: [],
            url: nil,
            documentationURL: "https://github.com/microsoft/playwright-mcp"
        ),
        MCPMarketplaceEntry(
            id: "memory",
            name: "memory",
            displayName: "Memory Graph MCP",
            summary: "Knowledge-graph memory that retains context across conversations.",
            publisher: "ModelContextProtocol",
            category: .productivity,
            iconName: "brain.head.profile",
            command: ["npx", "-y", "@modelcontextprotocol/server-memory"],
            environmentKeys: [],
            url: nil,
            documentationURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/memory"
        ),
        MCPMarketplaceEntry(
            id: "sequential-thinking",
            name: "sequential-thinking",
            displayName: "Sequential Thinking MCP",
            summary: "A structured scratchpad for breaking a hard problem into revisable steps.",
            publisher: "ModelContextProtocol",
            category: .productivity,
            iconName: "list.number",
            command: ["npx", "-y", "@modelcontextprotocol/server-sequential-thinking"],
            environmentKeys: [],
            url: nil,
            documentationURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/sequentialthinking"
        ),
        MCPMarketplaceEntry(
            id: "time",
            name: "time",
            displayName: "Time & Timezone MCP",
            summary: "Current time and timezone conversion, so the agent never guesses a date.",
            publisher: "ModelContextProtocol",
            category: .system,
            iconName: "clock.fill",
            command: ["uvx", "mcp-server-time"],
            environmentKeys: [],
            url: nil,
            documentationURL: "https://pypi.org/project/mcp-server-time/"
        ),
    ]
}
