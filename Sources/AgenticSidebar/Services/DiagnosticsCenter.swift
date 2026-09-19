import Foundation

/// Analist görünümünün tek okuma noktası: cihaz-içi kayıtları bir anlık
/// görüntüde toplar. Dışarıya hiçbir şey gönderilmez.
///
/// Kaynaklar: `CrashReporter` (çökme raporları + önceki çalış işareti),
/// `ToolAuditLog` (araç kararları ve çalıştırma olayları). Birleştirme
/// yalnızca okur; hiçbir kayda yazmaz.
struct DiagnosticsSnapshot: Sendable {
    let appVersion: String
    let launchedAt: Date
    let collectedAt: Date
    let previousRunCrashed: Bool
    let crashReports: [CrashReport]
    let recentDecisions: [ToolAuditLog.Record]
    let recentExecutions: [ToolAuditLog.ExecutionRecord]
    /// Diskteki aktif `/goal` koşusunun tek satırlık özeti; koşu yoksa `nil`.
    /// `var` tutulur: `let` + varsayılan değer üye-başlatıcıya parametre
    /// olarak girmez, eski çağrı noktalarının derlenmesi için varsayılan şart.
    var goalSummary: String? = nil
}

enum DiagnosticsCenter {
    nonisolated static let maximumDecisions = 100
    nonisolated static let maximumExecutions = 100

    static func collect(
        auditLog: ToolAuditLog = .live(),
        crashesDirectory: URL = CrashReporter.crashesDirectory(),
        goalStoreURL: URL? = GoalStore.liveFileURL()
    ) async -> DiagnosticsSnapshot {
        let decisions = await auditLog.recent(limit: maximumDecisions)
        let executions = await auditLog.recentExecutions(limit: maximumExecutions)
        return DiagnosticsSnapshot(
            appVersion: AppVersionInfo.current,
            launchedAt: CrashReporter.launchDate,
            collectedAt: Date(),
            previousRunCrashed: Self.previousRunCrashed(crashesDirectory: crashesDirectory),
            crashReports: CrashReporter.reports(in: crashesDirectory),
            recentDecisions: decisions,
            recentExecutions: executions,
            goalSummary: Self.storedGoalSummary(storeURL: goalStoreURL)
        )
    }

    /// Diskteki terminal-olmayan hedef koşusunu tek satırda özetler. Koşu
    /// yoksa, bitmişse ya da dosya okunamazsa `nil` döner; saf okumadır.
    static func storedGoalSummary(storeURL: URL?) -> String? {
        guard let storeURL, let stored = GoalStore.load(from: storeURL) else {
            return nil
        }
        guard !stored.run.isTerminal else {
            return nil
        }
        return "“\(stored.run.objective)” · \(stored.run.phase.rawValue) · iteration \(stored.run.iteration)/\(stored.budget.maxIterations)"
    }

    /// Önceki-çalış durumu: varsayılan dizinde `install` anında yakalanan
    /// değer geçerlidir (sonradan dosya varlığına bakmak her zaman "evet"
    /// derdi, çünkü `install` işareti yeni yazmıştır). Testlerin verdiği özel
    /// dizinlerde doğrudan dosya varlığına bakılır.
    static func previousRunCrashed(crashesDirectory: URL) -> Bool {
        if crashesDirectory == CrashReporter.crashesDirectory(),
            let captured = CrashReporter.previousRunCrashedAtLaunch
        {
            return captured
        }
        return CrashReporter.previousRunCrashed(in: crashesDirectory)
    }

    /// Dışa aktarma metni (markdown): sürüm, durum, çökmeler ve son araç
    /// kararları. Transkript ve pano içeriği taşınmaz — denetim kaydı zaten
    /// komut metnini değil kararı saklar.
    static func exportMarkdown(_ snapshot: DiagnosticsSnapshot) -> String {
        var lines = [
            "# AgenticSidebar Diagnostics Report",
            "",
            "- Version: \(snapshot.appVersion)",
            "- Launch: \(Self.plainDate(snapshot.launchedAt))",
            "- Collected: \(Self.plainDate(snapshot.collectedAt))",
            "- Previous run ended unexpectedly: \(snapshot.previousRunCrashed ? "yes" : "no")",
            "- Crash reports: \(snapshot.crashReports.count)",
            "- Tool decisions: \(snapshot.recentDecisions.count)",
            "- Tool executions: \(snapshot.recentExecutions.count)",
            "- Goal run: \(snapshot.goalSummary ?? "none")",
            "",
            "## Crash Reports",
            "",
        ]
        if snapshot.crashReports.isEmpty {
            lines.append("No records.")
        } else {
            for report in snapshot.crashReports {
                lines.append("### \(report.name) (\(report.size) bytes)")
                lines.append("")
                let fence = Self.fence(for: report.text)
                lines.append(fence)
                lines.append(report.text.isEmpty ? "(unreadable)" : report.text)
                lines.append(fence)
                lines.append("")
            }
        }
        lines.append("## Recent Tool Decisions")
        lines.append("")
        if snapshot.recentDecisions.isEmpty {
            lines.append("No records.")
        } else {
            for decision in snapshot.recentDecisions {
                lines.append(
                    "- \(Self.plainDate(decision.timestamp)) · \(decision.toolName) · \(decision.title) · \(decision.source.label) → \(decision.reply.rawValue)"
                )
            }
        }
        lines.append("")
        lines.append("## Recent Tool Executions")
        lines.append("")
        if snapshot.recentExecutions.isEmpty {
            lines.append("No records.")
        } else {
            for execution in snapshot.recentExecutions {
                lines.append(
                    "- \(Self.plainDate(execution.timestamp)) · \(execution.toolKind.rawValue) · \(execution.event.rawValue)"
                )
            }
        }
        lines.append("")
        lines.append("## Goal Run")
        lines.append("")
        if let goalSummary = snapshot.goalSummary {
            lines.append(goalSummary)
        } else {
            lines.append("No records.")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func plainDate(_ date: Date) -> String {
        dateFormatterLock.lock()
        defer { dateFormatterLock.unlock() }
        return sharedDateFormatter.string(from: date)
    }

    /// Tek paylaşılan biçimleyici: dışa aktarmada satır başına tahsis ve
    /// locale çözümleme yapılmaz. `DateFormatter` iş-parçacığı güvenli
    /// değildir, erişim kilit altındadır.
    nonisolated private static let sharedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    nonisolated private static let dateFormatterLock = NSLock()

    /// Rapor metni ``` içeriyorsa çiti uzat; dışa aktarılan markdown kırılmasın.
    static func fence(for text: String) -> String {
        var fence = "```"
        while text.contains(fence) {
            fence += "`"
        }
        return fence
    }

    // MARK: - Saf biçimleme (test edilebilir)

    /// Çalışma süresi: 30 sn altı saniye, saat altı dakika, üstü saat+dakika.
    /// İngilizce kısa birimler; sekmedeki durum satırı da bunu gösterir.
    static func uptimeString(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start).rounded()))
        if seconds < 60 {
            return "\(seconds) sec"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes) min"
        }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}
