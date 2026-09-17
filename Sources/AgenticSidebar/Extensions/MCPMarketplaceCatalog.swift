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
    let command: [String]
    let environmentKeys: [String]
    let documentationURL: String?

    func createDefinition() -> MCPDefinition {
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
    static let entries: [MCPMarketplaceEntry] = [
        MCPMarketplaceEntry(
            id: "github",
            name: "github",
            displayName: "GitHub MCP",
            summary: "Search repositories, read source code, inspect pull requests, and manage issues.",
            publisher: "ModelContextProtocol",
            category: .development,
            iconName: "chevron.left.forwardslash.chevron.right",
            command: ["npx", "-y", "@modelcontextprotocol/server-github"],
            environmentKeys: ["GITHUB_PERSONAL_ACCESS_TOKEN"],
            documentationURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/github"
        ),
        MCPMarketplaceEntry(
            id: "postgres",
            name: "postgres",
            displayName: "PostgreSQL MCP",
            summary: "Read-only schema inspection, table analysis, and analytical SQL querying.",
            publisher: "ModelContextProtocol",
            category: .database,
            iconName: "cylinder.split.1x2",
            command: ["npx", "-y", "@modelcontextprotocol/server-postgres"],
            environmentKeys: ["DATABASE_URL"],
            documentationURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/postgres"
        ),
        MCPMarketplaceEntry(
            id: "filesystem",
            name: "filesystem",
            displayName: "Filesystem MCP",
            summary: "Direct workspace directory exploration, file reading, and controlled disk operations.",
            publisher: "ModelContextProtocol",
            category: .system,
            iconName: "folder.fill",
            command: ["npx", "-y", "@modelcontextprotocol/server-filesystem", "."],
            environmentKeys: [],
            documentationURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem"
        ),
        MCPMarketplaceEntry(
            id: "brave-search",
            name: "brave-search",
            displayName: "Brave Search MCP",
            summary: "Web search and real-time local search intelligence via Brave Search API.",
            publisher: "ModelContextProtocol",
            category: .webSearch,
            iconName: "magnifyingglass",
            command: ["npx", "-y", "@modelcontextprotocol/server-brave-search"],
            environmentKeys: ["BRAVE_API_KEY"],
            documentationURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/brave-search"
        ),
        MCPMarketplaceEntry(
            id: "memory",
            name: "memory",
            displayName: "Memory Graph MCP",
            summary: "Knowledge graph-based memory storage to retain context across conversations.",
            publisher: "ModelContextProtocol",
            category: .productivity,
            iconName: "brain.head.profile",
            command: ["npx", "-y", "@modelcontextprotocol/server-memory"],
            environmentKeys: [],
            documentationURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/memory"
        ),
        MCPMarketplaceEntry(
            id: "fetch",
            name: "fetch",
            displayName: "Web Fetch MCP",
            summary: "Fetches and converts web pages, documentation, and HTML into clean Markdown.",
            publisher: "ModelContextProtocol",
            category: .webSearch,
            iconName: "arrow.down.doc.fill",
            command: ["npx", "-y", "@modelcontextprotocol/server-fetch"],
            environmentKeys: [],
            documentationURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/fetch"
        ),
        MCPMarketplaceEntry(
            id: "puppeteer",
            name: "puppeteer",
            displayName: "Puppeteer Browser MCP",
            summary: "Headless Chrome browser automation, full-page screenshots, and web interaction.",
            publisher: "ModelContextProtocol",
            category: .webSearch,
            iconName: "globe",
            command: ["npx", "-y", "@modelcontextprotocol/server-puppeteer"],
            environmentKeys: [],
            documentationURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/puppeteer"
        ),
        MCPMarketplaceEntry(
            id: "sqlite",
            name: "sqlite",
            displayName: "SQLite MCP",
            summary: "Inspect and query local SQLite database files, schemas, and table records.",
            publisher: "ModelContextProtocol",
            category: .database,
            iconName: "internaldrive",
            command: ["npx", "-y", "@modelcontextprotocol/server-sqlite"],
            environmentKeys: ["SQLITE_DB_PATH"],
            documentationURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/sqlite"
        ),
        MCPMarketplaceEntry(
            id: "slack",
            name: "slack",
            displayName: "Slack MCP",
            summary: "Search message history, inspect team channels, and post messages to Slack.",
            publisher: "ModelContextProtocol",
            category: .productivity,
            iconName: "bubble.left.and.bubble.right.fill",
            command: ["npx", "-y", "@modelcontextprotocol/server-slack"],
            environmentKeys: ["SLACK_BOT_TOKEN"],
            documentationURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/slack"
        ),
        MCPMarketplaceEntry(
            id: "docker",
            name: "docker",
            displayName: "Docker MCP",
            summary: "Inspect running Docker containers, images, volumes, and execute container commands.",
            publisher: "Community",
            category: .system,
            iconName: "shippingbox.fill",
            command: ["npx", "-y", "mcp-server-docker"],
            environmentKeys: [],
            documentationURL: "https://github.com/modelcontextprotocol/servers"
        ),
        MCPMarketplaceEntry(
            id: "sentry",
            name: "sentry",
            displayName: "Sentry MCP",
            summary: "Query application error traces, exception reports, and production crash telemetry.",
            publisher: "ModelContextProtocol",
            category: .development,
            iconName: "exclamationmark.triangle.fill",
            command: ["npx", "-y", "@modelcontextprotocol/server-sentry"],
            environmentKeys: ["SENTRY_AUTH_TOKEN"],
            documentationURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/sentry"
        ),
        MCPMarketplaceEntry(
            id: "google-drive",
            name: "google-drive",
            displayName: "Google Drive MCP",
            summary: "Search files, read Google Docs, spreadsheets, and workspace documents.",
            publisher: "ModelContextProtocol",
            category: .productivity,
            iconName: "doc.text.fill",
            command: ["npx", "-y", "@modelcontextprotocol/server-gdrive"],
            environmentKeys: ["GDRIVE_CREDENTIALS_PATH"],
            documentationURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/gdrive"
        )
    ]
}
