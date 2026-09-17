import AppKit
import SwiftUI

enum MCPServerViewSegment: String, CaseIterable, Identifiable, Sendable {
    case marketplace = "Marketplace"
    case installed = "Installed"

    var id: String { rawValue }
}

extension SettingsView {
    @ViewBuilder
    var mcpServersTabContent: some View {
        mcpServersMainView
    }
}

struct SettingsMCPServersView: View {
    @Environment(ExtensionStore.self) private var extensionStore
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.colorScheme) private var systemColorScheme

    @State private var selectedSegment: MCPServerViewSegment = .marketplace
    @State private var selectedCategory: MCPMarketplaceCategory = .all
    @State private var searchQuery: String = ""

    // Custom MCP Server Form
    @State private var isCustomServerExpanded: Bool = false
    @State private var customServerName: String = ""
    @State private var customServerTarget: String = ""
    @State private var customServerTransport: MCPTransport = .local
    @State private var configuringEntry: MCPMarketplaceEntry? = nil
    @State private var envValues: [String: String] = [:]

    private var isDarkMode: Bool {
        settingsStore.isDark(systemColorScheme: systemColorScheme)
    }

    private var currentTheme: AppThemePreset {
        settingsStore.currentThemePreset
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
        .sheet(item: $configuringEntry) { entry in
            configureServerSheet(for: entry)
                .background(
                    WindowSharingConfigurator(
                        excludedFromCapture: settingsStore.stealthModeEnabled
                    )
                    .frame(width: 0, height: 0)
                )
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MCP Servers")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary)

                    Text("Model Context Protocol servers connect your agent to external tools, databases, and APIs.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                primaryActionButton(
                    title: extensionStore.isWorking ? "Restarting…" : "Restart Agent",
                    icon: "arrow.clockwise",
                    isDisabled: extensionStore.isWorking
                ) {
                    Task {
                        await extensionStore.restart()
                    }
                }
            }

            // Segmented Switcher
            HStack(spacing: 6) {
                segmentButton(
                    title: "Marketplace (\(MCPMarketplaceCatalog.entries.count))",
                    icon: "cart",
                    segment: .marketplace
                )

                segmentButton(
                    title: "Installed (\(extensionStore.registry.mcpServers.count))",
                    icon: "server.rack",
                    segment: .installed
                )

                Spacer()
            }
        }
    }

    private func segmentButton(title: String, icon: String, segment: MCPServerViewSegment) -> some View {
        let isSelected = selectedSegment == segment

        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                selectedSegment = segment
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6.5)
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
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    TextField("Search MCP servers...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))

                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6.5)
                .background(
                    isDarkMode ? Color.white.opacity(0.06) : Color.black.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 0.5)
                )

                Spacer(minLength: 0)
            }

            // Category Chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MCPMarketplaceCategory.allCases) { category in
                        categoryChip(category)
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 2)
            }

            // Catalog Cards
            VStack(spacing: 10) {
                ForEach(filteredMarketplaceEntries) { entry in
                    marketplaceCard(entry)
                }

                if filteredMarketplaceEntries.isEmpty {
                    emptyCard(message: "No MCP server found matching “\(searchQuery)”.")
                }
            }

            customServerCard
        }
    }

    private var filteredMarketplaceEntries: [MCPMarketplaceEntry] {
        MCPMarketplaceCatalog.entries.filter { entry in
            let matchesCategory = selectedCategory == .all || entry.category == selectedCategory
            let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matchesSearch = trimmedQuery.isEmpty
                || entry.name.lowercased().contains(trimmedQuery)
                || entry.displayName.lowercased().contains(trimmedQuery)
                || entry.summary.lowercased().contains(trimmedQuery)

            return matchesCategory && matchesSearch
        }
    }

    private func categoryChip(_ category: MCPMarketplaceCategory) -> some View {
        let isSelected = selectedCategory == category

        return Button {
            selectedCategory = category
        } label: {
            Text(category.rawValue)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .background(
                    isSelected
                        ? (isDarkMode ? Color.white.opacity(0.12) : Color.black.opacity(0.08))
                        : (isDarkMode ? Color.white.opacity(0.04) : Color.black.opacity(0.03)),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .interactiveHoverPill(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func marketplaceCard(_ entry: MCPMarketplaceEntry) -> some View {
        let isInstalled = extensionStore.registry.mcpServers.contains { $0.name == entry.name }

        return HStack(alignment: .top, spacing: 12) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                    .frame(width: 36, height: 36)

                Image(systemName: entry.iconName)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(currentTheme.accentGradient.first ?? .primary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.displayName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(entry.publisher)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )

                    Text(entry.category.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(currentTheme.accentGradient.first ?? .primary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            (currentTheme.accentGradient.first ?? .primary).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )

                    Spacer()

                    if isInstalled {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.green)
                            Text("Installed")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.green)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Color.green.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                    } else {
                        Button {
                            if entry.environmentKeys.isEmpty {
                                extensionStore.addMCPServer(
                                    name: entry.name,
                                    definition: entry.createDefinition(),
                                    source: .manual
                                )
                            } else {
                                configuringEntry = entry
                                envValues = [:]
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Add to Agent")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                isDarkMode ? Color.white.opacity(0.10) : Color.black.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 0.5)
                            )
                            .interactiveHoverPill(cornerRadius: 7)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                }

                Text(entry.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(entry.installSummary)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    Spacer()

                    if !entry.environmentKeys.isEmpty {
                        Text("Requires: \(entry.environmentKeys.joined(separator: ", "))")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(12)
        .background(
            currentTheme.surface(isDark: isDarkMode)
                .opacity(settingsStore.glassOpacity),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(currentTheme.border(isDark: isDarkMode).opacity(settingsStore.contrast), lineWidth: 0.5)
        )
    }

    // MARK: - Add Custom Server

    private var customServerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    isCustomServerExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(currentTheme.accentGradient.first ?? .primary)

                    Text("Add Custom MCP Server")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCustomServerExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
                .interactiveHoverPill(cornerRadius: 8)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            if isCustomServerExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Server name (e.g. my-server)", text: $customServerName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(
                                isDarkMode ? Color.white.opacity(0.06) : Color.black.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )

                        TextField(
                            customServerTransport == .local ? "Command (e.g. npx -y my-mcp)" : "https://mcp.example.com",
                            text: $customServerTarget
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(
                            isDarkMode ? Color.white.opacity(0.06) : Color.black.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                    }

                    HStack(spacing: 10) {
                        Picker("", selection: $customServerTransport) {
                            Text("Local Command").tag(MCPTransport.local)
                            Text("Remote URL").tag(MCPTransport.remote)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 180)

                        Spacer()

                        Button("Add Server") {
                            addCustomServer()
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            isDarkMode ? Color.white.opacity(0.12) : Color.black.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .disabled(customServerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(
            currentTheme.surface(isDark: isDarkMode).opacity(settingsStore.glassOpacity),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(currentTheme.border(isDark: isDarkMode).opacity(settingsStore.contrast), lineWidth: 0.5)
        )
    }

    private func addCustomServer() {
        let command = customServerTarget
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }

        let definition = MCPDefinition(
            transport: customServerTransport,
            command: customServerTransport == .local ? command : [],
            url: customServerTransport == .remote ? customServerTarget.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        )

        if extensionStore.addMCPServer(name: customServerName, definition: definition, source: .manual) {
            customServerName = ""
            customServerTarget = ""
            isCustomServerExpanded = false
        }
    }

    // MARK: - Installed Section

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(extensionStore.registry.mcpServers) { record in
                installedMCPServerRow(record)
            }

            if extensionStore.registry.mcpServers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No MCP server is installed yet.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button("Browse Marketplace") {
                        withAnimation { selectedSegment = .marketplace }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(currentTheme.accentGradient.first ?? .primary)
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            }
        }
    }

    private func installedMCPServerRow(_ record: MCPServerRecord) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle(
                "",
                isOn: Binding(
                    get: { record.isEnabled },
                    set: { extensionStore.setMCPEnabled(record.name, $0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(record.definition.transport.rawValue)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                        )

                    if record.isInherited {
                        Text("config")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                Color.blue.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                            )
                    }
                }

                Text(record.definition.summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if record.definition.transport == .remote {
                Button("Auth") {
                    Task {
                        if let url = await extensionStore.authorizationURL(for: record.name) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            if !record.isInherited {
                Button {
                    extensionStore.removeMCPServer(named: record.name)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .interactiveHoverCircle()
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Remove this MCP server")
            }
        }
        .padding(12)
        .background(
            currentTheme.surface(isDark: isDarkMode).opacity(settingsStore.glassOpacity),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(currentTheme.border(isDark: isDarkMode).opacity(settingsStore.contrast), lineWidth: 0.5)
        )
    }

    private func statusBanner(_ status: ExtensionStatus) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: status.isFailure ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(status.isFailure ? Color.orange : Color.secondary)

            Text(status.message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func emptyCard(message: String) -> some View {
        HStack {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
        .background(
            Color.primary.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func configureServerSheet(for entry: MCPMarketplaceEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: entry.iconName)
                    .font(.system(size: 16))
                    .foregroundStyle(currentTheme.accentGradient.first ?? .primary)

                Text("Configure \(entry.displayName)")
                    .font(.system(size: 15, weight: .semibold))

                Spacer()

                Button("Cancel") {
                    configuringEntry = nil
                }
                .buttonStyle(.plain)
            }

            Text("This server requires environment variables to authenticate with external services.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            ForEach(entry.environmentKeys, id: \.self) { key in
                VStack(alignment: .leading, spacing: 4) {
                    Text(key)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)

                    SecureField("Value for \(key)", text: Binding(
                        get: { envValues[key] ?? "" },
                        set: { envValues[key] = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(8)
                    .background(
                        isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                }
            }

            HStack {
                Spacer()

                Button("Save and Add") {
                    var def = entry.createDefinition()
                    def.environment = envValues
                    extensionStore.addMCPServer(name: entry.name, definition: def, source: .manual)
                    configuringEntry = nil
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    currentTheme.accentGradient.first ?? .accentColor,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .foregroundStyle(.white)
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }

    private func primaryActionButton(
        title: String,
        icon: String?,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11.5, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                isDarkMode ? Color.white.opacity(0.10) : Color.black.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 0.5)
            )
            .interactiveHoverPill(cornerRadius: 8)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

extension SettingsView {
    var mcpServersMainView: some View {
        SettingsMCPServersView()
    }
}
