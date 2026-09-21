import AppKit
import PDFKit
import SwiftUI

struct ConversationDetailView: View {
    let sessionService: any AgentSessionServiceProtocol
    let permissionApprovalCenter: PermissionApprovalCenter
    let collapseStore: TimelineCollapseStore
    let focusedSessionID: UUID?
    let paneID: String?
    let showsNavigationTitle: Bool
    /// 2'li ve 4'lü düzende dikey alan bölünür: genişliğe bakılmaksızın
    /// besteci minimal çizilir, yoksa geniş pencerede 4 tam boy besteci
    /// transkripti ezer.
    let isDenseLayout: Bool

    init(
        sessionService: any AgentSessionServiceProtocol,
        permissionApprovalCenter: PermissionApprovalCenter,
        collapseStore: TimelineCollapseStore,
        focusedSessionID: UUID?,
        paneID: String?,
        showsNavigationTitle: Bool,
        isDenseLayout: Bool
    ) {
        self.sessionService = sessionService
        self.permissionApprovalCenter = permissionApprovalCenter
        self.collapseStore = collapseStore
        self.focusedSessionID = focusedSessionID
        self.paneID = paneID
        self.showsNavigationTitle = showsNavigationTitle
        self.isDenseLayout = isDenseLayout
    }

    private var focusedSession: AgentSession {
        if let focusedSessionID, let session = sessionService.session(for: focusedSessionID) {
            return session
        }
        return sessionService.activeSession
    }

