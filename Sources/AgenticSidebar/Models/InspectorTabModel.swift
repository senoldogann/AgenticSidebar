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
    /// Sağ panelde açılan tarayıcı. Sayfa durumu (gezinme geçmişi, çerezler)
    /// `BrowserServiceCenter` tarafında yaşar; sekme değişiminde sayfa yok
    /// olmaz, sekme kapanınca görünüm de bırakılır.
    case browser
    /// Sağ panelde açılan iOS Simülatörü: cihaz seçimi ve canlı görüntü
    /// `SimulatorService` tarafında yaşar.
    case simulator
    /// Bilgisayar kullanımının canlı görüntüsü: kareler
    /// `ComputerLiveCaptureService` tarafında üretilir, oturum bitince boş
    /// durum gösterilir.
    case computerLive
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

    /// Oturumun canlı dosya değişiklikleri sekmesi: kimlik oturuma bağlıdır,
    /// tura değil; akış sırasında tekrar tıklama aynı sekmeyi güncel özetle
    /// tazeler, sekme çoğalmaz. İçerik tıklama anının fotoğrafıdır.
    static func forSessionChanges(sessionID: UUID, summary: TurnFileChangesSummary) -> InspectorTab {
        let count = summary.fileCount
        return InspectorTab(
            id: "session-changes:\(sessionID.uuidString)",
            kind: .changesReview(
                turnID: sessionID,
                summary: summary,
                initialFile: nil
            ),
            title: "Changes (\(count))",
            iconName: "doc.badge.plus",
            iconColorName: "accent"
        )
    }

    /// Bölme+klasör başına tek terminal sekmesi: kimlik bölmeye ve
    /// normalize dizine bağlıdır, böylece farklı klasörde çalışan sohbetin
    /// terminali kendi klasöründe açılır. Aynı klasör aynı sekmeyi yeniden
    /// kullanır, canlı kabuk korunur.
    static func forTerminal(paneID: String, workingDirectory: String) -> InspectorTab {
        let normalized = URL(fileURLWithPath: workingDirectory, isDirectory: true).standardizedFileURL
            .path
        let id = "terminal:\(paneID):\(normalized)"
        let folder = normalized == "/" ? "/" : normalized.split(separator: "/").last.map(String.init) ?? "Terminal"
        return InspectorTab(
            id: id,
            kind: .terminal(id: id, workingDirectory: workingDirectory),
            title: "Terminal · \(folder)",
            iconName: "terminal",
            iconColorName: "green"
        )
    }

    /// Bölme başına tek tarayıcı sekmesi: kimlik bölmeye bağlıdır, böylece
    /// yan yana iki sohbetin tarayıcısı birbirine karışmaz.
    static func forBrowser(paneID: String) -> InspectorTab {
        InspectorTab(
            id: "browser:\(paneID)",
            kind: .browser,
            title: "Browser",
            iconName: "globe",
            iconColorName: "blue"
        )
    }

    /// Bölme başına tek simülatör sekmesi.
    static func forSimulator(paneID: String) -> InspectorTab {
        InspectorTab(
            id: "simulator:\(paneID)",
            kind: .simulator,
            title: "Simulator",
            iconName: "iphone",
            iconColorName: "purple"
        )
    }

    /// Bölme başına tek canlı bilgisayar sekmesi.
    static func forComputerLive(paneID: String) -> InspectorTab {
        InspectorTab(
            id: "computer:\(paneID)",
            kind: .computerLive,
            title: "Computer",
            iconName: "computermouse",
            iconColorName: "accent"
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
        case .file, .changesReview, .terminal, .browser, .simulator, .computerLive:
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
    /// Dar ikon şeridine inmiş mi (collapse): sekmeler korunur, içerik
    /// gizlenir; tıklanan ikon sekmeyi seçip şeridi geri açar.
    var collapsed: Bool = false

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
