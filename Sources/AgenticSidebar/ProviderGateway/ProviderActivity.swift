import Foundation

struct ProviderActivityID: Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Persisted as a bare string, so an archive stays readable and a preview of the
/// activity timeline survives a relaunch.
extension ProviderActivityID: Codable {
    init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum ProviderActivityKind: String, Equatable, Codable, Sendable {
    case thinking
    case command
    case read
    case delete
    case update
    case edit
    case webSearch
    /// The agent's own task list. It is a tool call like any other, but it is the
    /// one whose *result* the transcript shows as a checklist, so it is worth
    /// recognising rather than filing under a generic tool.
    case todo
    /// A delegated subagent (`task` tool). It runs its own tools in a child
    /// session, so without its own kind it was filed as a task-list update and
    /// the delegation was invisible in the timeline.
    case subagent
    /// A tool served by an MCP server (`mcp__server__tool`). The server name is
    /// part of what the row shows, so a generic wrench hides who ran what.
    case mcp
    case tool
    /// An interactive question posed to the user mid-turn.
    case question
}

enum ProviderActivityOutcome: Equatable, Sendable {
    case completed
    case failed
}

struct ProviderActivityDescriptor: Equatable, Sendable {
    let id: ProviderActivityID
    let kind: ProviderActivityKind
    let title: String?
    let detail: String?
    let output: String?
    /// A `+`/`-` preview of what a file-changing tool did, when the tool input
    /// describes the change.
    let diff: String?

    init(
        id: ProviderActivityID,
        kind: ProviderActivityKind,
        title: String?,
        detail: String?,
        output: String?,
        diff: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.output = output
        self.diff = diff
    }

    init(
        id: ProviderActivityID,
        kind: ProviderActivityKind
    ) {
        self.id = id
        self.kind = kind
        self.title = nil
        self.detail = nil
        self.output = nil
        self.diff = nil
    }

    static func sanitizedTool(
        id: ProviderActivityID,
        toolName: String,
        title: String?,
        detail: String?,
        output: String?,
        diff: String? = nil
    ) -> ProviderActivityDescriptor {
        ProviderActivityDescriptor(
            id: id,
            kind: sanitizedKind(for: toolName),
            title: title,
            detail: detail,
            output: output,
            diff: diff
        )
    }

    static func sanitizedTool(
        id: ProviderActivityID,
        toolName: String
    ) -> ProviderActivityDescriptor {
        ProviderActivityDescriptor(
            id: id,
            kind: sanitizedKind(for: toolName),
            title: nil,
            detail: nil,
            output: nil
        )
    }

    private static func sanitizedKind(for toolName: String) -> ProviderActivityKind {
        let normalizedName = toolName.lowercased()

        // Checked first: `task` and other subagent delegation tools. They run
        // their own tools in a child session, so without their own kind they
        // would fall into generic tool or todo lists.
        let subagentNames: Set<String> = [
            "task",
            "subagent",
            "sub_agent",
            "browser_subagent",
            "run_subagent",
            "call_subagent",
            "invoke_subagent",
            "delegate_task",
            "delegate_agent",
            "delegate",
            "agent"
        ]
        if subagentNames.contains(normalizedName)
            || normalizedName.hasSuffix("_subagent")
            || normalizedName.hasPrefix("subagent_")
        {
            return .subagent
        }

        // MCP tools arrive namespaced (`mcp__server__tool` on current OpenCode,
        // `mcp_server_tool` before the double-underscore convention, `mcp.server.tool`),
        // or via standard invocation wrappers like `call_mcp_tool`. Checked
        // before the todo group so an MCP tool whose server happens to mention
        // todos is still filed as an MCP call.
        if normalizedName.hasPrefix("mcp__")
            || normalizedName.hasPrefix("mcp_")
            || normalizedName.hasPrefix("mcp.")
            || normalizedName.hasPrefix("mcp:")
            || normalizedName == "call_mcp_tool"
            || normalizedName == "callmcptool"
        {
            return .mcp
        }

        // Checked before the file groups: a task-list tool's name can contain a
        // word the other groups also claim (`todo_write` reads as a write), and
        // a task list filed as a file change would be the wrong icon and would
        // miss the checklist refresh. Matched as a substring as well as a token,
        // because the name the backend sends is often one word (`todowrite`).
        if normalizedName.contains("todo")
            || !tokens(of: normalizedName).isDisjoint(with: ["todo", "todos"])
        {
            return .todo
        }

        let questionNames: Set<String> = [
            "ask_question",
            "ask_user",
            "askquestion",
            "askuser",
            "request_user_input",
            "prompt_user",
            "clarify",
            "user_input",
            "interactive_question"
        ]
        if questionNames.contains(normalizedName)
            || normalizedName.hasSuffix("_question")
            || normalizedName.hasPrefix("question_")
            || normalizedName.hasPrefix("ask_")
        {
            return .question
        }

        let tokens = tokens(of: normalizedName)

        if !tokens.isDisjoint(with: ["bash", "sh", "terminal", "exec", "command", "run"]) {
            return .command
        }

        if normalizedName.contains("web")
            && (normalizedName.contains("search") || normalizedName.contains("fetch"))
        {
            return .webSearch
        }

        if !tokens.isDisjoint(with: ["delete", "remove", "unlink", "rm"]) {
            return .delete
        }

        if !tokens.isDisjoint(with: ["edit", "patch"]) {
            return .edit
        }

        if !tokens.isDisjoint(with: ["update", "write", "create", "save"]) {
            return .update
        }

        if !tokens.isDisjoint(with: ["read", "get", "list", "glob", "grep", "search", "find", "fetch"]) {
            return .read
        }

        return .tool
    }