    @Environment(SettingsStore.self) private var settingsStore
    /// What "write again" on an earlier message is for: the draft it edits lives
    /// in the composer, one view away.
    @Environment(ComposerDraftCenter.self) private var draftCenter: ComposerDraftCenter?
    @Environment(SessionComposerPrefs.self) private var composerPrefs: SessionComposerPrefs?
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.paneWidth) private var paneWidth

    /// Sağ panelde açık olan sekmeler ve seçili olan sekme kimliği.
    @State private var inspectorTabs: [InspectorTab] = []
    @State private var selectedInspectorTabID: String? = nil
    @State private var inspectorWidth: CGFloat = 620
    @State private var isInspectorExpanded: Bool = false
    @State private var terminalCenter = TerminalServiceCenter()
    /// Yalnız bu iki karar gövdeyi etkiler. Kaydırma ölçümleri bunlara doğrudan
    /// yazılmaz: ölçümü yapan geri çağrı bir ekran döngüsünün içinde çalışır ve
    /// oradan `@State` yazmak aynı döngüde yeni bir yerleşim turu ister.
    @State private var isUserScrolledUp = false
    /// Mesaj sayısı değişiminde tetiklenen kaydırma görevi. Hızlı art arda
    /// eklemelerde (kullanıcı mesajı + asistan yer tutucusu) eski görevler
    /// birbirinin yerleşimini ezer ve görünüm boş kalırdı; yalnız sonuncusu yaşar.
    @State private var messageCountScrollTask: Task<Void, Never>?
    @State private var activePromptID: UUID? = nil
    @State private var offsetTracker = PromptOffsetTracker()
    /// Inspector yerleşim animasyonu bitince dibe sabitleyen görev: art arda
    /// açılıp kapanmalarda yalnız sonuncusu yaşar, yoksa bayat görev elle
    /// yukarı kaydırmış kullanıcıyı dibe çekerdi.
    @State private var inspectorPinTask: Task<Void, Never>?
    /// Collapse değişiminde konumu sabitleyen görev: art arda açılıp
    /// kapanmalarda yalnız sonuncusu yaşar (inspector görevindekiyle aynı
    /// gerekçe).
    @State private var collapsePinTask: Task<Void, Never>?
    /// Bölme genişliği animasyonla değişirken satır konumlarını ölçmek SwiftUI
    /// geometri eylemini aynı karede ileri geri besler. Ölçüm, genişlik kısa
    /// süre sabit kaldıktan sonra yeniden açılır.
    @State private var isPaneResizing = false
    @State private var paneResizeSettleTask: Task<Void, Never>?
    /// Sağ panel durumu oturum başına saklanır: bölme kimliği (`pane-…`)
    /// sohbet değişiminde aynı kaldığı için `@State` sekmeler yok olmazdı ve
    /// bir sohbette açılan rapor diğer sohbete geçince de görünürdü.
    @State private var inspectorStateBySession: [UUID: InspectorPaneState] = [:]
    /// Ölçümler burada toplanır ve döngü dışında yayınlanır (bkz. `body.task`).
    @State private var followState = ScrollFollowState()

    /// Derived lookups are memoized here rather than recomputed inside `body`:
    /// during streaming the body runs many times a second, and the rail titles
    /// and activity anchors do not change while an answer grows.
    @State private var indexCache = TranscriptIndexCache()
    /// Yan soru (`/btw`) servisi: bölme başına yaşar, bellek oturum kimliğine
    /// göre tutulur. Pane-scope seçimi `focusedSession.id` üzerinden yapılır,
    /// o yüzden bölmeler birbirinin sorusunu görmez.
    @State private var sideQuestionService = SideQuestionService()
    /// Tek-tık prompt iyileştirme servisi: bölme başına yaşar, transkripte
    /// yazmaz, turn makinesine girmez. Bitmiş iyileştirme besteci taslağının
    /// yerine geçer; hata taslağı değiştirmez, bildirim gösterir.
    @State private var promptEnhanceService = PromptEnhanceService()
    /// Son uygulanan iyileştirmenin geri alma kaydı: oturum başına tek kayıt.
    /// `enhanced` hâlâ taslaktaysa `original`a dönülür; kullanıcı sonrası
    /// yazdıysa kayıt bayatlar ve geri alma sunulmaz (yazı ezilmez).
    @State private var lastEnhanceUndo: EnhanceUndo?
    /// Hedef (`/goal`) orkestratörü: bölme başına yaşar, oturum başına tek
    /// koşu kuralıyla aynı sohbette ikinci başlatmayı reddeder; farklı
    /// sohbetler eşzamanlı goal koşar.
    @State private var goalOrchestrator = GoalOrchestrator()
    @Environment(ComposerDraftMemory.self) private var draftMemory: ComposerDraftMemory?

    private let contentMaxWidth: CGFloat = 820

    private static let transcriptSpace = "transcript"

    /// Geri alınabilir iyileştirme kaydı: istek anındaki taslak ve onun yerine
    /// geçen iyileşmiş metin. Geri alma yalnız taslak hâlâ `enhanced` ise
    /// yapılır, böylece sonradan yazılan metin ezilmez.
    private struct EnhanceUndo: Equatable {
        let sessionID: UUID
        let original: String
        let enhanced: String
    }

    var body: some View {
        let preset = settingsStore.currentThemePreset
        let isDark = isDarkMode

        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if focusedSession.state.messages.isEmpty {
                        emptyStateView(preset: preset)
                    } else {
                        transcriptScrollView(preset: preset, isDark: isDark)
                    }

                    if let error = focusedSession.state.error,
                        !focusedSession.state.messages.isEmpty
                    {
                        sessionBanner(
                            symbol: error.symbolName,
                            message: error.message,
                            tint: .orange,
                            onDismiss: nil
                        )
                    }

                    if let notice = focusedSession.state.notice,
                        !focusedSession.state.messages.isEmpty
                    {
                        sessionBanner(
                            symbol: notice.symbolName,
                            message: notice.message,
                            tint: .secondary,
                            onDismiss: {
                                focusedSession.dismissNotice()
                            }
                        )
                    }

                    if let question = focusedSession.state.activeQuestion {
                        AgentQuestionCard(
                            question: question,
                            preset: preset,
                            isDark: isDark,
                            isSubmitting: focusedSession.state.isQuestionSubmitting,
                            submissionFailed: focusedSession.state.questionSubmissionFailed,
                            onAnswer: { answer in
                                focusedSession.answerActiveQuestion(answer)
                            },
                            onDismiss: {
                                focusedSession.dismissActiveQuestion()
                            }
                        )
                        .id(question.id)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if let request = permissionApprovalCenter.pending.first(where: {
                        $0.appSessionID == focusedSession.id
                    }) ?? (focusedSessionID == nil ? permissionApprovalCenter.pending.first(where: { $0.appSessionID == nil }) : nil) {
                        let sessionPendingCount = permissionApprovalCenter.pending.filter {
                            $0.appSessionID == focusedSession.id || (focusedSessionID == nil && $0.appSessionID == nil)
                        }.count
                        permissionApprovalBar(
                            request,
                            pendingCount: sessionPendingCount,
                            preset: preset,
                            isDark: isDark
                        )
                    }

                    SideQuestionPanelView(
                        service: sideQuestionService,
                        focusedSessionID: focusedSession.id,
                        onInsertToComposer: { insertSideAnswerToComposer($0) },
                        onClose: { sideQuestionService.dismiss() }
                    )
                    GoalPanelView(
                        orchestrator: goalOrchestrator,
                        focusedSessionID: focusedSession.id
                    )

                    ComposerView(
                        sessionService: sessionService,
                        permissionApprovalCenter: permissionApprovalCenter,
                        focusedSessionID: focusedSessionID,
                        onInspectFile: { url in
                            openFileInInspector(url: url)
                        },
                        onSideQuestion: { question, speedMode, mode in
                            askSideQuestion(question, speedMode: speedMode, mode: mode)
                        },
                        onStartGoal: { objective, speedMode, mode, attachmentPaths in
                            startGoalObjective(
                                objective,
                                speedMode: speedMode,
                                mode: mode,
                                attachmentPaths: attachmentPaths
                            )
                        },
                        fileManager: .default,
                        isDenseLayout: isDenseLayout,
                        onEnhancePrompt: { draft, speedMode, mode, tagNames, attachmentNames in
                            enhancePrompt(
                                draft,
                                speedMode: speedMode,
                                mode: mode,
                                tagNames: tagNames,
                                attachmentNames: attachmentNames
                            )
                        },
                        isEnhancePromptAvailable: focusedSession.configuration != nil,
                        isEnhancingPrompt: isEnhancingPromptForFocusedSession,
                        onCancelEnhancePrompt: {
                            promptEnhanceService.cancelStreaming()
                        },
                        onUndoEnhancePrompt: {
                            undoPromptEnhancement()
                        },
                        isUndoEnhanceAvailable: isUndoEnhanceAvailableForFocusedSession
                    )
                    .onChange(of: promptEnhanceService.active) { _, current in
                        consumePromptEnhancement(current)
                    }
                }
                .frame(
                    // Yan panel açıkken sohbet sütunu kalan alana iner: sabit
                    // 360 tabanı dar bölmede panelin üstüne binerdi. Kapalıyken
                    // eski taban korunur.
                    minWidth: isInspectorExpanded
                        ? 0
                        : (inspectorTabs.isEmpty
                            ? 360 : max(0, paneWidth - fittedInspectorWidth - 6)),
                    maxWidth: isInspectorExpanded ? 0 : .infinity,
                    maxHeight: .infinity
                )
                .opacity(isInspectorExpanded ? 0 : 1)

                if !inspectorTabs.isEmpty,
                    let selectedID = selectedInspectorTabID,
                    let activeTab = inspectorTabs.first(where: { $0.id == selectedID }) ?? inspectorTabs.last
                {
                    if !isInspectorExpanded {
                        inspectorResizeSplitter
                    }

                    InspectorTabsContainerView(
                        tabs: inspectorTabs,
                        selectedTabID: activeTab.id,
                        preset: preset,
                        isDark: isDark,
                        isExpanded: isInspectorExpanded,
                        terminalCenter: terminalCenter,
                        onSelectTab: { tabID in
                            withAnimation(.easeInOut(duration: 0.18)) {
                                selectedInspectorTabID = tabID
                            }
                        },
                        onCloseTab: { tabID in
                            closeInspectorTab(tabID)
                        },
                        onToggleExpand: {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                isInspectorExpanded.toggle()
                            }
                        },
                        onCloseAll: {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                for tab in inspectorTabs {
                                    if case .terminal(let id, _) = tab.kind {
                                        terminalCenter.close(id: id)
                                    }
                                }
                                inspectorTabs = []
                                selectedInspectorTabID = nil
                                isInspectorExpanded = false
                            }
                        }
                    )
                    .frame(
                        // Dar bölmede ham genişlik transkripti ezerdi: kapak,
                        // kullanılabilir genişliğe göre hesaplanır (en az
                        // 280, bölmeyi en çok 32 pt daraltır).
                        minWidth: isInspectorExpanded ? 400 : min(380, fittedInspectorWidth),
                        idealWidth: isInspectorExpanded ? nil : fittedInspectorWidth,
                        maxWidth: isInspectorExpanded ? .infinity : fittedInspectorWidth
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(isDark ? preset.backgroundDark : preset.backgroundLight)
        .navigationTitle(showsNavigationTitle ? focusedSession.title : "")
        .onReceive(NotificationCenter.default.publisher(for: .openPaneTerminal)) { notification in
            guard let targetPane = notification.object as? String else { return }
            let myPane = paneID ?? "primary"
            guard targetPane == myPane else { return }
            let dir = ManagedOpenCodeServerManager.managedWorkingDirectoryURL()
            openTerminalInInspector(workingDirectory: dir)
        }
        .onAppear {
            // Yarım kalan hedef varsa panel devam etmeyi önerir (otomatik
            // başlamaz). Her sohbet kendi dosyasını okur, o yüzden farklı
            // sohbetlerin goal koşuları birbirini engellemez. Eski tek-dosya
            // sürümünden kalan miras kayıt önce sahibinin dosyasına taşınır.
            noticeGoalForFocusedSession()
        }
        .task {
            // Kaydırma ölçümlerini ekran döngüsünün dışında yayınlar. Ölçümü
            // yapan geri çağrının içinde yayınlamak, aynı döngüde yerleşimi
            // yeniden ister; zincir kendi kendini beslediğinde AppKit o döngüde
            // yüzlerce tur görüp istisna atar.
            while !Task.isCancelled {
                try? await Task.sleep(for: ScrollFollowState.publishInterval)
                publishFollowMeasurements()
            }
        }
        .onChange(of: focusedSession.id) { oldID, newID in
            // Bayat kaydırma sabitleme: collapse/inspector görevleri eski
            // bölmenin `proxy` ve `messageID` değerlerini tutar; oturum
            // değişince uyanıp yanlış transkripte `scrollTo` yapmamalı.
            collapsePinTask?.cancel()
            collapsePinTask = nil
            inspectorPinTask?.cancel()
            inspectorPinTask = nil
            switchInspectorState(from: oldID, to: newID)
            // Aynı bölme örneği başka sohbete döner: yeni sohbetin yarım
            // kalmış goal kaydı varsa panele taşınır (tekli kipte sohbet
            // değişiminde goal kartının kaybolması buydu).
            noticeGoalForFocusedSession()
        }
        .onChange(of: paneWidth) { _, _ in
            handlePaneWidthChange()
        }
        .onDisappear {
            collapsePinTask?.cancel()
            collapsePinTask = nil
            inspectorPinTask?.cancel()
            inspectorPinTask = nil
            paneResizeSettleTask?.cancel()
            paneResizeSettleTask = nil
        }
    }

    private var isDarkMode: Bool {
        settingsStore.isDark(systemColorScheme: systemColorScheme)
    }

    /// Text handed back to the assistant once the user accepts a plan. It is an
    /// ordinary user turn: the transcript keeps a record of the approval, and the
    /// stateless provider path sees the same instruction as the stateful one.
    private static let planApprovalPrompt = "Approved — implement the plan exactly as specified."

    /// A plan is actionable only while it is the newest thing in the transcript,
    /// the session is idle, and the composer still says Plan. Anything else means
    /// the user has moved on.
    private func isPlanAwaitingApproval(
        for message: ChatMessage,
        lastMessageID: UUID?,
        isBusy: Bool
    ) -> Bool {
        let currentMode =
            composerPrefs?.effectiveAgentMode(
                for: focusedSession.id,
                default: settingsStore.agentMode
            ) ?? settingsStore.agentMode

        guard
            message.role == .assistant,
            currentMode == .plan || currentMode == .review,
            !isBusy,
            message.id == lastMessageID
        else {
            return false
        }

        return containsPlanDocument(message.text)
    }

    /// Approving is what leaves Plan mode: the mode flips first, then the
    /// assistant is told to build, so nothing is ever built before consent.
    private func approvePlan() {
        if let composerPrefs {
            composerPrefs.setAgentMode(.build, for: focusedSession.id)
        } else {
            settingsStore.agentMode = .build
        }

        let speedMode =
            composerPrefs?.effectiveSpeedMode(
                for: focusedSession.id,
                default: settingsStore.responseSpeedMode
            ) ?? settingsStore.responseSpeedMode

        let acceptance = focusedSession.send(
            Self.planApprovalPrompt,
            attachmentPaths: [],
            speedMode: speedMode,
            mode: .build,
            tags: []
        )

        guard acceptance.wasAccepted else {
            AppLog.agentSession.error(
                "An approved plan could not be handed back to the assistant"
            )
            return
        }
    }

    /// Hands a message back to the composer, where it can be edited before it is
    /// sent again.
    private func writeAgain(_ message: ChatMessage) {
        draftCenter?.requestRestore(
            text: message.text,
            attachmentPaths: message.attachmentPaths,
            sessionID: focusedSession.id
        )
    }

    /// One transcript entry: the message, then the timeline of the turn it
    /// started.
    ///
    /// İkisi açık bir `VStack` içinde durur: çıplak `@ViewBuilder` iki görünümü
    /// aynı satır hücresinde üst üste bindirir, kullanıcı balonu timeline
    /// satırlarının üzerine biner ve yarı saydam kartların altından yazılar
    /// görünür.
    @ViewBuilder
    private func transcriptRow(
        for message: ChatMessage,
        preset: AppThemePreset,
        isDark: Bool,
        index: TranscriptIndex,
        isBusy: Bool,
        hasPendingApprovalForActiveSession: Bool,
        hidesInlineFileCard: Bool,
        onCollapse: ((UUID) -> Void)? = nil
    ) -> some View {
        let isVisibleUser = message.role == .user
        let isVisibleAssistant = message.role == .assistant && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasTurnHeader = message.role == .user && shouldShowTurnHeader(for: message, index: index, isBusy: isBusy)
        let activityGroup = index.activityGroup(after: message.id)

        VStack(alignment: .leading, spacing: 4) {
            if isVisibleUser || isVisibleAssistant {
                ChatMessageRow(
                    message: message,
                    preset: preset,
                    isDark: isDark,
                    contrast: settingsStore.contrast,
                    isPlanAwaitingApproval: isPlanAwaitingApproval(
                        for: message,
                        lastMessageID: index.lastMessageID,
                        isBusy: isBusy
                    ),
                    canResend: !isBusy,
                    isActiveAssistant: message.role == .assistant
                        && isBusy
                        && message.id == index.lastMessageID,
                    isLastAssistantOfTurn: index.lastAssistantMessageIDs.contains(message.id),
                    onApprovePlan: approvePlan,
                    onRestore: { writeAgain(message) },
                    onInspectFile: { url in
                        openFileInInspector(url: url)
                    }
                )
                .modifier(
                    PromptOffsetProbe(
                        messageID: message.id,
                        isUserMessage: message.role == .user,
                        isEnabled: promptItems.count > 1 && !isPaneResizing,
                        space: Self.transcriptSpace,
                        onOffset: { messageID, offset in
                            reportPromptOffset(offset, for: messageID)
                        }
                    )
                )
            }

            if hasTurnHeader {
                turnHeaderView(
                    for: message,
                    isDark: isDark,
                    lastUserMessageID: index.lastUserMessageID,
                    isBusy: isBusy
                )
            }

            if let activityGroup {
                let isTurnAct = isTurnActive(
                    for: activityGroup,
                    isBusy: isBusy,
                    activeTurnMessageIDs: index.activeTurnMessageIDs
                )
                AgentActivityTimelineView(
                    group: activityGroup,
                    isTurnActive: isTurnAct,
                    isSessionBusy: isBusy,
                    hasPendingApproval: hasPendingApprovalForActiveSession && isTurnAct,
                    sessionID: focusedSession.id,
                    collapseStore: collapseStore,
                    onOpenReport: { activity in
                        openSubagentReportInInspector(activity: activity)
                    },
                    onOpenReview: { summary, file in
                        openReviewInInspector(summary: summary, initialFile: file)
                    },
                    suppressesInlineFileCard: hidesInlineFileCard,
                    onCollapseChange: {
                        onCollapse?(message.id)
                    }
                )
                .equatable()
            }
        }
        .id(message.id)
    }

    private func shouldShowTurnHeader(
        for userMessage: ChatMessage,
        index: TranscriptIndex,
        isBusy: Bool
    ) -> Bool {
        guard userMessage.role == .user else { return false }
        if isBusy && userMessage.id == index.lastUserMessageID {
            return true
        }
        return index.turnHeaderUserMessageIDs.contains(userMessage.id)
    }

    @ViewBuilder
    private func turnHeaderView(
        for userMessage: ChatMessage,
        isDark: Bool,
        lastUserMessageID: UUID?,
        isBusy: Bool
    ) -> some View {
        let isCurrentBusyTurn = isBusy && userMessage.id == lastUserMessageID

        VStack(alignment: .leading, spacing: 4) {
            if isCurrentBusyTurn {
                // Bölme başına `TimelineView` yerine paylaşılan saniye saati:
                // 4 bölme = 4 ayrı 1Hz zamanlayıcı yerine tek saat çalışır.
                SecondTick { date in
                    let start = focusedSession.state.startedAt ?? Date()
                    let duration = formatTurnDuration(startedAt: start, endedAt: date)
                    Text("Working for \(duration)")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            } else {
                let start = focusedSession.state.startedAt ?? userMessage.createdAt
                let end = focusedSession.state.completedAt ?? Date()
                let duration = formatTurnDuration(startedAt: start, endedAt: end)
                Text("Working for \(duration)")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            Rectangle()
                .fill(Color.primary.opacity(isDark ? 0.08 : 0.06))
                .frame(height: 1)
        }
        .padding(.top, 2)
        .padding(.bottom, 1)
    }

    private func formatTurnDuration(startedAt: Date, endedAt: Date) -> String {
        let elapsed = max(1, Int(endedAt.timeIntervalSince(startedAt)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }

    private var emptyStateTitle: String {
        sessionService.state.error == nil ? "Start a conversation" : "Setup required"
    }

    private var emptyStateSymbol: String {
        sessionService.state.error?.symbolName ?? "bubble.left.and.bubble.right"
    }

    private var emptyStateDescription: String {
        if let error = sessionService.state.error {
            return error.message
        }

        if sessionService.providers.isEmpty {
            return "Configure a provider to get started."
        }

        return "Choose a provider configuration and send a message below."
    }

    // MARK: - Inspector Tabs

    /// Yan soru (`/btw`): besteci kancası panele taşınır. Bağlam bu bölmenin
    /// oturumundan kurulur; transkripte ve turn makinesine dokunulmaz.
    private func askSideQuestion(_ question: String, speedMode: ResponseSpeedMode, mode: AgentMode) {
        guard let context = sessionService.sideQuestionContext(for: focusedSession.id) else {
            sideQuestionService.fail(
                sessionID: focusedSession.id,
                question: question,
                message: "This conversation has no provider context yet."
            )
            return
        }
        sideQuestionService.ask(
            context: context,
            sessionID: focusedSession.id,
            question: question,
            speedMode: speedMode,
            mode: mode
        )
    }

    /// Tek-tık prompt iyileştirme: besteci kancası servise taşınır. Bağlam bu
    /// bölmenin oturumundan kurulur; transkripte ve turn makinesine
    /// dokunulmaz. Bağlam yoksa (sağlayıcısız oturum) bildirim gösterilir,
    /// taslak aynen durur. Yeni istek oturumun eski geri alma kaydını düşürür.
    private func enhancePrompt(
        _ draft: String,
        speedMode: ResponseSpeedMode,
        mode: AgentMode,
        tagNames: [String],
        attachmentNames: [String]
    ) {
        guard let context = sessionService.sideQuestionContext(for: focusedSession.id) else {
            focusedSession.presentNotice(.promptEnhancementFailed, autoDismissAfter: .seconds(6))
            return
        }
        if lastEnhanceUndo?.sessionID == focusedSession.id {
            lastEnhanceUndo = nil
        }
        promptEnhanceService.enhance(
            context: context,
            sessionID: focusedSession.id,
            draft: draft,
            speedMode: speedMode,
            mode: mode,
            tagNames: tagNames,
            attachmentNames: attachmentNames
        )
    }

    /// Bu bölmenin gösterdiği oturumda iyileştirme akıyor mu: servis bölme
    /// başına yaşadığı için başka oturumun akışı bu bestecide gösterilmez;
    /// o akış kendi oturumunun taslağına sessizce uygulanır.
    private var isEnhancingPromptForFocusedSession: Bool {
        promptEnhanceService.active?.sessionID == focusedSession.id
            && promptEnhanceService.isEnhancing
    }

    /// Geri alma düğmesi yalnız bu oturumun kaydı varken ve taslak hâlâ
    /// iyileşmiş metinken görünür: sonrası yazı ya da gönderim kaydı bayatlatır.
    private var isUndoEnhanceAvailableForFocusedSession: Bool {
        guard let undo = lastEnhanceUndo, undo.sessionID == focusedSession.id else {
            return false
        }
        let current = draftMemory?.drafts[focusedSession.id]?.text ?? ""
        return PromptEnhancer.shouldApplyEnhancement(currentDraft: current, originalDraft: undo.enhanced)
    }

    /// Kaydedilen iyileştirme öncesine döner: taslak `original`a yazılır.
    /// Taslak arada değiştiyse dokunulmaz, kayıt yine düşer (bayattır).
    private func undoPromptEnhancement() {
        guard let undo = lastEnhanceUndo, undo.sessionID == focusedSession.id else {
            return
        }
        lastEnhanceUndo = nil
        guard let draftMemory else {
            return
        }
        let current = draftMemory.drafts[focusedSession.id]?.text ?? ""
        guard PromptEnhancer.shouldApplyEnhancement(currentDraft: current, originalDraft: undo.enhanced) else {
            return
        }
        var drafts = draftMemory.drafts
        var draft = drafts[focusedSession.id, default: .empty]
        draft.text = undo.original
        drafts[focusedSession.id] = draft
        draftMemory.drafts = drafts
    }

    /// Bitmiş ya da düşmüş iyileştirmeyi tüketir: başarıda iyileşmiş metin,
    /// istek anından beri taslak değişmediyse isteğin açıldığı oturumun
    /// taslağının yerine geçer (ekler ve etiketler aynen kalır) ve geri alma
    /// kaydı tutulur. Taslak arada değiştiyse iyileştirme atılır, yazı korunur
    /// ve bildirim gösterilir. Hatada taslak değişmez, bildirim gösterilir.
    private func consumePromptEnhancement(_ current: PromptEnhanceService.ActiveEnhancement?) {
        guard let current else {
            return
        }
        switch current.phase {
        case .streaming, .cancelled:
            break
        case .done:
            if let text = promptEnhanceService.consumeDone() {
                applyEnhancedPrompt(text, sessionID: current.sessionID, originalDraft: current.originalDraft)
            }
        case .failed:
            promptEnhanceService.dismiss()
            sessionService.session(for: current.sessionID)?.presentNotice(
                .promptEnhancementFailed,
                autoDismissAfter: .seconds(6)
            )
        }
    }

    /// İyileşmiş metni oturumun taslağına yazar (üzerine yazar, eklemez) ve
    /// geri alma kaydını tutar. Taslak istek anından beri değiştiyse yazmaz.
    private func applyEnhancedPrompt(_ text: String, sessionID: UUID, originalDraft: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let draftMemory else {
            return
        }
        let current = draftMemory.drafts[sessionID]?.text ?? ""
        guard PromptEnhancer.shouldApplyEnhancement(currentDraft: current, originalDraft: originalDraft) else {
            sessionService.session(for: sessionID)?.presentNotice(
                .promptEnhancementSuperseded,
                autoDismissAfter: .seconds(6)
            )
            return
        }
        var drafts = draftMemory.drafts
        var draft = drafts[sessionID, default: .empty]
        draft.text = trimmed
        drafts[sessionID] = draft
        draftMemory.drafts = drafts
        lastEnhanceUndo = EnhanceUndo(sessionID: sessionID, original: originalDraft, enhanced: trimmed)
    }

    /// Yan cevabı besteci taslağına ekler (metin korunur, altına eklenir).
    private func insertSideAnswerToComposer(_ text: String) {        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let draftMemory else {
            return
        }
        let key = focusedSessionID ?? sessionService.activeSessionID
        var drafts = draftMemory.drafts
        var draft = drafts[key, default: .empty]
        draft.text = draft.text.isEmpty ? trimmed : draft.text + "\n\n" + trimmed
        drafts[key] = draft
        draftMemory.drafts = drafts
    }

    /// Hedef (`/goal`): besteci kancası orkestratöre taşınır. Doğrulama
    /// dizini önce sinyallerden bulunur (kayıtlı tercih, önceki koşu,
    /// oturumdaki dosya yolları, bestecideki ekler); hiçbir sinyal paket
    /// vermezse klasör hemen sorulur (yaz → seç → başla, tek akış).
    /// Her sohbet kendi goal dosyasında koşar, farklı sohbetler eşzamanlı
    /// goal çalıştırır (çoklu-goal serbest); aynı sohbette ikinci koşu
    /// reddedilir. Başarıyı döner: besteci taslağı yalnız kabulde temizler,
    /// rette metin alanda kalır. Meşgul kuyruğu da kabuldür: istek panelde
    /// "Goal queued" olarak durur, tur bitince kendiliğinden başlar.
    @discardableResult
    private func startGoalObjective(
        _ objective: String,
        speedMode: ResponseSpeedMode,
        mode: AgentMode,
        attachmentPaths: [String]
    ) -> Bool {
        if let directory = resolvedGoalDirectory(extraSeeds: attachmentPaths) {
            return startGoal(
                in: directory,
                objective: objective,
                speedMode: speedMode,
                mode: mode
            )
        }
        // Hiçbir sinyal proje vermedi: klasörü hemen sor. Vazgeçilirse ret
        // kartı yolu açılır ki hedef + kopyalama kaybolmasın. Bu seçimde
        // ret alınırsa ikinci pencere açılmaz, kart gösterilir.
        if let picked = promptPackageFolder() {
            // Seçilen klasörün kullanılabilir hâli: kendisi projeseyse
            // kendisi, tek bir alt dizini projeseyse o alt dizin (klasik
            // "bir üstü seçme" hatası sessizce düzelir). Desteklenmeyen
            // seçim ham hâliyle başlatmaya girer ki ret kartı doğru
            // iletiyle açılsın ve "Choose project folder…" yolu çalışsın.
            let usable = GoalRunners.usableProjectDirectory(at: picked) ?? picked
            return startGoal(
                in: usable,
                objective: objective,
                speedMode: speedMode,
                mode: mode,
                promptOnRefusal: false
            )
        }
        _ = startGoal(
            in: ManagedOpenCodeServerManager.managedWorkingDirectoryURL(),
            objective: objective,
            speedMode: speedMode,
            mode: mode
        )
        return false
    }

    /// Tek dizinde başlatmayı dener. Bu çağrıda klasör zaten sorulduysa
    /// (`promptOnRefusal == false`) rette ikinci kez sorulmaz; ret kartı
    /// kendi "Choose project folder…" düğmesiyle yolu açar. Art arda iki
    /// pencere, "seçtim ama çalışmıyor" hissinin ta kendisiydi.
    @discardableResult
    private func startGoal(
        in directory: URL,
        objective: String,
        speedMode: ResponseSpeedMode,
        mode: AgentMode,
        promptOnRefusal: Bool = true
    ) -> Bool {
        let started = goalOrchestrator.start(
            objective: objective,
            sessionID: focusedSession.id,
            speedMode: speedMode,
            mode: mode,
            workingDirectory: directory,
            bridge: goalBridge(),
            storeURL: GoalStore.liveFileURL(for: focusedSession.id)
        )
        if started {
            GoalStore.savePreferredPackageDirectory(directory.path)
            return true
        }
        if goalOrchestrator.failedRequest?.autoStart == true {
            return true
        }
        guard isPackageRefusal else {
            return false
        }
        guard promptOnRefusal, let picked = promptPackageFolder() else {
            return false
        }
        guard let usable = GoalRunners.usableProjectDirectory(at: picked) else {
            return false
        }
        if goalOrchestrator.retryFailedGoal(in: usable) {
            GoalStore.savePreferredPackageDirectory(usable.path)
            return true
        }
        return false
    }

    /// Son ret proje-dizin yokluğundan mı: kart zaten çizilir.
    private var isPackageRefusal: Bool {
        guard goalOrchestrator.engine == nil, goalOrchestrator.failedRequest != nil else {
            return false
        }
        return (goalOrchestrator.message ?? "").contains("not a SwiftPM package or Xcode project")
    }

    /// Proje klasörü sorar (`nil` = vazgeçildi). Tek alt dizin projeyse
    /// orası kullanılır ("bir üstü seçme" hatası); geçersiz seçim ret
    /// kartına düşer, ikinci pencere açılmaz.
    private func promptPackageFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose the project folder (SwiftPM package or Xcode project) where build and tests will run."
        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }
        return url
    }

    /// Hedef doğrulamanın koşacağı dizin: önce bu bölmenin bilinen dizini
    /// (koşan/biten koşudan), sonra kayıtlı tercih (geçerliyse), sonra
    /// oturumdaki dosya sinyallerinden türetilen proje dizini (ekler,
    /// aktivite yolları, bestecideki bekleyen ekler). `nil` = hiçbir aday
    /// desteklenen proje değildir; çağıran klasör sorar.
    private func resolvedGoalDirectory(extraSeeds: [String] = []) -> URL? {
        // Reddedilen isteğin dizini de adaydır: kullanıcı klasörü seçip
        // ret aldıysa (ör. tek alt dizin projesi) bir sonraki `/goal`
        // aynı seçimi hatırlasın, yeniden klasör sormasın.
        let known = [
            goalOrchestrator.workingDirectoryPath,
            goalOrchestrator.failedRequest?.workingDirectoryPath ?? "",
            GoalStore.preferredPackageDirectory() ?? "",
        ]
        var seeds = Self.goalDirectorySeeds(
            messages: focusedSession.state.messages,
            groups: focusedSession.state.activityGroups
        )
        seeds.append(contentsOf: extraSeeds)
        return GoalRunners.resolvePackageDirectory(knownPaths: known, seedPaths: seeds)
    }

    /// Oturumdaki dosya sinyalleri (en yeniden en eskiye, üst sınırlı):
    /// ileti ekleri ve aktivite detay yolları. Paket araması bunları tohum
    /// sayar; kullanıcıya klasör sormadan dizin bulunur.
    static func goalDirectorySeeds(
        messages: [ChatMessage],
        groups: [AgentTurnActivityGroup],
        maximumSeeds: Int = 50
    ) -> [String] {
        var seeds: [String] = []
        seeds.reserveCapacity(maximumSeeds)
        for message in messages.reversed() {
            for path in message.attachmentPaths.reversed() {
                seeds.append(path)
                if seeds.count >= maximumSeeds {
                    return seeds
                }
            }
        }
        for group in groups.reversed() {
            for activity in group.activities.reversed() {
                if let detail = activity.detail {
                    seeds.append(detail)
                    if seeds.count >= maximumSeeds {
                        return seeds
                    }
                }
            }
        }
        return seeds
    }

    /// Bölmenin goal orkestratörünü odaktaki sohbetin dosyasına bağlar.
    /// Birincil bölme tekli↔çoklu geçişte ve sohbet değişiminde aynı görünüm
    /// örneği yaşar (`pane-primary` kimliği sabittir), o yüzden `onAppear`
    /// yetmez: odak değişince de bu sohbetin yarım kalmış koşusu panele
    /// taşınır. Başka sohbette koşan hedef ezilmez (arka planda sürer, panel
    /// oturuma göre kapılar).
    private func noticeGoalForFocusedSession() {
        GoalStore.migrateLegacyIfNeeded()
        guard let storeURL = GoalStore.liveFileURL(for: focusedSession.id) else {
            return
        }
        if let current = goalOrchestrator.sessionID, current != focusedSession.id,
            goalOrchestrator.engine != nil
        {
            return
        }
        goalOrchestrator.noticeStoredRun(storeURL: storeURL, bridge: goalBridge())
    }

    private func goalBridge() -> GoalOrchestrator.Bridge {
        GoalOrchestrator.Bridge(
            isBusy: { [sessionService] id in
                sessionService.session(for: id)?.isBusy ?? false
            },
            activityCount: { [sessionService] id in
                sessionService.session(for: id)?.state.activityGroups.flatMap(\.activities).count ?? 0
            },
            submit: { [sessionService] id, text, turnMode, turnSpeed in
                sessionService.session(for: id)?.send(
                    text,
                    attachmentPaths: [],
                    speedMode: turnSpeed,
                    mode: turnMode,
                    tags: []
                ) ?? .rejected
            },
            turnError: { [sessionService] id in
                sessionService.session(for: id)?.state.error
            },
            lastAssistantText: { [sessionService] id in
                sessionService.session(for: id)?.state.messages.last(where: { $0.role == .assistant })?.text
            },
            cancel: { [sessionService] id in
                Task { await sessionService.session(for: id)?.cancel() }
            },
            isWaitingForUser: { [sessionService, permissionApprovalCenter] id in
                if sessionService.session(for: id)?.state.activeQuestion != nil {
                    return true
                }
                return !permissionApprovalCenter.pendingRequests(for: id).isEmpty
            }
        )
    }

    private func openFileInInspector(url: URL) {
        // Sembolik bağ kaçışı: yönetilen dizin içinde görünüp dışarıyı
        // gösteren bağ (ya da dışarıdaki dosya) sessizce önizlenmez;
        // bağlantı tıklamalarındaki desenle aynı bilinçli onay istenir.
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let base = ManagedOpenCodeServerManager.managedWorkingDirectoryURL()
            .resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalPath = canonical.path
        let isInside = canonicalPath == base || canonicalPath.hasPrefix(base + "/")
        let hopsThroughSymlink = canonicalPath != url.standardizedFileURL.path
        if hopsThroughSymlink, !isInside {
            let alert = NSAlert()
            alert.messageText = "Bu dosya dışarıyı gösteriyor. Önizlensin mi?"
            alert.informativeText = canonicalPath
            alert.addButton(withTitle: "Önizle")
            alert.addButton(withTitle: "Vazgeç")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
        }
        let tab = InspectorTab.forFile(url: url)
        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
            if !inspectorTabs.contains(where: { $0.id == tab.id }) {
                inspectorTabs.append(tab)
            }
            selectedInspectorTabID = tab.id
        }
    }

    private func openSubagentReportInInspector(activity: AgentActivity) {
        let tab = InspectorTab.forSubagentReport(activity: activity)
        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
            if !inspectorTabs.contains(where: { $0.id == tab.id }) {
                inspectorTabs.append(tab)
            }
            selectedInspectorTabID = tab.id
        }
    }

    /// Oturum sonu toplu dosya kartı: tüm turlardaki dosya değişiklikleri
    /// tek özette, transkriptin en altında. Oturum boşta ve herhangi bir dosya
    /// değişikliği varsa çizilir; çizildiğinde satır içi tur kartlarının tamamı
    /// gizlenir, yoksa aynı dosyalar üstte/ortada ve altta iki kez durur.
    /// Koşarken çizilmez: liste canlı uzar, kartın sayıları yalan olur.
    @ViewBuilder
    private func sessionReviewCard(summary: TurnFileChangesSummary?, sessionID: UUID) -> some View {
        if let summary {
            FileChangesSummaryCard(
                summary: summary,
                isExpanded: Binding(
                    get: {
                        collapseStore.isSessionFilesExpanded(sessionID: sessionID)
                    },
                    set: { expanded in
                        collapseStore.setSessionFilesExpanded(expanded, sessionID: sessionID)
                    }
                ),
                onOpenReview: { summary, file in
                    openReviewInInspector(summary: summary, initialFile: file)
                }
            )
            .padding(.top, 4)
        }
    }

    private func openReviewInInspector(summary: TurnFileChangesSummary, initialFile: FileChangeItem?) {
        let tab = InspectorTab.forReview(summary: summary, initialFile: initialFile)
        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
            if let idx = inspectorTabs.firstIndex(where: { $0.id == tab.id }) {
                inspectorTabs[idx] = tab
            } else {
                inspectorTabs.append(tab)
            }
            selectedInspectorTabID = tab.id
        }
    }

    private func openTerminalInInspector(workingDirectory: URL) {
        let paneKey = paneID ?? "primary"
        let tab = InspectorTab.forTerminal(
            paneID: paneKey,
            workingDirectory: workingDirectory.path
        )
        _ = terminalCenter.service(for: tab.id, workingDirectory: workingDirectory)
        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
            if !inspectorTabs.contains(where: { $0.id == tab.id }) {
                inspectorTabs.append(tab)
            }
            selectedInspectorTabID = tab.id
        }
    }

    private func closeInspectorTab(_ tabID: String) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            guard let idx = inspectorTabs.firstIndex(where: { $0.id == tabID }) else {
                return
            }
            let removed = inspectorTabs.remove(at: idx)
            if case .terminal(let id, _) = removed.kind {
                terminalCenter.close(id: id)
            }
            if selectedInspectorTabID == tabID {
                if inspectorTabs.indices.contains(idx) {
                    selectedInspectorTabID = inspectorTabs[idx].id
                } else if let last = inspectorTabs.last {
                    selectedInspectorTabID = last.id
                } else {
                    selectedInspectorTabID = nil
                    isInspectorExpanded = false
                }
            }
        }
    }

    /// Yan panelin bölmeye sığan genişliği: istenen genişlik, kullanılabilir
    /// alana göre kapaklanır. Saf hesap, durum tutulmaz.
    private var fittedInspectorWidth: CGFloat {
        PaneResponsive.inspectorWidth(
            requested: inspectorWidth,
            available: paneWidth,
            isExpanded: false
        )
    }

    private var inspectorResizeSplitter: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6)
            .overlay(
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let delta = -value.translation.width
                        inspectorWidth = max(380, min(1400, inspectorWidth + delta))
                    }
            )
    }

    /// Session errors and notices were previously stored and never shown; the
    /// user could not tell why a turn failed, why sending was disabled, or why
    /// part of the conversation was left out of the request.
    private func sessionBanner(
        symbol: String,
        message: String,
        tint: Color,
        onDismiss: (() -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))

            Text(message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(tint.opacity(0.8))
                        .padding(4)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Dismiss notice")
                .accessibilityLabel("Dismiss notice")
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            tint.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tint.opacity(0.28), lineWidth: 1)
        )
        .frame(maxWidth: contentMaxWidth)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    /// Bilgisayar kullanımı ve yetki istekleri burada onaylanır; onaylanana
    /// kadar OpenCode turu bu isteği bekler.
    private func permissionApprovalBar(
        _ request: PermissionApprovalCenter.PendingRequest,
        pendingCount: Int,
        preset: AppThemePreset,
        isDark: Bool
    ) -> some View {
        let accent = preset.accentGradient.first ?? .accentColor
        let owningTitle = request.appSessionID.flatMap { id in
            sessionService.sessions.first { $0.id == id }?.title
        }
        let isCurrentSession = request.appSessionID == focusedSession.id
        let conversation =
            isCurrentSession
            ? "Current conversation · \(owningTitle ?? focusedSession.title)"
            : request.appSessionID == nil
                ? "Backend session · \(request.remoteSessionID)"
                : "Background conversation · \(owningTitle ?? request.remoteSessionID)"
        // A delegated session asks on the agent's behalf, and its question is the
        // one a user is most likely to misread as the whole turn's. Saying who is
        // asking is what keeps "may I read outside this folder?" answerable.
        let origin =
            request.isDelegatedSession
            ? "Delegated subagent · \(conversation)"
            : conversation

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: request.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)

                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        pendingCount > 1
                            ? "\(request.title) · \(pendingCount) pending approvals"
                            : request.title
                    )
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                    Text(origin)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(request.toolName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)

                    if let detail = request.detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }

            // What will actually run, verbatim. A prompt that only named the tool
            // (`bash`) asked the user to approve a category; the command is the
            // thing being approved.
            if !request.patterns.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(request.patterns.prefix(3).enumerated()), id: \.offset) { _, pattern in
                        Text(pattern)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if request.patterns.count > 3 {
                        Text("+\(request.patterns.count - 3) more")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.primary.opacity(isDark ? 0.08 : 0.05),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
            }

            HStack(spacing: 8) {
                // The level, changeable from the prompt itself: deciding "ask me
                // nothing for this" is a decision about the whole class, and the
                // alternative is answering the same question again in a minute.
                Menu {
                    ForEach(ToolApprovalPolicy.allCases) { policy in
                        Button {
                            settingsStore.toolApprovalPolicy = policy
                            permissionApprovalCenter.reinterpretPendingRequests()
                        } label: {
                            Text(policy.compactName)
                        }
                        .help(policy.summary)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: settingsStore.toolApprovalPolicy.symbolName)
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(settingsStore.toolApprovalPolicy.displayName)
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(settingsStore.toolApprovalPolicy.isUnrestricted ? Color.orange : .secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Answer the waiting prompts with a different tool approval level")

                Spacer(minLength: 0)

                permissionApprovalButton(
                    title: "Deny",
                    tint: .red,
                    isProminent: false,
                    preset: preset,
                    isDark: isDark
                ) {
                    permissionApprovalCenter.resolve(id: request.id, reply: .reject)
                }

                permissionApprovalButton(
                    title: "Allow once",
                    tint: accent,
                    isProminent: false,
                    preset: preset,
                    isDark: isDark
                ) {
                    permissionApprovalCenter.resolve(id: request.id, reply: .once)
                }

                if !request.alwaysPatterns.isEmpty {
                    permissionApprovalButton(
                        title: "Always allow",
                        tint: accent,
                        isProminent: true,
                        preset: preset,
                        isDark: isDark
                    ) {
                        permissionApprovalCenter.resolve(id: request.id, reply: .always)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            accent.opacity(isDark ? 0.14 : 0.10),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accent.opacity(0.32), lineWidth: 1)
        )
        .frame(maxWidth: contentMaxWidth)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
    }

    private func permissionApprovalButton(
        title: String,
        tint: Color,
        isProminent: Bool,
        preset: AppThemePreset,
        isDark: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isProminent ? Color.white : tint)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background {
                    if isProminent {
                        LinearGradient(
                            colors: preset.accentGradient,
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .clipShape(Capsule())
                    } else {
                        tint.opacity(isDark ? 0.22 : 0.14)
                            .clipShape(Capsule())
                    }
                }
                .overlay(
                    Capsule().stroke(tint.opacity(isProminent ? 0 : 0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func isTurnActive(
        for group: AgentTurnActivityGroup,
        isBusy: Bool,
        activeTurnMessageIDs: Set<UUID>
    ) -> Bool {
        guard isBusy else {
            return false
        }

        guard let activeTurnID = focusedSession.activeTurnID else {
            return false
        }
        if let groupTurnID = group.turnID {
            return groupTurnID == activeTurnID
        }
        if activeTurnID == group.id {
            return true
        }

        if activeTurnMessageIDs.contains(group.anchorMessageID) {
            return true
        }

        return false
    }

    // MARK: - Prompt navigation

    /// One entry per prompt the user sent, oldest first: the rail maps the
    /// conversation's questions, not the answers.
    private var transcriptIndex: TranscriptIndex {
        indexCache.index(
            messages: focusedSession.state.messages,
            activityGroups: focusedSession.state.activityGroups,
            maximumPromptCount: PromptRailMetrics.maximumBarCount,
            activityRevision: focusedSession.state.activityRevision
        )
    }

    private var promptItems: [PromptNavigatorRail.Item] {
        transcriptIndex.promptItems
    }

    private func railTitle(for prompt: String) -> String {
        TranscriptIndex.railTitle(for: prompt)
    }

    /// Rows report a rounded position; updates only invalidate active prompt when it changes.
    ///
    /// Bu geri çağrı da bir yerleşim geçişinin içinde çalışır (her 8 pt'lik
    /// adımda), bu yüzden burada `@State` yazılmaz: yeni kimlik yayın sırasına
    /// girer ve döngü dışında uygulanır.
    private func reportPromptOffset(_ offset: CGFloat, for messageID: UUID) {
        guard
            let newActiveID = offsetTracker.update(
                messageID: messageID,
                offset: offset,
                items: promptItems
            )
        else {
            return
        }

        followState.recordActivePrompt(newActiveID)
    }

    /// The rail lives in the transcript's left gutter, so the text starts clear
    /// of it whether or not the window leaves room for a gutter of its own.
    private var transcriptLeadingInset: CGFloat {
        promptItems.count > 1 ? PromptRailMetrics.columnWidth : 20
    }

    /// A wide window leaves a gutter on either side of the centred transcript;
    /// the rail sits at the left edge of that gutter rather than against the
    /// window, and hugs the edge when the window is too narrow to have one.
    private func railLeadingInset(paneWidth: CGFloat) -> CGFloat {
        let gutter = (paneWidth - contentMaxWidth) / 2
        return max(6, gutter - PromptRailMetrics.columnWidth - 4)
    }

    /// Bekleyen kaydırma ölçümlerini gövdeye yazar.
    ///
    /// Yalnız değer gerçekten değiştiğinde yazılır: aynı değeri yeniden yazmak
    /// da bir çizim turudur ve o tur yeni bir ölçüm üretir. Animasyon da yok;
    /// kaydırma sırasında yumuşatma yerleşim turlarını çoğaltmaktan başka bir
    /// şey yapmıyordu (düğmenin kendi geçişi zaten var).
    private func publishFollowMeasurements() {
        let pending = followState.takePending()

        if let awayFromBottom = pending.awayFromBottom, awayFromBottom != isUserScrolledUp {
            isUserScrolledUp = awayFromBottom
        }

        if let newActiveID = pending.activePromptID, newActiveID != activePromptID {
            activePromptID = newActiveID
        }
    }

    private func scrollToBottomButton(
        proxy: ScrollViewProxy,
        preset: AppThemePreset,
        isDark: Bool
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                isUserScrolledUp = false
                followState.resumeFollow()
                proxy.scrollTo("bottom_anchor", anchor: .bottom)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                Text("Scroll to end")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(
                        (isDark ? preset.surfaceDark : preset.surfaceLight)
                            .opacity(isDark ? 0.94 : 0.97)
                    )
            )
            .overlay(
                Capsule()
                    .stroke(
                        (isDark ? preset.borderSubtleDark : preset.borderSubtleLight)
                            .opacity(1.0),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: .black.opacity(isDark ? 0.45 : 0.20),
                radius: 10,
                x: 0,
                y: 4
            )
            .interactiveHoverPill(cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .help("Scroll to the latest message")
        .accessibilityLabel("Scroll to end")
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    @ViewBuilder
    private func emptyStateView(preset: AppThemePreset) -> some View {
        VStack(spacing: 16) {
            Image(systemName: emptyStateSymbol)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: preset.accentGradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: 6) {
                Text(emptyStateTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(emptyStateDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    @ViewBuilder
    private func transcriptScrollView(preset: AppThemePreset, isDark: Bool) -> some View {
        let index = transcriptIndex
        let isBusy = focusedSession.isBusy
        let sessionID = focusedSession.id
        // Oturum toplu özeti bir kez hesaplanır: hem alttaki kart hem de
        // satır içi tur kartlarının gizlenme kararı aynı değerden beslenir.
        // Meşgulken toplu kart çizilmez, bitmiş turların kartı durur; oturum
        // bitince özet alta taşınır ve satır içi kartların tamamı gizlenir.
        let sessionSummary =
            isBusy
            ? nil
            : TurnFileChangesSummary.sessionReviewSummary(
                from: focusedSession.state.activityGroups
            )
        let hasPendingForActiveSession = permissionApprovalCenter.pending.contains { request in
            request.appSessionID == sessionID
        }

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(focusedSession.state.messages) { message in
                        transcriptRow(
                            for: message,
                            preset: preset,
                            isDark: isDark,
                            index: index,
                            isBusy: isBusy,
                            hasPendingApprovalForActiveSession: hasPendingForActiveSession,
                            hidesInlineFileCard: sessionSummary != nil,
                            onCollapse: { messageID in
                                handleTimelineCollapse(messageID: messageID, proxy: proxy)
                            }
                        )
                    }

                    sessionReviewCard(summary: sessionSummary, sessionID: sessionID)

                    Color.clear
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                        .id("bottom_anchor")
                }
                .padding(.leading, transcriptLeadingInset)
                .padding(.trailing, 20)
                .padding(.vertical, 10)
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .id(focusedSession.id)
            .coordinateSpace(.named(Self.transcriptSpace))
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: ChatScrollSnapshot.self) { geometry in
                guard geometry.containerSize.height > 0 && geometry.contentSize.height > 0 else {
                    return ChatScrollSnapshot(offsetY: 0, contentHeight: 0, containerHeight: 0)
                }
                return ChatScrollSnapshot(
                    offsetY: (geometry.contentOffset.y / 4).rounded() * 4,
                    contentHeight: (geometry.contentSize.height / 4).rounded() * 4,
                    containerHeight: geometry.containerSize.height
                )
            } action: { _, newValue in
                guard newValue.containerHeight > 0 else { return }
                followState.record(snapshot: newValue)
            }
            .onScrollPhaseChange { _, phase in
                followState.setScrolling(phase != .idle && phase != .animating)
            }
            .onChange(of: focusedSession.state.messages.count) { _, _ in
                let lastMessage = focusedSession.state.messages.last
                if lastMessage?.role == .user {
                    isUserScrolledUp = false
                    followState.resumeFollow()
                }

                guard focusedSession.state.messages.last != nil else {
                    return
                }

                messageCountScrollTask?.cancel()
                messageCountScrollTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(40))
                    guard !Task.isCancelled, followState.shouldAutoFollow(now: Date()) else {
                        return
                    }
                    proxy.scrollTo("bottom_anchor", anchor: .bottom)
                }
            }
            .onChange(of: focusedSession.state.messages.last?.text) { _, _ in
                handleStreamingTextChange(proxy: proxy)
            }
            .onChange(of: focusedSession.state.activityGroups.last?.activities.count) { _, _ in
                handleActivityCountChange(proxy: proxy)
            }
            .onChange(of: focusedSession.isBusy) { oldValue, newValue in
                handleBusyChange(oldValue: oldValue, newValue: newValue, proxy: proxy)
            }
            .onChange(of: focusedSession.id) { _, _ in
                handleActiveSessionChange(proxy: proxy)
            }
            .onChange(of: inspectorTabs.isEmpty) { _, _ in
                handleInspectorLayoutChange(proxy: proxy)
            }
            .onChange(of: isInspectorExpanded) { _, _ in
                handleInspectorLayoutChange(proxy: proxy)
            }
            .overlay(alignment: .leading) {
                promptNavigatorOverlay(proxy: proxy)
            }
            .overlay(alignment: .bottom) {
                if isUserScrolledUp {
                    scrollToBottomButton(
                        proxy: proxy,
                        preset: preset,
                        isDark: isDark
                    )
                    .animation(.easeInOut(duration: 0.2), value: isUserScrolledUp)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleStreamingTextChange(proxy: ScrollViewProxy) {
        guard focusedSession.isBusy, followState.shouldAutoFollow(now: Date()) else {
            return
        }
        proxy.scrollTo("bottom_anchor", anchor: .bottom)
    }

    private func handleActivityCountChange(proxy: ScrollViewProxy) {
        guard focusedSession.isBusy, followState.shouldAutoFollow(now: Date()) else {
            return
        }
        proxy.scrollTo("bottom_anchor", anchor: .bottom)
    }

    private func handleBusyChange(oldValue: Bool, newValue: Bool, proxy: ScrollViewProxy) {
        if oldValue && !newValue && !isUserScrolledUp && !followState.isUserScrolling {
            proxy.scrollTo("bottom_anchor", anchor: .bottom)
        }
    }

    private func handleActiveSessionChange(proxy: ScrollViewProxy) {
        isUserScrolledUp = false
        offsetTracker.clear()
        followState.reset()
        activePromptID = nil
        Task { @MainActor in
            proxy.scrollTo("bottom_anchor", anchor: .bottom)
        }
    }

    /// Oturum değişiminde sağ panel el değiştirir: çıkanın sekmeleri
    /// sözlüğe kaldırılır, gelenin kayıtlı sekmeleri geri yüklenir (yoksa boş
    /// panel). Bölme aynı kaldığı için `@State` kendiliğinden yapmazdı.
    private func switchInspectorState(from oldID: UUID, to newID: UUID) {
        let current = InspectorPaneState(
            tabs: inspectorTabs,
            selectedID: selectedInspectorTabID,
            expanded: isInspectorExpanded
        )
        let liveIDs = Set(sessionService.sessions.map(\.id))
        let result = InspectorPaneState.switched(
            inspectorStateBySession,
            from: oldID,
            to: newID,
            current: current,
            liveIDs: liveIDs
        )
        inspectorStateBySession = result.states
        inspectorTabs = result.restored.tabs
        selectedInspectorTabID = result.restored.selectedID
        isInspectorExpanded = result.restored.expanded
    }

    /// Inspector açılıp kapanınca (ya da genişleyince) genişlik animasyonu
    /// biterken transkripti dibe sabitler — ama yalnız dipte okuyan kullanıcı
    /// için. Tarihte okuyan kullanıcıya dokunulmaz.
    ///
    /// Neden gerekli: animasyon ortasında daralan satırlar yeniden sarılır,
    /// içerik boyu büyür, sabit kaydırma konumu görsel olarak yukarı kayar.
    /// O sırada ölçülen sahte düşüşler kullanıcı jesti sanılıp takip modu
    /// ölürdü (`suppressTransientDrop` onu engeller); yerleşim bitince dip
    /// yeniden tutturulur.
    ///
    /// Neden ölçülü: 350 ms'de ateşlenen kör `scrollTo`, spring (response
    /// 0.30) daha yerleşmeden geçici geometriye iner, görünümü ıssız bir
    /// bölgeye bırakırdı — programatik kayma kullanıcı konumu sayılmadığı
    /// için kurtarma düğmesi de belirmez, transkript kara kalırdı (Review
    /// sonrası kaybolan sohbet buydu). O yüzden ateş anında canlı durum
    /// yeniden sorulur ve zaten dipteyse kayma atlanır; kural
    /// `TranscriptRepinPolicy` içindedir, saf ve test edilebilir.
    private func handleInspectorLayoutChange(proxy: ScrollViewProxy) {
        followState.suppressTransientDrop()
        // Karar anındaki canlı durum: `@State` kopyası (`isUserScrolledUp`)
        // 90 ms gecikmeli yayınlanır; bayat "dipte" değeri tarihte okuyanı
        // dibe çekerdi.
        let wasFollowing = followState.isFollowing
        guard wasFollowing else {
            inspectorPinTask?.cancel()
            inspectorPinTask = nil
            return
        }
        inspectorPinTask?.cancel()
        inspectorPinTask = Task { @MainActor in
            // Spring yerleşimi bitsin diye ateş gecikir (response 0.30'un
            // yaklaşık iki katı); arada kullanıcı dokunursa görev iptal olur.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else {
                return
            }
            guard
                TranscriptRepinPolicy.shouldRepin(
                    wasFollowing: wasFollowing,
                    isFollowingNow: followState.isFollowing,
                    distanceFromBottom: followState.lastDistanceFromBottom
                ),
                followState.shouldAutoFollow(now: Date())
            else {
                return
            }
            proxy.scrollTo("bottom_anchor", anchor: .bottom)
        }
    }

    /// Sidebar, inspector ya da bölme ayırıcısı genişliği art arda değiştirir.
    /// Bu sırada prompt konum ölçerlerini kapatmak, aynı karede yinelenen
    /// geometri değerlerinin SwiftUI yerleşim döngüsüne dönüşmesini önler.
    private func handlePaneWidthChange() {
        isPaneResizing = true
        paneResizeSettleTask?.cancel()
        paneResizeSettleTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch is CancellationError {
                return
            } catch {
                assertionFailure("Bölme yeniden boyutlandırma beklemesi başarısız: \(error)")
                return
            }
            guard !Task.isCancelled else { return }
            isPaneResizing = false
        }
    }

    /// Collapse açılıp kapanınca transkript boyu yüzlerce pt değişir.
    /// `.defaultScrollAnchor(.bottom)` dibe göre koruduğu için viewport kayar
    /// ve düşüş kullanıcı jesti sanılıp takip modu ölürdü — kullanıcı kendini
    /// eski yazıların arasında bulur, dibe elle dönerdi. Burası düşüş yorumunu
    /// susturur (`suppressTransientDrop`), dipte okuyanı animasyon bitiminde
    /// dibe geri sabitler. Tarihte okuyana dokunulmaz: dokunduğu başlık zaten
    /// görünürdür, `scrollTo` yalnız görünmez kaldıysa en küçük hareketle
    /// geri getirir.
    ///
    /// Karar `followState.isFollowing` ile verilir: `@State` kopyası değil,
    /// ölçümün canlı durumudur. Art arda tıklamalarda yalnız son görev yaşar.
    private func handleTimelineCollapse(messageID: UUID, proxy: ScrollViewProxy) {
        let wasFollowing = followState.isFollowing
        followState.suppressTransientDrop(for: 0.9)
        collapsePinTask?.cancel()
        collapsePinTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            if wasFollowing {
                guard followState.shouldAutoFollow(now: Date()) else { return }
                proxy.scrollTo("bottom_anchor", anchor: .bottom)
            } else {
                guard !followState.isUserScrolling else { return }
                proxy.scrollTo(messageID)
            }
        }
    }

    @ViewBuilder
    private func promptNavigatorOverlay(proxy: ScrollViewProxy) -> some View {
        if promptItems.count > 1 {
            GeometryReader { geometry in
                PromptNavigatorRail(
                    items: promptItems,
                    activeID: activePromptID,
                    onSelect: { promptID in
                        withAnimation(.easeInOut(duration: 0.28)) {
                            proxy.scrollTo(promptID, anchor: .top)
                        }
                    }
                )
                .padding(
                    .leading,
                    railLeadingInset(paneWidth: geometry.size.width)
                )
            }
            .transition(.opacity)
        }
    }
}

/// Tells the prompt rail where a prompt row sits in the viewport.
///
/// The position is rounded into steps: the rail needs a reading position, not
/// pixel precision, and the rounding keeps a scroll gesture from publishing a
/// state change on every frame.
private struct PromptOffsetProbe: ViewModifier {
    let messageID: UUID
    let isUserMessage: Bool
    let isEnabled: Bool
    let space: String
    let onOffset: (UUID, CGFloat) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isUserMessage && isEnabled {
            content.onGeometryChange(
                for: CGFloat.self,
                of: { proxy in
                    (proxy.frame(in: .named(space)).minY / 8).rounded() * 8
                },
                action: { offset in
                    onOffset(messageID, offset)
                }
            )
        } else {
            content
        }
    }
}

/// Kaydırma sırasında her 8 pt'lik adımda tetiklenen probe, gövdeyi yeniden
/// çizmesin diye referans tipi: `@State` içinde tutulan bir sınıfın iç
/// mutasyonları SwiftUI'ı invalidate etmez; yalnızca değişen aktif prompt
/// kimliği yayınlanır.
private final class PromptOffsetTracker {
    private var offsets: [UUID: CGFloat] = [:]
    private var lastActiveID: UUID?

    func clear() {
        offsets.removeAll()
        lastActiveID = nil
    }

    /// Ölçülen konumların içinden okunan prompt'u seçer.
    ///
    /// Basitleştirilmiş "0..<300 penceresine giren" kuralı alta kaydırınca
    /// bayat kalıyordu: görünürde prompt yokken son kimlik aynen duruyordu.
    /// Doğru kural `PromptRailSelection` içindedir (eşik üstü en yakın,
    /// yoksa ölçülen en üst); burada yalnızca değişince yayınlanır.
    func update(
        messageID: UUID,
        offset: CGFloat,
        items: [PromptNavigatorRail.Item]
    ) -> UUID? {
        guard items.contains(where: { $0.id == messageID }) else {
            return nil
        }
        guard offsets[messageID] != offset else {
            return nil
        }
        offsets[messageID] = offset
        if offsets.count > items.count + 8 {
            let valid = Set(items.map(\.id))
            offsets = offsets.filter { valid.contains($0.key) }
        }
        let active = PromptRailSelection.activeID(
            among: items.map(\.id),
            offsets: offsets
        )
        guard active != lastActiveID else {
            return nil
        }
        lastActiveID = active
        return active
    }
}

/// The scrollable content metrics the follow-mode detection needs.
struct ChatScrollSnapshot: Equatable {
    let offsetY: CGFloat
    let contentHeight: CGFloat
    let containerHeight: CGFloat

    /// Alttan uzaklık. "Dipte mi" kararı `ScrollFollowState.bottomThreshold` ile
    /// orada verilir — sınır tek yerde dursun.
    var distanceFromBottom: CGFloat {
        contentHeight - offsetY - containerHeight
    }
}

private struct ChatMessageRow: View {
    let message: ChatMessage
    let preset: AppThemePreset
    let isDark: Bool
    let contrast: Double
    let isPlanAwaitingApproval: Bool
    /// False while a turn is running: re-sending the same text then would queue a
    /// duplicate of a message the user has not seen answered yet.
    let canResend: Bool
    /// True while this assistant message is still being written: the copy
    /// control and the timestamp appear only once the turn is over.
    let isActiveAssistant: Bool
    let isLastAssistantOfTurn: Bool
    let onApprovePlan: () -> Void
    let onRestore: () -> Void
    let onInspectFile: (URL) -> Void

    @Environment(SettingsStore.self) private var settingsStore: SettingsStore?
    @Environment(ExtensionStore.self) private var extensionStore: ExtensionStore?

    @State private var isCopied = false
    @State private var isCopiedOwnMessage = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == .user {
                Spacer(minLength: 60)

                VStack(alignment: .trailing, spacing: 4) {
                    userBubble

                    userMessageActions
                }
            } else {
                let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        MarkdownContentView(markdown: message.text)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)

                        if isPlanAwaitingApproval {
                            planApprovalBar
                        }

                        if !isActiveAssistant && isLastAssistantOfTurn {
                            HStack(spacing: 8) {
                                copyButton(
                                    text: message.text,
                                    isCopied: $isCopied,
                                    help: "Copy message to clipboard"
                                )

                                Text(formattedTimestamp(message.createdAt))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.leading, 4)
                            .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 40)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// What the user wrote, in the bubble it was sent in.
    private var userBubble: some View {
        let displayText = ChatMessagePresenter.cleanUserDisplayText(
            from: message.text,
            hasAttachments: !message.attachmentPaths.isEmpty
        )

        return VStack(alignment: .trailing, spacing: 8) {
            if !message.extensionTags.isEmpty {
                tagsView(for: message.extensionTags)
            }

            ForEach(message.attachmentPaths, id: \.self) { path in
                attachmentView(for: path)
            }

            if !displayText.isEmpty {
                let baseSize = settingsStore?.fontSize.pointSize ?? 14.0
                let design = settingsStore?.fontFamily.fontDesign ?? .default
                let spacing = settingsStore?.lineSpacing.spacing ?? 3.0
                Text(displayText)
                    .font(.system(size: baseSize, weight: .regular, design: design))
                    .lineSpacing(spacing)
                    // The light user-bubble gradients are pale, so white
                    // text vanished in light mode.
                    .foregroundStyle(preset.userBubbleForeground(isDark: isDark))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: isDark ? preset.userBubbleDark : preset.userBubbleLight,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(
                    (isDark ? preset.borderSubtleDark : preset.borderSubtleLight)
                        .opacity(contrast),
                    lineWidth: 1
                )
        )
    }

    /// What can be done with a message the user sent: read it again, or write it
    /// again. The send-again control only appears once the turn is over — it puts
    /// the text back in the composer rather than replaying it, so the user edits
    /// before it goes out.
    private var userMessageActions: some View {
        HStack(spacing: 8) {
            if canResend {
                Button(action: onRestore) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .medium))
                        Text("Write again")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .interactiveHoverPill(cornerRadius: 5)
                }
                .buttonStyle(.plain)
                .help("Put this message back in the composer so it can be sent again")
            }

            copyButton(
                text: message.text,
                isCopied: $isCopiedOwnMessage,
                help: "Copy your message to clipboard"
            )

            Text(formattedTimestamp(message.createdAt))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.trailing, 4)
    }

    /// One copy control for both roles: the click has no other visible effect, so
    /// the icon turning into a green check is the only proof it worked.
    private func copyButton(
        text: String,
        isCopied: Binding<Bool>,
        help: String
    ) -> some View {
        Button {
            Pasteboard.copy(text)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                isCopied.wrappedValue = true
            }
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                withAnimation {
                    isCopied.wrappedValue = false
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isCopied.wrappedValue ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isCopied.wrappedValue ? .green : .secondary)

                if isCopied.wrappedValue {
                    Text("Copied")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .interactiveHoverPill(cornerRadius: 5)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// The gate between proposing and building.
    ///
    /// Plan mode stops at the document, so the approval affordance sits directly
    /// under it — with the reminder that nothing has been changed yet.
    private var planApprovalBar: some View {
        HStack(spacing: 10) {
            Text("Plan mode · nothing is changed until you approve")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button {
                onApprovePlan()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))

                    Text("Approve & Build")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    LinearGradient(
                        colors: preset.accentGradient,
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Switch to Build mode and let the assistant implement this plan")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            preset.surface(isDark: isDark).opacity(isDark ? 0.55 : 0.75),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(preset.border(isDark: isDark), lineWidth: 1)
        )
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func tagsView(for tags: [ExtensionTag]) -> some View {
        HStack(spacing: 5) {
            ForEach(tags) { tag in
                let skillPath = tag.kind == .skill ? extensionStore?.registry.skills.first(where: { $0.name == tag.name })?.path : nil

                Button {
                    if let skillPath, !skillPath.isEmpty {
                        onInspectFile(URL(fileURLWithPath: skillPath))
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tag.kind.symbolName)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(preset.accentGradient.first ?? .primary)

                        Text(tag.name)
                            .font(.system(size: 11, weight: .medium))

                        if skillPath != nil {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .opacity(0.6)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        (isDark ? Color.white : Color.black).opacity(isDark ? 0.12 : 0.07),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().stroke(
                            (isDark ? Color.white : Color.black).opacity(0.16),
                            lineWidth: 0.8
                        )
                    )
                    .foregroundStyle(preset.userBubbleForeground(isDark: isDark))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(skillPath != nil ? "Inspect \(tag.name) documentation" : "\(tag.kind.displayName): \(tag.name)")
            }
        }
    }

    @ViewBuilder
    private func attachmentView(for rawPath: String) -> some View {
        let filePath = rawPath.hasPrefix("file://") ? (URL(string: rawPath)?.path ?? rawPath) : rawPath
        let url = URL(fileURLWithPath: filePath)
        let ext = url.pathExtension.lowercased()
        let isImage = ["png", "jpg", "jpeg", "webp", "tiff", "gif", "heic", "bmp"].contains(ext)
        let isPDF = ext == "pdf"

        if isImage, let image = AttachmentPreviewCache.shared.imageThumbnail(for: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 260, maxHeight: 190)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            (isDark ? preset.borderSubtleDark : preset.borderSubtleLight).opacity(0.4),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
                .onTapGesture {
                    onInspectFile(url)
                }
                .pointingHandCursor()
        } else if isPDF {
            pdfPreviewCard(for: url, path: rawPath)
        } else {
            genericFileCard(for: url)
        }
    }

    @ViewBuilder
    private func pdfPreviewCard(for url: URL, path: String) -> some View {
        let pageCount = AttachmentPreviewCache.shared.pdfPageCount(for: url) ?? 1
        let pdfThumbnail = AttachmentPreviewCache.shared.pdfThumbnail(for: url)

        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                if let pdfThumbnail {
                    Image(nsImage: pdfThumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 240, maxHeight: 150)
                        .background(Color.white)
                } else {
                    ZStack {
                        Color.primary.opacity(0.08)
                        Image(systemName: "doc.richtext.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.red.opacity(0.85))
                    }
                    .frame(width: 220, height: 110)
                }

                HStack(spacing: 4) {
                    Text("PDF")
                        .font(.system(size: 9.5, weight: .bold))
                    if pageCount > 1 {
                        Text("• \(pageCount)p")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Color.red.opacity(0.9),
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
                .padding(6)
            }

            HStack(spacing: 6) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.9))

                Text(url.lastPathComponent)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(preset.userBubbleForeground(isDark: isDark))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: 240, alignment: .leading)
            .background(
                isDark
                    ? preset.surfaceDark.opacity(0.85)
                    : preset.surfaceLight.opacity(0.85)
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    (isDark ? preset.borderSubtleDark : preset.borderSubtleLight).opacity(0.4),
                    lineWidth: 1
                )
        )
        .interactiveHoverOutline(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
        .onTapGesture {
            onInspectFile(url)
        }
        .pointingHandCursor()
    }

    @ViewBuilder
    private func genericFileCard(for url: URL) -> some View {
        Button {
            onInspectFile(url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(preset.userBubbleForeground(isDark: isDark).opacity(0.85))

                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(preset.userBubbleForeground(isDark: isDark))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(url.pathExtension.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(preset.userBubbleForeground(isDark: isDark).opacity(0.6))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Color.primary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func formattedTimestamp(_ date: Date) -> String {
        TranscriptTimestampFormatter.clock.string(from: date)
    }
}

/// Sohbet balonlarındaki saat biçimleyicisi.
///
/// Her görünür satır, her yeniden çizimde kendi `DateFormatter`'ını kuruyordu —
/// akış sırasında saniyede yüzlerce pahalı kurulum. Tek ve paylaşılan bir
/// biçimleyici bunu sabit maliyete indirir.
@MainActor
private enum TranscriptTimestampFormatter {
    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
