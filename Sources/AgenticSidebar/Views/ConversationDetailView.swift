import PDFKit
import SwiftUI

struct ConversationDetailView: View {
    let sessionService: any AgentSessionServiceProtocol
    let permissionApprovalCenter: PermissionApprovalCenter

    @Environment(SettingsStore.self) private var settingsStore
    /// What "write again" on an earlier message is for: the draft it edits lives
    /// in the composer, one view away.
    @Environment(ComposerDraftCenter.self) private var draftCenter: ComposerDraftCenter?
    @Environment(\.colorScheme) private var systemColorScheme

    /// Sağ panelde açık olan sekmeler ve seçili olan sekme kimliği.
    @State private var inspectorTabs: [InspectorTab] = []
    @State private var selectedInspectorTabID: String? = nil
    @State private var inspectorWidth: CGFloat = 620
    @State private var isInspectorExpanded: Bool = false
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
    /// Ölçümler burada toplanır ve döngü dışında yayınlanır (bkz. `body.task`).
    @State private var followState = ScrollFollowState()

    /// Derived lookups are memoized here rather than recomputed inside `body`:
    /// during streaming the body runs many times a second, and the rail titles
    /// and activity anchors do not change while an answer grows.
    @State private var indexCache = TranscriptIndexCache()

    private let contentMaxWidth: CGFloat = 820

    private static let transcriptSpace = "transcript"

