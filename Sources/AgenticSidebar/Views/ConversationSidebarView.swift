import SwiftUI

struct ConversationSidebarView: View {
    let sessionService: any AgentSessionServiceProtocol
    /// Yan yana görünüm: satır buradan sürüklenir ya da menüden sabitlenir.
    let splitStore: SplitLayoutStore

    @Environment(SettingsStore.self) private var settingsStore
    @Environment(SettingsWindowController.self) private var settingsWindowController: SettingsWindowController?
    @Environment(\.colorScheme) private var systemColorScheme

    /// Onay bekleyen tekli silme. Silinen bir sohbet geri getirilemez.
    @State private var sessionPendingDeletion: SessionSummary?
    /// Onay bekleyen toplu silme.
    @State private var sessionsPendingDeletion: Set<UUID>?
    /// Arama metni; başlık içinde case-insensitive eşleşir.
    @State private var searchText = ""
    /// Liste sıralaması.
    @State private var sortOption: SessionSortOption = .lastUsedNewest
    /// Tarih filtresi.
    @State private var dateFilter: SessionDateFilter = .all
    /// Toplu seçim kipi açık mı.
    @State private var isEditingSelection = false
    /// Toplu seçimde işaretli oturumlar.
    @State private var selection = Set<UUID>()
    /// Yeniden adlandırılan oturum + taslak başlık.
    @State private var sessionToRename: SessionSummary?
    @State private var renameDraft = ""

    private var isDarkMode: Bool {
        settingsStore.isDark(systemColorScheme: systemColorScheme)
    }

    private var currentTheme: AppThemePreset {
        settingsStore.currentThemePreset
    }

    private struct CategorizedSessions {
        let all: [SessionSummary]
        let pinned: [SessionSummary]
        let regular: [SessionSummary]
    }

    /// Single pass filtering and partitioning into pinned and regular sessions.
    private var categorizedSessions: CategorizedSessions {
        let all = filterSortSessions(
            sessionService.sessionList,
            query: searchText,
            sort: sortOption,
            dateFilter: dateFilter,
            now: Date(),
            calendar: .current
        )
        var pinned: [SessionSummary] = []
        var regular: [SessionSummary] = []
        pinned.reserveCapacity(all.count)
        regular.reserveCapacity(all.count)
        for session in all {
            if session.isPinned {
                pinned.append(session)
            } else {
                regular.append(session)
            }
        }
        return CategorizedSessions(all: all, pinned: pinned, regular: regular)
    }

    var body: some View {
        // Tek geçiş: `categorizedSessions` her okunuşta süzer+sıralar, o
        // yüzden gövde bir kez okuyup sayaç ve araç çubuklarını aynı sonuçla
        // besler (önceden gövde başına üç geçiş yapılıyordu).
        let sessions = categorizedSessions
        let pinned = sessions.pinned
        let regular = sessions.regular

        List {
            Section("Sessions") {
                newSessionRow

                searchAndFilterControls(
                    shownCount: sessions.all.count,
                    totalCount: sessionService.sessionList.count
                )

                if isEditingSelection {
                    selectionToolbar(filtered: sessions.all)
                }

                if !pinned.isEmpty {
                    Section("Pinned · \(pinned.count)") {
                        ForEach(pinned) { session in
                            sessionRow(session)
                        }
                    }
                }

                if regular.isEmpty && pinned.isEmpty {
                    emptyStateRow
                } else {
                    ForEach(regular) { session in
                        sessionRow(session)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // Liste odağı mavi çerçeve çizer (tıklama ve sağ tıkta): satırlar
        // kendi seçili zeminini zaten çizer, sistem odak efekti kapalı.
        .focusEffectDisabled()
        .navigationTitle(AppIdentity.name)
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 290)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(isEditingSelection ? "Done" : "Edit") {
                    isEditingSelection.toggle()
                    if !isEditingSelection {
                        selection.removeAll()
                    }
                }
                .help(isEditingSelection ? "Finish selecting sessions" : "Select multiple sessions")
                .accessibilityLabel(isEditingSelection ? "Done selecting" : "Select sessions")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if isEditingSelection, !selection.isEmpty {
                    bulkDeleteBar
                    Divider()
                        .opacity(0.4)
                }

                Divider()
                    .opacity(0.4)

                Button {
                    settingsWindowController?.show()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)

                        Text("Settings")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)

                        Spacer()

                        Text("⌘,")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                            )
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .interactiveHoverPill(cornerRadius: 8)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Open application settings (⌘,)")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .background(currentTheme.background(isDark: isDarkMode))
        }
        .background(currentTheme.background(isDark: isDarkMode))
        .confirmationDialog(
            deletionPromptTitle,
            isPresented: isDeletionPromptPresented,
            titleVisibility: .visible,
            presenting: sessionPendingDeletion
        ) { session in
            Button("Delete", role: .destructive) {
                sessionService.deleteSession(session.id)
                sessionPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                sessionPendingDeletion = nil
            }
        } message: { _ in
            Text("This conversation and its messages cannot be restored.")
        }
        .confirmationDialog(
            bulkDeletionTitle,
            isPresented: isBulkDeletionPresented,
            titleVisibility: .visible,
            presenting: sessionsPendingDeletion
        ) { ids in
            Button("Delete \(ids.count) sessions", role: .destructive) {
                sessionService.deleteSessions(ids)
                selection.removeAll()
                isEditingSelection = false
                sessionsPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                sessionsPendingDeletion = nil
            }
        } message: { _ in
            Text("These conversations and their messages cannot be restored. Running sessions will be stopped.")
        }
        .alert("Rename session", isPresented: isRenamePresented) {
            TextField("Session name", text: $renameDraft)
            Button("Save") {
                guard let sessionToRename else {
                    return
                }
                sessionService.renameSession(sessionToRename.id, to: renameDraft)
                self.sessionToRename = nil
            }
            Button("Cancel", role: .cancel) {
                sessionToRename = nil
            }
        } message: {
            Text("Leave empty to return to the automatic title.")
        }
    }

