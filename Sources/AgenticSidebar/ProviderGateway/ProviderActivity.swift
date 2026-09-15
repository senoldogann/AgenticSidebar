import Foundation

struct ProviderActivityID: Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

enum ProviderActivityKind: Equatable, Sendable {
    case thinking
    case read
    case delete
    case update
    case edit
    case webSearch
    case tool
}

enum ProviderActivityOutcome: Equatable, Sendable {
    case completed
    case failed
}

struct ProviderActivityDescriptor: Equatable, Sendable {
    let id: ProviderActivityID
    let kind: ProviderActivityKind

    static func sanitizedTool(
        id: ProviderActivityID,
        toolName: String
    ) -> ProviderActivityDescriptor {
        ProviderActivityDescriptor(
            id: id,
            kind: sanitizedKind(for: toolName)
        )
    }

    private static func sanitizedKind(for toolName: String) -> ProviderActivityKind {
        let normalizedName = toolName.lowercased()
        let tokens = Set(
            normalizedName
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
        )

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
