import AppKit
import SwiftUI

struct RootChatView: View {
    @Environment(\.openWindow) private var openWindow

    let sessionService: any AgentSessionServiceProtocol
    let mainWindowController: MainWindowController
    let capturePrivacyController: CapturePrivacyController
    let settingsStore: SettingsStore
    let openAICredentialSettings: OpenAICredentialSettings
    let openCodeSettings: OpenCodeSettings
    let permissionApprovalCenter: PermissionApprovalCenter
    let clipboardMonitor: ClipboardMonitorService
    let screenshotMonitor: ScreenshotMonitorService
    /// Zaman çizelgesi kartlarının açık/kapalı durumu; sohbet değişiminde yaşar.
    let collapseStore: TimelineCollapseStore
    /// Yan yana sohbet düzeni; ikincil bölme sabitlenmiş oturumu tutar.
    let splitStore: SplitLayoutStore
    /// Görev panosunun ana aktör projeksiyonu; `nil` ise pano hiç takılmaz.
    let taskBoardStore: TaskBoardStore?
    let onApplyGlobalShortcut: @MainActor (GlobalShortcutSpec) -> Void

    /// Ayraç sürüklenirken oranın başlangıç değeri (aynı anda tek sürükleme).
    @State private var splitDragBase: Double?
    /// Sürüklenen sohbetin üzerinde durduğu yuva; halka yalnız orada çizilir.
    @State private var dropTargetedSlot: PaneSlot?
    /// Pano ayrı bir sayfada açılır: sohbet yüzeyi ve besteci durumu
    /// yerinde kalır, pano kendi seçimini sayfa kapanınca korur.
    @State private var showsTaskBoard = false
    /// "Proje ekle" satırının form durumu; kayıt başarıyla dönünce temizlenir.
    @State private var projectRegistrationName = ""
    @State private var projectRegistrationFolder: URL?
    @State private var projectRegistrationMessage: String?
    /// Proje yeniden adlandırma ve silme durumu; ret mesajı kayıt satırında
    /// gösterilir, ayrı bir hata yüzeyi yoktur.
    @State private var showsProjectRename = false
    @State private var projectRenameName = ""
    @State private var showsProjectDeleteConfirmation = false
    /// Canlı gönderim durumu; pano alt bandı bu değere göre çizilir.
    @State private var taskBoardLiveDispatchAvailable = true

    /// Pano sayfasının boyutları: kolonlar kullanılabilir genişliğe esner
    /// (`TaskBoardLayout`), o yüzden en küçük boy dar ekrana inebilir;
    /// varsayılan genişlik beş kolonu da kaydırmasız gösterir. Dikeyde pano
    /// esnektir (kolonlar kendi içinde kayar), alt satırlar sabittir; en
    /// küçük yükseklik alt satırları kesmeden pencereye sığar.
    private static let taskBoardSheetMinWidth: CGFloat = 720
    private static let taskBoardSheetDefaultWidth: CGFloat = 1500
    private static let taskBoardSheetMinHeight: CGFloat = 560
    private static let taskBoardSheetDefaultHeight: CGFloat = 920

    @Environment(\.colorScheme) private var systemColorScheme

    private var isDarkMode: Bool {
        settingsStore.isDark(systemColorScheme: systemColorScheme)
    }

    private var currentTheme: AppThemePreset {
        settingsStore.currentThemePreset
    }

    /// Canlı oturum kimlikleri; bölme doğrulaması silineni kapatır.
    private var liveSessionIDs: Set<UUID> {
        Set(sessionService.sessionList.map(\.id))
    }

