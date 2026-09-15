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
        case .tool:
            title = "Using a tool"
            runningStatusName = "Tool"
            symbolName = "wrench.and.screwdriver"
        }
    }
}
