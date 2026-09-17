import Foundation

struct AgentActivityPresentation: Equatable, Sendable {
    let title: String
    let runningStatusName: String
    let symbolName: String

    init(kind: ProviderActivityKind) {
        switch kind {
        case .thinking:
            title = "Thinking"
            runningStatusName = "Thinking"
            symbolName = "brain"
        case .command:
            title = "Running command"
            runningStatusName = "Running command"
            symbolName = "terminal"
        case .read:
            title = "Reading"
            runningStatusName = "Read"
            symbolName = "doc.text.magnifyingglass"
        case .delete:
            title = "Deleting"
            runningStatusName = "Delete"
            symbolName = "trash"
        case .update:
            title = "Updating"
            runningStatusName = "Update"
            symbolName = "arrow.triangle.2.circlepath"
        case .edit:
            title = "Editing"
            runningStatusName = "Edit"
            symbolName = "pencil"
        case .webSearch:
            title = "Searching the web"
            runningStatusName = "Web Search"
            symbolName = "globe"
        case .todo:
            title = "Updating the task list"
            runningStatusName = "To-dos"
            symbolName = "checklist"
        case .subagent:
            title = "Delegated to subagent"
            runningStatusName = "Running subagent"
            symbolName = "arrow.triangle.branch"
        case .mcp:
            title = "Using MCP tool"
            runningStatusName = "MCP tool"
            symbolName = "server.rack"
        case .tool:
            title = "Using a tool"
            runningStatusName = "Tool"
            symbolName = "wrench.and.screwdriver"
        case .question:
            title = "Asking a question"
            runningStatusName = "Question"
            symbolName = "questionmark.bubble.fill"
        }
    }
}

enum ChatMessagePresenter {
    static func cleanUserDisplayText(from rawText: String, hasAttachments: Bool) -> String {
        var text = rawText

        if let ocrRange = text.range(of: #"Extracted content from screenshot:\s*"""[\s\S]*?"""\s*"#, options: .regularExpression) {
            text.removeSubrange(ocrRange)
        }

        text = text.replacingOccurrences(of: #"\s*\(No machine-readable text found in screenshot\)\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[Screenshot captured:[^\]]*\]\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s*Please inspect this screenshot carefully:.*"#, with: "", options: .regularExpression)

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if hasAttachments && trimmed == "Please inspect the attached file." {
            return ""
        }

        if trimmed.isEmpty && !hasAttachments {
            return rawText
        }

        return trimmed
    }
}
