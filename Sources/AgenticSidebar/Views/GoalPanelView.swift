import AppKit
import SwiftUI

/// Hedef (`/goal`) paneli: bestecinin üstünde demirler (yan soru deseni).
/// Yalnız koşu varken görünür (aktif, duraklatılmış, kapatılmayı bekleyen
/// bitmiş ya da diskten devam edilebilir); boşken ipucu satırı yoktur.
/// Koşarken faz rozeti, geçen süre sayacı, kriter listesi, bütçe sayaçları,
/// duraklat/devam/durdur ve inceleme onayı taşır. Başlatma besteciden
/// (`/goal hedef`) gelir; panel olanı yönetir.
struct GoalPanelView: View {
    @Bindable var orchestrator: GoalOrchestrator

    @Environment(\.colorScheme) private var colorScheme
    @Environment(SettingsStore.self) private var settingsStore
    /// Besteciyle aynı dış kenar boşluğu: panel kenarları giriş kutusuyla
    /// hizalı durur (besteci `composerOuterPadding` ile aynı yardımcıdan okur).
    @Environment(\.paneWidth) private var paneWidth
    @State private var newCriterionText = ""
    @State private var findingsCount = 0
    @State private var directoryText = ""
    @State private var copyConfirmation = CopyConfirmation()
    @State private var folderError: String?

    var body: some View {
        if orchestrator.engine != nil {
            card { content }
        } else if let resumable = orchestrator.resumableObjective {
            card { resumeRow(objective: resumable) }
        } else if let failed = orchestrator.failedRequest {
            card { failureRow(request: failed) }
        }
    }

    // MARK: - İskelet

    private var isDarkMode: Bool {
        settingsStore.isDark(systemColorScheme: colorScheme)
    }

