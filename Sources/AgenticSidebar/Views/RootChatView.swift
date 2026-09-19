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
    let onApplyGlobalShortcut: @MainActor (GlobalShortcutSpec) -> Void

    /// Ayraç sürüklenirken oranın başlangıç değeri (aynı anda tek sürükleme).
    @State private var splitDragBase: Double?
    /// Sürüklenen sohbetin üzerinde durduğu yuva; halka yalnız orada çizilir.
    @State private var dropTargetedSlot: PaneSlot?

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
                paneCell(scopes[0], activeID: activeID, showHeader: false, showSwap: false, showFocusRing: false)
                    .frame(width: total, height: height)
            case .dual:
                let (first, second) = paneLength(total: total, fraction: splitStore.splitFraction)
                HStack(spacing: 0) {
                    paneCell(scopes[0], activeID: activeID, showHeader: true, showSwap: true, showFocusRing: true)
                        .frame(width: first, height: height)
                    if scopes.count > 1 {
                        gridDivider(.dualSplit, total: total)
                        paneCell(scopes[1], activeID: activeID, showHeader: true, showSwap: true, showFocusRing: true)
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
                            paneCell(scopes[0], activeID: activeID, showHeader: true, showSwap: false, showFocusRing: true)
                                .frame(width: left, height: top)
                            gridDivider(.gridColumn, total: total)
                            paneCell(scopes[1], activeID: activeID, showHeader: true, showSwap: false, showFocusRing: true)
                                .frame(width: right, height: top)
                        }
                        .frame(width: total, height: top)
                        gridDivider(.gridRow, total: height)
                        HStack(spacing: 0) {
                            paneCell(scopes[2], activeID: activeID, showHeader: true, showSwap: false, showFocusRing: true)
                                .frame(width: left, height: bottom)
                            gridDivider(.gridColumn, total: total)
                            paneCell(scopes[3], activeID: activeID, showHeader: true, showSwap: false, showFocusRing: true)
                                .frame(width: right, height: bottom)
                        }
                        .frame(width: total, height: bottom)
                    }
                    .frame(width: total, height: height)
                } else {
                    paneCell(scopes[0], activeID: activeID, showHeader: false, showSwap: false, showFocusRing: false)
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
    private func paneCell(_ scope: PaneScope, activeID: UUID, showHeader: Bool, showSwap: Bool, showFocusRing: Bool) -> some View {
        PaneWidthReader(
            content: VStack(spacing: 0) {
                if scope.isPrimary {
                    conversationPane(scope: scope, sessionID: activeID, activeID: activeID, showHeader: showHeader, showSwap: showSwap)
                } else if let pinned = scope.sessionID,
                    sessionService.session(for: pinned) != nil
                {
                    conversationPane(scope: scope, sessionID: pinned, activeID: activeID, showHeader: showHeader, showSwap: showSwap)
                } else {
                    emptyPane(scope: scope, activeID: activeID)
                }
            }
        )
        .id("pane-\(scope.slot.rawValue)")
        .onTapGesture {
            splitStore.focus(scope.slot)
        }
        .overlay {
            if dropTargetedSlot == scope.slot {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.7), lineWidth: 2)
                    .padding(8)
            } else if showFocusRing, splitStore.focusedSlot == scope.slot {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.35), lineWidth: 1.5)
                    .padding(4)
            }
        }
        .onDrop(of: SplitDropSupport.dropTypes, isTargeted: dropBinding(for: scope.slot)) { providers in
            handleDrop(providers, to: scope.slot, activeID: activeID)
        }
    }

    /// Yan yana iken pencere araç çubuğu başlığı kullanılmaz: bölmeler kendi
    /// başlığını gösterir, yoksa birincil bölmenin terminal simgesi pencerenin
    /// en sağına düşer ve sağdaki sohbete ait sanılır.
    private func conversationPane(scope: PaneScope, sessionID: UUID, activeID: UUID, showHeader: Bool, showSwap: Bool) -> some View {
        VStack(spacing: 0) {
            if showHeader {
                SplitPaneHeader(
                    title: sessionService.session(for: sessionID)?.title ?? "Session",
                    isBusy: sessionService.session(for: sessionID)?.isBusy ?? false,
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
                    }
                )
            }
            ConversationDetailView(
                sessionService: sessionService,
                permissionApprovalCenter: permissionApprovalCenter,
                collapseStore: collapseStore,
                focusedSessionID: scope.isPrimary ? nil : sessionID,
                paneID: scope.paneID,
                showsNavigationTitle: !showHeader
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
                    Button(session.displayTitle) {
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
