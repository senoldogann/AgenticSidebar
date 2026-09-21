import AppKit
import SwiftUI

/// Hedef (`/goal`) paneli: bestecinin üstünde demirler (yan soru deseni).
/// Yalnız koşu varken görünür (aktif, duraklatılmış, kapatılmayı bekleyen
/// bitmiş ya da diskten devam edilebilir); boşken ipucu satırı yoktur.
/// Sade görünüm: başlık satırı her zaman görünür, gövde tek dokunuşla
/// daraltılıp genişletilir. Duraklatma oturumu kesmez; koşan tur kendi
/// halinde biter, devamında kaldığı yerden sürer.
struct GoalPanelView: View {
    @Bindable var orchestrator: GoalOrchestrator
    /// Oturum kapsamı: orkestratör bölme başına yaşar, o yüzden kart yalnız
    /// koşunun/retin oturumu odaktayken çizilir; başka sohbetteki hata ya da
    /// koşu bu sohbete sızmaz.
    let focusedSessionID: UUID

    @Environment(\.colorScheme) private var colorScheme
    @Environment(SettingsStore.self) private var settingsStore
    /// Besteciyle aynı dış kenar boşluğu: panel kenarları giriş kutusuyla
    /// hizalı durur (besteci `composerOuterPadding` ile aynı yardımcıdan okur).
    @Environment(\.paneWidth) private var paneWidth
    /// Gövde daraltma anahtarı: koşu başına sıfırlanır.
    @State private var isCollapsed = false
    /// Hedef düzenleme kipi: kapalıyken hedef tek satır özet, açıkken
    /// çok satırlı düzenleyici ve kaydet/vazgeç düğmeleri çizilir.
    @State private var isEditingObjective = false
    @State private var objectiveDraft = ""
    @State private var findingsCount = 0
    @State private var copyConfirmation = CopyConfirmation()
    @State private var folderError: String?

