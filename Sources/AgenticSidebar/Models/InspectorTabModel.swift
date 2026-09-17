import Foundation

/// Defines the underlying content presented in an inspector tab.
enum InspectorTabKind: Equatable, Hashable, Sendable {
    case file(url: URL)
    case subagentReport(activityID: ProviderActivityID, title: String, report: String)
    case changesReview(turnID: UUID, summary: TurnFileChangesSummary, initialFile: FileChangeItem?)
    /// LLM üretimi işaretlemeden canlı önizleme. Ham HTML saklanır; CSP ve
    /// izolasyon `PreviewArtifactBuilder` + `LivePreviewPanelView` tarafında
    /// uygulanır, burada yalnızca veri taşınır.
    case livePreview(id: String, title: String, html: String)
}

/// Represents one tab in the right-side inspector panel.
struct InspectorTab: Identifiable, Equatable, Sendable {
    let id: String
    let kind: InspectorTabKind
    let title: String
    let iconName: String
    let iconColorName: String

    init(
        id: String,
        kind: InspectorTabKind,
        title: String,
        iconName: String,
        iconColorName: String
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.iconName = iconName
        self.iconColorName = iconColorName
    }

    static func forFile(url: URL) -> InspectorTab {
        let ext = url.pathExtension.lowercased()
        let icon: String
        let color: String
        switch ext {
        case "swift":
            icon = "swift"
            color = "orange"
        case "json":
            icon = "curlybraces"
            color = "yellow"
        case "md", "markdown", "txt":
            icon = "doc.text"
            color = "blue"
        case "sh", "bash", "zsh":
            icon = "terminal"
            color = "green"
        case "png", "jpg", "jpeg", "gif", "webp", "svg":
            icon = "photo"
            color = "purple"
        case "pdf":
            icon = "doc.richtext"
            color = "red"
        default:
            icon = "doc.text"
            color = "secondary"
        }

        return InspectorTab(
            id: "file:\(url.standardizedFileURL.path)",
            kind: .file(url: url),
            title: url.lastPathComponent,
            iconName: icon,
            iconColorName: color
        )
    }

    static func forSubagentReport(activity: AgentActivity) -> InspectorTab {
        let title = activity.title ?? "Subagent report"
        return InspectorTab(
            id: "report:\(activity.id.rawValue)",
            kind: .subagentReport(
                activityID: activity.id,
                title: title,
                report: activity.output ?? ""
            ),
            title: title,
            iconName: "arrow.triangle.branch",
            iconColorName: "accent"
        )
    }

    static func forReview(summary: TurnFileChangesSummary, initialFile: FileChangeItem?) -> InspectorTab {
        let count = summary.fileCount
        return InspectorTab(
            id: "review:\(summary.id.uuidString)",
            kind: .changesReview(
                turnID: summary.id,
                summary: summary,
                initialFile: initialFile
            ),
            title: "Changes (\(count))",
            iconName: "doc.badge.plus",
            iconColorName: "accent"
        )
    }

    static func forLivePreview(id: String, title: String, html: String) -> InspectorTab {
        InspectorTab(
            id: "preview:\(id)",
            kind: .livePreview(id: id, title: title, html: html),
            title: title,
            iconName: "eye",
            iconColorName: "green"
        )
    }

    /// Discretely numbered label for the tab bar ("Sekme 1", "Sekme 2" or "Agent 1", "Agent 2").
    static func displayLabel(for tab: InspectorTab, among tabs: [InspectorTab]) -> String {
        switch tab.kind {
        case .subagentReport:
            let agentTabs = tabs.filter {
                if case .subagentReport = $0.kind { return true }
                return false
            }
            let index = (agentTabs.firstIndex(where: { $0.id == tab.id }) ?? 0) + 1
            return "Agent \(index)"
        case .file, .changesReview, .livePreview:
            let fileTabs = tabs.filter {
                if case .subagentReport = $0.kind { return false }
                return true
            }
            let index = (fileTabs.firstIndex(where: { $0.id == tab.id }) ?? 0) + 1
            return "Sekme \(index)"
        }
    }
}
