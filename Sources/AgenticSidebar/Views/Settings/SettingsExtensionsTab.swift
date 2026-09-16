import AppKit
import SwiftUI

/// The screen that decides what the agent can reach.
///
/// It is organised by *what an extension costs the model*, not by what it is:
/// MCP servers are listed with their context note because an enabled server's
/// tools are charged to every request, plugins are marked as code the user has
/// to trust, and skills — the cheap kind — get the skills.sh directory because
/// that is where new ones come from.
extension SettingsView {
    @ViewBuilder
    var extensionsTabContent: some View {
        extensionSummaryCard
        mcpServersCard
        pluginsCard
        skillsCard

        if let status = extensionStore.status {
            statusCard(status)
        }
    }

    // MARK: - Summary

    private var extensionSummaryCard: some View {
        settingsCard(
            title: "What reaches the model",
            subtitle: "An extension only costs context while it is enabled",
            icon: "gauge.with.dots.needle.33percent"
        ) {
            let summary = extensionStore.contextSummary

            HStack(spacing: 18) {
                summaryMetric(
                    value: "\(summary.activeMCPServers)/\(summary.knownMCPServers)",
                    label: "MCP servers on"
                )
                summaryMetric(
                    value: "\(summary.activePlugins)",
                    label: "Plugins on"
                )
                summaryMetric(
                    value: "\(summary.activeSkills)/\(summary.installedSkills)",
                    label: "Skills visible"
                )

                Spacer()

                primaryActionButton(
                    title: extensionStore.isWorking ? "Working…" : "Restart agent",
                    icon: "arrow.clockwise",
                    isDisabled: extensionStore.isWorking
                ) {
                    Task {
                        await extensionStore.restart()
                    }
                }
            }

            Text(
                "MCP servers and plugins are loaded when the agent starts, so a change takes effect on the next restart. Skills are read on demand and cost one line each."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summaryMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)

            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - MCP servers

    private var mcpServersCard: some View {
        settingsCard(
            title: "MCP servers",
            subtitle: ExtensionKind.mcp.contextNote,
            icon: "server.rack"
        ) {
            VStack(spacing: 8) {
                ForEach(extensionStore.registry.mcpServers) { record in
                    mcpServerRow(record)
                }

                if extensionStore.registry.mcpServers.isEmpty {
                    emptyRow("No MCP server is installed yet.")
                }
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 8) {
                Text("Add a server")
                    .font(.system(size: 12, weight: .semibold))

                HStack(spacing: 8) {
                    settingsTextField("Name", text: $newMCPName)
                    settingsTextField(
                        newMCPTransport == .local ? "Command" : "https://…",
                        text: $newMCPTarget
                    )
                }

                HStack(spacing: 8) {
                    Picker("", selection: $newMCPTransport) {
                        Text("Local command").tag(MCPTransport.local)
                        Text("Remote URL").tag(MCPTransport.remote)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)

                    Spacer()

                    primaryActionButton(
                        title: "Add",
                        icon: "plus",
                        isDisabled: newMCPName.trimmingCharacters(in: .whitespaces).isEmpty
                            || newMCPTarget.trimmingCharacters(in: .whitespaces).isEmpty
                    ) {
                        addNewMCPServer()
                    }
                }
            }
        }
    }

    private func mcpServerRow(_ record: MCPServerRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
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
                        .font(.system(size: 12.5, weight: .medium))

                    if record.isInherited {
                        badge("your own opencode.json", color: .orange)
                    }
                }

                Text(record.definition.summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !record.isEnabled {
                    Text("Silenced: its tools are kept out of the context window.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            if isRemote(record), record.isEnabled {
                Button("Authorize") {
                    Task {
                        await authorize(record)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(currentTheme.accentGradient.first ?? .accentColor)
                .pointingHandCursor()
                .help("Run this server's OAuth flow in your browser")
            }

            if !record.isInherited {
                Button {
                    extensionStore.removeMCPServer(named: record.name)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Remove this server from the app")
            }
        }
        .padding(10)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    // MARK: - Plugins

    private var pluginsCard: some View {
        settingsCard(
            title: "Plugins",
            subtitle: ExtensionKind.plugin.contextNote,
            icon: "puzzlepiece.extension"
        ) {
            installedPluginsRow

            Divider().opacity(0.4)

            HStack(spacing: 8) {
                settingsTextField("Search plugins, e.g. “opencode”", text: $pluginQuery)

                primaryActionButton(
                    title: "Search",
                    icon: "magnifyingglass",
                    isDisabled: extensionStore.isWorking
                ) {
                    Task {
                        await extensionStore.searchPlugins(pluginQuery)
                    }
                }

                primaryActionButton(
                    title: "Popular",
                    icon: "flame",
                    isDisabled: extensionStore.isWorking
                ) {
                    pluginQuery = ""
                    Task {
                        await extensionStore.searchPlugins("")
                    }
                }
            }

            ForEach(extensionStore.pluginCatalog) { entry in
                pluginCatalogRow(entry)
            }

            Divider().opacity(0.4)

            HStack(spacing: 8) {
                settingsTextField("or type an npm module name", text: $newPluginModule)

                primaryActionButton(
                    title: "Add",
                    icon: "plus",
                    isDisabled: newPluginModule
                        .trimmingCharacters(in: .whitespaces).isEmpty
                ) {
                    if extensionStore.addPlugin(module: newPluginModule) {
                        newPluginModule = ""
                    }
                }
            }

            Text(
                "A plugin is npm code that runs inside the agent. Only add one you trust; it loads when the agent restarts."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The installed plugins as marks, the way a catalogue screen shows them, and
    /// as rows underneath when there is something to switch or remove.
    @ViewBuilder
    private var installedPluginsRow: some View {
        let installed = extensionStore.registry.plugins

        if installed.isEmpty {
            emptyRow("No plugin is installed yet. Search below to add one.")
        } else {
            HStack(spacing: 8) {
                Text("Installed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(installed) { record in
                            pluginChip(record)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            VStack(spacing: 8) {
                ForEach(installed) { record in
                    pluginRow(record)
                }
            }
        }
    }

    private func pluginChip(_ record: PluginRecord) -> some View {
        HStack(spacing: 5) {
            PluginMark(name: record.module)

            Text(record.module)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Color.primary.opacity(record.isEnabled ? 0.08 : 0.04),
            in: Capsule()
        )
        .overlay(
            Capsule().stroke(
                Color.primary.opacity(record.isEnabled ? 0.14 : 0.08),
                lineWidth: 1
            )
        )
        .opacity(record.isEnabled ? 1 : 0.5)
        .help(record.isEnabled ? "Active" : "Switched off")
    }

    private func pluginCatalogRow(_ entry: PluginCatalogEntry) -> some View {
        let isInstalled = extensionStore.registry.plugins
            .contains { $0.module == entry.name }

        return HStack(spacing: 10) {
            PluginMark(name: entry.name)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 12.5, weight: .medium))

                    if let version = entry.version {
                        Text(version)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(entry.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if isInstalled {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(currentTheme.accentGradient.first ?? .accentColor)
                    .help("Already installed")
            } else {
                Button {
                    if extensionStore.addPlugin(
                        module: entry.name,
                        source: .npm(module: entry.name)
                    ) {
                        pluginQuery = ""
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(
                            LinearGradient(
                                colors: currentTheme.accentGradient,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Install \(entry.name)")
            }
        }
        .padding(9)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func pluginRow(_ record: PluginRecord) -> some View {
        HStack(spacing: 10) {
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
                    .font(.system(size: 12.5, weight: .medium))

                HStack(spacing: 6) {
                    Text(record.source.displayName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)

                    if record.requiresTrust {
                        badge("runs code", color: .orange)
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                extensionStore.removePlugin(module: record.module)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
        .padding(10)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    // MARK: - Skills

    private var skillsCard: some View {
        settingsCard(
            title: "Skills",
            subtitle: ExtensionKind.skill.contextNote,
            icon: "books.vertical"
        ) {
            VStack(spacing: 8) {
                ForEach(extensionStore.registry.skills) { record in
                    skillRow(record)
                }

                if extensionStore.registry.skills.isEmpty {
                    emptyRow("No skill is installed yet.")
                }
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 8) {
                Text("Find a skill on skills.sh")
                    .font(.system(size: 12, weight: .semibold))

                HStack(spacing: 8) {
                    settingsTextField("Search, e.g. “code review”", text: $skillQuery)

                    primaryActionButton(
                        title: "Search",
                        icon: "magnifyingglass",
                        isDisabled: skillQuery
                            .trimmingCharacters(in: .whitespaces).isEmpty
                    ) {
                        Task {
                            await extensionStore.searchSkills(skillQuery)
                        }
                    }
                }

                ForEach(extensionStore.searchResults) { entry in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name)
                                .font(.system(size: 12, weight: .medium))

                            Text("\(entry.source) · \(entry.installsText) installs")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        Button("Install") {
                            Task {
                                await extensionStore.installSkill(entry: entry)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(currentTheme.accentGradient.first ?? .accentColor)
                        .pointingHandCursor()
                    }
                    .padding(9)
                    .background(
                        Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 8) {
                Text("Install from a repository")
                    .font(.system(size: 12, weight: .semibold))

                HStack(spacing: 8) {
                    settingsTextField("owner/repo", text: $skillRepository)
                    settingsTextField("skill folder name", text: $skillName)

                    primaryActionButton(
                        title: "Install",
                        icon: "arrow.down.circle",
                        isDisabled: skillRepository
                            .trimmingCharacters(in: .whitespaces).isEmpty
                            || skillName.trimmingCharacters(in: .whitespaces).isEmpty
                    ) {
                        let name = skillName
                        let repository = skillRepository
                        Task {
                            await extensionStore.installSkill(
                                named: name,
                                from: repository
                            )
                        }
                    }
                }
            }
        }
    }

    private func skillRow(_ record: SkillRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(
                "",
                isOn: Binding(
                    get: { record.isEnabled },
                    set: { extensionStore.setSkillEnabled(record.name, $0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(.system(size: 12.5, weight: .medium))

                Text(record.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(record.source.displayName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)

                    if !record.isManaged {
                        badge("found on this Mac", color: .blue)
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                Task { await extensionStore.removeSkill(named: record.name) }
            } label: {
                Image(systemName: record.isManaged ? "trash" : "eye.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(record.isManaged ? "Delete this skill" : "Hide this skill from the agent")
        }
        .padding(10)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    // MARK: - Pieces

    private func statusCard(_ status: ExtensionStatus) -> some View {
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

    private func settingsTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(
                color.opacity(0.14),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
    }

    private func emptyRow(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func isRemote(_ record: MCPServerRecord) -> Bool {
        record.definition.transport == .remote
    }

    private func authorize(_ record: MCPServerRecord) async {
        guard let url = await extensionStore.authorizationURL(for: record.name) else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func addNewMCPServer() {
        let command = newMCPTarget
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }

        let definition = MCPDefinition(
            transport: newMCPTransport,
            command: newMCPTransport == .local ? command : [],
            url: newMCPTransport == .remote ? newMCPTarget
                .trimmingCharacters(in: .whitespacesAndNewlines) : nil
        )

        if extensionStore.addMCPServer(name: newMCPName, definition: definition) {
            newMCPName = ""
            newMCPTarget = ""
        }
    }
}