    var body: some View {
        if orchestrator.engine != nil, orchestrator.sessionID == focusedSessionID {
            card { content }
        } else if let resumable = orchestrator.resumableObjective,
            orchestrator.sessionID == focusedSessionID
        {
            card { resumeRow(objective: resumable) }
        } else if let failed = orchestrator.failedRequest, failed.sessionID == focusedSessionID {
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
    /// Meşgul reddi kuyruktur: tur bitince kendiliğinden başlar, kart bunu
    /// söyler ve klasör sormaz (dizin reddedildiği anda geçerliydi).
    private func failureRow(request: GoalOrchestrator.FailedGoalRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "target")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.purple)
                Text(request.autoStart ? "Goal queued" : "Goal couldn't start")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Button(request.autoStart ? "Cancel" : "Dismiss") {
                    orchestrator.clearFailure()
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .pointingHandCursor()
                .help(request.autoStart ? "Cancel the queued goal" : "Close this goal failure")
            }
            if let message = orchestrator.message {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(request.autoStart ? .blue : .orange)
            }
            Text("“\(request.objective)”")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
            if orchestrator.showsStaleGoalConflict {
                Text("No run is active in this conversation — the previous run never finished. Discard it, then send /goal again.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            if let folderError {
                Text(folderError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                if orchestrator.showsStaleGoalConflict {
                    Button("Discard stale goal") {
                        orchestrator.discardStaleStoredGoal()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .pointingHandCursor()
                    .help("Delete the stuck goal record so a new /goal can start")
                }
                if !request.autoStart {
                    Button("Choose project folder…") {
                        choosePackageFolder()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .pointingHandCursor()
                    .help("Choose the project folder (SwiftPM package or Xcode project) where build and tests will run, then retry")
                }
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

    /// Proje klasörü seçip reddedilen isteği aynı hedefle yeniden dener.
    /// Seçimde tek alt dizin projeyse orası kullanılır; desteklenen proje
    /// yoksa kartta kalır, dosya seçimi reddedilir.
    private func choosePackageFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose the project folder (SwiftPM package or Xcode project) where build and tests will run."
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            guard let usable = GoalRunners.usableProjectDirectory(at: url) else {
                folderError = "That folder has no SwiftPM package or Xcode project; choose a project folder."
                return
            }
            folderError = nil
            if orchestrator.retryFailedGoal(in: usable) {
                GoalStore.savePreferredPackageDirectory(usable.path)
            }
        }
    }

    // MARK: - Sade gövde

    @ViewBuilder
    private var content: some View {
        if let run = orchestrator.engine?.run {
            headerRow(run: run)
                .onChange(of: run.id) { _, _ in
                    isCollapsed = false
                    isEditingObjective = false
                    objectiveDraft = ""
                }
            if !isCollapsed {
                if !orchestrator.isActive {
                    terminalRow(run: run)
                } else {
                    objectiveSection(run: run)
                    statusLine(run: run)
                    if orchestrator.awaitingReview {
                        reviewSection
                    }
                    detailsSection(run: run)
                    logSection(run: run)
                }
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

    /// Başlık: her zaman görünür. Faz rozeti, başlangıç saati, anlık sayaç,
    /// daralt düğmesi ve duraklat/devam/bitir kontrolleri tek satırdadır.
    private func headerRow(run: GoalRun) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isCollapsed.toggle()
                }
            } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(isCollapsed ? "Goal ayrıntılarını genişlet" : "Goal ayrıntılarını daralt")
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
            // Başlangıç saati (duvar saati) + anlık sayan süre: bestecinin
            // üstünde goal ne zaman başladı ve ne kadar süredir koşuyor
            // tek bakışta görülür.
            Text("· \(GoalStartFormat.clock(run.startedAt))")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .help("Goal başlangıç saati: \(GoalStartFormat.full(run.startedAt))")
            GoalElapsedLabel(engine: orchestrator.engine)
            Spacer(minLength: 4)
            if run.phase == .paused {
                Button("Devam") {
                    orchestrator.resume()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointingHandCursor()
                .help("Duraklatılan goal kaldığı yerden sürer; oturum kesilmez")
            } else if orchestrator.isActive {
                Button("Duraklat") {
                    orchestrator.pause()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointingHandCursor()
                .help("Döngüyü duraklatır; koşan tur bitirilir, oturum kesilmez")
            }
            if orchestrator.isActive {
                Button("Bitir") {
                    orchestrator.stop()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointingHandCursor()
                .help("Koşan turu iptal eder, goal döngüsünü bitirir")
            }
        }
    }

    /// Hedef metni: kapalıyken iki satır özet + düzenle düğmesi; açıkken
    /// çok satırlı düzenleyici ve kaydet/vazgeç. Kaydet boşta ise düzeltme
    /// turunu kuyruklar, meşgulse sıradaki tur güncel metni kullanır.
    private func objectiveSection(run: GoalRun) -> some View {
        Group {
            if isEditingObjective {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $objectiveDraft)
                        .font(.system(size: 12))
                        .frame(minHeight: 56, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(
                            currentTheme.composerBackground(isDark: isDarkMode),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(
                                    currentTheme.border(isDark: isDarkMode).opacity(0.6),
                                    lineWidth: 1
                                )
                        )
                        .onAppear {
                            if objectiveDraft.isEmpty {
                                objectiveDraft = run.objective
                            }
                        }
                    HStack(spacing: 8) {
                        Button("Kaydet ve devam et") {
                            orchestrator.updateObjective(objectiveDraft)
                            isEditingObjective = false
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(
                            objectiveDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || objectiveDraft.trimmingCharacters(in: .whitespacesAndNewlines) == run.objective
                        )
                        .pointingHandCursor()
                        .help("Goal içeriğini günceller, ajan güncel içerikle devam eder")
                        Button("Vazgeç") {
                            isEditingObjective = false
                            objectiveDraft = run.objective
                        }
                        .buttonStyle(.plain)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                        .pointingHandCursor()
                        .help("Düzenlemeyi kapatır")
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    Text(run.objective)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Düzenle") {
                        objectiveDraft = run.objective
                        isEditingObjective = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointingHandCursor()
                    .help("Goal içeriğini güncelle; ajan güncel içerikle devam eder")
                }
            }
        }
        .onChange(of: run.objective) { _, newValue in
            if !isEditingObjective, objectiveDraft != newValue {
                objectiveDraft = newValue
            }
        }
    }

    private func statusLine(run: GoalRun) -> some View {
        HStack(spacing: 10) {
            Text("Iteration \(run.iteration)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Tool calls \(run.toolCallCount)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if run.unmetCriteriaCount > 0 {
                Text("Kriter \(run.criteria.count - run.unmetCriteriaCount)/\(run.criteria.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
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

    /// Ayrıntılar: kriter listesi, klasör ve rapor kopyası. Ana gövde sade
    /// kalır; ikincil kontroller burada daraltılabilir durur.
    private func detailsSection(run: GoalRun) -> some View {
        DisclosureGroup("Ayrıntılar") {
            VStack(alignment: .leading, spacing: 6) {
                if run.criteria.isEmpty {
                    Text("Kriter yok.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else {
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
                }
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text(orchestrator.workingDirectoryPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(orchestrator.workingDirectoryPath)
                    Button("Değiştir…") {
                        chooseActivePackageFolder()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointingHandCursor()
                    .help("Doğrulamanın koşacağı proje klasörünü değiştir")
                }
                if let folderError {
                    Text(folderError)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .help("Kriterler, klasör ve rapor kopyası")
    }

    private func binding(for item: AcceptanceCriterion) -> Binding<Bool> {
        Binding(
            get: { item.isMet },
            set: { orchestrator.setCriterion(id: item.id, isMet: $0) }
        )
    }

    /// Aktif koşunun klasörünü değiştirir: desteklenen proje barındırmayan
    /// dizin reddedilir, koşu etkilenmez. Başarılı seçim bir sonraki
    /// `/goal`un varsayılanı olur.
    private func chooseActivePackageFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose the project folder (SwiftPM package or Xcode project) where build and tests will run."
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            guard GoalRunners.usableProjectDirectory(at: url) != nil else {
                folderError = "That folder has no SwiftPM package or Xcode project; keeping the previous one."
                return
            }
            folderError = nil
            orchestrator.updateWorkingDirectory(path: url.path)
            if orchestrator.message == nil {
                GoalStore.savePreferredPackageDirectory(url.path)
            }
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
        // Panel sayacı da paylaşılan saniye saatini dinler: her hedef
        // kartı kendi `TimelineView` zamanlayıcısını kurmaz.
        SecondTick { date in
            Text(elapsedText(at: date))
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

/// Başlangıç saati biçimi: besteci üstünde goal ne zaman başladı tek
/// bakışta görülür. Saat `HH:mm:ss`, ipucu tam tarih-saat taşır.
enum GoalStartFormat {
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    static func full(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
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
