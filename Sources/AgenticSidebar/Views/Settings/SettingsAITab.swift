import AppKit
import SwiftUI

// MARK: - AI Tab

extension SettingsView {
    /// Which adapter runs the turns.
    ///
    /// It lives here rather than in the composer because it is a long-lived
    /// choice about how the app is wired, not something to change mid-sentence,
    /// and because the composer's width is better spent on the model, the
    /// reasoning effort and the mode.
    @ViewBuilder
    var providerCard: some View {
        settingsCard(
            title: "Provider",
            subtitle: "The adapter that runs your turns. The composer only shows which one is active.",
            icon: "server.rack"
        ) {
            if sessionService.providers.isEmpty {
                Text("No provider is available yet. Start the engine below.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(sessionService.providers, id: \.id) { provider in
                        providerRow(provider)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func providerRow(_ provider: ProviderCapabilities) -> some View {
        let isActive = sessionService.state.configuration?.providerID == provider.id

        HStack(spacing: 10) {
            ProviderLogoView(
                logo: ProviderLogo.matching(provider.id.rawValue),
                size: 18,
                tint: isActive
                    ? (currentTheme.accentGradient.first ?? .primary)
                    : .secondary
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.system(size: 13, weight: .medium))

                Text(
                    isActive
                        ? "Active · \(provider.models.count) models available"
                        : "\(provider.models.count) models available"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleOnly)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(currentTheme.accentGradient.first ?? .accentColor)
            } else {
                primaryActionButton(
                    title: "Use",
                    icon: nil,
                    isDisabled: false
                ) {
                    try? sessionService.selectProvider(provider.id)
                }
            }
        }
        .padding(10)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }
    /// The one decision that governs every tool, in the shape the user makes it:
    /// ask, decide the safe ones for me, or do not ask.
    ///
    /// It sits above the provider cards because it is the question a user answers
    /// before anything runs, and because the composer's per-turn controls do not
    /// cover it: this is a long-lived choice about the agent's reach. The level is
    /// read per tool call rather than written into the agent's configuration, so
    /// changing it applies to the running agent immediately — there is no restart
    /// row here because there is nothing to restart.
    @ViewBuilder
    var toolApprovalCard: some View {
        toolApprovalCardBody
            // The deep-link target: "More info" in the composer scrolls here.
            .id(SettingsAnchor.toolApprovals)
    }

    @ViewBuilder
    var toolApprovalCardBody: some View {
        settingsCard(
            title: "Tool approvals",
            subtitle: "How much the agent may do without asking. One level for every tool: shell commands, edits, the network and computer use. Changes apply to the running agent on its next tool call.",
            icon: "lock.shield.fill"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(ToolApprovalPolicy.allCases) { policy in
                    toolApprovalRow(policy)
                }

                Text(settingsStore.toolApprovalPolicy.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let override = GlobalOpenCodeConfigReader.live().globalPermissionOverrides(),
                   !override.rules.isEmpty {
                    let conflictingRules = override.rules.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 14))

                        VStack(alignment: .leading, spacing: 3) {
                            Text("External OpenCode configuration overrides approvals")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.primary)

                            Text(
                                "Your external configuration at \(override.sourceURL.path) defines `\(conflictingRules)`. OpenCode applies these rules with higher priority, which may allow tools (e.g. bash) without prompting regardless of the policy selected above."
                            )
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 8)

                        secondaryActionButton(
                            title: "Reveal",
                            icon: "folder"
                        ) {
                            NSWorkspace.shared.activateFileViewerSelecting([override.sourceURL])
                        }
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                // The grant is a file the user can read, so it is named here
                // rather than left to be inferred from behaviour. What the file
                // does *not* contain is the level — that is the point.
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Agent permission rules")
                            .font(.system(size: 11, weight: .semibold))

                        Text(policyConfigurationURL.path)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)

                        Text(
                            "These are the strictest rules the app writes; the level above is applied per tool call, which is why changing it takes effect immediately."
                        )
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    secondaryActionButton(
                        title: "Reveal",
                        icon: "folder"
                    ) {
                        NSWorkspace.shared.activateFileViewerSelecting([policyConfigurationURL])
                    }
                }

                if !permissionApprovalCenter.grants.isEmpty {
                    Divider().opacity(0.3)

                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Always allowed in this session")
                                .font(.system(size: 12, weight: .semibold))

                            ForEach(permissionApprovalCenter.grants) { grant in
                                Text(grant.displayText)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Spacer(minLength: 8)

                        secondaryActionButton(
                            title: "Revoke all",
                            icon: "arrow.uturn.backward"
                        ) {
                            permissionApprovalCenter.revokeAllGrants()
                        }
                    }
                }
            }
        }
    }

    /// What the app actually decided, in order, with the reason for each one.
    ///
    /// On a level that does not ask, this list is the substitute for the prompt:
    /// the record of what ran, from where, and whether a level, an earlier
    /// "Always allow" or the user answered it. Kapalı bir görüntüleyicidir —
    /// kayıt `audit.jsonl` dosyasına zaten yazılır, bu kart yalnız kuyruğunu
    /// gösterir, o yüzden varsayılan olarak kapalı durur.
    @ViewBuilder
    var toolDecisionLogCard: some View {
        collapsibleSettingsCard(
            title: "Recent tool activity",
            subtitle: "Observed executions and permission decisions are recorded separately, newest first.",
            icon: "list.bullet.rectangle",
            isExpanded: $isToolDecisionLogExpanded,
            trailingText: recentDecisions.isEmpty && recentExecutions.isEmpty
                ? nil : "\(recentDecisions.count + recentExecutions.count)"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Observed executions")
                    .font(.system(size: 12, weight: .semibold))
                if recentExecutions.isEmpty {
                    Text("No tool execution has been observed yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recentExecutions.reversed()) { record in
                        toolExecutionRow(record)
                    }
                }

                Divider().opacity(0.3)
                Text("Permission decisions")
                    .font(.system(size: 12, weight: .semibold))
                if recentDecisions.isEmpty {
                    Text("No permission decisions have been recorded yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recentDecisions.reversed()) { record in
                        toolDecisionRow(record)
                    }
                }

                HStack(spacing: 10) {
                    secondaryActionButton(
                        title: "Refresh",
                        icon: "arrow.clockwise"
                    ) {
                        Task { await reloadRecentToolActivity() }
                    }

                    secondaryActionButton(
                        title: "Reveal audit log",
                        icon: "folder"
                    ) {
                        NSWorkspace.shared.activateFileViewerSelecting([toolAuditLogURL])
                    }
                }
            }
        }
        // Kart kapalıyken de başlıktaki sayı güncel kalsın diye kuyruk kart
        // görünür olduğunda okunur; satırlar yalnız açılınca kurulur.
        .task { await reloadRecentToolActivity() }
    }

    @ViewBuilder
    private func toolDecisionRow(_ record: ToolAuditLog.Record) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(toolDecisionTint(record.reply))
                    .frame(width: 6, height: 6)

                Text(record.title)
                    .font(.system(size: 12, weight: .semibold))

                Text(record.reply.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(toolDecisionTint(record.reply))

                Spacer(minLength: 8)

                Text(record.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Text(
                record.patterns.isEmpty
                    ? "\(record.source.label) · \(record.toolName)"
                    : "\(record.source.label) · \(record.patterns.joined(separator: ", "))"
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func toolExecutionRow(_ record: ToolAuditLog.ExecutionRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(record.event == .failed ? Color.red : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(record.title ?? record.toolKind.rawValue.capitalized)
                    .font(.system(size: 12, weight: .semibold))
                Text(record.event.rawValue.capitalized)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(record.event == .failed ? .red : .secondary)
                Spacer(minLength: 8)
                Text(record.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(record.detail ?? record.toolKind.rawValue)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toolDecisionTint(_ reply: ProviderPermissionReply) -> Color {
        switch reply {
        case .once, .always:
            return .green
        case .reject:
            return .red
        }
    }

    private var policyConfigurationURL: URL {
        ManagedAppDirectories.openCodeWorkingDirectory()
            .appendingPathComponent(ManagedOpenCodeConfiguration.fileName)
    }

    private var toolAuditLogURL: URL {
        ManagedAppDirectories.openCodeWorkingDirectory()
            .appendingPathComponent("audit.jsonl")
    }

    private func reloadRecentToolActivity() async {
        recentDecisions = await permissionApprovalCenter.recentDecisions(limit: 20)
        recentExecutions = await permissionApprovalCenter.recentExecutions(limit: 20)
    }

    @ViewBuilder
    private func toolApprovalRow(_ policy: ToolApprovalPolicy) -> some View {
        let isSelected = settingsStore.toolApprovalPolicy == policy
        let accent = currentTheme.accentGradient.first ?? .accentColor

        Button {
            guard settingsStore.toolApprovalPolicy != policy else {
                return
            }
            settingsStore.toolApprovalPolicy = policy
            // The prompts already on screen were asked under the previous level.
            permissionApprovalCenter.reinterpretPendingRequests()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: policy.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        policy.isUnrestricted
                            ? Color.orange
                            : (isSelected ? accent : .secondary)
                    )
                    .frame(width: 18)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(policy.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(policy.isUnrestricted ? Color.orange : .primary)

                    Text(policy.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accent)
                        .padding(.top, 2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(isSelected ? 0.06 : 0.02),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        isSelected
                            ? (policy.isUnrestricted ? Color.orange : accent).opacity(0.55)
                            : currentTheme.border(isDark: isDarkMode).opacity(0.6),
                        lineWidth: isSelected ? 1.2 : 1
                    )
            )
            .contentShape(Rectangle())
            .interactiveHoverOutline(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(policy.displayName). \(policy.summary)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    var aiTabContent: some View {
        @Bindable var openAI = openAICredentialSettings
        @Bindable var openCode = openCodeSettings

        providerCard

        toolApprovalCard

        toolDecisionLogCard

        // OpenAI Configuration
        settingsCard(
            title: "OpenAI Configuration",
            subtitle: "Manage your direct OpenAI API credentials securely stored in macOS Keychain.",
            icon: "key.fill"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle()
                        .fill(openAICredentialSettings.hasStoredCredential ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)

                    Text(
                        openAICredentialSettings.hasStoredCredential
                            ? "API key configured in Keychain"
                            : "No API key configured"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(openAICredentialSettings.hasStoredCredential ? .green : .secondary)

                    Spacer()
                }

                SecureField("Enter OpenAI API key (sk-...)", text: $openAI.apiKeyDraft)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        currentTheme.background(isDark: isDarkMode)
                            .opacity(settingsStore.glassOpacity),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(
                                currentTheme.border(isDark: isDarkMode)
                                    .opacity(settingsStore.contrast),
                                lineWidth: 1
                            )
                    )

                HStack(spacing: 10) {
                    primaryActionButton(
                        title: "Save API Key",
                        icon: "checkmark",
                        isDisabled: openAICredentialSettings.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        if openAICredentialSettings.save() {
                            onOpenAICredentialChange()
                        }
                    }

                    destructiveActionButton(
                        title: "Delete Key",
                        icon: "trash",
                        isDisabled: !openAICredentialSettings.hasStoredCredential
                    ) {
                        if openAICredentialSettings.delete() {
                            onOpenAICredentialChange()
                        }
                    }
                }

                if let errorMessage = openAICredentialSettings.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Text("Your API key is stored securely in macOS Keychain and is never synced or logged.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        // OpenCode Configuration
        settingsCard(
            title: "OpenCode Engine",
            subtitle: "Local tool orchestration, coding subagents, and filesystem inspection server.",
            icon: "terminal.fill"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Circle()
                        .fill(isOpenCodeRunning ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)

                    Text(openCodeStatusText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if isOpenCodeRunning {
                        destructiveActionButton(
                            title: "Stop OpenCode",
                            icon: "stop.fill",
                            isDisabled: false
                        ) {
                            Task {
                                await openCodeSettings.stop()
                                onOpenCodeChange()
                            }
                        }
                    } else {
                        primaryActionButton(
                            title: "Start OpenCode",
                            icon: "play.fill",
                            isDisabled: !openCodeSettings.isInstalled
                        ) {
                            Task {
                                if await openCodeSettings.start() {
                                    onOpenCodeChange()
                                }
                            }
                        }
                    }
                }

                if isOpenCodeRunning {
                    Divider().opacity(0.3)

                    if !openCodeSettings.apiProviderIDs.isEmpty {
                        Picker("Provider credential", selection: providerSelection) {
                            ForEach(openCodeSettings.apiProviderIDs, id: \.self) { providerID in
                                Text(providerID).tag(providerID)
                            }
                        }

                        if openCodeSettings.selectedAPIMethods.count > 1 {
                            Picker("Authentication method", selection: methodSelection) {
                                ForEach(
                                    Array(openCodeSettings.selectedAPIMethods.enumerated()),
                                    id: \.offset
                                ) { index, method in
                                    Text(method.label).tag(index)
                                }
                            }
                        } else if let method = openCodeSettings.selectedAPIMethod {
                            LabeledContent("Authentication method", value: method.label)
                        }

                        ForEach(openCodeSettings.activePrompts, id: \.key) { prompt in
                            metadataControl(for: prompt)
                        }

                        SecureField("Provider API key", text: $openCode.apiKeyDraft)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                currentTheme.background(isDark: isDarkMode)
                                    .opacity(settingsStore.glassOpacity),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(
                                        currentTheme.border(isDark: isDarkMode)
                                            .opacity(settingsStore.contrast),
                                        lineWidth: 1
                                    )
                            )

                        primaryActionButton(
                            title: "Save Provider Credential",
                            icon: "checkmark",
                            isDisabled: openCodeSettings.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ) {
                            Task {
                                if await openCodeSettings.saveAPIKey() {
                                    onOpenCodeChange()
                                }
                            }
                        }

                        Text("Provider credentials are sent to the local OpenCode server and are not persisted by AgenticSidebar.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No API-key authentication methods are advertised by this OpenCode installation.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if !oauthProviderIDs.isEmpty {
                        Text("OAuth sign-in is available for \(oauthProviderIDs.joined(separator: ", ")), but browser OAuth setup is not implemented in this milestone.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage = openCodeSettings.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    func metadataControl(for prompt: OpenCodeAuthPrompt) -> some View {
        switch prompt.type {
        case .text:
            TextField(
                prompt.message,
                text: metadataBinding(for: prompt.key),
                prompt: prompt.placeholder.map(Text.init)
            )
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                currentTheme.background(isDark: isDarkMode)
                    .opacity(settingsStore.glassOpacity),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        currentTheme.border(isDark: isDarkMode)
                            .opacity(settingsStore.contrast),
                        lineWidth: 1
                    )
            )

        case .select:
            Picker(
                prompt.message,
                selection: metadataBinding(for: prompt.key)
            ) {
                ForEach(prompt.options ?? [], id: \.value) { option in
                    Text(option.hint.map { "\(option.label) — \($0)" } ?? option.label)
                        .tag(option.value)
                }
            }
        }
    }

    var providerSelection: Binding<String> {
        Binding(
            get: { openCodeSettings.selectedProviderID ?? "" },
            set: { openCodeSettings.selectProvider($0) }
        )
    }

    var methodSelection: Binding<Int> {
        Binding(
            get: { openCodeSettings.selectedMethodIndex },
            set: { openCodeSettings.selectMethod(index: $0) }
        )
    }

    func metadataBinding(for key: String) -> Binding<String> {
        Binding(
            get: { openCodeSettings.metadataDrafts[key] ?? "" },
            set: { openCodeSettings.metadataDrafts[key] = $0 }
        )
    }

    var isOpenCodeRunning: Bool {
        if case .running = openCodeSettings.serverStatus {
            return true
        }
        return false
    }

    var openCodeStatusText: String {
        switch openCodeSettings.serverStatus {
        case .stopped:
            openCodeSettings.isInstalled
                ? "Installed — server stopped"
                : "OpenCode executable not found"
        case .starting:
            "Starting local server…"
        case let .running(version, _):
            "Running OpenCode \(version) on authenticated loopback"
        }
    }

    var oauthProviderIDs: [String] {
        openCodeSettings.authMethods
            .filter { _, methods in methods.contains(where: { $0.type == .oauth }) }
            .map(\.key)
            .sorted()
    }
}
