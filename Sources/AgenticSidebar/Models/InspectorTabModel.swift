import Foundation

/// Defines the underlying content presented in an inspector tab.
enum InspectorTabKind: Equatable, Hashable, Sendable {
    case file(url: URL)
    case subagentReport(activityID: ProviderActivityID, title: String, report: String)
    case changesReview(turnID: UUID, summary: TurnFileChangesSummary, initialFile: FileChangeItem?)
    /// Sağ panelde açılan gömülü kabuk. Kabuğun kendisi
    /// `TerminalServiceCenter` tarafında yaşar; sekme yalnız kimlik ve dizin
    /// taşır, kapanınca kabuk da kapatılır.
    case terminal(id: String, workingDirectory: String)
}

/// Represents one tab in the right-side inspector panel.
struct InspectorTab: Identifiable, Equatable, Sendable {
    let id: String
    let kind: InspectorTabKind
    let title: String
    let iconName: String
    let iconColorName: String

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

    /// Bölme başına tek terminal sekmesi: kimlik bölmeye bağlıdır, böylece yan
    /// yana iki sohbetin kabuğu birbirine karışmaz.
    static func forTerminal(paneID: String, workingDirectory: String) -> InspectorTab {
        let id = "terminal:\(paneID)"
        return InspectorTab(
            id: id,
            kind: .terminal(id: id, workingDirectory: workingDirectory),
            title: "Terminal",
            iconName: "terminal",
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
        case .file, .changesReview, .terminal:
            let fileTabs = tabs.filter {
                if case .subagentReport = $0.kind { return false }
                return true
            }
            let index = (fileTabs.firstIndex(where: { $0.id == tab.id }) ?? 0) + 1
            return "Sekme \(index)"
        }
    }
}

/// Bir sohbetin sağ panel durumu: açık sekmeler, seçili sekme, genişletme.
/// Bölme görünümü (`ConversationDetailView`) bölme kimliğiyle yaşar, sohbet
/// değişiminde yok olmaz; o yüzden sekmeler oturum başına burada saklanır.
/// Yoksa A sohbetinde açılan rapor B sohbetine geçince de görünür — her
/// sohbetin alanı kendine özel olmalı.
struct InspectorPaneState: Equatable, Sendable {
    var tabs: [InspectorTab] = []
    var selectedID: String?
    var expanded: Bool = false

    /// Oturum değişimi: çıkanı sözlüğe kaldır, geleni sözlükten çıkar.
    /// Silinmiş oturumların kayıtları tutulmaz.
    static func switched(
        _ states: [UUID: InspectorPaneState],
        from oldID: UUID,
        to newID: UUID,
        current: InspectorPaneState,
        liveIDs: Set<UUID>
    ) -> (states: [UUID: InspectorPaneState], restored: InspectorPaneState) {
        guard oldID != newID else {
            return (states, current)
        }
        var next = states
        next[oldID] = current
        next = next.filter { liveIDs.contains($0.key) }
        return (next, next[newID] ?? InspectorPaneState())
    }
}
