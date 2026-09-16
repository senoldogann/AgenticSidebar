import PDFKit
import SwiftUI

struct ConversationDetailView: View {
    let sessionService: AgentSessionService
    let permissionApprovalCenter: PermissionApprovalCenter

    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.colorScheme) private var systemColorScheme

    @State private var previewImagePath: String? = nil
    @State private var isUserScrolledUp = false
    @State private var isUserScrolling = false

    /// Where each prompt sits in the transcript, relative to the top of the
    /// viewport. The rail uses it to mark the prompt being read; only prompts
    /// report their position.
    @State private var promptOffsets: [UUID: CGFloat] = [:]

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
            VStack(spacing: 0) {
                if sessionService.state.messages.isEmpty {
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
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 14) {
                                ForEach(sessionService.state.messages) { message in
                                    transcriptRow(
                                        for: message,
                                        preset: preset,
                                        isDark: isDark
                                    )
                                }

                                Color.clear
                                    .frame(height: 1)
                                    .id("bottom_anchor")
                            }
                            .padding(.leading, transcriptLeadingInset)
                            .padding(.trailing, 20)
                            .padding(.vertical, 16)
                            .frame(maxWidth: contentMaxWidth)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .animation(
                                .easeOut(duration: 0.18),
                                value: sessionService.state.messages.count
                            )
                        }
                        .coordinateSpace(.named(Self.transcriptSpace))
                        .onScrollGeometryChange(for: ChatScrollSnapshot.self) { geometry in
                            ChatScrollSnapshot(
                                offsetY: geometry.contentOffset.y,
                                contentHeight: geometry.contentSize.height,
                                containerHeight: geometry.containerSize.height
                            )
                        } action: { oldValue, newValue in
                            updateScrollState(from: oldValue, to: newValue)
                        }
                        .onScrollPhaseChange { _, phase in
                            isUserScrolling = phase != .idle && phase != .animating
                        }
                        .onChange(of: sessionService.state.messages.count) { _, _ in
                            let lastMessageIsUser = sessionService.state.messages.last?.role == .user

                            if lastMessageIsUser {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    isUserScrolledUp = false
                                    proxy.scrollTo("bottom_anchor", anchor: .bottom)
                                }
                            } else if !isUserScrolledUp {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("bottom_anchor", anchor: .bottom)
                                }
                            }
                        }
                        .onChange(of: sessionService.state.messages.last?.text) { _, _ in
                            if !isUserScrolledUp && sessionService.isBusy {
                                proxy.scrollTo("bottom_anchor", anchor: .bottom)
                            }
                        }
                        .onChange(of: sessionService.activeSessionID) { _, _ in
                            isUserScrolledUp = false
                            promptOffsets.removeAll()
                            Task { @MainActor in
                                proxy.scrollTo("bottom_anchor", anchor: .bottom)
                            }
                        }
                        .overlay(alignment: .leading) {
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
                        .overlay(alignment: .bottom) {
                            if isUserScrolledUp {
                                scrollToBottomButton(
                                    proxy: proxy,
                                    preset: preset,
                                    isDark: isDark
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

                if let request = permissionApprovalCenter.pending.first {
                    permissionApprovalBar(
                        request,
                        pendingCount: permissionApprovalCenter.pending.count,
                        preset: preset,
                        isDark: isDark
                    )
                }

                ComposerView(sessionService: sessionService)
            }

            if let path = previewImagePath {
                ImagePreviewModal(
                    path: path,
                    preset: preset,
                    isDark: isDark,
                    onDismiss: { previewImagePath = nil }
                )
            }
        }
        .background(isDark ? preset.backgroundDark : preset.backgroundLight)
        .navigationTitle(sessionService.activeSessionTitle)
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
            settingsStore.agentMode == .plan,
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
            speedMode: settingsStore.responseSpeedMode,
            mode: .build
        )

        guard acceptance.wasAccepted else {
            AppLog.agentSession.error(
                "An approved plan could not be handed back to the assistant"
            )
            return
        }
    }

    /// One transcript entry: the message, then the timeline of the turn it
    /// started.
    @ViewBuilder
    private func transcriptRow(
        for message: ChatMessage,
        preset: AppThemePreset,
        isDark: Bool
    ) -> some View {
        ChatMessageRow(
            message: message,
            preset: preset,
            isDark: isDark,
            contrast: settingsStore.contrast,
            isPlanAwaitingApproval: isPlanAwaitingApproval(for: message),
            onApprovePlan: approvePlan,
            onImageTap: { path in
                previewImagePath = path
            }
        )
        .modifier(
            PromptOffsetProbe(
                messageID: message.id,
                isUserMessage: message.role == .user,
                space: Self.transcriptSpace,
                onOffset: { messageID, offset in
                    reportPromptOffset(offset, for: messageID)
                }
            )
        )
        .id(message.id)
        .transition(.opacity.combined(with: .move(edge: .bottom)))

        if let activityGroup = activityGroup(after: message.id) {
            AgentActivityTimelineView(
                group: activityGroup,
                isTurnActive: isTurnActive(for: activityGroup)
            )
            .transition(.opacity)
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
                            Text("\(policy.displayName) — \(policy.summary)")
                        }
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
            return activeTurnID == group.id
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
            maximumPromptCount: PromptRailMetrics.maximumBarCount
        )
    }

    private var promptItems: [PromptNavigatorRail.Item] {
        transcriptIndex.promptItems
    }

    private func railTitle(for prompt: String) -> String {
        TranscriptIndex.railTitle(for: prompt)
    }

    private var activePromptID: UUID? {
        PromptRailSelection.activeID(
            among: promptItems.map(\.id),
            offsets: promptOffsets
        )
    }

    /// Rows report a rounded position, so this is called on meaningful movement
    /// rather than on every scrolled pixel.
    private func reportPromptOffset(_ offset: CGFloat, for messageID: UUID) {
        guard promptOffsets[messageID] != offset else {
            return
        }

        promptOffsets[messageID] = offset
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

    /// Follow mode tracks whether the transcript should keep auto-scrolling.
    ///
    /// Only changes the user caused (a scroll gesture, or content moving back
    /// toward the bottom while paused) flip the state: content growing under the
    /// auto-scroll must never be mistaken for the user scrolling away, or the
    /// transcript would stop following the stream after the first token.
    private func updateScrollState(
        from oldValue: ChatScrollSnapshot,
        to newValue: ChatScrollSnapshot
    ) {
        let movedTowardTop = newValue.offsetY < oldValue.offsetY - 0.5
        let movedTowardBottom = newValue.offsetY > oldValue.offsetY + 0.5
        let isScrollingBack = isUserScrolledUp && movedTowardBottom

        guard isUserScrolling || movedTowardTop || isScrollingBack else {
            return
        }

        let isAwayFromBottom = newValue.isAwayFromBottom
        guard isAwayFromBottom != isUserScrolledUp else {
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            isUserScrolledUp = isAwayFromBottom
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
                proxy.scrollTo("bottom_anchor", anchor: .bottom)
            }
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(preset.accentGradient.first ?? .accentColor)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(
                            (isDark ? preset.surfaceDark : preset.surfaceLight)
                                .opacity(isDark ? 0.94 : 0.97)
                        )
                )
                .overlay(
                    Circle()
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
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Scroll to the latest message")
        .accessibilityLabel("Scroll to bottom")
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
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
    let space: String
    let onOffset: (UUID, CGFloat) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isUserMessage {
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

/// The scrollable content metrics the follow-mode detection needs.
private struct ChatScrollSnapshot: Equatable {
    let offsetY: CGFloat
    let contentHeight: CGFloat
    let containerHeight: CGFloat

    var isAwayFromBottom: Bool {
        contentHeight - offsetY - containerHeight > 120
    }
}

private struct ChatMessageRow: View {
    let message: ChatMessage
    let preset: AppThemePreset
    let isDark: Bool
    let contrast: Double
    let isPlanAwaitingApproval: Bool
    let onApprovePlan: () -> Void
    let onImageTap: (String) -> Void

    @Environment(SettingsStore.self) private var settingsStore: SettingsStore?

    @State private var isCopied = false
    @State private var isHoveringCopy = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == .user {
                Spacer(minLength: 60)

                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(message.attachmentPaths, id: \.self) { path in
                        attachmentView(for: path)
                    }

                    let displayText = ChatMessagePresenter.cleanUserDisplayText(
                        from: message.text,
                        hasAttachments: !message.attachmentPaths.isEmpty
                    )
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
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    MarkdownContentView(markdown: message.text)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)

                    if isPlanAwaitingApproval {
                        planApprovalBar
                    }

                    HStack(spacing: 8) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                isCopied = true
                            }
                            Task {
                                try? await Task.sleep(nanoseconds: 1_800_000_000)
                                withAnimation {
                                    isCopied = false
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(isCopied ? .green : (isHoveringCopy ? .primary : .secondary.opacity(0.7)))

                                if isCopied {
                                    Text("Copied")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.green)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                isHoveringCopy
                                    ? (isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08))
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                            )
                            .animation(.easeInOut(duration: 0.15), value: isHoveringCopy)
                            .onHover { hovering in
                                isHoveringCopy = hovering
                            }
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .help("Copy message to clipboard")

                        Text(formattedTimestamp(message.createdAt))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.leading, 4)
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity)
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
    private func attachmentView(for rawPath: String) -> some View {
        let filePath = rawPath.hasPrefix("file://") ? (URL(string: rawPath)?.path ?? rawPath) : rawPath
        let url = URL(fileURLWithPath: filePath)
        let ext = url.pathExtension.lowercased()
        let isImage = ["png", "jpg", "jpeg", "webp", "tiff", "gif", "heic", "bmp"].contains(ext)
        let isPDF = ext == "pdf"

        if isImage, let image = NSImage(contentsOfFile: filePath) {
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
                    onImageTap(rawPath)
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
        let doc = PDFDocument(url: url)
        let pageCount = doc?.pageCount ?? 1
        let pdfThumbnail = doc?.page(at: 0)?.thumbnail(of: CGSize(width: 240, height: 160), for: .mediaBox)

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
        .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
        .onTapGesture {
            onImageTap(path)
        }
        .pointingHandCursor()
    }

    @ViewBuilder
    private func genericFileCard(for url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
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
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

private struct ImagePreviewModal: View {
    let path: String
    let preset: AppThemePreset
    let isDark: Bool
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }

            VStack(spacing: 12) {
                HStack {
                    Text(URL(fileURLWithPath: resolvedPath).lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.90))
                        .lineLimit(1)

                    Spacer()

                    Button {
                        let fileURL = path.hasPrefix("file://") ? (URL(string: path) ?? URL(fileURLWithPath: path)) : URL(fileURLWithPath: path)
                        NSWorkspace.shared.open(fileURL)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Open with external application")

                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)

                if let image = previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(
                                    (isDark ? preset.borderSubtleDark : preset.borderSubtleLight).opacity(0.4),
                                    lineWidth: 1
                                )
                        )
                        .shadow(color: .black.opacity(0.6), radius: 28, x: 0, y: 12)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
            }
            .background(
                (isDark ? preset.surfaceDark : preset.surfaceLight).opacity(0.96),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        (isDark ? preset.borderSubtleDark : preset.borderSubtleLight).opacity(0.5),
                        lineWidth: 1
                    )
            )
            .frame(maxWidth: 860, maxHeight: 680)
            .padding(32)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .animation(.easeInOut(duration: 0.2), value: path)
    }

    private var resolvedPath: String {
        path.hasPrefix("file://") ? (URL(string: path)?.path ?? path) : path
    }

    private var previewImage: NSImage? {
        let filePath = resolvedPath
        if let image = NSImage(contentsOfFile: filePath) {
            return image
        }
        if let doc = PDFDocument(url: URL(fileURLWithPath: filePath)),
           let page = doc.page(at: 0) {
            return page.thumbnail(of: CGSize(width: 900, height: 700), for: .mediaBox)
        }
        return nil
    }
}
