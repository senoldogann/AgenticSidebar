import AppKit
import SwiftUI

// MARK: - Diagnostics Tab

extension SettingsView {
    /// Cihaz-içi gözlem tek menüde: durum, çökme raporları, araç gözlemi ve
    /// dışa aktarma. Her şey yerelde okunur; dışarıya hiçbir şey gönderilmez.
    /// Dışa aktarma komut metni içerir, o yüzden hedefi kullanıcı seçer.
    ///
    /// Kart kromu diğer sekmelerle aynıdır (`settingsCard`): sekmeye özel
    /// çerçeve bu dosyaya geri gelmemeli, yoksa sayfa yine dağılır.
    @ViewBuilder
    var diagnosticsTabContent: some View {
        Group {
            diagnosticsStatusCard

            diagnosticsCrashesCard

            toolDecisionLogCard

            diagnosticsExportCard
        }
        .task {
            await reloadDiagnostics()
        }
    }

    // MARK: - Durum

    @ViewBuilder
    private var diagnosticsStatusCard: some View {
        settingsCard(
            title: "Status",
            subtitle: "App version, uptime and what the app currently holds.",
            icon: "heart.text.square"
        ) {
            if let snapshot = diagnosticsSnapshot {
                VStack(alignment: .leading, spacing: 6) {
                    diagnosticsStatusRow(label: "Version", value: snapshot.appVersion)
                    diagnosticsStatusRow(
                        label: "Uptime",
                        value: DiagnosticsCenter.uptimeString(
                            from: snapshot.launchedAt,
                            to: snapshot.collectedAt
                        )
                    )
                    diagnosticsStatusRow(
                        label: "Tool decisions",
                        value: "\(snapshot.recentDecisions.count) records"
                    )
                    diagnosticsStatusRow(
                        label: "Tool executions",
                        value: "\(snapshot.recentExecutions.count) records"
                    )
                    diagnosticsStatusRow(
                        label: "Goal",
                        value: snapshot.goalSummary ?? "no running goal"
                    )
                    if snapshot.previousRunCrashed {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("The previous run ended unexpectedly. Reports are listed below.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.orange)
                        }
                        .padding(.top, 4)
                    }
                }
            } else {
                Text("Loading…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func diagnosticsStatusRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .textSelection(.enabled)
        }
    }

    // MARK: - Çökmeler

    @ViewBuilder
    private var diagnosticsCrashesCard: some View {
        settingsCard(
            title: "Crash Reports",
            subtitle: "Unexpected terminations captured on disk.",
            icon: "exclamationmark.bubble"
        ) {
            if let snapshot = diagnosticsSnapshot {
                if snapshot.crashReports.isEmpty {
                    Text("No records. A clean-exit marker is written at every launch and removed on graceful shutdown.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(snapshot.crashReports) { report in
                            diagnosticsCrashRow(report)
                        }
                    }
                }
            } else {
                Text("Loading…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func diagnosticsCrashRow(_ report: CrashReport) -> some View {
        let isExpanded = diagnosticsExpandedReportID == report.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        diagnosticsExpandedReportID = isExpanded ? nil : report.id
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(report.name)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                        Text("(\(report.size) bytes)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(isExpanded ? "Collapse report" : "Expand report")

                Spacer(minLength: 4)

                Button {
                    CrashReporter.deleteReport(report)
                    Task { await reloadDiagnostics() }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Delete this report")
            }

            if isExpanded {
                ScrollView {
                    Text(report.text.isEmpty ? "(unreadable)" : report.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Araç gözlemi (AI sekmesinden taşındı)

    /// Uygulamanın gerçekte neye karar verdiği, sırasıyla ve gerekçesiyle.
    ///
    /// Sormayan seviyede istemin yerine geçen listedir: neyin nereden
    /// çalıştığı ve düzeye, eski "Always allow" kaydına ya da kullanıcıya
    /// kimin cevap verdiği. Gözlem Diagnostics menüsünde durur; AI sekmesindeki
    /// kopya kaldırıldı (aynı kuyruğun iki izleyicisi sayfayı dağıtıyordu).
    /// Kapalı bir görüntüleyicidir — kayıt `audit.jsonl` dosyasına zaten
    /// yazılır, bu kart yalnız kuyruğunu gösterir.
    @ViewBuilder
    var toolDecisionLogCard: some View {
        collapsibleSettingsCard(
            title: "Recent tool activity",
            subtitle: "Observed executions and permission decisions are recorded separately, newest first.",
            icon: "list.bullet.rectangle",
            isExpanded: $isToolDecisionLogExpanded,
            trailingText: recentDecisions.isEmpty && recentExecutions.isEmpty
                ? nil : "\(recentDecisions.count + recentExecutions.count)"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Observed executions")
                    .font(.system(size: 12, weight: .semibold))
                if recentExecutions.isEmpty {
                    Text("No tool execution has been observed yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recentExecutions.reversed()) { record in
                        toolExecutionRow(record)
                    }
                }

                Divider().opacity(0.3)
                Text("Permission decisions")
                    .font(.system(size: 12, weight: .semibold))
                if recentDecisions.isEmpty {
                    Text("No permission decisions have been recorded yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recentDecisions.reversed()) { record in
                        toolDecisionRow(record)
                    }
                }

                HStack(spacing: 10) {
                    secondaryActionButton(
                        title: "Refresh",
                        icon: "arrow.clockwise"
                    ) {
                        Task { await reloadRecentToolActivity() }
                    }

                    secondaryActionButton(
                        title: "Reveal audit log",
                        icon: "folder"
                    ) {
                        NSWorkspace.shared.activateFileViewerSelecting([toolAuditLogURL])
                    }
                }
            }
        }
        // Kart kapalıyken de başlıktaki sayı güncel kalsın diye kuyruk kart
        // görünür olduğunda okunur; satırlar yalnız açılınca kurulur.
        .task { await reloadRecentToolActivity() }
    }

    @ViewBuilder
    private func toolDecisionRow(_ record: ToolAuditLog.Record) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(toolDecisionTint(record.reply))
                    .frame(width: 6, height: 6)

                Text(record.title)
                    .font(.system(size: 12, weight: .semibold))

                Text(record.reply.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(toolDecisionTint(record.reply))

                Spacer(minLength: 8)

                Text(record.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Text(
                record.patterns.isEmpty
                    ? "\(record.source.label) · \(record.toolName)"
                    : "\(record.source.label) · \(record.patterns.joined(separator: ", "))"
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func toolExecutionRow(_ record: ToolAuditLog.ExecutionRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(record.event == .failed ? Color.red : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(record.title ?? record.toolKind.rawValue.capitalized)
                    .font(.system(size: 12, weight: .semibold))
                Text(record.event.rawValue.capitalized)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(record.event == .failed ? .red : .secondary)
                Spacer(minLength: 8)
                Text(record.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(record.detail ?? record.toolKind.rawValue)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toolDecisionTint(_ reply: ProviderPermissionReply) -> Color {
        switch reply {
        case .once, .always:
            return .green
        case .reject:
            return .red
        }
    }

    private var toolAuditLogURL: URL {
        ManagedAppDirectories.openCodeWorkingDirectory()
            .appendingPathComponent("audit.jsonl")
    }

    private func reloadRecentToolActivity() async {
        recentDecisions = await permissionApprovalCenter.recentDecisions(limit: 20)
        recentExecutions = await permissionApprovalCenter.recentExecutions(limit: 20)
    }

    // MARK: - Dışa aktarma

    @ViewBuilder
    private var diagnosticsExportCard: some View {
        settingsCard(
            title: "Export",
            subtitle: "One markdown file for status, crashes, the goal run and recent tool decisions.",
            icon: "square.and.arrow.up"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Command text is included; save it only somewhere you trust.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button {
                        Task { await reloadDiagnostics() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .disabled(diagnosticsIsLoading)
                    .opacity(diagnosticsIsLoading ? 0.5 : 1)
                    .help("Re-read records")

                    Button {
                        exportDiagnosticsSnapshot()
                    } label: {
                        Label("Save report…", systemImage: "square.and.arrow.down")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .disabled(diagnosticsSnapshot == nil)
                    .opacity(diagnosticsSnapshot == nil ? 0.5 : 1)
                    .help("Save the diagnostics report as markdown")

                    if let exportError = diagnosticsExportError {
                        Text(exportError)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    // MARK: - Yükleme

    private func reloadDiagnostics() async {
        diagnosticsIsLoading = true
        defer { diagnosticsIsLoading = false }
        diagnosticsSnapshot = await DiagnosticsCenter.collect()
    }

    private func exportDiagnosticsSnapshot() {
        guard let snapshot = diagnosticsSnapshot else {
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AgenticSidebar-diagnostics.md"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            try DiagnosticsCenter.exportMarkdown(snapshot).write(to: url, atomically: true, encoding: .utf8)
            diagnosticsExportError = nil
        } catch {
            diagnosticsExportError = "Could not save: \(error.localizedDescription)"
        }
    }
}