    var body: some View {
        NavigationSplitView {
            ConversationSidebarView(sessionService: sessionService, splitStore: splitStore)
        } detail: {
            detailView
        }
        // No approval control in the toolbar: it lives in the composer (see
        // `ComposerView.approvalLevelSection`), beside the input it applies to,
        // and two controls for the same decision read as two decisions.
        .navigationSplitViewStyle(.prominentDetail)
        .background(currentTheme.background(isDark: isDarkMode))
        .toolbarBackground(currentTheme.background(isDark: isDarkMode), for: .windowToolbar)
        // Sabit pencere alt sınırı: kipa bağlı `minWidth` değişimi
        // (`900 ↔ 760`) display-cycle layout turunun ortasında
        // `NSHostingView.updateAnimatedWindowSize` tetikleyip AppKit'in
        // reentrancy istisnasıyla çökmesine (22:46 SIGABRT) yol açıyordu.
        // Yan yana görünüm dar pencereye içerdeki orantılı bölmeyle uyar.
        .frame(minWidth: 760, minHeight: 520)
        .environment(settingsStore)
        // `nil` for the System preference keeps the scene (and therefore every
        // semantic colour in it) tracking the real system appearance; forcing
        // the *resolved* mode here is what froze the app after one switch.
        .preferredColorScheme(settingsStore.colorSchemeMode.preferredColorScheme)
        .background {
            WindowLifecycleBridge(
                windowController: mainWindowController,
                capturePrivacyController: capturePrivacyController,
                stealthModeEnabled: settingsStore.stealthModeEnabled
            )
            .frame(width: 0, height: 0)
        }
        .onAppear {
            mainWindowController.setOpacity(settingsStore.windowOpacity)
            mainWindowController.setAppearance(settingsStore.colorSchemeMode)
            mainWindowController.setStealthMode(settingsStore.stealthModeEnabled)
            mainWindowController.setReopenAction {
                openWindow(id: "main")
            }
            onApplyGlobalShortcut(settingsStore.globalShortcutChoice.spec)
        }
        .onChange(of: settingsStore.colorSchemeMode) { _, newMode in
            mainWindowController.setAppearance(newMode)
        }
        .onChange(of: settingsStore.windowOpacity) { _, newOpacity in
            mainWindowController.setOpacity(newOpacity)
        }
        .onChange(of: settingsStore.globalShortcutChoice) { _, newChoice in
            onApplyGlobalShortcut(newChoice.spec)
        }
        .onChange(of: settingsStore.stealthModeEnabled) { _, newStealth in
            mainWindowController.setStealthMode(newStealth)
            capturePrivacyController.setStealthMode(newStealth)
        }
        .onChange(of: settingsStore.autoSubmitClipboard) { _, _ in
            clipboardMonitor.syncWithSettings()
        }
        .onChange(of: settingsStore.autoAnalyzeScreenshots) { _, _ in
            screenshotMonitor.syncWithSettings()
        }
        .onAppear {
            adoptSelection(sessionService.activeSessionID, previousActive: sessionService.activeSessionID)
            syncVisibleSessions(activeID: sessionService.activeSessionID)
        }
        .onChange(of: sessionService.sessionList.map(\.id)) { _, _ in
            splitStore.validate(liveIDs: liveSessionIDs, primary: sessionService.activeSessionID)
            syncVisibleSessions(activeID: sessionService.activeSessionID)
        }
        .onChange(of: sessionService.activeSessionID) { oldID, newID in
            adoptSelection(newID, previousActive: oldID)
            syncVisibleSessions(activeID: newID)
        }
        .onChange(of: splitStore.layoutMode) { _, _ in
            syncVisibleSessions(activeID: sessionService.activeSessionID)
        }
        .textSelection(.enabled)
        // Pano ayrı bir sayfada açılır: sohbet, besteci ve `/goal` yüzeylerine
        // dokunulmaz; pano yalnızca enjekte edilen mağazadan konuşur.
        .sheet(isPresented: $showsTaskBoard) {
            taskBoardSheet
        }
    }