    // MARK: - Yeni oturum ve aktif klasör etiketi

    /// Yeni oturum satırı: ana düğme klasörsüz taslak açar (mevcut davranış),
    /// klasör düğmesi opsiyonel klasör seçtirip taslağı o klasöre bağlar.
    /// Klasör seçimi zorunlu değildir; seçimsiz kullanım aynen çalışır.
    @ViewBuilder
    private var newSessionRow: some View {
        HStack(spacing: 8) {
            Button {
                // Sohbet hemen doğmaz: bekleyen taslak açılır, ilk
                // gönderimde gerçek oturum olur. Taslak varsa aynı
                // anahtar döner, yazılan korunur.
                sessionService.beginPendingSession()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("New session")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 0)

                    Text("⌘N")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(
                    isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .interactiveHoverPill(cornerRadius: 8)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Start a new session (⌘N)")
            .accessibilityLabel("New session")

            Button {
                if pendingDraftHasDirectory {
                    // Taslak klasörlüyken aynı düğme klasörü söker: ayrı satır
                    // kalktığı için sökme işlevi burada yaşar, taslak metni korunur.
                    sessionService.clearPendingSessionDirectory()
                } else {
                    presentSessionFolderPicker()
                }
            } label: {
                Image(systemName: pendingDraftHasDirectory ? "folder.badge.minus" : "folder.badge.plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(
                        isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .interactiveHoverPill(cornerRadius: 8)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(
                pendingDraftHasDirectory
                    ? "Remove the folder from this unsent draft (the draft text stays)"
                    : "Start a new session in a chosen folder (optional)"
            )
            .accessibilityLabel(pendingDraftHasDirectory ? "Remove folder from draft" : "New session in folder")
        }
    }

    /// Bekleyen taslak bir klasöre bağlı mı (düğme o zaman sökme kipindedir).
    private var pendingDraftHasDirectory: Bool {
        guard sessionService.isPendingSessionVisible,
            let pending = sessionService.pendingSessionID,
            let draft = sessionService.session(for: pending)
        else {
            return false
        }
        guard let path = draft.workingDirectoryPath else {
            return false
        }
        return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Klasör seçici yalnızca dizin kabul eder; seçim bekleyen taslağı o
    /// klasöre bağlar, yazılan metin korunur. Vazgeçilirse hiçbir şey olmaz.
    private func presentSessionFolderPicker() {
        guard
            let url = DirectoryPicker.chooseDirectory(
                prompt: "Seç",
                message: "Oturumun çalışacağı klasörü seçin (opsiyonel)"
            )
        else {
            return
        }
        sessionService.beginPendingSession(workingDirectoryPath: url.path)
    }

    // MARK: - Arama, sıralama ve filtre

    /// Arama alanı + üç nokta menüsünde sıralama ve tarih filtreleri.
    ///
    /// İki ayrı hap buton satırı kaplıyordu; şimdi tek satırda sonuç sayısı ve
    /// filtre göstergeli bir menü var, aktif filtreler altında silinebilir çip
    /// olarak durur.
    @ViewBuilder
    private func searchAndFilterControls(shownCount: Int, totalCount: Int) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary.opacity(0.8))
                TextField("Search sessions...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Search sessions")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6.5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isDarkMode ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 0.5)
            )

            HStack(spacing: 6) {
                Text(sessionCountText(shownCount: shownCount, totalCount: totalCount))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("\(shownCount) of \(totalCount) sessions shown")

                Spacer(minLength: 0)

                if hasActiveFilters || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Reset") {
                        resetSidebarFilters()
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(currentTheme.accentGradient.first ?? .primary)
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Clear search, sort and date filters")
                    .accessibilityLabel("Reset search and filters")
                }

                Menu {
                    Section("Sort by") {
                        Picker("Sort", selection: $sortOption) {
                            ForEach(SessionSortOption.allCases, id: \.self) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                    }

                    Section("Date") {
                        Picker("Date", selection: $dateFilter) {
                            ForEach(SessionDateFilter.allCases, id: \.self) { filter in
                                Text(filter.displayName).tag(filter)
                            }
                        }
                    }

                    Divider()

                    Button("Reset filters", role: .destructive) {
                        resetSidebarFilters()
                    }
                    .disabled(!hasActiveFilters && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(
                                hasActiveFilters
                                    ? (currentTheme.accentGradient.first ?? .accentColor)
                                    : (isDarkMode ? Color.white.opacity(0.85) : Color.primary.opacity(0.70))
                            )
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(hasActiveFilters ? activeRowBackground : currentTheme.surface(isDark: isDarkMode))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(hasActiveFilters ? activeRowBorder : currentTheme.border(isDark: isDarkMode), lineWidth: 1)
                            )

                        if hasActiveFilters {
                            Circle()
                                .fill(currentTheme.accentGradient.first ?? .accentColor)
                                .frame(width: 7, height: 7)
                                .offset(x: 1, y: -1)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .colorScheme(isDarkMode ? .dark : .light)
                .pointingHandCursor()
                .help("Sort and filter sessions")
                .accessibilityLabel("Session options, sort \(sortOption.displayName), date \(dateFilter.displayName)")
            }
            .padding(.horizontal, 2)

            if hasActiveFilters {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if sortOption != .lastUsedNewest {
                            sidebarFilterChip(
                                icon: "arrow.up.arrow.down",
                                text: sortOption.displayName,
                                help: "Sort: \(sortOption.displayName). Click × for default order.",
                                onClear: { sortOption = .lastUsedNewest }
                            )
                        }

                        if dateFilter != .all {
                            sidebarFilterChip(
                                icon: "calendar",
                                text: dateFilter.displayName,
                                help: "Date filter: \(dateFilter.displayName). Click × to show all dates.",
                                onClear: { dateFilter = .all }
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Sıralama ya da tarih varsayılanın dışında mı.
    private var hasActiveFilters: Bool {
        sortOption != .lastUsedNewest || dateFilter != .all
    }

    /// Liste başlığı altındaki küçük sayaç metni.
    private func sessionCountText(shownCount: Int, totalCount: Int) -> String {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty || hasActiveFilters {
            return "\(shownCount) of \(totalCount)"
        }
        return totalCount == 1 ? "1 session" : "\(totalCount) sessions"
    }

    /// Arama, sıralama ve tarih filtresini birlikte temizler.
    private func resetSidebarFilters() {
        searchText = ""
        sortOption = .lastUsedNewest
        dateFilter = .all
    }

    /// Aktif filtrenin altında duran, çarpıyla tek tek kapatılan çip.
    @ViewBuilder
    private func sidebarFilterChip(
        icon: String,
        text: String,
        help: String,
        onClear: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))

            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            Button {
                onClear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Clear this filter")
            .accessibilityLabel("Clear \(text) filter")
        }
        .foregroundStyle(currentTheme.accentGradient.first ?? .primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(activeRowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(activeRowBorder, lineWidth: 1)
        )
        .help(help)
    }

    /// Toplu seçim kipinde tümünü seç / bırak kısayolu.
    @ViewBuilder
    private func selectionToolbar(filtered: [SessionSummary]) -> some View {
        HStack {
            Button(selection.count == filtered.count ? "Deselect all" : "Select all") {
                if selection.count == filtered.count {
                    selection.removeAll()
                } else {
                    selection = Set(filtered.map(\.id))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .pointingHandCursor()
            Spacer(minLength: 0)
            if !selection.isEmpty {
                Text("\(selection.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(selection.count) sessions selected")
            }
        }
        .padding(.horizontal, 4)
    }

    /// Seçim varken altta beliren toplu silme çubuğu; tema vurgusunu kullanır.
    @ViewBuilder
    private var bulkDeleteBar: some View {
        HStack(spacing: 8) {
            Button(role: .destructive) {
                sessionsPendingDeletion = selection
            } label: {
                Label("Delete \(selection.count)", systemImage: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.red.opacity(isDarkMode ? 0.22 : 0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.red.opacity(isDarkMode ? 0.4 : 0.3), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .accessibilityLabel("Delete \(selection.count) selected sessions")

            Button("Cancel") {
                selection.removeAll()
                isEditingSelection = false
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .pointingHandCursor()

            Spacer(minLength: 0)
        }
    }

    /// Liste boşken gösterilen dostça durum kartı.
    @ViewBuilder
    private var emptyStateRow: some View {
        VStack(spacing: 6) {
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text("No results for “\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))”")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Clear search") {
                    searchText = ""
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(currentTheme.accentGradient.first ?? .primary)
                .buttonStyle(.plain)
                .pointingHandCursor()
                .accessibilityLabel("No sessions match the search. Clear search")
            } else if hasActiveFilters {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text("No sessions in this period")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Button("Show all") {
                    resetSidebarFilters()
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(currentTheme.accentGradient.first ?? .primary)
                .buttonStyle(.plain)
                .pointingHandCursor()
                .accessibilityLabel("No sessions in the selected period. Show all sessions")
            } else {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text("No sessions yet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Start a new session above")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var deletionPromptTitle: String {
        guard let sessionPendingDeletion else {
            return "Delete session?"
        }

        return "Delete “\(sessionPendingDeletion.qualifiedTitle)”?"
    }

    private var isDeletionPromptPresented: Binding<Bool> {
        Binding(
            get: { sessionPendingDeletion != nil },
            set: { isPresented in
                guard !isPresented else {
                    return
                }
                sessionPendingDeletion = nil
            }
        )
    }

    private var bulkDeletionTitle: String {
        guard let sessionsPendingDeletion else {
            return "Delete sessions?"
        }

        return "Delete \(sessionsPendingDeletion.count) sessions?"
    }

    private var isBulkDeletionPresented: Binding<Bool> {
        Binding(
            get: { sessionsPendingDeletion != nil },
            set: { isPresented in
                guard !isPresented else {
                    return
                }
                sessionsPendingDeletion = nil
            }
        )
    }

    private var isRenamePresented: Binding<Bool> {
        Binding(
            get: { sessionToRename != nil },
            set: { isPresented in
                guard !isPresented else {
                    return
                }
                sessionToRename = nil
            }
        )
    }

    @ViewBuilder
    private func sessionRow(_ session: SessionSummary) -> some View {
        let isActive = session.id == sessionService.activeSessionID
        let isSelected = selection.contains(session.id)

        Button {
            if isEditingSelection {
                if isSelected {
                    selection.remove(session.id)
                } else {
                    selection.insert(session.id)
                }
            } else {
                sessionService.selectSession(session.id)
            }
        } label: {
            HStack(spacing: 8) {
                if isEditingSelection {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(
                            isSelected
                                ? (currentTheme.accentGradient.first ?? .accentColor)
                                : .secondary
                        )
                        .frame(width: 18)
                        .accessibilityLabel(isSelected ? "Deselect session" : "Select session")
                }

                Image(systemName: isActive ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.text.bubble.right")
                    .font(.system(size: 13, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if let folderName = session.workingDirectoryName {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(folderName)
                                .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(1)
                            Text(">")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        Text(session.displayTitle)
                            .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if session.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .help("Pinned session")
                        }
                    }
                    .help(session.workingDirectoryPath ?? session.displayTitle)

                    Text(sessionSubtitle(session))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if session.isBusy {
                    // `scaleEffect` yalnız çizimi küçültür; yerleşim boyutu
                    // AppKit göstergesinin kendi ölçüsüdür. Sabit bir
                    // `frame(width: 12)` bu yüzden min > max yapar ve SwiftUI
                    // "has a maximum length that doesn't satisfy min <= max"
                    // diye hata basar — ölçü alt sınırla verilir.
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(minWidth: 12, minHeight: 12)
                } else if session.showsDoneBadge {
                    // Tamamlanan tur: okunmadı parlaklığında mavi nokta + Done.
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.blue)
                            .frame(width: 8, height: 8)
                            .shadow(color: .blue.opacity(0.7), radius: 2.5)
                            .accessibilityHidden(true)
                        Text("Done")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.blue)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.blue)
                    }
                    .help("Turn completed")
                    .accessibilityLabel("Done, turn completed")
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? activeRowBackground : (isSelected ? activeRowBackground.opacity(0.7) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isActive ? activeRowBorder : (isSelected ? activeRowBorder.opacity(0.7) : Color.clear), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .interactiveHoverPill(cornerRadius: 8)
            .draggable(session.id.uuidString)
            .help("Drag onto a composer to continue with its summary, or onto a pane to work side by side")
        }
        .buttonStyle(.plain)
        // Sağ tık odağı mavi çerçeve çizer; görsel odak efekti kapalı, işlev aynı.
        .focusEffectDisabled()
        .accessibilityLabel(accessibilityLabel(for: session, isActive: isActive, isSelected: isSelected))
        .contextMenu {
            Button {
                if let slot = splitStore.togglePin(session.id) {
                    splitStore.focus(slot)
                }
            } label: {
                Label(
                    splitStore.slot(containing: session.id) != nil
                        ? "Remove from pane"
                        : "Open in a pane",
                    systemImage: "rectangle.split.2x1"
                )
            }
            .disabled(session.id == sessionService.activeSessionID)
            Divider()
            Button {
                sessionToRename = session
                renameDraft = session.customTitle ?? session.displayTitle
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                sessionService.toggleSessionPin(session.id)
            } label: {
                Label(
                    session.isPinned ? "Unpin" : "Pin",
                    systemImage: session.isPinned ? "pin.slash" : "pin"
                )
            }
            Divider()
            Button("Delete Session", role: .destructive) {
                sessionPendingDeletion = session
            }
        }
    }

    /// The selected conversation gets a soft frosted translucent pill, matching the reference styling.
    private var activeRowBackground: Color {
        isDarkMode ? Color.white.opacity(0.12) : Color.black.opacity(0.07)
    }

    private var activeRowBorder: Color {
        isDarkMode ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }

    private func accessibilityLabel(
        for session: SessionSummary,
        isActive: Bool,
        isSelected: Bool
    ) -> String {
        var parts = [session.qualifiedTitle, sessionSubtitle(session)]
        if let folderName = session.workingDirectoryName {
            parts.append("proje: \(folderName)")
        }
        if session.isPinned {
            parts.append("pinned")
        }
        if isActive {
            parts.append("active")
        }
        if session.showsDoneBadge {
            parts.append("done")
        }
        if isEditingSelection {
            parts.append(isSelected ? "selected" : "not selected")
        }
        return parts.joined(separator: ", ")
    }

    private func sessionSubtitle(_ session: SessionSummary) -> String {
        if session.isBusy {
            switch session.status {
            case .waiting:
                return "Waiting for you"
            case .cancelling:
                return "Stopping"
            case .runningTool(let name):
                return name
            default:
                return "Streaming"
            }
        }

        guard let reference = session.completedAt ?? session.lastMessageAt else {
            return "No messages yet"
        }

        // Cached per minute: this is a row subtitle, and the sidebar re-renders
        // on every state change of a running turn.
        return RelativeTimestamp.text(for: reference)
    }
}
