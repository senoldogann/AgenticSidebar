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
    case tool
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
        let tokens = Set(
            normalizedName
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
        )

        // Checked first: a task-list tool's name can contain a word the other
        // groups also claim (`todo_write` reads as a write), and a task list filed
        // as a file change would be the wrong icon and would miss the checklist
        // refresh. Matched as a substring as well as a token, because the name the
        // backend sends is often one word (`todowrite`).
        if normalizedName.contains("todo")
            || !tokens.isDisjoint(with: ["todo", "todos", "task", "tasks"])
        {
            return .todo
        }

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
}