    /// Görev panosu sayfası: proje seçici, kayıt satırı ve canlı gönderim
    /// durumunu dürüstçe söyleyen alt bant. Pano yalnızca enjekte edilen
    /// mağazadan konuşur; sahte "devre dışı" ibaresi gösterilmez.
    ///
    /// Sayfa çekerek yeniden boyutlandırılabilir: `frame(min/ideal/max:
    /// .infinity)` sayfayı esnek yapar, `presentationSizing(.fitted)` bilerek
    /// kullanılmaz çünkü fitted sayfayı içeriğe kilitleyip sürükleyerek
    /// büyütmeyi engeller. Kolonlar genişliğe esner, dar pencerede yatay
    /// kaydırma devreye girer; dikeyde kolonlar kendi içinde kayar, o yüzden
    /// pano en küçük yükseklikte de kesilmez.
    @ViewBuilder
    private var taskBoardSheet: some View {
        if let taskBoardStore {
            VStack(spacing: 0) {
                TaskBoardView(store: taskBoardStore, preset: currentTheme, isDark: isDarkMode)
                    // Pano sayfanın aslan payını alır: proje satırları sabit,
                    // kalan dikey alan kolonlara kalır. En küçük boy düşük
                    // tutulur, yoksa kısa ekranda alt satırlar kesilirdi.
                    .frame(minHeight: 300, maxHeight: .infinity)

                Divider().opacity(0.35)

                projectPickerRow(store: taskBoardStore)

                Divider().opacity(0.35)

                projectRegistrationRow(store: taskBoardStore)

                Divider().opacity(0.35)

                HStack(spacing: 6) {
                    Image(systemName: taskBoardLiveDispatchAvailable ? "bolt.circle" : "pause.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text(
                        taskBoardLiveDispatchAvailable
                            ? "Canlı koşu bağlı: Başlat, seçili sağlayıcıyla sahipli çalışma alanında koşar."
                            : "Canlı koşu bağlı değil: pano kaydı tutulur, sağlayıcıya yazma gönderilmez."
                    )
                    .font(.system(size: 11))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(
                minWidth: Self.taskBoardSheetMinWidth,
                idealWidth: Self.taskBoardSheetDefaultWidth,
                maxWidth: .infinity,
                minHeight: Self.taskBoardSheetMinHeight,
                idealHeight: Self.taskBoardSheetDefaultHeight,
                maxHeight: .infinity
            )
            .background(currentTheme.background(isDark: isDarkMode))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Görev panosu")
            .task {
                taskBoardLiveDispatchAvailable = await taskBoardStore.liveDispatchAvailable()
                await taskBoardStore.refreshProjects()
            }
        }
    }

    /// Kayıtlı projeler arasında geçiş; yeniden başlatma sonrası pano boş
    /// kalmasın diye liste kalıcı depodan beslenir.
    @ViewBuilder
    private func projectPickerRow(store: TaskBoardStore) -> some View {
        HStack(spacing: 8) {
            Text("Proje")
                .font(.system(size: 11, weight: .semibold))
            if store.projects.isEmpty {
                Text("Kayıtlı proje yok — aşağıdan ekleyin")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Kayıtlı proje yok")
            } else {
                Menu {
                    ForEach(store.projects) { project in
                        Button {
                            store.selectProject(project.id)
                            Task { await store.refresh() }
                        } label: {
                            Text(project.name)
                        }
                    }
                } label: {
                    Text(store.projects.first { $0.id == store.selectedProjectID }?.name ?? "Proje seçin")
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .controlSize(.small)
                .help("Kayıtlı projeler arasından seç")
                .accessibilityLabel("Proje seçin")
                projectManagementButtons(store: store)
            }
            Spacer(minLength: 0)
            Text("\(store.projects.count) proje")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .sheet(isPresented: $showsProjectRename) {
            projectRenameSheet(store: store)
        }
        .confirmationDialog(
            "Projeyi sil",
            isPresented: $showsProjectDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Projeyi sil", role: .destructive) {
                deleteSelectedProject(store: store)
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text(projectDeleteConfirmationMessage(store: store))
        }
    }

    /// Proje silme onay metni: seçili ad geçirilerek tek kaynaktan üretilir.
    private func projectDeleteConfirmationMessage(store: TaskBoardStore) -> String {
        guard let name = selectedProjectName(store: store) else {
            return "Seçili proje ve altındaki tüm görevler kalıcı olarak silinir."
        }
        return "“\(name)” ve altındaki tüm görevler kalıcı olarak silinir. Bu işlem geri alınamaz."
    }

    /// Seçili projenin görünen adı; seçim yoksa nil.
    private func selectedProjectName(store: TaskBoardStore) -> String? {
        guard let selected = store.selectedProjectID else { return nil }
        return store.projects.first { $0.id == selected }?.name
    }

    /// Proje satırındaki yeniden adlandır/sil düğmeleri; proje seçiliyken görünür.
    @ViewBuilder
    private func projectManagementButtons(store: TaskBoardStore) -> some View {
        if store.selectedProjectID != nil {
            Button {
                projectRenameName = selectedProjectName(store: store) ?? ""
                projectRegistrationMessage = nil
                showsProjectRename = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .interactiveHoverCircle()
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Projenin adını değiştir")
            .accessibilityLabel("Projeyi yeniden adlandır")

            Button {
                showsProjectDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .interactiveHoverCircle()
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .foregroundStyle(.red.opacity(0.85))
            .help("Projeyi ve görevlerini kalıcı olarak sil")
            .accessibilityLabel("Projeyi sil")
        }
    }

    /// Yeniden adlandırma sayfası: boş adla kaydetme kapalıdır, ret satırda söylenir.
    @ViewBuilder
    private func projectRenameSheet(store: TaskBoardStore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Projeyi yeniden adlandır")
                .font(.system(size: 14, weight: .semibold))
            TextField("Proje adı", text: $projectRenameName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .accessibilityLabel("Proje adı")
            HStack {
                Spacer()
                Button("Vazgeç") { showsProjectRename = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .pointingHandCursor()
                Button("Kaydet") {
                    renameSelectedProject(store: store)
                }
                .buttonStyle(.borderedProminent)
                .disabled(projectRenameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Proje adını kaydet")
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(currentTheme.background(isDark: isDarkMode))
    }

    private func renameSelectedProject(store: TaskBoardStore) {
        guard let selected = store.selectedProjectID else { return }
        let name = projectRenameName
        Task {
            let result = await store.renameProject(id: selected, name: name)
            switch result {
            case .applied:
                projectRegistrationMessage = nil
                showsProjectRename = false
            case .refused(let refusal):
                projectRegistrationMessage = refusal.message
                showsProjectRename = false
            }
        }
    }

    private func deleteSelectedProject(store: TaskBoardStore) {
        guard let selected = store.selectedProjectID else { return }
        Task {
            let result = await store.deleteProject(id: selected)
            switch result {
            case .applied:
                projectRegistrationMessage = nil
            case .refused(let refusal):
                projectRegistrationMessage = refusal.message
            }
        }
    }

    /// "Proje ekle" satırı: ad alanı, yalnızca klasör seçen bir seçici ve kayıt
    /// düğmesi. Kayıt servise `store.createProject` ile devredilir; red
    /// mesajları satırın altında görünür ve düğme kayıt sürerken kapanır.
    @ViewBuilder
    private func projectRegistrationRow(store: TaskBoardStore) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Yeni proje")
                    .font(.system(size: 11, weight: .semibold))
                TextField("Proje adı", text: $projectRegistrationName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .accessibilityLabel("Proje adı")
                Button("Klasör seç…") {
                    presentProjectFolderPicker()
                }
                .controlSize(.small)
                .help("Proje kök klasörünü seç")
                Text(projectRegistrationFolder?.path ?? "Klasör seçilmedi")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(projectRegistrationFolder?.path ?? "Klasör seçilmedi")
                Spacer(minLength: 0)
                Button("Proje ekle") {
                    submitProjectRegistration(store: store)
                }
                .controlSize(.small)
                .disabled(
                    !TaskBoardProjectRegistrationPresenter.submitEnabled(
                        name: projectRegistrationName,
                        repositoryURL: projectRegistrationFolder,
                        isSubmitting: store.isCreatingProject
                    )
                )
                .help("Seçilen klasörü Git deposu olarak panoya kaydet")
            }
            Text("Projenizin Git klasörünü seçin — kodunuz kopyalanmaz; ajan ayrı bir çalışma alanında çalışır")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            if let projectRegistrationMessage {
                Text(projectRegistrationMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .accessibilityLabel("Proje kaydı reddedildi: \(projectRegistrationMessage)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Klasör seçici yalnızca dizin kabul eder; seçim sonrası ad alanı klasör
    /// adından türetilir ve önceki hata mesajı temizlenir.
    private func presentProjectFolderPicker() {
        guard
            let url = DirectoryPicker.chooseDirectory(
                prompt: "Seç",
                message: "Projenin Git deposu klasörünü seçin"
            )
        else {
            return
        }
        projectRegistrationFolder = url
        projectRegistrationName = TaskBoardProjectRegistrationPresenter.suggestedName(for: url)
        projectRegistrationMessage = nil
    }

    /// Kayıt düğmesi: servis reddi mesajı satırda gösterilir; başarıda form
    /// temizlenir ve pano seçilen projeye geçer (mağaza bunu kendisi yapar).
    private func submitProjectRegistration(store: TaskBoardStore) {
        guard let folder = projectRegistrationFolder,
            TaskBoardProjectRegistrationPresenter.submitEnabled(
                name: projectRegistrationName,
                repositoryURL: projectRegistrationFolder,
                isSubmitting: store.isCreatingProject
            )
        else {
            return
        }
        let name = projectRegistrationName
        Task {
            let result = await store.createProject(name: name, repositoryURL: folder)
            switch result {
            case .applied:
                projectRegistrationName = ""
                projectRegistrationFolder = nil
                projectRegistrationMessage = nil
            case .refused(let refusal):
                projectRegistrationMessage = refusal.message
            }
        }
    }

    private func syncVisibleSessions(activeID: UUID) {
        let visibleIDs = Set(visibleScopes(activeID: activeID).compactMap(\.sessionID))
        sessionService.updateVisibleSessions(visibleIDs)
    }

    // MARK: - Bölme ızgarası

    /// Görünür bölme kapsamları: kip + sabitlemelerden türetilir. Birincil
    /// her zaman aktifi izler; boş yuvalar yer-tutucu gösterir (aktif
    /// oturuma düşülmez, yoksa iki bölme aynı sohbeti gösterirdi).
    private func visibleScopes(activeID: UUID) -> [PaneScope] {
        switch splitStore.layoutMode {
        case .single:
            [PaneScope(slot: .primary, sessionID: activeID)]
        case .dual:
            [
                PaneScope(slot: .primary, sessionID: activeID),
                PaneScope(slot: .secondary, sessionID: splitStore.sessionID(for: .secondary)),
            ]
        case .quad:
            PaneSlot.allCases.map { slot in
                PaneScope(
                    slot: slot,
                    sessionID: slot == .primary ? activeID : splitStore.sessionID(for: slot)
                )
            }
        }
    }

    /// Kenar çubuğundan seçilen sabitli oturum birincile taşınır: yuvası
    /// çözülür, eski birincil boşalan yuvaya geçer. Böylece iki bölme asla
    /// aynı sohbeti göstermez. Açılıştaki çakışma da burada çözülür.
    private func adoptSelection(_ newID: UUID, previousActive oldID: UUID) {
        if let slot = splitStore.slot(containing: newID) {
            splitStore.unpinSlot(slot)
            if oldID != newID, liveSessionIDs.contains(oldID) {
                splitStore.pin(oldID, to: slot)
            }
        }
        splitStore.focus(.primary)
        splitStore.validate(liveIDs: liveSessionIDs, primary: newID)
    }

    /// Birincil bölme her kipte de aynı yapısal konumda durur: tekli↔çoklu
    /// geçiş birincil `ConversationDetailView`'u yok etmez, o yüzden besteci
    /// taslağı, inspector sekmeleri, terminal kabukları ve kaydırma durumu
    /// korunur. Yalnız ek bölmeler eklenir/kaldırılır.
    private var detailView: some View {
        let activeID = sessionService.activeSessionID
        let scopes = visibleScopes(activeID: activeID)
        return GeometryReader { geometry in
            detailGrid(
                scopes: scopes,
                activeID: activeID,
                size: geometry.size
            )
        }
        .toolbar {
            // Tekli düzende bölme başlığı yoktur, o yüzden terminal düğmesinin
            // gideceği başka yer yoktur: yan yana kiplerde her bölme kendi
            // başlığındaki düğmeyi kullanır, tekli kipte araç çubuğundaki
            // düğme birincil bölmenin inspector sekmesinde terminal açar.
            if splitStore.layoutMode == .single {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        NotificationCenter.default.post(
                            name: .openPaneTerminal,
                            object: PaneSlot.primary.rawValue
                        )
                    } label: {
                        Image(systemName: "terminal")
                    }
                    .help("Open a terminal in this conversation's side panel")
                    .accessibilityLabel("Open terminal")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        NotificationCenter.default.post(
                            name: .openPaneComputerLive,
                            object: PaneSlot.primary.rawValue
                        )
                    } label: {
                        Image(systemName: "computermouse")
                    }
                    .help("Watch the computer-use session live in the side panel")
                    .accessibilityLabel("Watch computer use")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        NotificationCenter.default.post(
                            name: .openPaneSimulator,
                            object: PaneSlot.primary.rawValue
                        )
                    } label: {
                        Image(systemName: "iphone")
                    }
                    .help("Open the iOS Simulator in the side panel")
                    .accessibilityLabel("Open iOS Simulator")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        NotificationCenter.default.post(
                            name: .openPaneBrowser,
                            object: PaneSlot.primary.rawValue
                        )
                    } label: {
                        Image(systemName: "globe")
                    }
                    .help("Open a browser in the side panel")
                    .accessibilityLabel("Open browser")
                }
                // Canlı review düğmesi yalnız değişiklik varken çizilir:
                // klasörsüz ya da dokunulmamış sohbette araç çubuğu şişmez.
                if let activeSession = sessionService.session(for: sessionService.activeSessionID),
                    TurnFileChangesSummary.hasFileChanges(in: activeSession.state.activityGroups)
                {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            NotificationCenter.default.post(
                                name: .openPaneSessionChanges,
                                object: PaneSlot.primary.rawValue
                            )
                        } label: {
                            Image(systemName: "doc.badge.plus")
                        }
                        .help("Review this conversation's file changes in the side panel")
                        .accessibilityLabel("Review file changes")
                    }
                }
            }
            if taskBoardStore != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsTaskBoard = true
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .help("Görev panosunu aç")
                    .accessibilityLabel("Görev panosunu aç")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                layoutPicker
            }
        }
        .task {
            // Dal üreten bölmeye yerleşir (`ConversationDetailView.forkFromHere`
            // bildirir); her yuva yalnız kendine geleni alır.
            for await note in NotificationCenter.default.notifications(named: .adoptForkedBranch) {
                guard let info = note.object as? [String: Any],
                    let raw = info["slot"] as? String,
                    let slot = PaneSlot(rawValue: raw),
                    let branch = info["session"] as? UUID,
                    sessionService.session(for: branch) != nil
                else {
                    continue
                }
                splitStore.pin(branch, to: slot)
                splitStore.focus(slot)
            }
        }
    }

    /// Düzen seçici: tekli, yan yana ikili, 2×2 dörtlü. Sabitlemeler korunur,
    /// kip değişimi sohbet kapatmaz.
    private var layoutPicker: some View {
        Picker("Conversation layout", selection: layoutBinding) {
            Image(systemName: "rectangle").tag(PaneLayoutMode.single)
            Image(systemName: "rectangle.split.2x1").tag(PaneLayoutMode.dual)
            Image(systemName: "square.grid.2x2").tag(PaneLayoutMode.quad)
        }
        .pickerStyle(.segmented)
        .help("Conversation layout: single, side by side, or a 2 by 2 grid")
    }

    private var layoutBinding: Binding<PaneLayoutMode> {
        Binding(
            get: { splitStore.layoutMode },
            set: { splitStore.setLayoutMode($0) }
        )
    }

    @ViewBuilder
    private func detailGrid(scopes: [PaneScope], activeID: UUID, size: CGSize) -> some View {
        let total = max(0, size.width)
        let height = max(0, size.height)
        if scopes.isEmpty {
            EmptyView()
        } else {
            switch splitStore.layoutMode {
            case .single:
                paneCell(scopes[0], activeID: activeID, showHeader: false, showSwap: false)
                    .frame(width: total, height: height)
            case .dual:
                let (first, second) = paneLength(total: total, fraction: splitStore.splitFraction)
                HStack(spacing: 0) {
                    paneCell(scopes[0], activeID: activeID, showHeader: true, showSwap: true)
                        .frame(width: first, height: height)
                    if scopes.count > 1 {
                        gridDivider(.dualSplit, total: total)
                        paneCell(scopes[1], activeID: activeID, showHeader: true, showSwap: true)
                            .frame(width: second, height: height)
                    }
                }
                .frame(width: total, height: height)
            case .quad:
                if scopes.count >= 4 {
                    let (left, right) = paneLength(total: total, fraction: splitStore.columnFraction)
                    let (top, bottom) = paneLength(total: height, fraction: splitStore.rowFraction)
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            paneCell(scopes[0], activeID: activeID, showHeader: true, showSwap: false)
                                .frame(width: left, height: top)
                            gridDivider(.gridColumn, total: total)
                            paneCell(scopes[1], activeID: activeID, showHeader: true, showSwap: false)
                                .frame(width: right, height: top)
                        }
                        .frame(width: total, height: top)
                        gridDivider(.gridRow, total: height)
                        HStack(spacing: 0) {
                            paneCell(scopes[2], activeID: activeID, showHeader: true, showSwap: false)
                                .frame(width: left, height: bottom)
                            gridDivider(.gridColumn, total: total)
                            paneCell(scopes[3], activeID: activeID, showHeader: true, showSwap: false)
                                .frame(width: right, height: bottom)
                        }
                        .frame(width: total, height: bottom)
                    }
                    .frame(width: total, height: height)
                } else {
                    paneCell(scopes[0], activeID: activeID, showHeader: false, showSwap: false)
                        .frame(width: total, height: height)
                }
            }
        }
    }

    /// Oranlı bölme boyu: kenar çubuğu açılıp alan daraldığında bölmeler
    /// orantılı daralır, taşma olmaz. Ayraç payı düşülür. Sert taban toplam
    /// alandan büyük olduğunda taban gevşetilir: boylar her zaman toplama
    /// eşitlenir.
    private func paneLength(total: CGFloat, fraction: Double) -> (first: CGFloat, second: CGFloat) {
        let dividerWidth: CGFloat = 7
        let available = max(0, total - dividerWidth)
        let comfortableMin: CGFloat = 320
        let hardMin: CGFloat = 240
        if available <= 2 * hardMin {
            return (available * fraction, available * (1 - fraction))
        }
        let lo = min(comfortableMin, available - hardMin)
        let hi = max(lo, available - hardMin)
        let first = min(max(available * fraction, lo), hi)
        return (first, max(0, available - first))
    }

    /// Tek bölme hücresi: başlık + sohbet ya da yer-tutucu. Kimlik yuvaya
    /// sabitlenir; yoksa yuva değişiminde besteci taslağı ve kaydırma durumu
    /// düşerdi. Her tıklama yuvayı odaklar (HUD takibi); alt denetimler
    /// çalışmaya devam eder.
    private func paneCell(_ scope: PaneScope, activeID: UUID, showHeader: Bool, showSwap: Bool) -> some View {
        PaneWidthReader(
            content: VStack(spacing: 0) {
                if scope.isPrimary, let pending = visiblePendingID {
                    pendingPane(
                        scope: scope,
                        pendingID: pending,
                        activeID: activeID,
                        showHeader: showHeader,
                        showSwap: showSwap
                    )
                } else if scope.isPrimary {
                    conversationPane(
                        scope: scope, sessionID: activeID, activeID: activeID, showHeader: showHeader, showSwap: showSwap, focusID: nil)
                } else if let pinned = scope.sessionID,
                    sessionService.session(for: pinned) != nil
                {
                    conversationPane(
                        scope: scope, sessionID: pinned, activeID: activeID, showHeader: showHeader, showSwap: showSwap, focusID: pinned)
                } else {
                    emptyPane(scope: scope, activeID: activeID)
                }
            }
        )
        .id("pane-\(scope.slot.rawValue)")
        // Bölme tıklaması mavi odak çerçevesi çizer: başlık ve içerik
        // zaten odağı belli eder (başlık, meşgul noktası), sistem efekti kapalı.
        .focusEffectDisabled()
        .onTapGesture {
            splitStore.focus(scope.slot)
        }
        .overlay {
            if dropTargetedSlot == scope.slot {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.7), lineWidth: 2)
                    .padding(8)
            }
        }
        .onDrop(of: SplitDropSupport.dropTypes, isTargeted: dropBinding(for: scope.slot)) { providers in
            handleDrop(providers, to: scope.slot, activeID: activeID)
        }
    }

    /// Bekleyen taslak birincilde görünür mü: kimlik var, görünür işaretli
    /// ve çözülüyor. Sohbet seçimi gizler (taslak durur), `+` yeniden gösterir.
    private var visiblePendingID: UUID? {
        guard sessionService.isPendingSessionVisible,
            let pending = sessionService.pendingSessionID,
            sessionService.session(for: pending) != nil
        else {
            return nil
        }
        return pending
    }

    /// Gönderilmemiş yeni sohbet: boş transkript + besteci; ilk gönderimde
    /// aynı kimlikle gerçek oturum doğar. Sohbet listede yoktur.
    private func pendingPane(scope: PaneScope, pendingID: UUID, activeID: UUID, showHeader: Bool, showSwap: Bool) -> some View {
        VStack(spacing: 0) {
            pendingHintRow
            conversationPane(
                scope: scope,
                sessionID: pendingID,
                activeID: activeID,
                showHeader: showHeader,
                showSwap: showSwap,
                focusID: pendingID
            )
        }
    }

    /// Bekleyen taslak şeridi: ne olacağı tek cümle, vazgeçme tek düğme.
    /// Vazgeçme oturum doğurmaz, taslak silinir. Taslak klasöre bağlıysa
    /// klasör adı da söylenir, yoksa ek etiket çizilmez.
    private var pendingHintRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.bubble")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(pendingHintText)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button("Discard") {
                sessionService.discardPendingSession()
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .foregroundStyle(.secondary)
            .help("Discard this unsent draft (no session is created)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Bekleyen taslağın ipucu metni: klasör bağlıysa adıyla söylenir.
    /// Ad türetimi `WorkingDirectoryDisplay` tek kaynağındadır.
    private var pendingHintText: String {
        guard let pending = sessionService.pendingSessionID,
            let path = sessionService.session(for: pending)?.workingDirectoryPath,
            let name = WorkingDirectoryDisplay.name(for: path)
        else {
            return "New session — sending the first message creates the chat."
        }
        return "New session in “\(name)” — sending the first message creates the chat."
    }

    /// Yan yana iken pencere araç çubuğu başlığı kullanılmaz: bölmeler kendi
    /// başlığını gösterir, yoksa birincil bölmenin terminal simgesi pencerenin
    /// en sağına düşer ve sağdaki sohbete ait sanılır.
    private func conversationPane(scope: PaneScope, sessionID: UUID, activeID: UUID, showHeader: Bool, showSwap: Bool, focusID: UUID?)
        -> some View
    {
        // Başlık rozeti için ucuz ön kontrol: sayım/diff birleştirme yok,
        // ilk dosya bulgusunda durur; tam özet tıklama anında hesaplanır.
        let paneSession = sessionService.session(for: sessionID)
        let paneHasFileChanges =
            paneSession.map { TurnFileChangesSummary.hasFileChanges(in: $0.state.activityGroups) } ?? false
        return VStack(spacing: 0) {
            if showHeader {
                SplitPaneHeader(
                    title: paneSession?.qualifiedTitle ?? "Session",
                    directoryPath: paneSession?.workingDirectoryPath,
                    isBusy: paneSession?.isBusy ?? false,
                    onFocus: scope.isPrimary
                        ? nil
                        : {
                            sessionService.selectSession(sessionID)
                        },
                    onSwap: {
                        if scope.isPrimary {
                            if let other = splitStore.sessionID(for: .secondary) {
                                sessionService.selectSession(other)
                            }
                        } else {
                            sessionService.selectSession(activeID)
                        }
                    },
                    showsSwap: showSwap,
                    onClose: scope.isPrimary
                        ? nil
                        : {
                            splitStore.unpinSlot(scope.slot)
                        },
                    onOpenTerminal: {
                        NotificationCenter.default.post(
                            name: .openPaneTerminal,
                            object: scope.paneID
                        )
                    },
                    onOpenComputerLive: {
                        NotificationCenter.default.post(
                            name: .openPaneComputerLive,
                            object: scope.paneID
                        )
                    },
                    onOpenSimulator: {
                        NotificationCenter.default.post(
                            name: .openPaneSimulator,
                            object: scope.paneID
                        )
                    },
                    onOpenBrowser: {
                        NotificationCenter.default.post(
                            name: .openPaneBrowser,
                            object: scope.paneID
                        )
                    },
                    onOpenSessionChanges: {
                        NotificationCenter.default.post(
                            name: .openPaneSessionChanges,
                            object: scope.paneID
                        )
                    },
                    hasFileChanges: paneHasFileChanges
                )
            }
            ConversationDetailView(
                sessionService: sessionService,
                permissionApprovalCenter: permissionApprovalCenter,
                collapseStore: collapseStore,
                focusedSessionID: focusID,
                paneID: scope.paneID,
                showsNavigationTitle: !showHeader,
                isDenseLayout: splitStore.layoutMode != .single
            )
        }
    }

    /// Boş yuva: atanabilir sohbetler menüsü + bırakma hedefi. Aktif oturum
    /// ve sabitli oturumlar listelenmez; iki bölme aynı sohbeti gösteremez.
    private func emptyPane(scope: PaneScope, activeID: UUID) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("Empty pane")
                .font(.system(size: 13, weight: .semibold))
            Menu {
                ForEach(assignableSessions(activeID: activeID), id: \.id) { session in
                    Button(session.qualifiedTitle) {
                        splitStore.pin(session.id, to: scope.slot)
                        splitStore.focus(scope.slot)
                    }
                }
            } label: {
                Text("Open conversation")
            }
            .help("Pin a conversation to this pane")
            Text("or drop a conversation here")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func assignableSessions(activeID: UUID) -> [SessionSummary] {
        let pinned = splitStore.pinnedSessionIDs
        return sessionService.sessionList.filter { $0.id != activeID && !pinned.contains($0.id) }
    }

    private func dropBinding(for slot: PaneSlot) -> Binding<Bool> {
        Binding(
            get: { dropTargetedSlot == slot },
            set: { dropTargetedSlot = $0 ? slot : nil }
        )
    }

    /// Bırakılan oturumu yuvaya yerleştirir. Birincile bırakma eski tekli
    /// davranıştır (ilk boş yuvaya sabitle); sabitliyi bırakma o yuvaya
    /// odaklar; aktifi bırakma yok sayılır.
    private func handleDrop(_ providers: [NSItemProvider], to slot: PaneSlot, activeID: UUID) -> Bool {
        SplitDropSupport.sessionID(from: providers) { id in
            if slot == .primary {
                if let existing = splitStore.slot(containing: id) {
                    splitStore.focus(existing)
                    return
                }
                guard id != activeID else {
                    return
                }
                if let affected = splitStore.togglePin(id) {
                    splitStore.focus(affected)
                }
                return
            }
            guard id != activeID else {
                return
            }
            splitStore.pin(id, to: slot)
            splitStore.focus(slot)
        }
    }

    private enum DividerTarget {
        case dualSplit
        case gridColumn
        case gridRow
    }

    private func gridDivider(_ target: DividerTarget, total: CGFloat) -> some View {
        let isVertical = target != .gridRow
        return Rectangle()
            .fill(Color.clear)
            .frame(width: isVertical ? 7 : nil, height: isVertical ? nil : 7)
            .overlay(
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: isVertical ? 1 : nil, height: isVertical ? nil : 1)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    (isVertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard total > 1 else { return }
                        if splitDragBase == nil {
                            splitDragBase = currentDividerFraction(target)
                        }
                        let delta = (isVertical ? value.translation.width : value.translation.height) / total
                        previewDividerFraction(target, (splitDragBase ?? 0.5) + delta)
                    }
                    .onEnded { _ in
                        splitDragBase = nil
                        // Sürükleme tek bir karardır: kalıcılık parmak kalkınca,
                        // olay başına değil.
                        splitStore.commitFractions()
                    }
            )
            .help(dividerHelp(target))
    }

    private func currentDividerFraction(_ target: DividerTarget) -> Double {
        switch target {
        case .dualSplit: splitStore.splitFraction
        case .gridColumn: splitStore.columnFraction
        case .gridRow: splitStore.rowFraction
        }
    }

    private func previewDividerFraction(_ target: DividerTarget, _ fraction: Double) {
        switch target {
        case .dualSplit: splitStore.previewSplitFraction(fraction)
        case .gridColumn: splitStore.previewColumnFraction(fraction)
        case .gridRow: splitStore.previewRowFraction(fraction)
        }
    }

    private func dividerHelp(_ target: DividerTarget) -> String {
        switch target {
        case .dualSplit: "Drag to resize the two conversations"
        case .gridColumn: "Drag to resize the left and right panes"
        case .gridRow: "Drag to resize the top and bottom panes"
        }
    }
}

// MARK: - Proje kaydı sunumu

/// "Proje ekle" satırının saf sunum mantığı: düğme etkinliği ve klasörden
/// türetilen varsayılan ad. SwiftUI gövdesinden bağımsız olduğundan doğrudan
/// sınanabilir; servis doğrulaması burada tekrarlanmaz.
enum TaskBoardProjectRegistrationPresenter {
    /// Kayıt düğmesi yalnızca boş olmayan ad, seçilmiş klasör ve sürmeyen bir
    /// kayıt varken etkindir.
    static func submitEnabled(name: String, repositoryURL: URL?, isSubmitting: Bool) -> Bool {
        guard !isSubmitting, repositoryURL != nil else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Seçilen klasörün adı; kök gibi adsız bir yol için "Proje" döner.
    static func suggestedName(for repositoryURL: URL) -> String {
        let name = repositoryURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "/" ? "Proje" : name
    }
}