    private var currentTheme: AppThemePreset {
        settingsStore.currentThemePreset
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                currentTheme.surface(isDark: isDarkMode).opacity(0.96),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        currentTheme.border(isDark: isDarkMode).opacity(settingsStore.contrast),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(isDarkMode ? 0.30 : 0.08), radius: 8, y: 3)
            // Besteci gövdesiyle aynı kap (820) ve aynı dış dolgu: iki kartın
            // sol/sağ kenarları her bölme genişliğinde üst üste biner.
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, PaneResponsive.outerPadding(forWidth: paneWidth))
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .center)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Satırlar

    private func resumeRow(objective: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "target")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.purple)
            Text("A goal was left behind: “\(objective)”")
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button("Resume") {
                orchestrator.resumeStoredRun()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointingHandCursor()
            .help("Resume the stored goal run from its last safe step")
            Button("Discard") {
                orchestrator.dismiss()
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .foregroundStyle(.secondary)
            .pointingHandCursor()
            .help("Delete the stored goal run")
        }
    }

    /// Reddedilen başlatma kartı: hata, hedef ve yeniden deneme bir arada.
    /// Besteci taslağı koruduğu için metin kaybolmaz; kart yalnız nedeni
    /// açıklar ve ileriye yol verir (klasör seçimi ya da kapatma).
    private func failureRow(request: GoalOrchestrator.FailedGoalRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "target")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.purple)
                Text("Goal couldn't start")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Button("Dismiss") {
                    orchestrator.clearFailure()
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .pointingHandCursor()
                .help("Close this goal failure")
            }
            if let message = orchestrator.message {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
            }
            Text("“\(request.objective)”")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
            if let folderError {
                Text(folderError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Button("Choose package folder…") {
                    choosePackageFolder()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .pointingHandCursor()
                .help("Choose the Swift package folder where swift build and swift test will run, then retry")
                Button(copyConfirmation.isCopied ? "Copied" : "Copy objective") {
                    copyConfirmation.copy(request.objective)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointingHandCursor()
                .help("Copy the goal objective back to the clipboard")
            }
        }
    }

    /// Paket klasörü seçip reddedilen isteği aynı hedefle yeniden dener.
    /// `Package.swift` yoksa kartta kalır, dosya seçimi reddedilir.
    private func choosePackageFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose the Swift package folder where swift build and swift test will run."
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            guard GoalRunners.isSwiftPackage(at: url) else {
                folderError = "That folder has no Package.swift; choose a Swift package folder."
                return
            }
            folderError = nil
            if orchestrator.retryFailedGoal(in: url) {
                GoalStore.savePreferredPackageDirectory(url.path)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let run = orchestrator.engine?.run {
            headerRow(run: run)
            if !orchestrator.isActive {
                terminalRow(run: run)
            } else {
                criteriaSection(run: run)
                statusLine(run: run)
                directoryRow
                if orchestrator.awaitingReview {
                    reviewSection
                }
                controlsRow
                logSection(run: run)
            }
            if let message = statusMessage {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var statusMessage: String? {
        // Terminal özeti `terminalRow`da durur; burada yalnız ara mesajlar.
        guard orchestrator.isActive else {
            return nil
        }
        return orchestrator.message
    }

    private func headerRow(run: GoalRun) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "target")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.purple)
            Text("Goal")
                .font(.system(size: 12, weight: .semibold))
            Text(run.phase.rawValue)
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.purple.opacity(0.15), in: Capsule())
            GoalElapsedLabel(engine: orchestrator.engine)
            Text(run.objective)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if run.phase == .paused {
                Button("Resume") {
                    orchestrator.resume()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointingHandCursor()
                .help("Resume the paused goal loop")
            } else if orchestrator.isActive {
                Button("Pause") {
                    orchestrator.pause()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointingHandCursor()
                .help("Pause the goal loop after the current step")
            }
            if orchestrator.isActive {
                Button("Stop") {
                    orchestrator.stop()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointingHandCursor()
                .help("Stop the goal loop now (the running turn finishes harmlessly)")
            }
        }
    }

    private func criteriaSection(run: GoalRun) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(run.criteria, id: \.id) { item in
                Toggle(isOn: binding(for: item)) {
                    Text(item.text)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                .toggleStyle(.checkbox)
                .help("Mark this acceptance criterion as met or unmet")
            }
            HStack(spacing: 6) {
                TextField("Add a criterion…", text: $newCriterionText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { addCriterion() }
                    .help("Add another acceptance criterion to this goal")
                Button("Add") {
                    addCriterion()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(newCriterionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .pointingHandCursor()
                .help("Add the typed acceptance criterion")
            }
        }
    }

    private func binding(for item: AcceptanceCriterion) -> Binding<Bool> {
        Binding(
            get: { item.isMet },
            set: { orchestrator.setCriterion(id: item.id, isMet: $0) }
        )
    }

    private func addCriterion() {
        orchestrator.addCriterion(text: newCriterionText)
        newCriterionText = ""
    }

    private func statusLine(run: GoalRun) -> some View {
        HStack(spacing: 10) {
            Text("Iteration \(run.iteration)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Tool calls \(run.toolCallCount)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if orchestrator.isVerifying {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
                Text("Verifying…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .help("Loop counters: iterations and counted tool calls against the budget caps")
    }

    private var directoryRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            TextField("Package directory", text: $directoryText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
                .onAppear {
                    if directoryText.isEmpty {
                        directoryText = orchestrator.workingDirectoryPath
                    }
                }
                .onChange(of: orchestrator.workingDirectoryPath) { _, newPath in
                    directoryText = newPath
                }
                .onSubmit { applyDirectory() }
                .help("Swift package directory where swift build and swift test run")
            Button("Apply") {
                applyDirectory()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointingHandCursor()
            .help("Use this directory for the next verification step")
        }
    }

    private func applyDirectory() {
        orchestrator.updateWorkingDirectory(path: directoryText)
        // Başarılı dizin bir sonraki `/goal`un varsayılanı olur:
        // `updateWorkingDirectory` her yolda iletiyi yazar (hata ya da
        // `nil`), o yüzden `nil` başarı demektir.
        if orchestrator.message == nil {
            GoalStore.savePreferredPackageDirectory(
                directoryText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private var reviewSection: some View {
        HStack(spacing: 8) {
            Stepper("Open Critical/High findings: \(findingsCount)", value: $findingsCount, in: 0...99)
                .font(.system(size: 12))
                .help("How many Critical or High issues the review turn found (0 when clean)")
            Button("Confirm review") {
                orchestrator.confirmReview(findings: findingsCount)
                findingsCount = 0
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .pointingHandCursor()
            .help("Accept the review: finishes the goal when all gates are green, otherwise starts a fix turn")
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            Button {
                if let report = orchestrator.currentReport() {
                    copyConfirmation.copy(report)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copyConfirmation.isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5))
                    Text(copyConfirmation.isCopied ? "Copied" : "Copy report")
                        .font(.system(size: 11.5))
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointingHandCursor()
            .help("Copy the goal report (objective, gates, criteria, log) to the clipboard")
            Spacer(minLength: 0)
        }
    }

    private func logSection(run: GoalRun) -> some View {
        DisclosureGroup("Progress (\(run.log.count))") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(run.log.suffix(8).enumerated()), id: \.offset) { _, entry in
                    Text("\(entry.phase.rawValue) · \(entry.message)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .help("Show the latest goal loop steps")
    }

    private func terminalRow(run: GoalRun) -> some View {
        HStack(spacing: 8) {
            Image(systemName: run.phase == .done ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(run.phase == .done ? .green : .orange)
            Text(run.phase == .done ? "Goal done: all gates are green." : "Goal stopped.")
                .font(.system(size: 12, weight: .medium))
            if let engine = orchestrator.engine {
                Text("in \(GoalElapsedFormat.text(seconds: engine.elapsedSeconds(now: Date())))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .help("Total active goal time, excluding pauses")
            }
            Spacer(minLength: 4)
            Button {
                if let report = orchestrator.currentReport() {
                    copyConfirmation.copy(report)
                }
            } label: {
                Text(copyConfirmation.isCopied ? "Copied" : "Copy report")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointingHandCursor()
            .help("Copy the goal report (objective, gates, criteria, log) to the clipboard")
            Button("Dismiss") {
                orchestrator.dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointingHandCursor()
            .help("Clear the finished goal from this pane")
        }
    }
}

// MARK: - Geçen süre sayacı

/// Başlangıçtan beri akan hedef süresi: saniyede bir tazelenir, duraklatma
/// motorun sayacını dondurduğu için duraklatmada görünen değer de donar.
/// Saf biçim saf `GoalElapsedFormat` içindedir, donanımsız test edilir.
struct GoalElapsedLabel: View {
    let engine: GoalEngine?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            Text(elapsedText(at: context.date))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .help("Active goal time since start, excluding pauses")
        }
    }

    /// Etiket metni: motor yoksa boş, yoksa o andaki geçen süre.
    func elapsedText(at date: Date) -> String {
        guard let engine else {
            return ""
        }
        return GoalElapsedFormat.text(seconds: engine.elapsedSeconds(now: date))
    }
}

/// Saniye → `m:ss` / `h:mm:ss`: panel sayacı ve terminal özeti aynı dizeyi
/// gösterir, o yüzden biçim tek yerdedir.
enum GoalElapsedFormat {
    static func text(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
