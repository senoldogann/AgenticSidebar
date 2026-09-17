import Foundation

struct CuratedPluginEntry: Identifiable, Equatable, Sendable {
    let name: String
    let displayName: String
    let description: String
    let version: String
    let author: String
    let tags: [String]

    var id: String { name }
}

enum PluginMarketplaceCatalog {
    static let curatedPlugins: [CuratedPluginEntry] = [
        CuratedPluginEntry(
            name: "@opencode/plugin-code-review",
            displayName: "Code Reviewer",
            description: "Automated diff analysis, code quality inspections, and security linting before commits.",
            version: "1.4.2",
            author: "OpenCode Ecosystem",
            tags: ["Review", "Quality", "Linting"]
        ),
        CuratedPluginEntry(
            name: "@opencode/plugin-git-helper",
            displayName: "Git Automator",
            description: "Intelligent git commit message drafting, branch switching, and pull request generation.",
            version: "1.2.0",
            author: "OpenCode Ecosystem",
            tags: ["Git", "Workflow"]
        ),
        CuratedPluginEntry(
            name: "@opencode/plugin-linter",
            displayName: "Multi-Language Linter",
            description: "Real-time syntax diagnostics and formatting for Swift, TypeScript, Python, and Go.",
            version: "2.0.1",
            author: "Community",
            tags: ["Formatting", "Linting"]
        ),
        CuratedPluginEntry(
            name: "@opencode/plugin-terminal",
            displayName: "Terminal Enhancer",
            description: "Command execution history, output filtering, and background job notifications.",
            version: "1.1.5",
            author: "Community",
            tags: ["Terminal", "Productivity"]
        ),
        CuratedPluginEntry(
            name: "opencode-auto-commit",
            displayName: "Conventional Commits",
            description: "Enforces semantic conventional commit standards (feat, fix, docs, chore) automatically.",
            version: "0.9.4",
            author: "DevTools Labs",
            tags: ["Git", "Standards"]
        ),
        CuratedPluginEntry(
            name: "opencode-security-scanner",
            displayName: "Dependency Security Audit",
            description: "Audits npm and SPM dependencies for known vulnerabilities and security advisories.",
            version: "1.3.0",
            author: "Security Team",
            tags: ["Security", "Dependencies"]
        ),
        CuratedPluginEntry(
            name: "opencode-docs-generator",
            displayName: "Markdown Docs Generator",
            description: "Generates comprehensive markdown documentation and API references from code comments.",
            version: "1.0.8",
            author: "DevTools Labs",
            tags: ["Documentation"]
        )
    ]
}