    var body: some View {
        let preset = settingsStore.currentThemePreset
        let isDark = isDarkMode

        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if sessionService.state.messages.isEmpty {
                        emptyStateView(preset: preset)
                    } else {
                        transcriptScrollView(preset: preset, isDark: isDark)
                    }

                if let error = sessionService.state.error,
                   !sessionService.state.messages.isEmpty {
                    sessionBanner(
                        symbol: error.symbolName,
                        message: error.message,
                        tint: .orange
                    )
                }

                if let notice = sessionService.state.notice,
                   !sessionService.state.messages.isEmpty {
                    sessionBanner(
                        symbol: notice.symbolName,
                        message: notice.message,
                        tint: .secondary
                    )
                }

                if let question = sessionService.state.activeQuestion {
                    AgentQuestionCard(
                        question: question,
                        preset: preset,
                        isDark: isDark,
                        isSubmitting: sessionService.state.isQuestionSubmitting,
                        submissionFailed: sessionService.state.questionSubmissionFailed,
                        onAnswer: { answer in
                            sessionService.answerActiveQuestion(answer)
                        },
                        onDismiss: {
                            sessionService.dismissActiveQuestion()
                        }
                    )
                    .id(question.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let request = permissionApprovalCenter.pending.first(where: {
                    $0.appSessionID == sessionService.activeSessionID
                }) ?? permissionApprovalCenter.pending.first {
                    permissionApprovalBar(
                        request,
                        pendingCount: permissionApprovalCenter.pending.count,
                        preset: preset,
                        isDark: isDark
                    )
                }

                ComposerView(
                    sessionService: sessionService,
                    permissionApprovalCenter: permissionApprovalCenter,
                    onInspectFile: { url in
                        openFileInInspector(url: url)
                    }
                )
            }
            .frame(
                minWidth: isInspectorExpanded ? 0 : 360,
                maxWidth: isInspectorExpanded ? 0 : .infinity,
                maxHeight: .infinity
            )
            .opacity(isInspectorExpanded ? 0 : 1)

            if !inspectorTabs.isEmpty,
               let selectedID = selectedInspectorTabID,
               let activeTab = inspectorTabs.first(where: { $0.id == selectedID }) ?? inspectorTabs.last {
                if !isInspectorExpanded {
                    inspectorResizeSplitter
                }

                InspectorTabsContainerView(
                    tabs: inspectorTabs,
                    selectedTabID: activeTab.id,
                    preset: preset,
                    isDark: isDark,
                    isExpanded: isInspectorExpanded,
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
                            inspectorTabs = []
                            selectedInspectorTabID = nil
                            isInspectorExpanded = false
                        }
                    }
                )
                .frame(
                    minWidth: isInspectorExpanded ? 400 : 380,
                    idealWidth: isInspectorExpanded ? nil : inspectorWidth,
                    maxWidth: isInspectorExpanded ? .infinity : inspectorWidth
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }
        .background(isDark ? preset.backgroundDark : preset.backgroundLight)
        .navigationTitle(sessionService.activeSessionTitle)
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
    private func isPlanAwaitingApproval(for message: ChatMessage) -> Bool {
        guard
            message.role == .assistant,
            settingsStore.agentMode == .plan || settingsStore.agentMode == .review,
            !sessionService.isBusy,
            message.id == sessionService.state.messages.last?.id
        else {
            return false
        }

        return containsPlanDocument(message.text)
    }

    /// Approving is what leaves Plan mode: the mode flips first, then the
    /// assistant is told to build, so nothing is ever built before consent.
    private func approvePlan() {
        settingsStore.agentMode = .build

        let acceptance = sessionService.send(
            Self.planApprovalPrompt,
            attachmentPaths: [],
            speedMode: settingsStore.responseSpeedMode,
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
            sessionID: sessionService.activeSessionID
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
        isDark: Bool
    ) -> some View {
        let isVisibleUser = message.role == .user
        let isVisibleAssistant = message.role == .assistant && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasTurnHeader = message.role == .user && shouldShowTurnHeader(for: message)
        let activityGroup = activityGroup(after: message.id)

        VStack(alignment: .leading, spacing: 4) {
            if isVisibleUser || isVisibleAssistant {
                ChatMessageRow(
                    message: message,
                    preset: preset,
                    isDark: isDark,
                    contrast: settingsStore.contrast,
                    isPlanAwaitingApproval: isPlanAwaitingApproval(for: message),
                    canResend: !sessionService.isBusy,
                    isActiveAssistant: message.role == .assistant
                        && sessionService.isBusy
                        && message.id == sessionService.state.messages.last?.id,
                    isLastAssistantOfTurn: isLastAssistantMessageOfTurn(message),
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
                        isEnabled: promptItems.count > 1,
                        space: Self.transcriptSpace,
                        onOffset: { messageID, offset in
                            reportPromptOffset(offset, for: messageID)
                        }
                    )
                )
            }

            if hasTurnHeader {
                turnHeaderView(for: message, isDark: isDark)
            }

            if let activityGroup {
                let hasPending = permissionApprovalCenter.pending.contains {
                    $0.appSessionID == sessionService.activeSessionID
                } || !permissionApprovalCenter.pending.isEmpty
                AgentActivityTimelineView(
                    group: activityGroup,
                    isTurnActive: isTurnActive(for: activityGroup),
                    isSessionBusy: sessionService.isBusy,
                    hasPendingApproval: hasPending,
                    onOpenReport: { activity in
                        openSubagentReportInInspector(activity: activity)
                    },
                    onOpenReview: { summary, file in
                        openReviewInInspector(summary: summary, initialFile: file)
                    }
                )
            }
        }
        .id(message.id)
    }

    private func isLastAssistantMessageOfTurn(_ message: ChatMessage) -> Bool {
        guard message.role == .assistant else { return false }
        let allMessages = sessionService.state.messages
        guard let index = allMessages.firstIndex(where: { $0.id == message.id }) else {
            return false
        }
        for i in (index + 1)..<allMessages.count {
            let next = allMessages[i]
            if next.role == .user {
                return true
            }
            if next.role == .assistant {
                return false
            }
        }
        return true
    }

    private func shouldShowTurnHeader(for userMessage: ChatMessage) -> Bool {
        guard userMessage.role == .user else { return false }
        if sessionService.isBusy && userMessage.id == sessionService.state.messages.last(where: { $0.role == .user })?.id {
            return true
        }
        let allMessages = sessionService.state.messages
        guard let index = allMessages.firstIndex(where: { $0.id == userMessage.id }) else {
            return false
        }
        if index + 1 < allMessages.count && allMessages[index + 1].role == .assistant {
            return true
        }
        if activityGroup(after: userMessage.id) != nil {
            return true
        }
        return false
    }

    @ViewBuilder
    private func turnHeaderView(for userMessage: ChatMessage, isDark: Bool) -> some View {
        let isCurrentBusyTurn = sessionService.isBusy &&
            userMessage.id == sessionService.state.messages.last(where: { $0.role == .user })?.id

        VStack(alignment: .leading, spacing: 4) {
            if isCurrentBusyTurn {
                TimelineView(.periodic(from: .now, by: 1.0)) { context in
                    let start = sessionService.state.startedAt ?? Date()
                    let duration = formatTurnDuration(startedAt: start, endedAt: context.date)
                    Text("Working for \(duration)")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            } else {
                let start = sessionService.state.startedAt ?? userMessage.createdAt
                let end = sessionService.state.completedAt ?? Date()
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

    private func openFileInInspector(url: URL) {
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

    private func closeInspectorTab(_ tabID: String) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            guard let idx = inspectorTabs.firstIndex(where: { $0.id == tabID }) else {
                return
            }
            inspectorTabs.remove(at: idx)
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
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))

            Text(message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
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
        let conversation = request.appSessionID == sessionService.activeSessionID
            ? "Current conversation · \(owningTitle ?? sessionService.activeSessionTitle)"
            : request.appSessionID == nil
                ? "Backend session · \(request.remoteSessionID)"
                : "Background conversation · \(owningTitle ?? request.remoteSessionID)"
        // A delegated session asks on the agent's behalf, and its question is the
        // one a user is most likely to misread as the whole turn's. Saying who is
        // asking is what keeps "may I read outside this folder?" answerable.
        let origin = request.isDelegatedSession
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

    private func isGroupRunning(_ group: AgentTurnActivityGroup) -> Bool {
        group.activities.contains { $0.phase == .running }
    }

    private func isTurnActive(for group: AgentTurnActivityGroup) -> Bool {
        guard sessionService.isBusy else {
            return false
        }

        if let activeTurnID = sessionService.activeTurnID {
            if let groupTurnID = group.turnID {
                return groupTurnID == activeTurnID
            }
            if activeTurnID == group.id {
                return true
            }
        }

        let messages = sessionService.state.messages
        if let activeUserIndex = messages.lastIndex(where: { $0.role == .user }) {
            let activeTurnMessageIDs = Set(messages[activeUserIndex...].map(\.id))
            if activeTurnMessageIDs.contains(group.anchorMessageID) {
                return true
            }
        }

        return sessionService.state.activityGroups.last?.id == group.id
    }

    private func activityGroup(after messageID: UUID) -> AgentTurnActivityGroup? {
        transcriptIndex.activityGroup(after: messageID)
    }

    // MARK: - Prompt navigation

    /// One entry per prompt the user sent, oldest first: the rail maps the
    /// conversation's questions, not the answers.
    private var transcriptIndex: TranscriptIndex {
        indexCache.index(
            messages: sessionService.state.messages,
            activityGroups: sessionService.state.activityGroups,
            maximumPromptCount: PromptRailMetrics.maximumBarCount,
            activityRevision: sessionService.state.activityRevision
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(sessionService.state.messages) { message in
                        transcriptRow(
                            for: message,
                            preset: preset,
                            isDark: isDark
                        )
                    }

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
            .id(sessionService.activeSessionID)
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
            .onChange(of: sessionService.state.messages.count) { _, _ in
                let lastMessage = sessionService.state.messages.last
                if lastMessage?.role == .user {
                    isUserScrolledUp = false
                    followState.resumeFollow()
                }

                guard sessionService.state.messages.last != nil else {
                    return
                }

                messageCountScrollTask?.cancel()
                messageCountScrollTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(40))
                    guard !Task.isCancelled else {
                        return
                    }
                    proxy.scrollTo("bottom_anchor", anchor: .bottom)
                }
            }
            .onChange(of: sessionService.state.messages.last?.text) { _, _ in
                handleStreamingTextChange(proxy: proxy)
            }
            .onChange(of: sessionService.state.activityGroups.last?.activities.count) { _, _ in
                handleActivityCountChange(proxy: proxy)
            }
            .onChange(of: sessionService.isBusy) { oldValue, newValue in
                handleBusyChange(oldValue: oldValue, newValue: newValue, proxy: proxy)
            }
            .onChange(of: sessionService.activeSessionID) { _, _ in
                handleActiveSessionChange(proxy: proxy)
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
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isUserScrolledUp)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleStreamingTextChange(proxy: ScrollViewProxy) {
        guard sessionService.isBusy, followState.shouldAutoFollow(now: Date()) else {
            return
        }
        proxy.scrollTo("bottom_anchor", anchor: .bottom)
    }

    private func handleActivityCountChange(proxy: ScrollViewProxy) {
        guard sessionService.isBusy, followState.shouldAutoFollow(now: Date()) else {
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
                }
            ) { offset in
                onOffset(messageID, offset)
            }
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
    private var lastActiveID: UUID?

    func clear() {
        lastActiveID = nil
    }

    /// En üstte veya ona en yakın olan prompt'u seçer.
    func update(
        messageID: UUID,
        offset: CGFloat,
        items: [PromptNavigatorRail.Item]
    ) -> UUID? {
        guard let item = items.first(where: { $0.id == messageID }) else {
            return nil
        }

        // Görünür alanın üst kenarına en yakın olan prompt aktif sayılır.
        if offset >= 0 && offset < 300 {
            if lastActiveID != item.id {
                lastActiveID = item.id
                return item.id
            }
        }
        return nil
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