    /// Splits string by non-alphanumeric characters: `todo_write` -> {"todo", "write"}.
    private static func tokens(of normalizedName: String) -> Set<String> {
        Set(
            normalizedName
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
        )
    }

    /// Separates MCP tool name into server and tool components.
    ///
    /// The primary convention is `mcp__server__tool` (double underscore delimiter).
    /// Also supports `mcp:server:tool`, `mcp:server_tool`, and `mcp.server.tool`.
    static func mcpServerAndTool(from toolName: String) -> (server: String?, tool: String) {
        let name = toolName.lowercased()

        if name.hasPrefix("mcp__") {
            let remainder = String(name.dropFirst("mcp__".count))
            let segments = remainder.split(separator: "__", omittingEmptySubsequences: true)
            if segments.count >= 2 {
                let server = String(segments[0])
                let tool = segments.dropFirst().joined(separator: "__")
                return (server, tool)
            }
            return (nil, remainder)
        }

        if name.hasPrefix("mcp.") {
            let remainder = String(name.dropFirst("mcp.".count))
            let segments = remainder.split(separator: ".", omittingEmptySubsequences: true)
            if segments.count >= 2 {
                let server = String(segments[0])
                let tool = segments.dropFirst().joined(separator: ".")
                return (server, tool)
            }
            return (nil, remainder)
        }

        if name.hasPrefix("mcp:") {
            let remainder = String(name.dropFirst("mcp:".count))
            if let colonIndex = remainder.firstIndex(of: ":") {
                let server = String(remainder[..<colonIndex])
                let tool = String(remainder[remainder.index(after: colonIndex)...])
                return (server, tool)
            }
            if let slashIndex = remainder.firstIndex(of: "/") {
                let server = String(remainder[..<slashIndex])
                let tool = String(remainder[remainder.index(after: slashIndex)...])
                return (server, tool)
            }
            if let underscoreIndex = remainder.firstIndex(of: "_") {
                let server = String(remainder[..<underscoreIndex])
                let tool = String(remainder[remainder.index(after: underscoreIndex)...])
                return (server, tool)
            }
            return (nil, remainder)
        }

        if name.hasPrefix("mcp_") {
            return (nil, String(name.dropFirst("mcp_".count)))
        }

        return (nil, toolName)
    }

    /// Separates MCP tool name into server and tool components, taking into
    /// account argument dictionaries for wrapper tools like `call_mcp_tool`.
    static func mcpServerAndTool(
        from toolName: String,
        input: [String: Any]
    ) -> (server: String?, tool: String) {
        let normalized = toolName.lowercased()
        if normalized == "call_mcp_tool" || normalized == "callmcptool" {
            let server = (input["ServerName"] as? String)
                ?? (input["server_name"] as? String)
                ?? (input["server"] as? String)
            let tool = (input["ToolName"] as? String)
                ?? (input["tool_name"] as? String)
                ?? (input["tool"] as? String)
                ?? toolName
            return (server, tool)
        }
        return mcpServerAndTool(from: toolName)
    }

    /// `get_user` → "Get user": zaman çizelgesindeki satır başlığı için.
    static func humanizedToolName(_ rawTool: String) -> String {
        let words = rawTool
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !words.isEmpty else {
            return rawTool
        }

        return words
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
