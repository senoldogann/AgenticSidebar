import AppKit
import SwiftUI

enum SkillViewSegment: String, CaseIterable, Identifiable, Sendable {
    case marketplace = "Marketplace"
    case installed = "Installed"

    var id: String { rawValue }
}

extension SettingsView {
    @ViewBuilder
    var skillsTabContent: some View {
        skillsMainView
    }
}

struct SettingsSkillsView: View {
    @Environment(ExtensionStore.self) private var extensionStore
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.colorScheme) private var systemColorScheme

    @State private var selectedSegment: SkillViewSegment = .marketplace
    @State private var selectedCategory: String = "All"
    @State private var searchQuery: String = ""

    // GitHub Direct Install Form
    @State private var isCustomInstallExpanded: Bool = false
    @State private var customRepository: String = ""
    @State private var customSkillName: String = ""

    private var isDarkMode: Bool {
        settingsStore.isDark(systemColorScheme: systemColorScheme)
    }

    private var currentTheme: AppThemePreset {
        settingsStore.currentThemePreset
    }

    private var categories: [String] {
        let unique = Set(SkillsMarketplaceCatalog.curatedSkills.map(\.category))
        return ["All"] + unique.sorted()
    }

    private var filteredCuratedSkills: [CuratedSkillEntry] {
        SkillsMarketplaceCatalog.curatedSkills.filter { skill in
            let matchesCategory = selectedCategory == "All" || skill.category == selectedCategory
            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matchesSearch =
                query.isEmpty || skill.name.lowercased().contains(query) || skill.displayName.lowercased().contains(query)
                || skill.description.lowercased().contains(query) || skill.category.lowercased().contains(query)
            return matchesCategory && matchesSearch
        }
    }

    private var installedSkillNames: Set<String> {
        Set(extensionStore.catalog.map(\.name))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerBar

            switch selectedSegment {
            case .marketplace:
                marketplaceSection
            case .installed:
                installedSection
            }

            if let status = extensionStore.status {
                statusBanner(status)
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Skills")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary)

                    Text("Skills teach your agent specialized workflows, debugging procedures, and framework guidelines.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                primaryActionButton(
                    title: extensionStore.isWorking ? "Refreshing…" : "Scan Skills",
                    icon: "arrow.clockwise",
                    isDisabled: extensionStore.isWorking
                ) {
                    Task {
                        await extensionStore.discover()
                    }
                }
            }

            // Segmented Switcher
            HStack(spacing: 6) {
                segmentButton(
                    title: "Marketplace (\(SkillsMarketplaceCatalog.curatedSkills.count))",
                    icon: "cart",
                    segment: .marketplace
                )

                segmentButton(
                    title: "Installed (\(extensionStore.catalog.count))",
                    icon: "checkmark.circle",
                    segment: .installed
                )

                Spacer()
            }
        }
        .padding(.bottom, 4)
    }

    private func segmentButton(title: String, icon: String, segment: SkillViewSegment) -> some View {
        let isSelected = selectedSegment == segment
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                selectedSegment = segment
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))

                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isDarkMode ? Color.white.opacity(0.12) : Color.black.opacity(0.08))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: - Marketplace Section

    private var marketplaceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Search & Category Filters
            searchAndFiltersBar

            // Curated Grid
            Text("Featured Agent Skills")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(filteredCuratedSkills) { skill in
                    curatedSkillCard(skill)
                }
            }

            // skills.sh Live Search Results (if available)
            if !extensionStore.searchResults.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Live skills.sh Results (\(extensionStore.searchResults.count))")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.top, 8)

                    ForEach(extensionStore.searchResults) { entry in
                        skillsShResultRow(entry)
                    }
                }
            }

            // Custom GitHub Import Accordion Card
            customGitHubImportCard
        }
    }

    // MARK: - Search & Filters

    private var searchAndFiltersBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    TextField("Search curated skills or press enter for skills.sh…", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit {
                            let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            Task {
                                await extensionStore.searchSkills(trimmed)
                            }
                        }

                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isDarkMode ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(currentTheme.border(isDark: isDarkMode).opacity(0.3), lineWidth: 1)
                )

                if !searchQuery.isEmpty {
                    primaryActionButton(
                        title: extensionStore.isWorking ? "Searching…" : "Search skills.sh",
                        icon: "globe",
                        isDisabled: extensionStore.isWorking
                    ) {
                        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        Task {
                            await extensionStore.searchSkills(trimmed)
                        }
                    }
                }
            }

            // Category Chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(categories, id: \.self) { category in
                        categoryChip(category)
                    }
                }
            }
        }
    }

    private func categoryChip(_ category: String) -> some View {
        let isSelected = selectedCategory == category
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedCategory = category
            }
        } label: {
            Text(category)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            isSelected
                                ? (isDarkMode ? Color.white.opacity(0.16) : Color.black.opacity(0.1))
                                : (isDarkMode ? Color.white.opacity(0.05) : Color.black.opacity(0.03))
                        )
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(
                            isSelected
                                ? currentTheme.border(isDark: isDarkMode).opacity(0.6)
                                : Color.clear,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: - Curated Skill Card

    private func curatedSkillCard(_ skill: CuratedSkillEntry) -> some View {
        let isInstalled = installedSkillNames.contains(skill.name)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                        .frame(width: 32, height: 32)

                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(currentTheme.accentGradient.first ?? .accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(skill.category)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text("•")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary.opacity(0.6))

                        Text(skill.author)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary.opacity(0.8))
                            .lineLimit(1)
                    }
                }

                Spacer()
            }

            Text(skill.description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            HStack {
                Text(skill.name)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineLimit(1)

                Spacer()

                if isInstalled {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9.5, weight: .bold))
                        Text("Installed")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.green)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.green.opacity(isDarkMode ? 0.15 : 0.1))
                    )
                } else {
                    Button {
                        installCuratedSkill(skill)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Install")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(.white)
                        .background(
                            Capsule()
                                .fill(currentTheme.accentGradient.first ?? Color.accentColor)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .disabled(extensionStore.isWorking)
                }
            }
        }
        .padding(12)
        .frame(minHeight: 124)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isDarkMode ? Color.white.opacity(0.04) : Color.black.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(currentTheme.border(isDark: isDarkMode).opacity(0.35), lineWidth: 1)
        )
    }

    private func installCuratedSkill(_ skill: CuratedSkillEntry) {
        Task {
            // The entry's own repository, not a guess: every card names the
            // `owner/repo/path` its files actually live at.
            await extensionStore.installSkill(named: skill.name, from: skill.repository)
        }
    }

    // MARK: - skills.sh Result Row

    private func skillsShResultRow(_ entry: SkillsShEntry) -> some View {
        let isInstalled = installedSkillNames.contains(entry.skillID)

        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isDarkMode ? Color.white.opacity(0.07) : Color.black.opacity(0.04))
                    .frame(width: 28, height: 28)

                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(entry.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.8))
                }

                HStack(spacing: 8) {
                    Text("Source: \(entry.source)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)

                    Text("•")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary.opacity(0.5))

                    Text("\(entry.installsText) installs")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isInstalled {
                Text("Installed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.green.opacity(0.12))
                    )
            } else {
                Button {
                    Task {
                        await extensionStore.installSkill(entry: entry)
                    }
                } label: {
                    Text("Install")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(.white)
                        .background(
                            Capsule().fill(currentTheme.accentGradient.first ?? Color.accentColor)
                        )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .disabled(extensionStore.isWorking)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDarkMode ? Color.white.opacity(0.035) : Color.black.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(currentTheme.border(isDark: isDarkMode).opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Custom GitHub Import Card

    private var customGitHubImportCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    isCustomInstallExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isCustomInstallExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)

                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(currentTheme.accentGradient.first ?? .accentColor)

                    Text("Import Skill from GitHub")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Text("Direct Download")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            if isCustomInstallExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Install any skill containing a valid SKILL.md from a public GitHub repository.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Repository (owner/repo)")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)

                            TextField("e.g. google/antigravity-skills", text: $customRepository)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11.5))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(isDarkMode ? Color.white.opacity(0.07) : Color.black.opacity(0.04))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(currentTheme.border(isDark: isDarkMode).opacity(0.3), lineWidth: 1)
                                )
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Skill Name (Folder)")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)

                            TextField("e.g. code-review", text: $customSkillName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11.5))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(isDarkMode ? Color.white.opacity(0.07) : Color.black.opacity(0.04))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(currentTheme.border(isDark: isDarkMode).opacity(0.3), lineWidth: 1)
                                )
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(" ")
                                .font(.system(size: 10.5))

                            Button {
                                installFromGitHub()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "square.and.arrow.down")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text("Install")
                                        .font(.system(size: 11.5, weight: .semibold))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .foregroundStyle(.white)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(currentTheme.accentGradient.first ?? Color.accentColor)
                                )
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                            .disabled(customRepository.isEmpty || customSkillName.isEmpty || extensionStore.isWorking)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isDarkMode ? Color.white.opacity(0.035) : Color.black.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(currentTheme.border(isDark: isDarkMode).opacity(0.3), lineWidth: 1)
        )
    }

    private func installFromGitHub() {
        let repo = customRepository.trimmingCharacters(in: .whitespacesAndNewlines)
        let skill = customSkillName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty, !skill.isEmpty else { return }

        Task {
            await extensionStore.installSkill(named: skill, from: repo)
            customRepository = ""
            customSkillName = ""
        }
    }

    // MARK: - Installed Section

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if extensionStore.catalog.isEmpty {
                emptyInstalledState
            } else {
                ForEach(extensionStore.catalog) { skill in
                    installedSkillCard(skill)
                }
            }
        }
    }

    private var emptyInstalledState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(.secondary.opacity(0.7))
                .padding(.top, 16)

            Text("No Skills Installed Yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)

            Text("Explore the Marketplace tab to install curated skills or import skills from GitHub repositories.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Button {
                withAnimation {
                    selectedSegment = .marketplace
                }
            } label: {
                Text("Browse Marketplace")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .foregroundStyle(.white)
                    .background(
                        Capsule()
                            .fill(currentTheme.accentGradient.first ?? Color.accentColor)
                    )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isDarkMode ? Color.white.opacity(0.03) : Color.black.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(currentTheme.border(isDark: isDarkMode).opacity(0.25), lineWidth: 1)
        )
    }

    private func installedSkillCard(_ skill: DiscoveredSkill) -> some View {
        let record = extensionStore.registry.skills.first(where: { $0.name == skill.name })
        let isEnabled = record?.isEnabled ?? true

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                        .frame(width: 32, height: 32)

                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(skill.isLoadable ? (currentTheme.accentGradient.first ?? .accentColor) : .orange)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(skill.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)

                        if skill.isManaged {
                            Text("Managed")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                                )
                        }

                        if !skill.isLoadable {
                            Text("Invalid")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(Color.red.opacity(0.15))
                                )
                        }
                    }

                    Text(skill.locationLabel)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Active / Inactive Toggle
                Toggle(
                    "",
                    isOn: Binding(
                        get: { isEnabled },
                        set: { newValue in
                            extensionStore.setSkillEnabled(skill.name, newValue)
                        }
                    )
                )
                .toggleStyle(.switch)
                .tint(currentTheme.accentGradient.first ?? .accentColor)
                .labelsHidden()

                // Actions Menu (Reveal in Finder, Remove)
                Menu {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(skill.path, inFileViewerRootedAtPath: "")
                    }

                    if skill.isManaged {
                        Divider()

                        Button(role: .destructive) {
                            Task {
                                await extensionStore.removeSkill(named: skill.name)
                            }
                        } label: {
                            Label("Delete Skill", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if let description = skill.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let error = skill.validationError {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.red.opacity(0.08))
                    )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isDarkMode ? Color.white.opacity(0.04) : Color.black.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(currentTheme.border(isDark: isDarkMode).opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Status Banner

    private func statusBanner(_ status: ExtensionStatus) -> some View {
        HStack(spacing: 8) {
            Image(systemName: status.isFailure ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(status.isFailure ? Color.red : Color.green)

            Text(status.message)
                .font(.system(size: 11.5))
                .foregroundStyle(status.isFailure ? Color.red : Color.primary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(status.isFailure ? Color.red.opacity(0.08) : (isDarkMode ? Color.white.opacity(0.06) : Color.black.opacity(0.04)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(status.isFailure ? Color.red.opacity(0.3) : currentTheme.border(isDark: isDarkMode).opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Action Button Helper

    private func primaryActionButton(
        title: String,
        icon: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))

                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isDisabled ? Color.secondary : Color.white)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        isDisabled
                            ? (isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.08))
                            : (currentTheme.accentGradient.first ?? Color.accentColor))
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .disabled(isDisabled)
        .help(title)
    }
}

extension SettingsView {
    var skillsMainView: some View {
        SettingsSkillsView()
    }
}
