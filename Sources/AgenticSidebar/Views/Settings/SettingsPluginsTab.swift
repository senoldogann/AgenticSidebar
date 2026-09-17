import AppKit
import SwiftUI

enum PluginViewSegment: String, CaseIterable, Identifiable, Sendable {
    case marketplace = "Marketplace"
    case installed = "Installed"

    var id: String { rawValue }
}

extension SettingsView {
    @ViewBuilder
    var pluginsTabContent: some View {
        SettingsPluginsView()
    }
}

struct SettingsPluginsView: View {
    @Environment(ExtensionStore.self) private var extensionStore
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.colorScheme) private var systemColorScheme

    @State private var selectedSegment: PluginViewSegment = .marketplace
    @State private var searchQuery: String = ""
    @State private var customModuleName: String = ""
    @State private var isSearching: Bool = false

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
        .task {
            if extensionStore.pluginCatalog.isEmpty {
                await extensionStore.searchPlugins("")
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Plugins")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary)

                    Text("Plugins run inside the agent to provide custom tool hooks, linters, and command extensions.")
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
                    title: "Marketplace / npm",
                    icon: "cart",
                    segment: .marketplace
                )

                segmentButton(
                    title: "Installed (\(extensionStore.registry.plugins.count))",
                    icon: "puzzlepiece.extension.fill",
                    segment: .installed
                )

                Spacer()
            }
        }
    }

    private func segmentButton(title: String, icon: String, segment: PluginViewSegment) -> some View {
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
            // Live Search Bar
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    TextField("Search npm plugins (e.g. “opencode”, “linter”)...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .onSubmit {
                            performSearch()
                        }

                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                            Task { await extensionStore.searchPlugins("") }
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

                Button("Search") {
                    performSearch()
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6.5)
                .background(
                    isDarkMode ? Color.white.opacity(0.10) : Color.black.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            // Quick npm Module Direct Install
            HStack(spacing: 8) {
                TextField("Install any npm package name (e.g. @my-org/my-plugin)", text: $customModuleName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        isDarkMode ? Color.white.opacity(0.05) : Color.black.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )

                Button("Install") {
                    let trimmed = customModuleName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        extensionStore.addPlugin(module: trimmed, source: .npm(module: trimmed))
                        customModuleName = ""
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    currentTheme.accentGradient.first ?? .accentColor,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .foregroundStyle(.white)
                .buttonStyle(.plain)
                .disabled(customModuleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // Results / Curated List
            VStack(spacing: 10) {
                if !extensionStore.pluginCatalog.isEmpty {
                    ForEach(extensionStore.pluginCatalog) { entry in
                        npmCatalogCard(entry)
                    }
                } else {
                    // Show curated open plugins
                    ForEach(PluginMarketplaceCatalog.curatedPlugins) { entry in
                        curatedPluginCard(entry)
                    }
                }
            }
        }
    }

    private func performSearch() {
        Task {
            await extensionStore.searchPlugins(searchQuery)
        }
    }

    private func curatedPluginCard(_ entry: CuratedPluginEntry) -> some View {
        let isInstalled = extensionStore.registry.plugins.contains { $0.module == entry.name }

        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                    .frame(width: 36, height: 36)

                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(currentTheme.accentGradient.first ?? .primary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.displayName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(entry.version)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                        )

                    Text(entry.author)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

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
                            extensionStore.addPlugin(module: entry.name, source: .npm(module: entry.name))
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Install Plugin")
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

                Text(entry.description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)

                    Spacer()

                    ForEach(entry.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                            )
                    }
                }
            }
        }
        .padding(12)
        .background(
            currentTheme.surface(isDark: isDarkMode).opacity(settingsStore.glassOpacity),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(currentTheme.border(isDark: isDarkMode).opacity(settingsStore.contrast), lineWidth: 0.5)
        )
    }

    private func npmCatalogCard(_ entry: PluginCatalogEntry) -> some View {
        let isInstalled = extensionStore.registry.plugins.contains { $0.module == entry.name }

        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                    .frame(width: 36, height: 36)

                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(currentTheme.accentGradient.first ?? .primary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)

                    if let version = entry.version {
                        Text("v\(version)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                            )
                    }

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
                            extensionStore.addPlugin(module: entry.name, source: .npm(module: entry.name))
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Install")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                isDarkMode ? Color.white.opacity(0.10) : Color.black.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .interactiveHoverPill(cornerRadius: 7)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                }

                Text(entry.description.isEmpty ? "No description provided." : entry.description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(
            currentTheme.surface(isDark: isDarkMode).opacity(settingsStore.glassOpacity),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(currentTheme.border(isDark: isDarkMode).opacity(settingsStore.contrast), lineWidth: 0.5)
        )
    }

    // MARK: - Installed Section

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(extensionStore.registry.plugins) { record in
                installedPluginRow(record)
            }

            if extensionStore.registry.plugins.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No plugin is installed yet.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button("Browse npm Marketplace") {
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

    private func installedPluginRow(_ record: PluginRecord) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle(
                "",
                isOn: Binding(
                    get: { record.isEnabled },
                    set: { extensionStore.setPluginEnabled(record.module, $0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.module)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)

                Text(record.source.displayName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                extensionStore.removePlugin(module: record.module)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .interactiveHoverCircle()
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Remove this plugin")
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
