import SwiftUI

struct ConversationSidebarView: View {
    let sessionService: AgentSessionService

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

    /// Arama + filtre + sıralama uygulanmış liste; sabitliler üstte.
    private var filteredSessions: [SessionSummary] {
        filterSortSessions(
            sessionService.sessionList,
            query: searchText,
            sort: sortOption,
            dateFilter: dateFilter,
            now: Date(),
            calendar: .current
        )
    }

    private var pinnedSessions: [SessionSummary] {
        filteredSessions.filter(\.isPinned)
    }

    private var regularSessions: [SessionSummary] {
        filteredSessions.filter { !$0.isPinned }
    }

    var body: some View {
        List {
            Section("Sessions") {
                Button {
                    sessionService.createSession()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 14, weight: .semibold))

                        Text("New session")
                            .font(.system(size: 13, weight: .semibold))

                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(
                        LinearGradient(
                            colors: currentTheme.accentGradient,
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .interactiveHoverOutline(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Start a new session")
                .accessibilityLabel("New session")

                searchAndFilterControls

                if isEditingSelection {
                    selectionToolbar
                }

                if !pinnedSessions.isEmpty {
                    Section("Pinned · \(pinnedSessions.count)") {
                        ForEach(pinnedSessions) { session in
                            sessionRow(session)
                        }
                    }
                }

                if regularSessions.isEmpty, pinnedSessions.isEmpty {
                    emptyStateRow
                } else {
                    ForEach(regularSessions) { session in
                        sessionRow(session)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
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
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text("Settings")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)

                        Spacer()

                        Text("⌘,")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
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

    // MARK: - Arama, sıralama ve filtre

    /// Arama alanı + üç nokta menüsünde sıralama ve tarih filtreleri.
    ///
    /// İki ayrı hap buton satırı kaplıyordu; şimdi tek satırda sonuç sayısı ve
    /// filtre göstergeli bir menü var, aktif filtreler altında silinebilir çip
    /// olarak durur.
    @ViewBuilder
    private var searchAndFilterControls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search sessions", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Search sessions")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(currentTheme.surface(isDark: isDarkMode))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(currentTheme.border(isDark: isDarkMode), lineWidth: 1)
            )

            HStack(spacing: 6) {
                Text(sessionCountText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("\(filteredSessions.count) of \(sessionService.sessionList.count) sessions shown")

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
                            .foregroundStyle(hasActiveFilters ? (currentTheme.accentGradient.first ?? .primary) : .secondary)
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
    private var sessionCountText: String {
        let total = sessionService.sessionList.count
        let shown = filteredSessions.count
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty || hasActiveFilters {
            return "\(shown) of \(total)"
        }
        return total == 1 ? "1 session" : "\(total) sessions"
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
    private var selectionToolbar: some View {
        HStack {
            Button(selection.count == filteredSessions.count ? "Deselect all" : "Select all") {
                if selection.count == filteredSessions.count {
                    selection.removeAll()
                } else {
                    selection = Set(filteredSessions.map(\.id))
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

        return "Delete “\(sessionPendingDeletion.displayTitle)”?"
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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isActive ? (currentTheme.accentGradient.first ?? .primary) : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(session.displayTitle)
                            .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if session.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(currentTheme.accentGradient.first ?? .secondary)
                                .help("Pinned session")
                        }
                    }

                    Text(sessionSubtitle(session))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if session.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? activeRowBackground : (isSelected ? activeRowBackground.opacity(0.6) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isActive ? activeRowBorder : (isSelected ? activeRowBorder.opacity(0.7) : Color.clear), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .interactiveHoverPill(cornerRadius: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: session, isActive: isActive, isSelected: isSelected))
        .contextMenu {
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

    /// The selected conversation gets a soft theme-tinted plate, so the active
    /// session is obvious at a glance without looking like a system selection.
    private var activeRowBackground: Color {
        (currentTheme.accentGradient.first ?? .accentColor)
            .opacity(isDarkMode ? 0.22 : 0.14)
    }

    private var activeRowBorder: Color {
        (currentTheme.accentGradient.first ?? .accentColor)
            .opacity(isDarkMode ? 0.34 : 0.26)
    }

    private func accessibilityLabel(
        for session: SessionSummary,
        isActive: Bool,
        isSelected: Bool
    ) -> String {
        var parts = [session.displayTitle, sessionSubtitle(session)]
        if session.isPinned {
            parts.append("pinned")
        }
        if isActive {
            parts.append("active")
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
