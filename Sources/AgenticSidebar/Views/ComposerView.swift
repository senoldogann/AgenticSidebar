import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    let sessionService: any AgentSessionServiceProtocol
    /// Answers this session's "Always allow" decisions and holds the prompts that
    /// are waiting, which the level control has to show and re-answer.
    let permissionApprovalCenter: PermissionApprovalCenter
    var onInspectFile: ((URL) -> Void)? = nil
    /// Ek yolu filtreleri için enjekte edilen dosya sistemi; üretimde `.default`.
    var fileManager: FileManager = .default

    @Environment(SettingsStore.self) private var settingsStore
    @Environment(ExtensionStore.self) private var extensionStore
    /// "Write this again" on an earlier message puts its text back in this field.
    @Environment(ComposerDraftCenter.self) private var draftCenter: ComposerDraftCenter?
    /// Unsent drafts kept across relaunches; the field stays the source of truth
    /// while the app runs, the store only carries it over a quit.
    @Environment(ComposerDraftStore.self) private var draftStore: ComposerDraftStore?
    @Environment(\.colorScheme) private var systemColorScheme

    /// Taslaklar oturuma göre saklanır.
    ///
    /// Tek bir taslak alanı sohbetler arasında sızıyordu: A'da yazılan metin B'ye
    /// geçildiğinde B'nin alanında duruyor ve B'ye gönderiliyordu. Ekler ve
    /// etiketler için de aynısı geçerliydi.
    @State private var draftsBySession: [UUID: ComposerDraft] = [:]
    @State private var isTargetedForDrop = false
    /// Escape ya da panelin kapatma düğmesiyle reddedilen token. Aynı token
    /// yazılmaya devam ettiği sürece öneri paneli geri açılmaz; taslaktan
    /// trigger tümüyle çıkınca silinir.
    @State private var dismissedSuggestionToken: String?

    /// Yazılmakta olan mesajın tamamı: metin, ekler ve etiketler.
    private struct ComposerDraft: Equatable {
        var text: String
        var attachedURLs: [URL]
        /// Extensions the user tagged for the next turn. They are chips rather
        /// than characters in the draft so the text the agent receives stays the
        /// text the user wrote.
        var selectedTags: [ExtensionTag]

        static let empty = ComposerDraft(text: "", attachedURLs: [], selectedTags: [])
    }

    private var draft: String {
        get { draftsBySession[sessionService.activeSessionID]?.text ?? "" }
        nonmutating set {
            draftsBySession[sessionService.activeSessionID, default: .empty].text = newValue
        }
    }

    private var attachedURLs: [URL] {
        get { draftsBySession[sessionService.activeSessionID]?.attachedURLs ?? [] }
        nonmutating set {
            draftsBySession[sessionService.activeSessionID, default: .empty].attachedURLs = newValue
        }
    }

    private var selectedTags: [ExtensionTag] {
        get { draftsBySession[sessionService.activeSessionID]?.selectedTags ?? [] }
        nonmutating set {
            draftsBySession[sessionService.activeSessionID, default: .empty].selectedTags = newValue
        }
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { draft },
            set: { draft = $0 }
        )
    }

    /// Silinen sohbetlerin taslakları tutulmaz.
    private func discardDraftsOfRemovedSessions() {
        let liveIDs = Set(sessionService.sessions.map(\.id))
        draftsBySession = draftsBySession.filter { liveIDs.contains($0.key) }
    }

    private var isDarkMode: Bool {
        settingsStore.isDark(systemColorScheme: systemColorScheme)
    }

    private var currentTheme: AppThemePreset {
        settingsStore.currentThemePreset
    }

    var body: some View {
        // The panels that belong to the composer *area* but not to the composer
        // box: the queued messages and the `/`/`@` suggestions. Both are siblings
        // above the input in the layout, so neither is an overlay on the box —
        // there is no shared edge, no shared background and nothing of the input
        // underneath them. They also have their own surface, border and shadow, so
        // each reads as a panel of its own rather than a part of the field.
        VStack(spacing: 8) {
            if !sessionService.queuedPrompts.isEmpty {
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
                todos: sessionService.todos,
                isTurnRunning: sessionService.isBusy
            ) {
                AgentTodoChecklistView(
                    todos: sessionService.todos,
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
        }
        .animation(.easeOut(duration: 0.14), value: visibleTrigger)
        .animation(.easeOut(duration: 0.14), value: sessionService.queuedPrompts.isEmpty)
        .animation(.easeOut(duration: 0.14), value: sessionService.todos.count)
        .frame(maxWidth: 820)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
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
        VStack(spacing: 8) {
            if !selectedTags.isEmpty {
                selectedTagsRow
            }

            if !attachedURLs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachedURLs, id: \.self) { url in
                            attachmentPreviewPill(for: url)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 2)
                }
            }

            ZStack(alignment: .topLeading) {
                ComposerTextEditor(
                    text: draftBinding,
                    submissionAvailability: submissionAvailability,
                    onSubmit: sendDraft,
                    onCancelSuggestions: dismissVisibleSuggestions,
                    onSpillLargePaste: spillLargePasteToAttachment
                )

                if draft.isEmpty {
                    Text(placeholderText)
                        .font(.system(size: 13.5))
                        .foregroundStyle(
                            isDarkMode
                                ? Color.white.opacity(0.35)
                                : Color.black.opacity(0.40)
                        )
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 26, maxHeight: 96)
            .padding(.horizontal, 2)

            HStack(alignment: .center, spacing: 6) {
                composerControlPill

                Spacer(minLength: 8)

                attachmentButton

                submitButton
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            currentTheme.composerBackground(isDark: isDarkMode)
                .opacity(settingsStore.glassOpacity),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isTargetedForDrop
                        ? (currentTheme.accentGradient.first ?? .accentColor)
                        : currentTheme.composerBorder(isDark: isDarkMode).opacity(settingsStore.contrast),
                    lineWidth: isTargetedForDrop ? 2 : 1
                )
        )
        .overlay {
            if isTargetedForDrop {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(currentTheme.composerBackground(isDark: isDarkMode).opacity(0.95))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
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

                            Text("Drop image or file here")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                    )
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            handleDrop(providers: providers)
        }
        .onChange(of: extensionStore.registry) { _, _ in
            // An extension the user switched off cannot be tagged any more.
            let available = Set(extensionStore.tagSuggestions.map(\.id))
            selectedTags.removeAll { !available.contains($0.id) }
        }
        .onChange(of: sessionService.activeSessionID) { _, _ in
            discardDraftsOfRemovedSessions()
            restoreStoredDraftIfEmpty()
            applyPendingRestore()
        }
        .onChange(of: sessionService.sessionList.map(\.id)) { _, ids in
            draftStore?.discardSessions(notIn: Set(ids))
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
        }
        .onChange(of: draftCenter?.pending) { _, _ in
            applyPendingRestore()
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
            let request = draftCenter.pending,
            request.sessionID == sessionService.activeSessionID
        else {
            return
        }

        _ = draftCenter.consumePending()
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
            sessionID: sessionService.activeSessionID,
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
            let stored = draftStore?.storedDraft(for: sessionService.activeSessionID)
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
            }
        }
        return handled
    }

    private var isSelectedModelThinking: Bool {
        guard let selectedModelID else { return false }
        return sessionService.availableModels.first(where: { $0.id == selectedModelID })?.supportsThinking == true
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
            if !sessionService.availableModels.isEmpty {
                modelMenuSection
            }

            // Reasoning effort and fast mode, in one control
            pillDivider
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
        let pendingCount = permissionApprovalCenter.pending.count

        return HStack(spacing: 2) {
            ComposerDropdown(
                isEnabled: true,
                helpText: "Tool approvals: \(policy.summary)",
                accessibilityText: "Tool approvals: \(policy.displayName)"
            ) {
                HStack(spacing: 4) {
                    Image(systemName: policy.symbolName)
                        .font(.system(size: 10.5, weight: .semibold))

                    Text(policy.compactName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    if pendingCount > 0 {
                        Text("\(pendingCount)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange, in: Capsule())
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(policy.isUnrestricted ? Color.orange : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
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
        // The prompts on screen were asked under the previous level; leaving them
        // to time out would refuse work the user just approved.
        permissionApprovalCenter.reinterpretPendingRequests()
    }

    /// Build or Plan for the *next* turn, so it stays switchable while a turn is
    /// running — the same reason the speed mode is not disabled either.
    private var agentModeMenuSection: some View {
        let mode = settingsStore.agentMode

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

                Text(mode.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .interactiveHoverPill(cornerRadius: 6)
        } content: {
            ForEach(AgentMode.allCases) { candidate in
                ComposerDropdownRow(
                    title: candidate.displayName,
                    isSelected: candidate == mode,
                    helpText: candidate.helpText
                ) {
                    settingsStore.agentMode = candidate
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
            prompts: sessionService.queuedPrompts,
            onEditInComposer: { id in
                editQueuedPromptInComposer(id)
            },
            onMove: { id, index in
                sessionService.moveQueuedPrompt(id, to: index)
            },
            onRemove: { id in
                sessionService.removeQueuedPrompt(id)
            },
            onClear: {
                sessionService.clearQueuedPrompts()
            }
        )
    }

    /// Kalem satırı yerinde açmıyor: kuyruk girdisini oradan çıkarıp metnini ve
    /// eklerini "Write again" ile aynı yoldan composer girdisine taşır, kullanıcı
    /// düzenlemeyi tam boy alanda yapar ve normal gönderir.
    private func editQueuedPromptInComposer(_ id: UUID) {
        guard let prompt = sessionService.queuedPrompts.first(where: { $0.id == id }) else {
            return
        }

        sessionService.removeQueuedPrompt(id)
        draftCenter?.requestRestore(
            text: prompt.text,
            attachmentPaths: prompt.attachmentPaths,
            sessionID: sessionService.activeSessionID
        )
    }

    private var placeholderText: String {
        if sessionService.state.activeQuestion != nil {
            return "Agent is waiting for your choice above — or write a reply here"
        }
        if sessionService.isBusy {
            return "Add a follow-up — it is queued and sent when this turn finishes"
        }
        switch settingsStore.agentMode {
        case .build:
            return "Message or request changes — @ for MCP and plugins, / for skills"
        case .plan:
            return "Ask to plan a feature, architectural change, or refactoring…"
        case .review:
            return "Ask to review changes, branch, or target project using Alibaba OCR…"
        case .exam:
            return "Ask an exam question, paste a problem, or take a screenshot to solve…"
        }
    }

    private var pillDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(isDarkMode ? 0.12 : 0.10))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 2)
    }

    private var modelMenuSection: some View {
        ComposerDropdown(
            isEnabled: !sessionService.isBusy,
            helpText: "Select the model for this conversation",
            accessibilityText: "Model"
        ) {
            HStack(spacing: 4) {
                // The provider's drawn mark belongs here, on a label SwiftUI
                // renders as a view, rather than inside the menu.
                ProviderLogoView(
                    logo: ProviderLogo.matching(selectedModelID?.rawValue ?? ""),
                    size: 11,
                    tint: isSelectedModelThinking
                        ? (currentTheme.accentGradient.first ?? .secondary)
                        : .secondary
                )

                Text(selectedModelName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if isSelectedModelThinking {
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

                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .interactiveHoverPill(cornerRadius: 6)
        } content: {
            ForEach(sessionService.availableModels, id: \.id) { model in
                ComposerDropdownRow(
                    title: model.displayName,
                    isSelected: model.id == selectedModelID,
                    helpText: nil
                ) {
                    try? sessionService.selectModel(model.id)
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
        let isFast = settingsStore.responseSpeedMode == .fast

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

                Text(effortLabel(isFast: isFast))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .interactiveHoverPill(cornerRadius: 6)
        } content: {
            ComposerDropdownSectionHeader(title: "Reasoning")

            ComposerDropdownRow(
                title: ReasoningEffortPresentation.rowTitle("Default", isDefault: true),
                isSelected: variantID == nil,
                helpText: "Whatever the model ships with"
            ) {
                try? sessionService.selectVariant(nil)
            } icon: {
                Image(systemName: "brain")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            ForEach(sessionService.availableVariants, id: \.id) { variant in
                ComposerDropdownRow(
                    title: variant.displayName,
                    isSelected: variant.id == variantID,
                    helpText: nil
                ) {
                    try? sessionService.selectVariant(variant.id)
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
                settingsStore.responseSpeedMode = .fast
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
                settingsStore.responseSpeedMode = .normal
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
                .frame(width: 28, height: 28)
                .interactiveHoverCircle()
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Attach files")
    }

    @ViewBuilder
    private var submitButton: some View {
        HStack(spacing: 6) {
            sendOrQueueButton

            if sessionService.isBusy {
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
                                    Color.primary.opacity(0.06)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                    )
                    .frame(width: 28, height: 28)

                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(
                        submissionAvailability == .available
                            ? Color.white
                            : Color.primary.opacity(0.35)
                    )

                if sessionService.isBusy {
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
            sessionService.isBusy ? "Queue message" : "Send message"
        )
    }

    private var cancelButton: some View {
        Button {
            Task {
                await sessionService.cancel()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.85))
                    .frame(width: 28, height: 28)

                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            .interactiveHoverOutlineCircle()
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Cancel the active turn")
    }

    private var selectedModelID: ProviderModelID? {
        sessionService.state.configuration?.modelID
    }

    private var selectedModelName: String {
        if let selectedModelID,
           let model = sessionService.availableModels.first(where: { $0.id == selectedModelID }) {
            return model.displayName
        }
        return sessionService.availableModels.first?.displayName ?? "Select model"
    }

    private var selectedVariantID: ProviderVariantID? {
        sessionService.state.configuration?.variantID
    }

    private var selectedVariantName: String {
        if let selectedVariantID,
           let variant = sessionService.availableVariants.first(where: { $0.id == selectedVariantID }) {
            return variant.displayName
        }
        return "Default"
    }

    private var selectedProviderID: ProviderID? {
        sessionService.state.configuration?.providerID
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

        guard sessionService.isBusy else {
            return "Send message"
        }

        let queued = sessionService.queuedPrompts.count
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
        return sessionService.canAcceptPrompt ? .available : .unavailable
    }

    private func sendDraft() {
        let promptText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePrompt: String
        if promptText.isEmpty {
            effectivePrompt = "Please inspect the attached file."
        } else {
            effectivePrompt = promptText
        }

        let attachmentPaths = attachedURLs.map { $0.path }
        let acceptance = sessionService.send(
            effectivePrompt,
            attachmentPaths: attachmentPaths,
            speedMode: settingsStore.responseSpeedMode,
            mode: settingsStore.agentMode,
            tags: selectedTags
        )

        if acceptance.wasAccepted {
            draft = ""
            attachedURLs = []
            selectedTags = []
            draftStore?.clear(sessionID: sessionService.activeSessionID)
        }
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
        String(draft[trigger.tokenRange])
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

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: trigger.kinds.first == .skill
                    ? "slash.circle"
                    : "at")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)

                Text(trigger.kinds.first == .skill
                    ? "Skills — the agent loads one only when it uses it"
                    : "MCP servers and plugins for this turn")
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

    private func attachmentPreviewPill(for url: URL) -> some View {
        let ext = url.pathExtension.lowercased()
        let isImage = ["png", "jpg", "jpeg", "webp", "tiff", "gif", "heic", "bmp"]
            .contains(ext)
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
                attachedURLs.removeAll { $0 == url }
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
