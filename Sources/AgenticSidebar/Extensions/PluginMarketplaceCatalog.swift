import Foundation

struct CuratedPluginEntry: Identifiable, Equatable, Sendable {
    /// The npm module name, which is exactly what OpenCode is told to load.
    let name: String
    let displayName: String
    let description: String
    /// The version published when this list was written. The screen replaces the
    /// whole list with npm's live answer as soon as the search returns, so this is
    /// a hint for the offline case rather than a pin.
    let version: String
    let author: String
    let tags: [String]

    var id: String { name }
}

/// The plugins offered before npm's own search answers.
///
/// Every module here is published on npm and installs under its listed name. The
/// previous list was not: all seven of its entries (`@opencode/plugin-*`,
/// `opencode-auto-commit`, …) were names that have never existed on the registry,
/// so "Install Plugin" recorded a module that OpenCode could only fail to load.
enum PluginMarketplaceCatalog {
    static let curatedPlugins: [CuratedPluginEntry] = [
        CuratedPluginEntry(
            name: "opencode-supermemory",
            displayName: "Supermemory",
            description: "Gives the agent persistent memory across sessions through Supermemory.",
            version: "2.0.13",
            author: "Supermemory",
            tags: ["Memory", "Context"]
        ),
        CuratedPluginEntry(
            name: "@tarquinen/opencode-dcp",
            displayName: "Dynamic Context Pruning",
            description: "Cuts token spend by pruning tool output that the conversation no longer needs.",
            version: "3.1.15",
            author: "tarquinen",
            tags: ["Context", "Cost"]
        ),
        CuratedPluginEntry(
            name: "opencode-command-hooks",
            displayName: "Command Hooks",
            description: "Runs shell commands you declare on tool, subagent and session events.",
            version: "0.7.1",
            author: "Shane Bishop",
            tags: ["Automation", "Workflow"]
        ),
        CuratedPluginEntry(
            name: "opencode-claude-hooks",
            displayName: "Claude Code Hooks",
            description: "Runs your existing Claude Code hooks inside OpenCode unchanged.",
            version: "0.1.0",
            author: "Martin Garcia",
            tags: ["Automation", "Compatibility"]
        ),
        CuratedPluginEntry(
            name: "opencode-auto-resume",
            displayName: "Auto Resume",
            description: "Restarts a session that froze mid-generation instead of leaving it stalled.",
            version: "1.1.17",
            author: "Daniele Scasciafratte",
            tags: ["Reliability"]
        ),
        CuratedPluginEntry(
            name: "opencode-models-discovery",
            displayName: "Model Discovery",
            description: "Finds OpenAI-compatible models and configures their providers automatically.",
            version: "1.5.5",
            author: "yuhp",
            tags: ["Models", "Providers"]
        ),
        CuratedPluginEntry(
            name: "opencode-openrouter-sync",
            displayName: "OpenRouter Sync",
            description: "Keeps the OpenRouter model catalogue in step with what the account can reach.",
            version: "1.8.1",
            author: "tbui17",
            tags: ["Models", "Providers"]
        ),
        CuratedPluginEntry(
            name: "@langfuse/opencode-observability-plugin",
            displayName: "Langfuse Observability",
            description: "Sends session telemetry to Langfuse for tracing and evaluation.",
            version: "0.4.0",
            author: "Langfuse",
            tags: ["Observability"]
        ),
        CuratedPluginEntry(
            name: "@langchain/langsmith-opencode",
            displayName: "LangSmith Tracing",
            description: "Traces runs to LangSmith so a turn can be inspected step by step.",
            version: "0.1.0",
            author: "LangChain",
            tags: ["Observability"]
        )
    ]
}
