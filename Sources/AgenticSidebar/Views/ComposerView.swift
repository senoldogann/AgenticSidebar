import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    let sessionService: any AgentSessionServiceProtocol
    /// Answers this session's "Always allow" decisions and holds the prompts that
    /// are waiting, which the level control has to show and re-answer.
    let permissionApprovalCenter: PermissionApprovalCenter
    /// The session this composer writes to; when nil, it tracks the active session.
    /// In multi-pane (dual or quad) split layouts, secondary, tertiary, and quaternary
    /// panes pass their pinned session UUID to isolate drafts, queues, and message dispatch.
    let focusedSessionID: UUID?
    let onInspectFile: ((URL) -> Void)?
    /// Hook for side questions (`/btw`).
    let onSideQuestion: ((String, ResponseSpeedMode, AgentMode) -> Void)?
    /// Hook for one-tap prompt enhancement: the current draft plus the tag and
    /// attachment names visible in the composer. The hook owns the enhancement
    /// run and writes the improved text back into the draft.
    let onEnhancePrompt: ((String, ResponseSpeedMode, AgentMode, [String], [String]) -> Void)?
    /// Hook for cancelling a running enhancement (the wand button becomes a
    /// cancel target while streaming, so a stuck or unwanted run is stoppable).
    let onCancelEnhancePrompt: (() -> Void)?
    /// Hook for undoing the last applied enhancement: restores the draft text
    /// from before the improvement. Attachments and tags are untouched.
    let onUndoEnhancePrompt: (() -> Void)?
    /// Enhancement availability (provider context exists) and run state. Both
    /// default off so previews and tests keep compiling without the feature.
    let isEnhancePromptAvailable: Bool
    let isEnhancingPrompt: Bool
    /// Whether an undoable enhancement exists for the focused session. Shown
    /// as a separate button so the improved text stays reviewable and
    /// revertible before submission (Qoder parity: undo or submit).
    let isUndoEnhanceAvailable: Bool
    /// Hook for goals (`/goal`). Başarıyı döner: `true` ise taslak
    /// temizlenir, `false` ise metin alanda kalır (ret panelde görünür).
    /// Son parametre bestecideki bekleyen eklerin yollarıdır; hedef dizin
    /// çözümlemesinde tohum sayılır.
    let onStartGoal: ((String, ResponseSpeedMode, AgentMode, [String]) -> Bool)?
    /// File manager injected for path filtering.
    let fileManager: FileManager
    /// Oturumun klasöründeki git dalları: bestecideki dal seçici buradan
    /// beslenir; git dışı klasörde ya da klasörsüz oturumda seçici gizlenir.
    let gitBranchStore: GitBranchStore
    /// 2'li ve 4'lü düzende dikey alan bölünür: bölme genişliği tekli
    /// düzeni andırsa bile besteci minimal çizilir.
    let isDenseLayout: Bool

    init(
        sessionService: any AgentSessionServiceProtocol,
        permissionApprovalCenter: PermissionApprovalCenter,
        focusedSessionID: UUID?,
        gitBranchStore: GitBranchStore,
        onInspectFile: ((URL) -> Void)?,
        onSideQuestion: ((String, ResponseSpeedMode, AgentMode) -> Void)?,
        onStartGoal: ((String, ResponseSpeedMode, AgentMode, [String]) -> Bool)?,
        fileManager: FileManager,
        isDenseLayout: Bool,
        onEnhancePrompt: ((String, ResponseSpeedMode, AgentMode, [String], [String]) -> Void)? = nil,
        isEnhancePromptAvailable: Bool = false,
        isEnhancingPrompt: Bool = false,
        onCancelEnhancePrompt: (() -> Void)? = nil,
        onUndoEnhancePrompt: (() -> Void)? = nil,
        isUndoEnhanceAvailable: Bool = false
    ) {
        self.sessionService = sessionService
        self.permissionApprovalCenter = permissionApprovalCenter
        self.focusedSessionID = focusedSessionID
        self.gitBranchStore = gitBranchStore
        self.onInspectFile = onInspectFile
        self.onSideQuestion = onSideQuestion
        self.onStartGoal = onStartGoal
        self.fileManager = fileManager
        self.isDenseLayout = isDenseLayout
        self.onEnhancePrompt = onEnhancePrompt
        self.isEnhancePromptAvailable = isEnhancePromptAvailable
        self.isEnhancingPrompt = isEnhancingPrompt
        self.onCancelEnhancePrompt = onCancelEnhancePrompt
        self.onUndoEnhancePrompt = onUndoEnhancePrompt
        self.isUndoEnhanceAvailable = isUndoEnhanceAvailable
    }

    @Environment(SettingsStore.self) private var settingsStore
    @Environment(ExtensionStore.self) private var extensionStore
    /// "Write this again" on an earlier message puts its text back in this field.
    @Environment(ComposerDraftCenter.self) private var draftCenter: ComposerDraftCenter?
    /// Unsent drafts kept across relaunches; the field stays the source of truth
    /// while the app runs, the store only carries it over a quit.
    @Environment(ComposerDraftStore.self) private var draftStore: ComposerDraftStore?
    @Environment(\.colorScheme) private var systemColorScheme
    /// Kök ızgaradan gelen bölme genişliği; dar uyum kararları buradan okunur.
    @Environment(\.paneWidth) private var paneWidth

    /// Taslaklar oturuma göre saklanır.
    ///
    /// Tek bir taslak alanı sohbetler arasında sızıyordu: A'da yazılan metin B'ye
    /// geçildiğinde B'nin alanında duruyor ve B'ye gönderiliyordu. Ekler ve
    /// etiketler için de aynısı geçerliydi.
    ///
    /// Sözlük paylaşılan `ComposerDraftMemory` deposunda yaşar: tekli↔yan yana
    /// geçişte görünüm yok olsa da taslak korunur. Depo ortama verilmemişse
    /// (önizleme/test) yerel alan kullanılır.
    @Environment(ComposerDraftMemory.self) private var draftMemory: ComposerDraftMemory?
    /// Ajan modu ve hız modu oturum başınadır: bir sohbette Plan'a geçmek
    /// diğer sohbeti etkilemez. Depo yoksa (önizleme/test) genel değer kullanılır.
    @Environment(SessionComposerPrefs.self) private var composerPrefs: SessionComposerPrefs?
    @State private var localDrafts: [UUID: ComposerDraft] = [:]

    private var draftsBySession: [UUID: ComposerDraft] {
        get { draftMemory?.drafts ?? localDrafts }
        nonmutating set {
            if let draftMemory {
                draftMemory.drafts = newValue
            } else {
                localDrafts = newValue
            }
        }
    }
    /// Bölmenin bağlı olduğu oturum: sabit kimlik çözülemezse (silinmişse)
    /// aktif oturuma düşer.
    private var focusedSession: AgentSession {
        if let focusedSessionID,
            let match = sessionService.session(for: focusedSessionID)
        {
            return match
        }
        return sessionService.activeSession
    }
    @State private var isTargetedForDrop = false
    /// Escape ya da panelin kapatma düğmesiyle reddedilen token. Aynı token
    /// yazılmaya devam ettiği sürece öneri paneli geri açılmaz; taslaktan
    /// trigger tümüyle çıkınca silinir.
    @State private var dismissedSuggestionToken: String?
    /// Tıklanan fotoğrafın büyük önizleme popup hedefi.
    @State private var previewingImage: PreviewableImageAttachment?
    /// Sesle yazma durumu; kayıt `SpeechDictationService` tarafındadır, burada
    /// yalnızca düğme görünümü ve taslağa akan metin yaşar.
    @State private var dictationService = SpeechDictationService()
    @State private var isDictating: Bool = false
    /// Model menüsündeki arama sorgusu; menü kapanınca temizlenir
    /// (`ComposerDropdown` kapatırken sıfırlar), yoksa eski sorgu bir
    /// sonraki açılışta listeyi süzülü bırakırdı.
    @State private var modelMenuSearchText = ""

    /// Taslağın anahtarı: bölme kimliği çözülemezse bile o kimlikte kalır,
    /// böylece silinmiş bir oturumun bölmesi aktif sohbetin taslağını ezmez.
    private var draftSessionID: UUID {
        focusedSessionID ?? sessionService.activeSessionID
    }

    private var draft: String {
        get { draftsBySession[draftSessionID]?.text ?? "" }
        nonmutating set {
            draftsBySession[draftSessionID, default: .empty].text = newValue
        }
    }

    private var attachedURLs: [URL] {
        get { draftsBySession[draftSessionID]?.attachedURLs ?? [] }
        nonmutating set {
            draftsBySession[draftSessionID, default: .empty].attachedURLs = newValue
        }
    }

    /// Fotoğraf ekleri kare sırada, diğer dosyalar hap sırada durur.
    private var attachedImageURLs: [URL] {
        attachedURLs.filter { AttachmentKind.isImage(url: $0) }
    }

    private var attachedFileURLs: [URL] {
        attachedURLs.filter { !AttachmentKind.isImage(url: $0) }
    }

    private var selectedTags: [ExtensionTag] {
        get { draftsBySession[draftSessionID]?.selectedTags ?? [] }
        nonmutating set {
            draftsBySession[draftSessionID, default: .empty].selectedTags = newValue
        }
    }

    /// Bu sohbetin etkin ajan modu: geçersiz kılma yoksa genel değer.
    private var agentMode: AgentMode {
        get {
            composerPrefs?.effectiveAgentMode(
                for: focusedSession.id,
                default: settingsStore.agentMode
            ) ?? settingsStore.agentMode
        }
        nonmutating set {
            composerPrefs?.setAgentMode(newValue, for: focusedSession.id)
        }
    }

    /// Bu sohbetin etkin hız modu: geçersiz kılma yoksa genel değer.
    private var speedMode: ResponseSpeedMode {
        get {
            composerPrefs?.effectiveSpeedMode(
                for: focusedSession.id,
                default: settingsStore.responseSpeedMode
            ) ?? settingsStore.responseSpeedMode
        }
        nonmutating set {
            composerPrefs?.setSpeedMode(newValue, for: focusedSession.id)
        }
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { draft },
            set: { draft = $0 }
        )
    }

    /// Silinen sohbetlerin taslakları tutulmaz. Bekleyen yeni-sohbet taslağı
    /// listede olmadığı halde yaşar: anahtarı korunur, gönderimde oturuma dönüşür.
    private func discardDraftsOfRemovedSessions() {
        var liveIDs = Set(sessionService.sessions.map(\.id))
        if let pending = sessionService.pendingSessionID {
            liveIDs.insert(pending)
        }
        draftsBySession = draftsBySession.filter { liveIDs.contains($0.key) }
    }

    private var isDarkMode: Bool {
        settingsStore.isDark(systemColorScheme: systemColorScheme)
    }

    private var currentTheme: AppThemePreset {
        settingsStore.currentThemePreset
    }

    /// 2'li ve 4'lü düzen minimal besteci kullanır; tekli düzen etkilenmez.
    /// Yoğun düzende genişlik tekliyi andırsa bile dikey alan bölünmüştür,
    /// o yüzden genişliğe bakılmaksızın minimal çizilir.
    private var isMinimalComposer: Bool {
        isDenseLayout || PaneResponsive.isMinimalComposer(width: paneWidth)
    }

    /// Dar bölmede denetimler simgeye iner; 2'li ve 4'lü düzende minimaldir.
    private var isCompactPane: Bool {
        isMinimalComposer
    }

    private var composerOuterHorizontal: CGFloat {
        PaneResponsive.composerOuterHorizontal(forWidth: paneWidth)
    }

    private var composerOuterVertical: CGFloat {
        PaneResponsive.composerOuterVertical(forWidth: paneWidth)
    }

    private var composerBoxHorizontal: CGFloat {
        PaneResponsive.composerBoxHorizontal(forWidth: paneWidth)
    }

    private var composerBoxVertical: CGFloat {
        PaneResponsive.composerBoxVertical(forWidth: paneWidth)
    }

    private var composerStackSpacing: CGFloat {
        PaneResponsive.composerStackSpacing(forWidth: paneWidth)
    }

    private var composerBoxSpacing: CGFloat {
        PaneResponsive.composerBoxSpacing(forWidth: paneWidth)
    }

    private var composerEditorMinHeight: CGFloat {
        PaneResponsive.composerEditorMinHeight(forWidth: paneWidth)
    }

    private var composerEditorMaxHeight: CGFloat {
        PaneResponsive.composerEditorMaxHeight(forWidth: paneWidth)
    }

    private var composerCornerRadius: CGFloat {
        PaneResponsive.composerCornerRadius(forWidth: paneWidth)
    }

    private var composerButtonSize: CGFloat {
        PaneResponsive.composerControlButtonSize(forWidth: paneWidth)
    }

    private var composerPillHorizontal: CGFloat {
        PaneResponsive.composerPillHorizontal(forWidth: paneWidth)
    }

    private var composerPillVertical: CGFloat {
        PaneResponsive.composerPillVertical(forWidth: paneWidth)
    }

    private var composerControlSpacing: CGFloat {
        PaneResponsive.composerControlSpacing(forWidth: paneWidth)
    }

    private var composerControlTop: CGFloat {
        PaneResponsive.composerControlTopPadding(forWidth: paneWidth)
    }

    var body: some View {
        // The panels that belong to the composer *area* but not to the composer
        // box: the queued messages and the `/`/`@` suggestions. Both are siblings
        // above the input in the layout, so neither is an overlay on the box —
        // there is no shared edge, no shared background and nothing of the input
        // underneath them. They also have their own surface, border and shadow, so
        // each reads as a panel of its own rather than a part of the field.
        VStack(spacing: composerStackSpacing) {
            if !focusedSession.queuedPrompts.isEmpty {
                floatingPanel {
                    queuedPromptsStrip
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Ajanın görev listesi composer'ın üstünde ayrı bir panel olarak da
            // durur: transkriptteki kart turun altına gömülür ve kaydırınca
            // kaybolur, oysa bu panel o anki oturumun listesini çalışırken
            // açılır-kapanır gösterir.
            if AgentTodoPlacement.shouldShow(
                todos: focusedSession.todos,
                isTurnRunning: focusedSession.isBusy
            ) {
                AgentTodoChecklistView(
                    todos: focusedSession.todos,
                    preset: currentTheme,
                    isDark: isDarkMode
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let trigger = visibleTrigger {
                floatingPanel {
                    extensionSuggestions(for: trigger)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            composerBox

            // Git bağlam şeridi: kutunun altında, içe gömülü ayrı bir
            // sekme olarak durur; hapın içinde yer yemez, besteci daralmaz.
            // Yalnız git deposuna bağlı oturumda görünür.
            if gitBranchStore.isRepository == true {
                composerContextStrip
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.14), value: visibleTrigger)
        .animation(.easeOut(duration: 0.14), value: focusedSession.queuedPrompts.isEmpty)
        .animation(.easeOut(duration: 0.14), value: focusedSession.todos.count)
        // Panel `shouldShow` ile durum değişiminde de (aynı sayıda) açılıp
        // kapanır; yalnız sayı izlenirse boy sıçraması animasyonsuz olur ve
        // transkript kabını sarsar. Bitmemiş sayısı aynı kareyi izler.
        .animation(
            .easeOut(duration: 0.14),
            value: focusedSession.todos.filter { !$0.status.isFinished }.count
        )
        .popover(item: $previewingImage) { preview in
            ImagePreviewPopoverContent(
                url: preview.url,
                onRemove: preview.allowsRemove ? { removeAttachment(preview.url) } : nil,
                onClose: { previewingImage = nil }
            )
        }
        .frame(maxWidth: 820)
        .padding(.horizontal, composerOuterHorizontal)
        .padding(.vertical, composerOuterVertical)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// The chrome every panel above the input shares: its own surface, border and
    /// shadow, so it is never read as part of the composer box below it.
    private func floatingPanel<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
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
    }

    /// The input box itself: what the user types, and the controls under it.
    ///
    /// Nothing that merely *reports* something lives in here: the queue and the
    /// suggestions are panels above the box, and the box keeps one job.
    private var composerBox: some View {
        VStack(spacing: composerBoxSpacing) {
            if !selectedTags.isEmpty {
                selectedTagsRow
            }

            attachedImagesRow

            attachedFilesRow

            composerEditorArea

            composerControlRow
        }
        .padding(.horizontal, composerBoxHorizontal)
        .padding(.vertical, composerBoxVertical)
        .background(
            currentTheme.composerBackground(isDark: isDarkMode)
                .opacity(settingsStore.glassOpacity),
            in: RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous)
                .stroke(
                    isTargetedForDrop
                        ? (currentTheme.accentGradient.first ?? .accentColor)
                        : currentTheme.composerBorder(isDark: isDarkMode).opacity(settingsStore.contrast),
                    lineWidth: isTargetedForDrop ? 2 : 1
                )
        )
        .overlay {
            dropTargetOverlay
        }
        // Dosya URL'si yanında ham görüntü de kabul edilir: macOS ekran
        // görüntüsü önizleme küçük resmi sürüklendiğinde pano dosya URL'si
        // vermez, yalnızca görüntü verisi verir; yalnız `.fileURL` dinlenirse
        // bırakma sessizce reddedilir. Metin türleri soldaki sohbet
        // listesinden sürüklenen oturum kimliğini taşır (özet devri).
        .onDrop(of: [.fileURL, .image, .text, .utf8PlainText], isTargeted: $isTargetedForDrop) { providers in
            handleDrop(providers: providers)
        }
        .onChange(of: extensionStore.registry) { _, _ in
            // An extension the user switched off cannot be tagged any more.
            let available = Set(extensionStore.tagSuggestions.map(\.id))
            selectedTags.removeAll { !available.contains($0.id) }
        }
        .onChange(of: focusedSession.id) { _, _ in
            discardDraftsOfRemovedSessions()
            restoreStoredDraftIfEmpty()
            applyPendingRestore()
        }
        .onChange(of: sessionService.sessionList.map(\.id)) { _, ids in
            // Bekleyen taslak listede yoktur ama bestecide yaşar: disk ve
            // tercihlerden düşürülmez, yoksa başka oturumun her durum
            // değişimi taslağın Plan/Hızlı seçimini globale sıfırlar.
            var liveIDs = Set(ids)
            if let pending = sessionService.pendingSessionID {
                liveIDs.insert(pending)
            }
            draftStore?.discardSessions(notIn: liveIDs)
            composerPrefs?.discardSessions(notIn: liveIDs)
            discardDraftsOfRemovedSessions()
        }
        .onChange(of: draft) { _, _ in
            // Trigger taslaktan tümüyle çıkınca kapanış kaydı da düşer: aynı
            // token sonra yeniden yazılırsa panel yine açılmalı.
            if activeTrigger == nil {
                dismissedSuggestionToken = nil
            }
            pushDraftToStore()
        }
        .onChange(of: attachedURLs) { _, _ in
            pushDraftToStore()
        }
        .onAppear {
            restoreStoredDraftIfEmpty()
            applyPendingRestore()
            gitBranchStore.refreshIfNeeded(directoryPath: focusedSession.workingDirectoryPath)
        }
        .onChange(of: focusedSession.id) { _, _ in
            gitBranchStore.refreshIfNeeded(directoryPath: focusedSession.workingDirectoryPath)
        }
        .onChange(of: focusedSession.workingDirectoryPath) { _, _ in
            gitBranchStore.refreshIfNeeded(directoryPath: focusedSession.workingDirectoryPath)
        }
        .onDisappear {
            // Pane kapanınca tanıyıcı öksüz kalmamalı: mikrofon açık kalır,
            // kısmi sonuçlar ölü taslağa akardı.
            stopDictation()
        }
        .onChange(of: draftCenter?.pending) { _, _ in
            applyPendingRestore()
        }
    }

    /// Fotoğraflar yan yana kareler olarak durur, diğer dosyalar hap olarak;
    /// kareye tıklayınca büyük önizleme popup açılır.
    @ViewBuilder
    private var attachedImagesRow: some View {
        if !attachedImageURLs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(attachedImageURLs, id: \.self) { url in
                        ImageSquareThumbnail(url: url, onRemove: { removeAttachment(url) }) {
                            previewingImage = PreviewableImageAttachment(url: url, allowsRemove: true)
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 2)
            }
        }
    }

    @ViewBuilder
    private var attachedFilesRow: some View {
        if !attachedFileURLs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachedFileURLs, id: \.self) { url in
                        attachmentPreviewPill(for: url)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 2)
            }
        }
    }

    /// Metin alanı ve yer tutucu.
    ///
    /// Oturum kimliğine bağlı kimlik: `NSViewRepresentable` koordinatörü
    /// oluşturulduğu andaki bağlamayı tutar. Yan yana görünümde takasta (ya da
    /// kenar çubuğunda sohbet değişiminde) aynı konumdaki alan başka oturumu
    /// gösterirdi ama yazı koordinatördeki bayat bağlamayla önceki oturumun
    /// taslağına giderdi — yazılan diğer bölmede belirirdi. Kimlik değişince
    /// alan ve koordinatör yeniden kurulur, yazı doğru taslağa düşer.
    private var composerEditorArea: some View {
        ZStack(alignment: .topLeading) {
            ComposerTextEditor(
                text: draftBinding,
                submissionAvailability: submissionAvailability,
                onSubmit: sendDraft,
                onCancelSuggestions: dismissVisibleSuggestions,
                onSpillLargePaste: spillLargePasteToAttachment
            )
            .id(focusedSession.id)

            if draft.isEmpty {
                Text(placeholderText)
                    .font(.system(size: 13.5))
                    .foregroundStyle(
                        isDarkMode
                            ? Color.white.opacity(0.35)
                            : Color.black.opacity(0.40)
                    )
                    .padding(.top, 2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: composerEditorMinHeight, maxHeight: composerEditorMaxHeight)
        .padding(.horizontal, isMinimalComposer ? 0 : 2)
    }

    /// Denetim satırı her genişlikte tek satırdır: hap sığmadığında yatay
    /// kayar, işlem düğmeleri (ses/ek/gönder) sabit durur. 2'li ve 4'lü
    /// düzende hap zaten simgeye iner (`isMinimalComposer`), o yüzden
    /// kaydırma yalnız en dar ızgaralarda devreye girer; besteci yüksekliği
    /// bölme sayısıyla büyümez.
    private var composerControlRow: some View {
        HStack(alignment: .center, spacing: composerControlSpacing) {
            ScrollView(.horizontal, showsIndicators: false) {
                composerControlPill
            }
            // Hap taşarsa düğmelerin üstüne boyar: kayma görünümü kendi
            // sınırında kırpılır, simgeler her zaman temiz kalır.
            .clipped()

            ComposerDictationButton(
                isRecording: isDictating,
                size: composerButtonSize,
                onToggle: { toggleDictation() }
            )

            attachmentButton

            enhancePromptButton

            undoEnhanceButton

            submitButton
        }
        .padding(.top, composerControlTop)
    }

    /// Sürükleme geri bildirimi: hedefin üstünü örten kesikli çerçeve.
    @ViewBuilder
    private var dropTargetOverlay: some View {
        if isTargetedForDrop {
            RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous)
                .fill(currentTheme.composerBackground(isDark: isDarkMode).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: currentTheme.accentGradient,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                        )
                )
                .overlay(
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: currentTheme.accentGradient,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )

                        Text("Drop image, file, or conversation here")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                )
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// Puts a message the user asked to write again back into the field.
    ///
    /// The text is appended rather than swapped in, and the request is only
    /// consumed once it has been applied: a restore for another conversation
    /// stays pending until that conversation is the one on screen, because a
    /// draft belongs to the session it was written in.
    private func applyPendingRestore() {
        guard
            let draftCenter,
            let request = draftCenter.consumePending(for: focusedSession.id)
        else {
            return
        }

        draft = ComposerDraftPlacement.merged(existing: draft, restored: request.text)

        // An attachment whose file is gone would be sent as a path the agent
        // cannot read, so it is left out rather than restored as a warning.
        attachedURLs.append(
            contentsOf: AttachmentPaths.existingAttachmentURLs(
                request.attachmentPaths,
                excluding: Set(attachedURLs.map(\.path)),
                fileManager: fileManager
            )
        )
    }

    /// Unsent field content rides to the store; the store debounces the disk
    /// write, so a keystroke costs a comparison, not I/O.
    private func pushDraftToStore() {
        draftStore?.update(
            sessionID: focusedSession.id,
            text: draft,
            attachmentPaths: attachedURLs.map(\.path)
        )
    }

    /// Brings back what was left unsent before a quit. Only into an empty
    /// field: a draft written since launch is newer than anything on disk, and
    /// a pending "write again" merges on top afterwards.
    private func restoreStoredDraftIfEmpty() {
        guard
            draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            attachedURLs.isEmpty,
            let stored = draftStore?.storedDraft(for: focusedSession.id)
        else {
            return
        }

        if !stored.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = stored.text
        }

        // An attachment whose file is gone would be sent as a path the agent
        // cannot read, so it is left out rather than restored as a warning.
        attachedURLs.append(
            contentsOf: AttachmentPaths.existingAttachmentURLs(
                stored.attachmentPaths,
                fileManager: fileManager
            )
        )
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        if !attachedURLs.contains(url) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                attachedURLs.append(url)
                            }
                        }
                    }
                }
                handled = true
            } else if let imageType = Self.preferredImageTypeIdentifier(for: provider) {
                let suggestedName = provider.suggestedName
                _ = provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, _ in
                    guard let data, !data.isEmpty else { return }
                    Task { @MainActor in
                        do {
                            let url = try DroppedImageAttachment.save(
                                data,
                                suggestedName: suggestedName,
                                typeIdentifier: imageType
                            )
                            if !attachedURLs.contains(url) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    attachedURLs.append(url)
                                }
                            }
                        } catch {
                            AppLog.agentSession.error(
                                "A dropped image could not be stored as an attachment"
                            )
                        }
                    }
                }
                handled = true
            } else if provider.canLoadObject(ofClass: NSString.self) {
                // Soldaki sohbet satırı oturum kimliğini düz metin taşır:
                // kaynağın özeti/context'i taslağa eklenir. Kimlik değilse
                // sessizce atlanır (başka metin akışı eklenmez).
                _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                    let raw = (text as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard let sourceID = UUID(uuidString: raw) else {
                        return
                    }
                    Task { @MainActor in
                        self.insertSessionHandoff(from: sourceID)
                    }
                }
                handled = true
            }
        }
        return handled
    }

    /// Soldaki sohbet listesinden bırakılan oturum kimlikleri: kaynağın
    /// özeti/context'i hedef taslağa eklenir. Aynı sohbetin kendisine
    /// bırakılması, bulunamayan kaynak ve içeriği boş kaynak yok sayılır.
    /// Ham geçmiş taşınmaz, yalnız `SessionHandoff` özeti taşınır.
    private func insertSessionHandoff(from sourceID: UUID) {
        guard sourceID != focusedSession.id else {
            return
        }
        guard let source = sessionService.session(for: sourceID) else {
            return
        }
        guard
            let handoff = SessionHandoff.handoffText(
                sourceTitle: source.title,
                contextSummary: source.contextSummary,
                messages: source.state.messages,
                todos: source.todos,
                workingDirectoryPath: source.workingDirectoryPath
            )
        else {
            return
        }
        draft = ComposerDraftPlacement.merged(existing: draft, restored: handoff)
        pushDraftToStore()
    }

    /// Sağlayıcının sunduğu görüntü türlerinden kayıpsız olana öncelik verir;
    /// dosya URL'si ayrıca ele alınır, buraya yalnız URL'siz bırakmalar düşer.
    private static func preferredImageTypeIdentifier(for provider: NSItemProvider) -> String? {
        let offered = provider.registeredTypeIdentifiers
        let preference = [
            UTType.png.identifier,
            UTType.tiff.identifier,
            UTType.jpeg.identifier,
            UTType.gif.identifier,
            UTType.heic.identifier,
            UTType.webP.identifier,
            UTType.bmp.identifier,
        ]
        if let exact = preference.first(where: { offered.contains($0) }) {
            return exact
        }
        return offered.first {
            guard let type = UTType($0) else { return false }
            return type.conforms(to: .image)
        }
    }

    private var isSelectedModelThinking: Bool {
        guard let selectedModelID else { return false }
        return focusedSession.availableModels.first(where: { $0.id == selectedModelID })?.supportsThinking == true
    }

    // MARK: - Unified composer control pill

    /// Transparent row housing: model | variant | agent mode | speed mode |
    /// approval level. Sections are separated by thin vertical dividers. Each
    /// section gets its own hover highlight via `interactiveHoverPill`.
    ///
    /// The provider is deliberately not here any more: it is a long-lived choice
    /// made in Settings, and the room is better spent on the approval level, which
    /// is the one setting a user changes *while* watching the agent work.
    private var composerControlPill: some View {
        HStack(spacing: 0) {
            // Model section
            if !focusedSession.availableModels.isEmpty {
                modelMenuSection
                pillDivider
            }

            // Reasoning effort and fast mode, in one control
            effortMenuSection

            // Agent mode section (Build / Plan)
            pillDivider
            agentModeMenuSection

            // Tool approval level: short here, explained in Settings.
            pillDivider
            approvalLevelSection
        }
        .fixedSize()
    }

    /// Git bağlam şeridi: kutunun altına yapışık, iki yanı içe gömülü dar
    /// bir sekme. Solda klasör (çalışma dizini), sağda dal seçici durur.
    /// Üst köşeler kareye yakın tutulur ki kutunun devamı gibi okunsun.
    private var composerContextStrip: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(checkoutDisplayName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(focusedSession.workingDirectoryPath ?? "")

            Spacer(minLength: 8)

            branchMenuSection
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            currentTheme.surface(isDark: isDarkMode).opacity(0.92),
            in: UnevenRoundedRectangle(
                topLeadingRadius: 4,
                bottomLeadingRadius: 10,
                bottomTrailingRadius: 10,
                topTrailingRadius: 4,
                style: .continuous
            )
        )
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 4,
                bottomLeadingRadius: 10,
                bottomTrailingRadius: 10,
                topTrailingRadius: 4,
                style: .continuous
            )
            .stroke(
                currentTheme.border(isDark: isDarkMode).opacity(settingsStore.contrast),
                lineWidth: 1
            )
        )
        // İçe gömülü sekme görünümü: yanlardan dar, üstten kutuya yapışık.
        .padding(.horizontal, 18)
        .padding(.top, -composerStackSpacing)
    }

    /// Şeridin solundaki klasör adı: oturumun çalışma dizininin son
    /// bileşeni; yol yoksa örnekteki gibi "Local checkout" yazar.
    private var checkoutDisplayName: String {
        if let path = focusedSession.workingDirectoryPath,
            !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let name = URL(fileURLWithPath: path).lastPathComponent
            if !name.isEmpty, name != "/" {
                return name
            }
        }
        return "Local checkout"
    }

    /// Oturumun klasöründeki git dalı: listeler ve güvenli geçirir.
    ///
    /// Seçici yalnız git deposunda görünür (artık kutu altındaki bağlam
    /// şeridinde). Turuncu nokta izlenen dosyada kayıtsız değişiklik demektir; o hâlde dal değişimi reddedilir
    /// (yarım iş kaybolmasın), neden menüde yazılır.
    private var branchMenuSection: some View {
        let store = gitBranchStore

        return ComposerDropdown(
            isEnabled: !store.isSwitching,
            helpText: branchHelpText,
            accessibilityText: "Git branch: \(store.displayName ?? "unknown")"
        ) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                if !isCompactPane {
                    Text(store.displayName ?? "…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if store.hasDirtyChanges {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .help("\(store.dirtyCount) uncommitted change(s)")
                }

                if store.isSwitching || store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                } else if !isCompactPane {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, composerPillHorizontal)
            .padding(.vertical, composerPillVertical)
            .interactiveHoverPill(cornerRadius: 6)
        } content: {
            ComposerDropdownSectionHeader(title: "Branches")

            if store.branches.isEmpty {
                Text(store.isRefreshing ? "Reading branches…" : "No branches found")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5.5)
            }
            ForEach(store.branches, id: \.self) { branch in
                ComposerDropdownRow(
                    title: branch,
                    isSelected: branch == store.currentBranch,
                    helpText: branch == store.currentBranch
                        ? "Current branch" : "Switch to \(branch)"
                ) {
                    Task {
                        await store.checkout(branch: branch)
                    }
                } icon: {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5.5)
            }

            ComposerDropdownRow(
                title: "Refresh branches",
                isSelected: false,
                helpText: "Re-read branches from git"
            ) {
                store.forceRefresh()
            } icon: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var branchHelpText: String {
        let store = gitBranchStore
        var parts: [String] = []
        if let name = store.displayName {
            parts.append("Branch: \(name)")
        }
        if store.hasDirtyChanges {
            parts.append("\(store.dirtyCount) uncommitted change(s) — switching is paused")
        } else {
            parts.append("Switch branches")
        }
        return parts.joined(separator: " · ")
    }

    /// How much the agent may do without asking, in one line.
    ///
    /// The level names are kept to a word each ("Ask", "Approve", "Full access")
    /// and the explanation is not repeated here: a composer that recited two
    /// sentences per state would push the input field out of the place it is being
    /// typed into. There is no "More info" link either — the card in Settings
    /// explains the levels, and a control row that points at its own explanation
    /// reads as part of the decision when it is not.
    private var approvalLevelSection: some View {
        let policy = settingsStore.toolApprovalPolicy
        let pendingCount = permissionApprovalCenter.pendingRequests(for: focusedSession.id).count

        return HStack(spacing: 2) {
            ComposerDropdown(
                isEnabled: true,
                helpText: "Tool approvals: \(policy.summary)",
                accessibilityText: "Tool approvals: \(policy.displayName)"
            ) {
                HStack(spacing: 4) {
                    Image(systemName: policy.symbolName)
                        .font(.system(size: 10.5, weight: .semibold))

                    if !isCompactPane {
                        Text(policy.compactName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    if pendingCount > 0 {
                        Text("\(pendingCount)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange, in: Capsule())
                    }

                    if !isCompactPane {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(policy.isUnrestricted ? Color.orange : .secondary)
                .padding(.horizontal, composerPillHorizontal)
                .padding(.vertical, composerPillVertical)
                .interactiveHoverPill(cornerRadius: 6)
            } content: {
                ForEach(ToolApprovalPolicy.allCases) { candidate in
                    ComposerDropdownRow(
                        title: candidate.displayName,
                        isSelected: candidate == policy,
                        helpText: candidate.summary
                    ) {
                        chooseApprovalLevel(candidate)
                    } icon: {
                        Image(systemName: candidate.symbolName)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(
                                candidate.isUnrestricted ? Color.orange : .secondary
                            )
                    }
                }
            }
        }
        .padding(.trailing, 4)
    }

    private func chooseApprovalLevel(_ policy: ToolApprovalPolicy) {
        guard settingsStore.toolApprovalPolicy != policy else {
            return
        }

        settingsStore.toolApprovalPolicy = policy
        // Koşan turun bekleyenleri eski kuralla durur (merkez tur ortası
        // değişimi uygulamaz); tur çalışmıyorken bekleyen istek varsa yeni
        // kuralla yeniden yorumlanır. Yalnız bu bölmenin sohbeti kapsanır,
        // diğer bölmenin kuyusuna dokunulmaz.
        permissionApprovalCenter.reinterpretPendingRequests(appSessionID: focusedSession.id)
    }

    /// Build or Plan for the *next* turn, so it stays switchable while a turn is
    /// running — the same reason the speed mode is not disabled either.
    private var agentModeMenuSection: some View {
        let mode = agentMode

        return ComposerDropdown(
            isEnabled: true,
            helpText: mode.helpText,
            accessibilityText: "Agent mode"
        ) {
            HStack(spacing: 4) {
                AgentModeGlyph(
                    mode: mode,
                    size: 11,
                    tint: mode != .build
                        ? (currentTheme.accentGradient.first ?? .secondary)
                        : .secondary
                )

                if !isCompactPane {
                    Text(mode.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if !isCompactPane {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, composerPillHorizontal)
            .padding(.vertical, composerPillVertical)
            .interactiveHoverPill(cornerRadius: 6)
        } content: {
            ForEach(AgentMode.allCases) { candidate in
                ComposerDropdownRow(
                    title: candidate.displayName,
                    isSelected: candidate == mode,
                    helpText: candidate.helpText
                ) {
                    agentMode = candidate
                } icon: {
                    AgentModeGlyph(
                        mode: candidate,
                        size: 11,
                        tint: candidate == mode
                            ? (currentTheme.accentGradient.first ?? .secondary)
                            : .secondary
                    )
                }
            }
        }
    }

    /// Messages that arrived while a turn was running, in the order they will be
    /// sent. They stay above the composer rather than in the transcript: a queued
    /// prompt has not been answered yet, so it is not part of the conversation.
    private var queuedPromptsStrip: some View {
        QueuedPromptsStrip(
            prompts: focusedSession.queuedPrompts,
            onEditInComposer: { id in
                editQueuedPromptInComposer(id)
            },
            onMove: { id, index in
                focusedSession.moveQueuedPrompt(id, to: index)
            },
            onRemove: { id in
                focusedSession.removeQueuedPrompt(id)
            },
            onClear: {
                focusedSession.clearQueuedPrompts()
            },
            onSendNow: { id in
                focusedSession.sendQueuedPromptImmediately(id)
            }
        )
    }

    /// Kalem satırı yerinde açmıyor: kuyruk girdisini oradan çıkarıp metnini ve
    /// eklerini "Write again" ile aynı yoldan composer girdisine taşır, kullanıcı
    /// düzenlemeyi tam boy alanda yapar ve normal gönderir.
    private func editQueuedPromptInComposer(_ id: UUID) {
        guard let prompt = focusedSession.queuedPrompts.first(where: { $0.id == id }) else {
            return
        }

        focusedSession.removeQueuedPrompt(id)
        draftCenter?.requestRestore(
            text: prompt.text,
            attachmentPaths: prompt.attachmentPaths,
            sessionID: focusedSession.id
        )
    }

    private var placeholderText: String {
        if isCompactPane {
            if focusedSession.activeQuestion != nil {
                return "Reply here…"
            }
            if focusedSession.isBusy {
                return "Add a follow-up…"
            }
            return "Message… @ tools, / skills"
        }
        if focusedSession.activeQuestion != nil {
            return "Agent is waiting for your choice above — or write a reply here"
        }
        if focusedSession.isBusy {
            return "Add a follow-up — it is queued and sent when this turn finishes"
        }
        switch agentMode {
        case .build:
            return "Message or request changes — @ for MCP and plugins, / for skills"
        case .plan:
            return "Ask to plan a feature, architectural change, or refactoring…"
        case .review:
            return "Ask to review changes, branch, or target project using Alibaba OCR…"
        case .exam:
            return "Ask an exam question, paste a problem, or take a screenshot to solve…"
        case .ask:
            return "Ask a question — answered directly, files are never changed…"
        }
    }

    private var pillDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(isDarkMode ? 0.12 : 0.10))
            .frame(width: 1, height: isMinimalComposer ? 12 : 14)
            .padding(.horizontal, isMinimalComposer ? 1 : 2)
    }

    /// Sonraki turun modeli: tur ortasında değişim koşan turu etkilemez —
    /// istek tur başında anlık görüntüyü alır — bu yüzden seçici, mod menüsü
    /// gibi, meşgulken de açık kalır.
    private var modelMenuSection: some View {
        ComposerDropdown(
            isEnabled: true,
            helpText: "Select the model for this conversation",
            accessibilityText: "Model",
            searchText: $modelMenuSearchText,
            searchPlaceholder: "Search models"
        ) {
            HStack(spacing: 4) {
                // The provider's drawn mark belongs here, on a label SwiftUI
                // renders as a view, rather than inside the menu.
                ProviderLogoView(
                    logo: ProviderLogo.matching(resolvedSelectedModelID?.rawValue ?? ""),
                    size: 11,
                    tint: isSelectedModelThinking
                        ? (currentTheme.accentGradient.first ?? .secondary)
                        : .secondary
                )

                if !isCompactPane {
                    Text(selectedModelName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 160)
                        .truncationMode(.tail)
                }

                if isSelectedModelThinking && !isCompactPane {
                    Text("Thinking")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            (currentTheme.accentGradient.first ?? .purple).opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                        )
                        .foregroundStyle(currentTheme.accentGradient.first ?? .purple)
                }

                if !isCompactPane {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, composerPillHorizontal)
            .padding(.vertical, composerPillVertical)
            .interactiveHoverPill(cornerRadius: 6)
        } content: {
            if filteredModels.isEmpty {
                Text("No models match your search")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5.5)
            }
            ForEach(filteredModels, id: \.id) { model in
                ComposerDropdownRow(
                    title: model.displayName,
                    isSelected: model.id == selectedModelID,
                    helpText: nil
                ) {
                    try? focusedSession.selectModel(model.id)
                } icon: {
                    ProviderLogoView(
                        logo: ProviderLogo.matching(model.id.rawValue),
                        size: 11,
                        tint: model.id == selectedModelID
                            ? (currentTheme.accentGradient.first ?? .secondary)
                            : .secondary
                    )
                }
            }
        }
    }

    /// Reasoning effort and fast mode in one control.
    ///
    /// They answer the same question — how hard the model should work on this
    /// turn — and keeping them in separate chips made the composer read as a row
    /// of unrelated settings. The chip shows both at once: “XHigh · Fast”.
    private var effortMenuSection: some View {
        let variantID = selectedVariantID
        let isFast = speedMode == .fast

        return ComposerDropdown(
            isEnabled: true,
            helpText: "How hard the model should think about this turn",
            accessibilityText: ReasoningEffortPresentation.summary(
                variantName: selectedVariantName,
                isFast: isFast
            )
        ) {
            HStack(spacing: 4) {
                Image(systemName: isFast ? "bolt.fill" : "brain")
                    .font(.system(size: 10, weight: isFast ? .bold : .medium))
                    .foregroundStyle(isFast ? Color.yellow : Color.secondary)

                if !isCompactPane {
                    Text(effortLabel(isFast: isFast))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if !isCompactPane {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, composerPillHorizontal)
            .padding(.vertical, composerPillVertical)
            .interactiveHoverPill(cornerRadius: 6)
        } content: {
            ComposerDropdownSectionHeader(title: "Reasoning")

            ComposerDropdownRow(
                title: ReasoningEffortPresentation.rowTitle("Default", isDefault: true),
                isSelected: variantID == nil,
                helpText: "Whatever the model ships with"
            ) {
                try? focusedSession.selectVariant(nil)
            } icon: {
                Image(systemName: "brain")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            ForEach(focusedSession.availableVariants, id: \.id) { variant in
                ComposerDropdownRow(
                    title: variant.displayName,
                    isSelected: variant.id == variantID,
                    helpText: nil
                ) {
                    try? focusedSession.selectVariant(variant.id)
                } icon: {
                    Image(systemName: "brain")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            ComposerDropdownSectionHeader(title: "Fast Mode")

            ComposerDropdownRow(
                title: ResponseSpeedMode.fast.displayName,
                isSelected: isFast,
                helpText: ResponseSpeedMode.fast.helpText
            ) {
                speedMode = .fast
            } icon: {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            ComposerDropdownRow(
                title: ReasoningEffortPresentation.rowTitle(
                    ResponseSpeedMode.normal.displayName,
                    isDefault: true
                ),
                isSelected: !isFast,
                helpText: ResponseSpeedMode.normal.helpText
            ) {
                speedMode = .normal
            } icon: {
                Image(systemName: "bolt.slash")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func effortLabel(isFast: Bool) -> String {
        ReasoningEffortPresentation.label(
            variantName: selectedVariantName,
            isFast: isFast
        )
    }

    private var attachmentButton: some View {
        Button {
            openFileAttachmentDialog()
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: composerButtonSize, height: composerButtonSize)
                .interactiveHoverCircle()
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Attach files")
        .accessibilityLabel("Attach files")
    }

    /// Tek-tık prompt iyileştirme düğmesi: taslağı sağlayıcıdaki modelle
    /// düzelttirir, sonuç taslağın yerine geçer. Komut önekleri (`/…`) ve
    /// boş taslakta kapalıdır. Akış sürerken düğme iptale döner, böylece
    /// istenmeyen ya da takılan koşu durdurulabilir. Ekler ve etiketler
    /// aynen durur, yalnız metin değişir.
    private var enhancePromptButton: some View {
        Button {
            if isEnhancingPrompt {
                onCancelEnhancePrompt?()
            } else {
                requestPromptEnhancement()
            }
        } label: {
            if isEnhancingPrompt {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: composerButtonSize, height: composerButtonSize)
            } else {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: composerButtonSize, height: composerButtonSize)
                    .interactiveHoverCircle()
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .disabled(!isEnhanceButtonEnabled)
        .help(enhancePromptHelp)
        .accessibilityLabel(isEnhancingPrompt ? "Cancel prompt improvement" : "Improve prompt")
    }

    /// Son uygulanan iyileştirmeyi geri alır: taslak, iyileştirme öncesi
    /// metne döner. Yalnız ilgili oturumda, akış yokken ve geri alınacak
    /// metin varken görünür ve etkindir.
    private var undoEnhanceButton: some View {
        Group {
            if isUndoEnhanceAvailable && !isEnhancingPrompt {
                Button {
                    onUndoEnhancePrompt?()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: composerButtonSize, height: composerButtonSize)
                        .interactiveHoverCircle()
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .disabled(onUndoEnhancePrompt == nil)
                .help("Undo prompt improvement")
                .accessibilityLabel("Undo prompt improvement")
            }
        }
    }

    private var isEnhanceButtonEnabled: Bool {
        if isEnhancingPrompt {
            return onCancelEnhancePrompt != nil
        }
        return isEnhanceActionEnabled
    }

    private var isEnhanceActionEnabled: Bool {
        isEnhancePromptAvailable && !isEnhancingPrompt && onEnhancePrompt != nil
            && PromptEnhancer.isEnhanceable(draft)
    }

    private var enhancePromptHelp: String {
        if isEnhancingPrompt {
            return "Improving the prompt… Click to cancel."
        }
        if !isEnhancePromptAvailable {
            return "Improving needs a provider context"
        }
        if !PromptEnhancer.isEnhanceable(draft) {
            return "Write a prompt first — commands starting with / are sent as-is"
        }
        return "Improve this prompt with the current model"
    }

    /// İyileştirme isteği: o anki taslak ve görünür bağlam (etiket, ek adı)
    /// kancaya taşınır. Taslak korunur; iyileşmiş metin dönünce onun yerine
    /// geçer, ekler ve etiketler aynen kalır.
    private func requestPromptEnhancement() {
        guard isEnhanceActionEnabled, let onEnhancePrompt else {
            return
        }
        let promptText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        onEnhancePrompt(
            promptText,
            speedMode,
            agentMode,
            selectedTags.map(\.name),
            attachedURLs.map(\.lastPathComponent)
        )
    }

    @ViewBuilder
    private var submitButton: some View {
        HStack(spacing: composerControlSpacing) {
            sendOrQueueButton

            if focusedSession.isBusy {
                cancelButton
            }
        }
    }

    /// Stays enabled while a turn is running and queues the draft instead of
    /// disabling itself: a follow-up thought must not be lost just because the
    /// assistant is still answering the previous question.
    private var sendOrQueueButton: some View {
        Button {
            sendDraft()
        } label: {
            ZStack {
                Circle()
                    .fill(
                        submissionAvailability == .available
                            ? LinearGradient(
                                colors: currentTheme.accentGradient,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            : LinearGradient(
                                colors: [
                                    Color.primary.opacity(0.12),
                                    Color.primary.opacity(0.06),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                    )
                    .frame(width: composerButtonSize, height: composerButtonSize)

                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(
                        submissionAvailability == .available
                            ? Color.white
                            : Color.primary.opacity(0.35)
                    )

                if focusedSession.isBusy {
                    // Marks the button as "this will be queued", not "this will be
                    // sent now".
                    Image(systemName: "clock.fill")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(Color.orange))
                        .offset(x: 11, y: -11)
                }
            }
            // The opaque accent circle hides a highlight drawn *behind* it, so
            // the hover signal is an outline on the shape itself.
            .interactiveHoverOutlineCircle()
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .disabled(submissionAvailability == .unavailable)
        .help(sendButtonHelp)
        .accessibilityLabel(
            focusedSession.isBusy ? "Queue message" : "Send message"
        )
    }

    private var cancelButton: some View {
        Button {
            Task {
                await focusedSession.cancel()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.85))
                    .frame(width: composerButtonSize, height: composerButtonSize)

                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            .interactiveHoverOutlineCircle()
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Cancel the active turn")
        .accessibilityLabel("Cancel the active turn")
    }

    private var selectedModelID: ProviderModelID? {
        focusedSession.configuration?.modelID
    }

    /// Listede gerçekten bulunan seçim; bulunamayan kimlik görüntüde ve
    /// logoda eski değeri taşımaz.
    private var resolvedSelectedModelID: ProviderModelID? {
        guard let selectedModelID,
            focusedSession.availableModels.contains(where: { $0.id == selectedModelID })
        else {
            return nil
        }
        return selectedModelID
    }

    private var selectedModelName: String {
        // Seçili model listede yoksa ilk modelin adı yazılmamalı: hap yanlış
        // model adını gösterir, hiçbir satır seçili görünmez ve gönderim bayat
        // kimlikle devam eder. Kayıp seçim açıkça "Select model" der.
        if let selectedModelID,
            let model = focusedSession.availableModels.first(where: { $0.id == selectedModelID })
        {
            return model.displayName
        }
        if selectedModelID != nil {
            return "Select model"
        }
        return focusedSession.availableModels.first?.displayName ?? "Select model"
    }

    private var selectedVariantID: ProviderVariantID? {
        focusedSession.configuration?.variantID
    }

    /// Model menüsünün süzülmüş listesi: boş sorguda hepsi, doluyken adı
    /// sorguyu içerenler (büyük-küçük harf duyarsız). Seçim değişmez, yalnız
    /// görünüm elenir.
    private var filteredModels: [ProviderModelCapability] {
        let query = modelMenuSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return focusedSession.availableModels
        }
        return focusedSession.availableModels.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedVariantName: String {
        if let selectedVariantID {
            if let variant = focusedSession.availableVariants.first(where: { $0.id == selectedVariantID }) {
                return variant.displayName
            }
            // Listede olmayan varyant "Default" gibi davranmamalı: çip
            // bekleyen değeri söyler, menüde hiçbir satır seçili görünmez.
            return selectedVariantID.rawValue
        }
        return "Default"
    }

    private var selectedProviderID: ProviderID? {
        focusedSession.configuration?.providerID
    }

    private var selectedProviderIdentifier: String {
        guard let selectedProviderID else {
            return ""
        }

        return sessionService.providers.first { $0.id == selectedProviderID }?.id.rawValue
            ?? selectedProviderID.rawValue
    }

    private var sendButtonHelp: String {
        if sessionService.providers.isEmpty {
            return "A provider adapter is required before sending messages"
        }

        guard focusedSession.isBusy else {
            return "Send message"
        }

        let queued = focusedSession.queuedPrompts.count
        return queued == 0
            ? "Queue this message for the next turn"
            : "Queue this message (\(queued) already waiting)"
    }

    private var submissionAvailability: ComposerSubmissionAvailability {
        // No `trimmingCharacters` here: it copied the whole draft on every
        // keystroke, which a pasted document turns into a stall.
        let hasContent = ComposerDraftMetrics.hasContent(draft)
        let hasAttachments = !attachedURLs.isEmpty

        guard hasContent || hasAttachments else {
            return .unavailable
        }

        // A running turn accepts a follow-up into its queue, so only a session
        // that could never run a turn — no provider configured, or a queue that
        // is already full — is disabled.
        return focusedSession.canAcceptPrompt ? .available : .unavailable
    }

    private func sendDraft() {
        // Kayıt sürerken gönderilirse mikrofon durur: dikte metni zaten
        // taslaktadır (o gönderilir), sonrasındaki kısmi sonuçlar boşalan
        // besteciyi hayalet metinle doldurmamalı. Önce durdurulur ki araya
        // kısmi sonuç giremesin, sonra taslak okunur.
        stopDictation()
        let promptText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePrompt: String
        if promptText.isEmpty {
            effectivePrompt = "Please inspect the attached file."
        } else {
            effectivePrompt = promptText
        }

        // Bekleyen taslaktan gönderim: sohbet bu anda, aynı kimlikle doğar;
        // taslak anahtarı değişmediği için metin/ek/etiket korunur. Sonrası
        // normal akıştır (yan soru/hedef/düz gönderim).
        if let pending = sessionService.pendingSessionID, draftSessionID == pending {
            sessionService.materializePendingSession(pending)
        }

        // İçeriksiz komut (`/btw`, `/goal`): transkripte yazılmaz, ipucu
        // gösterilir, taslak korunur.
        if let bare = SlashCommand.bareCommandName(from: effectivePrompt) {
            focusedSession.presentNotice(
                .slashCommandHint("Type a question after /\(bare), e.g. /\(bare) what does this do?"),
                autoDismissAfter: .seconds(6)
            )
            return
        }

        // Yan soru önek yakalama: `/btw` normal kuyruğa girmez, panele gider.
        // Meşgul oturumdan da sorulabilir; transkript kirlenmez.
        if let sideQuestion = Self.sideQuestion(from: effectivePrompt),
            let onSideQuestion
        {
            // Ek ve etiketler yan soruya taşınmaz: sessizce düşürmek yerine
            // durdurulur, kullanıcı neyi ayıklayacağına karar verir.
            guard attachedURLs.isEmpty, selectedTags.isEmpty else {
                focusedSession.presentNotice(
                    .slashCommandHint("/btw does not take attachments or tags; remove them or send as a normal message."),
                    autoDismissAfter: .seconds(6)
                )
                return
            }
            onSideQuestion(sideQuestion, speedMode, agentMode)
            draft = ""
            attachedURLs = []
            selectedTags = []
            draftStore?.clear(sessionID: focusedSession.id)
            return
        }

        // Hedef önek yakalama: `/goal` normal kuyruğa girmez, hedef
        // paneline gider. Ret panelde görünür, taslak korunur: yazı ne
        // sohbete ne boşluğa düşer. Kanca yoksa düz metin gibi gönderilir.
        // Bekleyen ekler dizin çözümlemesine tohum olarak taşınır.
        if let objective = SlashCommand.parseGoal(from: effectivePrompt),
            let onStartGoal
        {
            guard onStartGoal(objective, speedMode, agentMode, attachedURLs.map(\.path)) else {
                return
            }
            draft = ""
            attachedURLs = []
            selectedTags = []
            draftStore?.clear(sessionID: focusedSession.id)
            return
        }

        let attachmentPaths = attachedURLs.map { $0.path }
        let acceptance = focusedSession.send(
            effectivePrompt,
            attachmentPaths: attachmentPaths,
            speedMode: speedMode,
            mode: agentMode,
            tags: selectedTags
        )

        if acceptance.wasAccepted {
            draft = ""
            attachedURLs = []
            selectedTags = []
            draftStore?.clear(sessionID: focusedSession.id)
        }
    }

    /// `/btw soru` önekini ayıklar: `/btw` + boşluk + boş-olmayan soru.
    /// Saf ve test edilebilir; büyük/küçük harf duyarsızdır.
    static func sideQuestion(from text: String) -> String? {
        let prefix = "/btw"
        guard text.count > prefix.count else {
            return nil
        }
        guard text.lowercased().hasPrefix(prefix) else {
            return nil
        }
        let remainder = text.dropFirst(prefix.count)
        guard remainder.first?.isWhitespace == true else {
            return nil
        }
        let question = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        return question.isEmpty ? nil : question
    }

    /// Codex/ChatGPT davranışı: eşik üstü bir yapıştırma metin alanını şişirmez,
    /// markdown dosya eki olur. Alan olduğu gibi kalır — varsa yazı korunur —
    /// dosya ek çipi olarak yana eklenir. Yazma başarısız olursa `false` döner
    /// ve metin her zamanki gibi satıra yapışır: yapıştırmanın kaybolması,
    /// ağır bir taslaktan kötüdür.
    private func spillLargePasteToAttachment(_ text: String) -> Bool {
        do {
            let url = try PastedTextAttachment.spill(text)
            if !attachedURLs.contains(url) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    attachedURLs.append(url)
                }
            }
            pushDraftToStore()
            return true
        } catch {
            AppLog.agentSession.error(
                "A long paste could not be spilled to a file; inserting inline"
            )
            return false
        }
    }

    // MARK: - Extension tags

    private var activeTrigger: ExtensionTrigger? {
        ExtensionTrigger.detected(in: draft)
    }

    /// Panelin gerçekten gösterileceği trigger: kullanıcı aynı token'ı Escape ya
    /// da kapatma düğmesiyle reddettiyse bir daha açılmaz.
    private var visibleTrigger: ExtensionTrigger? {
        guard let trigger = activeTrigger else { return nil }
        return suggestionToken(of: trigger) == dismissedSuggestionToken ? nil : trigger
    }

    private func suggestionToken(of trigger: ExtensionTrigger) -> String {
        // `trigger` bir önceki gövde değerlendirmesinden kalma olabilir;
        // taslak o sırada değiştiyse aralık artık uymaz ve `subscript`
        // tuzağa düşer. Geçersiz aralıkta boş belirteç dönülür, panel gizlenir.
        guard trigger.tokenRange.lowerBound >= draft.startIndex,
            trigger.tokenRange.upperBound <= draft.endIndex,
            trigger.tokenRange.lowerBound <= trigger.tokenRange.upperBound
        else {
            return ""
        }
        return String(draft[trigger.tokenRange])
    }

    private func dismissSuggestions(_ trigger: ExtensionTrigger) {
        dismissedSuggestionToken = suggestionToken(of: trigger)
    }

    /// Escape yolu: kapatılacak bir panel yoksa `false` döner ve tuş metin
    /// görünümünün varsayılanına bırakılır.
    private func dismissVisibleSuggestions() -> Bool {
        guard let trigger = visibleTrigger else { return false }
        dismissSuggestions(trigger)
        return true
    }

    private func suggestions(for trigger: ExtensionTrigger) -> [ExtensionSuggestion] {
        extensionStore.registry
            .suggestions(matching: trigger.query)
            .filter { trigger.kinds.contains($0.kind) }
            .filter { !selectedTags.contains($0.tag) }
    }

    @ViewBuilder
    private func extensionSuggestions(for trigger: ExtensionTrigger) -> some View {
        let matches = suggestions(for: trigger)
        // Yerleşik komutlar yalnız `/` panelinde çıkar (`@` paneli
        // sunucu/eklenti listesidir, komut almaz).
        let commands =
            trigger.kinds.contains(.skill)
            ? SlashCommand.matching(query: trigger.query)
            : []

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(
                    systemName: trigger.kinds.first == .skill
                        ? "slash.circle"
                        : "at"
                )
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)

                Text(
                    trigger.kinds.first == .skill
                        ? "Skills — the agent loads one only when it uses it"
                        : "MCP servers and plugins for this turn"
                )
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                if matches.isEmpty {
                    Text(
                        trigger.kinds.first == .skill
                            ? "none installed — add one in Settings"
                            : "none enabled"
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                }

                Button {
                    dismissSuggestions(trigger)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(3)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Close suggestions")
                .accessibilityLabel("Close suggestions")
            }
            .padding(.horizontal, 6)

            if !commands.isEmpty {
                commandsSection(commands, in: trigger)
            }

            // Bounded: a machine with sixty skills must not turn this panel into a
            // full-height wall over the conversation.
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(matches.prefix(Self.maximumSuggestionRows)) { suggestion in
                        suggestionRow(suggestion, in: trigger)
                    }
                }
            }
            .frame(maxHeight: Self.maximumSuggestionPanelHeight)
        }
        .padding(6)
    }

    private static let maximumSuggestionRows = 6
    private static let maximumSuggestionPanelHeight: CGFloat = 220

    @ViewBuilder
    private func suggestionRow(
        _ suggestion: ExtensionSuggestion,
        in trigger: ExtensionTrigger
    ) -> some View {
        Button {
            select(suggestion, in: trigger)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: iconName(for: suggestion.kind))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(currentTheme.accentGradient.first ?? .secondary)
                    .frame(width: 14)

                Text(suggestion.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)

                Text(suggestion.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .interactiveHoverPill(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Insert this suggestion into the draft")
    }

    /// Yerleşik komut bölümü: beceri etiketinden önce, kendi başlığıyla.
    /// Komutlar tura etiket olarak eklenmez; gönderimde kendi akışına gider.
    @ViewBuilder
    private func commandsSection(_ commands: [SlashCommand], in trigger: ExtensionTrigger) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Commands — run on send, never as a tag")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)

            ForEach(commands) { command in
                slashCommandRow(command, in: trigger)
            }
        }
    }

    private func slashCommandRow(_ command: SlashCommand, in trigger: ExtensionTrigger) -> some View {
        Button {
            selectSlashCommand(command, in: trigger)
        } label: {
            HStack(spacing: 8) {
                Text("/\(command.name)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(currentTheme.accentGradient.first ?? .secondary)
                    .frame(minWidth: 46, alignment: .leading)

                Text(command.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .interactiveHoverPill(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Insert /\(command.name) into the draft")
    }

    /// Komut seçimi etikete değil metne yazar: `/btw ` önekinden sonra
    /// soru, `/goal ` önekinden sonra hedef yazılır; gönderimde ilgili
    /// akışa yönlenir. Aralık güvenliği `select` ile aynı desendir
    /// (bayat aralık çökmez, en kötü halde yazı korunur).
    private func selectSlashCommand(_ command: SlashCommand, in trigger: ExtensionTrigger) {
        if let current = ExtensionTrigger.detected(in: draft),
            current.kinds == trigger.kinds,
            current.tokenRange.lowerBound < draft.endIndex,
            current.tokenRange.upperBound <= draft.endIndex
        {
            draft.removeSubrange(current.tokenRange)
        }

        while let last = draft.last, last == " " {
            draft.removeLast()
        }

        if !draft.isEmpty {
            draft += " "
        }
        draft += command.prefix
    }

    /// Choosing a suggestion turns the typed token into a chip: the draft keeps
    /// the sentence, the tag travels beside it.
    private func select(_ suggestion: ExtensionSuggestion, in trigger: ExtensionTrigger) {
        // `trigger` was captured by an earlier body evaluation, so its range belongs
        // to that snapshot of the draft. `removeSubrange` traps on a range that no
        // longer fits the current string, which an input-method commit, a paste or
        // a programmatic edit landing between render and tap can produce. Re-detect
        // and cut only what still matches; otherwise keep the typed text and attach
        // the tag.
        if let current = ExtensionTrigger.detected(in: draft),
            current.kinds == trigger.kinds,
            current.tokenRange.lowerBound < draft.endIndex,
            current.tokenRange.upperBound <= draft.endIndex
        {
            draft.removeSubrange(current.tokenRange)
        }

        while let last = draft.last, last == " " {
            draft.removeLast()
        }

        if !selectedTags.contains(suggestion.tag) {
            selectedTags.append(suggestion.tag)
        }
    }

    private var selectedTagsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(selectedTags) { tag in
                    HStack(spacing: 4) {
                        Image(systemName: iconName(for: tag.kind))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(currentTheme.accentGradient.first ?? .secondary)

                        Text(tag.name)
                            .font(.system(size: 11, weight: .medium))

                        Button {
                            selectedTags.removeAll { $0.id == tag.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(.secondary)
                                .padding(3)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .help("Remove tag")
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 4)
                    .padding(.vertical, 3)
                    .background(
                        Color.primary.opacity(isDarkMode ? 0.10 : 0.07),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .help("\(tag.kind.displayName): \(tag.name)")
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func iconName(for kind: ExtensionKind) -> String {
        kind.symbolName
    }

    private func openFileAttachmentDialog() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            if response == .OK {
                for url in panel.urls {
                    if !attachedURLs.contains(url) {
                        attachedURLs.append(url)
                    }
                }
            }
        }
    }

    /// Eki kaldırır; önizleme popup açıksa onu da kapatır.
    private func removeAttachment(_ url: URL) {
        attachedURLs.removeAll { $0 == url }
        if previewingImage?.url == url {
            previewingImage = nil
        }
    }

    /// Mikrofon düğmesi: kayıtta kapatıp nihai metni bırakır, duruyorsa izin
    /// isteyip kısmi sonuçları taslağa akıtır. Metin yalnızca taslakta birikir.
    ///
    /// Kayıt sürerken oturum değişirse kısmi sonuçlar yanlış taslağa akmasın
    /// diye başlayan oturum yakalanır; uyuşmazlıkta kayıt durdurulur.
    private func stopDictation() {
        guard isDictating else {
            return
        }
        // Servisin döndürdüğü nihai metin atılır: taslak zaten son kısmi
        // sonucu taşır ve gönderim onu okur; buradaki iş yalnız kaydı
        // kapatıp geç gelen geri çağrıları geçersiz kılmaktır.
        dictationService.stop()
        isDictating = false
    }

    private func toggleDictation() {
        if isDictating {
            draft = dictationService.stop()
            isDictating = false
            return
        }
        let base = draft
        let sessionID = draftSessionID
        Task { @MainActor in
            let authorization = await dictationService.requestAuthorization()
            guard authorization == .authorized else {
                focusedSession.state.notice = .dictationUnavailable
                return
            }
            do {
                try dictationService.start(
                    baseText: base,
                    onPartial: { partial in
                        guard
                            DictationSessionGuard.shouldApplyPartial(
                                startedSessionID: sessionID,
                                currentSessionID: self.draftSessionID
                            )
                        else {
                            dictationService.stop()
                            isDictating = false
                            return
                        }
                        draft = partial
                    },
                    onEnded: {
                        isDictating = false
                    }
                )
                isDictating = true
            } catch {
                isDictating = false
            }
        }
    }

    private func attachmentPreviewPill(for url: URL) -> some View {
        let ext = url.pathExtension.lowercased()
        let isImage = AttachmentKind.isImage(url: url)
        let isPDF = ext == "pdf"

        return HStack(spacing: 6) {
            Button {
                onInspectFile?(url)
            } label: {
                HStack(spacing: 6) {
                    if isImage, let image = AttachmentPreviewCache.shared.imageThumbnail(for: url, maxPixelSize: 96) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    } else if isPDF, let thumbnail = AttachmentPreviewCache.shared.pdfThumbnail(for: url, maxPixelSize: 96) {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(Color.red.opacity(0.4), lineWidth: 0.5)
                            )
                    } else {
                        Image(systemName: isPDF ? "doc.richtext.fill" : (ext == "md" ? "doc.richtext.fill" : "doc.fill"))
                            .font(.system(size: 13))
                            .foregroundStyle(isPDF ? .red : (ext == "md" ? .blue : .secondary))
                            .frame(width: 24, height: 24)
                    }

                    Text(url.lastPathComponent)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 160)
                }
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Click to preview file")

            Button {
                removeAttachment(url)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Remove attachment")
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(
            Color.primary.opacity(isDarkMode ? 0.08 : 0.06),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    Color.primary.opacity(isDarkMode ? 0.12 : 0.10),
                    lineWidth: 1
                )
        )
    }
}
