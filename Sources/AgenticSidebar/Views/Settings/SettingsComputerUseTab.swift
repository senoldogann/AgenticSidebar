import AppKit
import SwiftUI

// MARK: - Computer Use Tab

extension SettingsView {
    @ViewBuilder
    var computerUseTabContent: some View {
        computerUseOverviewCard
        computerUsePermissionsCard
        computerUseSetupCard
        computerUseSafetyCard
    }

    // MARK: Overview

    @ViewBuilder
    private var computerUseOverviewCard: some View {
        @Bindable var settings = settingsStore

        settingsCard(
            title: "Computer Use (chatgpt-system)",
            subtitle: "Observe and control this Mac through the local chatgpt-system MCP server.",
            icon: "cursorarrow.rays"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable Computer Use", isOn: $settings.computerUseEnabled)
                    .tint(currentTheme.accentGradient.first ?? .accentColor)

                computerUseReadinessBanner

                Text("The managed OpenCode server registers `chatgpt-system` as a local MCP server. computer_* tools observe the screen (accessibility tree + screenshots) and post pointer/keyboard input. Every action asks for your approval first; authority is an Admin lease with a one-hour maximum that the agent must renew.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                computerUseApprovalsBlock
                computerUseFolderRow

                Divider()

                computerUseStatusRow(
                    symbol: "shippingbox.fill",
                    title: "Node.js",
                    detail: nodeStatusDetail,
                    isHealthy: nodeStatusHealthy
                )

                computerUseStatusRow(
                    symbol: "doc.text.fill",
                    title: "dist/cli.js",
                    detail: cliStatusDetail,
                    isHealthy: cliStatusHealthy
                )

                computerUseStatusRow(
                    symbol: "lock.shield.fill",
                    title: "Computer Runtime helper",
                    detail: helperStatusDetail,
                    isHealthy: helperStatusHealthy
                )

                computerUseStatusRow(
                    symbol: "server.rack",
                    title: "OpenCode server",
                    detail: openCodeServerDetail,
                    isHealthy: isOpenCodeServerRunning
                )

                computerUseStatusRow(
                    symbol: "point.3.connected.trianglepath.dotted",
                    title: "MCP registration",
                    detail: computerUseRegistrationDetail,
                    isHealthy: openCodeSettings.computerUseRegistration == .registered
                )

                if computerUseNeedsRestart {
                    HStack(spacing: 10) {
                        Text("The setting changed after the server started; restart it to apply.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 8)

                        primaryActionButton(
                            title: "Restart OpenCode",
                            icon: "arrow.clockwise",
                            isDisabled: false
                        ) {
                            Task {
                                await openCodeSettings.restart()
                                onOpenCodeChange()
                                await refreshComputerUseReadiness()
                            }
                        }
                    }
                } else if case .failed(let message) = openCodeSettings.computerUseRegistration {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task {
            await refreshComputerUseReadiness()
        }
        // Turning the switch changes what has to be checked: off means nothing
        // is registered and nothing needs asking.
        .onChange(of: settings.computerUseEnabled) { _, _ in
            Task {
                await refreshComputerUseReadiness()
            }
        }
    }

    /// The one line the reader came for: can the agent act, and if not, why not.
    @ViewBuilder
    private var computerUseReadinessBanner: some View {
        let presentation = readinessPresentation

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: presentation.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(presentation.tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(presentation.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if computerUseStatus.isChecking {
                ProgressView()
                    .controlSize(.small)
            } else {
                secondaryActionButton(title: "Re-check", icon: "arrow.clockwise") {
                    Task {
                        await refreshComputerUseReadiness()
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            presentation.tint.opacity(isDarkMode ? 0.14 : 0.10),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(presentation.tint.opacity(0.28), lineWidth: 1)
        )
    }

    private var readinessPresentation: (
        title: String,
        detail: String,
        symbol: String,
        tint: Color
    ) {
        guard let readiness = computerUseStatus.readiness else {
            return (
                "Checking…",
                "Looking for the folder, the helper and the permissions macOS has granted it.",
                "clock",
                .secondary
            )
        }

        switch readiness.state {
        case .disabled:
            return (
                "Turned off",
                "Nothing is registered and no computer server runs. Turn the switch on and restart OpenCode.",
                "pause.circle.fill",
                .secondary
            )
        case .misconfigured(let message):
            return (
                "Setup is not finished",
                "\(message) Fix the folder below, then re-check.",
                "exclamationmark.triangle.fill",
                .orange
            )
        case .helperMissing:
            return (
                "The signed helper is not installed",
                "Without it every computer action fails. Run “Install the signed helper” below.",
                "exclamationmark.triangle.fill",
                .orange
            )
        case .permissionsUnknown:
            return (
                "The helper did not answer",
                "It is installed but did not reply to a permission check, so its grants cannot be read. Re-run the install step if this repeats.",
                "questionmark.circle.fill",
                .orange
            )
        case .missingPermissions(let missing):
            return (
                "macOS permissions missing",
                missingPermissionsDetail(missing),
                "exclamationmark.triangle.fill",
                .orange
            )
        case .ready:
            return (
                "Ready",
                "Node, the CLI, the signed helper and all four grants are in place"
                    + (readiness.permissionsSurviveRebuildDescription),
                "checkmark.circle.fill",
                .green
            )
        }
    }

    @ViewBuilder
    private var computerUseApprovalsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Approvals")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)

                Text(settingsStore.toolApprovalPolicy.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(
                        settingsStore.toolApprovalPolicy.isUnrestricted
                            ? .orange
                            : .primary
                    )

                Text("— set in AI & Models for every tool, not just this one")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("Computer use keeps its own limits at every level: only computer_* and session_authority_* tools are exposed, and the authority lease is always yours to approve unless you chose Full access.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var computerUseFolderRow: some View {
        @Bindable var settings = settingsStore

        HStack(spacing: 8) {
            Text("Folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            TextField("~/Desktop/chatgpt-system", text: $settings.chatgptSystemRootPath)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11.5, design: .monospaced))
            .onSubmit {
                Task {
                    await refreshComputerUseReadiness()
                }
            }

            secondaryActionButton(title: "Choose…", icon: "folder") {
                chooseComputerUseFolder()
            }
        }
    }

    private func chooseComputerUseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Use this folder"
        panel.message = "Select the chatgpt-system checkout that contains dist/cli.js"

        if case .ready(let configuration) = computerUseStatus.readiness?.decision {
            panel.directoryURL = configuration.projectRootURL
        }

        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            settingsStore.chatgptSystemRootPath = url.path
            Task {
                await refreshComputerUseReadiness()
            }
        }
    }

    // MARK: Permissions

    @ViewBuilder
    private var computerUsePermissionsCard: some View {
        settingsCard(
            title: "macOS permissions",
            subtitle: "Each grant is held by the process macOS asks for it: Screen Recording by this app, the rest by the signed helper.",
            icon: "hand.raised.fill"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let readiness = computerUseStatus.readiness, readiness.permissions != nil {
                    ForEach(ComputerUsePermission.allCases, id: \.self) { permission in
                        computerUsePermissionRow(
                            permission: permission,
                            isGranted: readiness.isGranted(permission)
                        )
                    }

                    if !readiness.missingPermissions.isEmpty {
                        if readiness.missingAppPermissions.contains(.screenRecording) {
                            // The one sentence that saves an hour: the helper's own
                            // Screen Recording switch is real, on, and never
                            // consulted, because macOS asks the process that
                            // launched it.
                            Text("Screen Recording is enforced on the process that launches the helper, so macOS asks this app — not the helper — for it. A switched-on **ChatGPTSystemComputerRuntime** row in that list has no effect on its own.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: 8) {
                            secondaryActionButton(title: "Reveal helper in Finder", icon: "folder") {
                                computerUseStatus.revealHelper()
                            }

                            Text("If a list has no entry yet, add it with the “+” button — drag the revealed app in.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else if computerUseStatus.readiness == nil {
                    Text("Checking the helper's permissions…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.top, 1)

                        Text("The helper could not be asked what macOS has granted it. Install it with the step below; the check runs again by itself afterwards.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func computerUsePermissionRow(
        permission: ComputerUsePermission,
        isGranted: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isGranted ? Color.green : Color.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(permissionRowDetail(permission, isGranted: isGranted))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !isGranted, permission.subject == .app {
                // Only Screen Recording can be requested from here: macOS adds an
                // app to the list when it asks, which is what makes the switch
                // findable without a scavenger hunt through System Settings.
                if computerUseStatus.isRequestingScreenRecording {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    primaryActionButton(
                        title: "Grant Screen Recording…",
                        icon: "hand.raised.fill",
                        isDisabled: false
                    ) {
                        computerUseStatus.requestScreenRecording()
                    }

                    secondaryActionButton(
                        title: "Open \(permission.settingsPane.title)",
                        icon: "arrow.up.forward.app"
                    ) {
                        computerUseStatus.openSettingsPane(permission.settingsPane)
                    }
                }
            } else if !isGranted {
                secondaryActionButton(
                    title: "Open \(permission.settingsPane.title)",
                    icon: "arrow.up.forward.app"
                ) {
                    computerUseStatus.openSettingsPane(permission.settingsPane)
                }
            }
        }
    }

    private func permissionRowDetail(
        _ permission: ComputerUsePermission,
        isGranted: Bool
    ) -> String {
        let owner = permission.subject == .app ? "this app" : "the helper"
        guard !isGranted else {
            return "Granted to \(owner)"
        }

        var detail = "Missing — \(permission.consequence). macOS asks \(owner)."
        if permission.subject == .app {
            // macOS caches this one for the life of the process, so a switch that
            // is already on can still read as missing until the app is reopened.
            detail += " If the switch is already on, quit and reopen this app."
        }
        return detail
    }

    /// Says who owes what, because "enable the helper" would send the user to a
    /// switch that cannot fix Screen Recording.
    private func missingPermissionsDetail(_ missing: [ComputerUsePermission]) -> String {
        let appOwned = missing.filter { $0.subject == .app }.map(\.title)
        let helperOwned = missing.filter { $0.subject == .helper }.map(\.title)

        var parts: [String] = []
        if !appOwned.isEmpty {
            parts.append(
                "This app needs \(appOwned.joined(separator: ", ")) — macOS enforces it on whatever launched the helper."
            )
        }
        if !helperOwned.isEmpty {
            parts.append("The helper needs \(helperOwned.joined(separator: ", ")).")
        }
        parts.append("Use the buttons below; macOS only accepts these grants while the app is running.")
        return parts.joined(separator: " ")
    }

    // MARK: Setup

    @ViewBuilder
    private var computerUseSetupCard: some View {
        settingsCard(
            title: "Setup",
            subtitle: "Runs in the folder above. Nothing is written into the chatgpt-system repository.",
            icon: "wrench.and.screwdriver.fill"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(ComputerUseSetupStep.allCases) { step in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(step.title)
                                .font(.system(size: 11.5, weight: .semibold))

                            if step.isSlow {
                                Text("slow")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        Color.secondary.opacity(0.15),
                                        in: Capsule(style: .continuous)
                                    )
                            }

                            Spacer(minLength: 8)

                            secondaryActionButton(
                                title: "Copy",
                                icon: "doc.on.doc",
                                isDisabled: computerUseStatus.isRunningSetup
                            ) {
                                computerUseStatus.copySetupCommand(
                                    for: step,
                                    rootPath: settingsStore.chatgptSystemRootPath
                                )
                            }

                            secondaryActionButton(
                                title: "Run",
                                icon: "play.fill",
                                isDisabled: computerUseStatus.isRunningSetup
                            ) {
                                computerUseStatus.runSetup(step)
                            }
                        }

                        Text(step.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("cd \(settingsStore.chatgptSystemRootPath) && \(step.command)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let run = computerUseStatus.setupRun {
                    Divider()
                    computerUseSetupLog(run)
                }

                Text("After either step, restart OpenCode from the card above so the running server picks up the new state.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func computerUseSetupLog(_ run: ComputerUseStatus.SetupRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if run.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("\(run.step.title)…")
                        .font(.system(size: 11.5, weight: .semibold))
                } else if let outcome = run.outcome {
                    Image(systemName: outcome.didSucceed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(outcome.didSucceed ? Color.green : Color.orange)
                    Text(outcomeText(outcome))
                        .font(.system(size: 11.5, weight: .semibold))
                }

                Spacer(minLength: 8)

                if run.isRunning {
                    secondaryActionButton(title: "Cancel", icon: "stop.fill") {
                        computerUseStatus.cancelSetup()
                    }
                }
            }

            if !run.output.isEmpty {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(run.output.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 180)
                .background(
                    currentTheme.surface(isDark: isDarkMode),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
            }
        }
    }

    private func outcomeText(_ outcome: ComputerUseSetupOutcome) -> String {
        if outcome.didCancel {
            return "Cancelled"
        }
        if !outcome.didLaunch {
            return "Could not start npm — is Node.js installed and on PATH?"
        }
        if outcome.exitCode == 0 {
            return "Finished"
        }
        return "Exited with status \(outcome.exitCode)"
    }

    // MARK: Safety

    @ViewBuilder
    private var computerUseSafetyCard: some View {
        settingsCard(
            title: "Safety",
            subtitle: "What this integration deliberately does not do.",
            icon: "exclamationmark.shield.fill"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                computerUseSafetyBullet("Only computer_* and session_authority_* tools are exposed; filesystem, git, terminal and browser tools of the MCP server are denied by policy.")
                computerUseSafetyBullet("Full-host JavaScript (computer_run_js) stays disabled; the server is started with --personal-admin and --enable-computer-use only.")
                computerUseSafetyBullet(approvalSafetyText)
                computerUseSafetyBullet("The permission check spawns the signed helper for one health question and nothing else; it performs no action and reads no screen content.")
                computerUseSafetyBullet("Screen Recording is the one grant macOS enforces on this app rather than on the helper, because tccd attributes it to the process that launched the helper. Nothing is captured by the check itself.")
                computerUseSafetyBullet("The setup buttons run `npm run build` and `npm run setup:computer:macos` in the folder above, through `env`, never a shell — no other command can be run from here.")
                computerUseSafetyBullet("chatgpt-system writes its own redacted audit log at ~/.chatgpt-system/audit.jsonl.")
                computerUseSafetyBullet("The setup files live in AgenticSidebar's Application Support folder; your opencode.json is never modified.")
            }
        }
    }

    /// Güvenlik kartındaki onay metni seçilen politikayı yansıtır.
    private var approvalSafetyText: String {
        switch settingsStore.toolApprovalPolicy {
        case .ask:
            "Every computer action and every authority request is approved by you; the running OpenCode turn waits for that decision."
        case .approveSafe:
            "Screen observation runs unattended; anything that moves the pointer, types, presses a key, runs a program or mints the Admin authority lease waits for you."
        case .fullAccess:
            "Full access is on: computer actions and the authority lease run unattended without any approval. Switch the level in AI & Models to bring the prompts back."
        }
    }

    // MARK: Shared rows

    private var isOpenCodeServerRunning: Bool {
        if case .running = openCodeSettings.serverStatus {
            return true
        }
        return false
    }

    private var openCodeServerDetail: String {
        switch openCodeSettings.serverStatus {
        case .stopped:
            "Stopped"
        case .starting:
            "Starting…"
        case .running(let version, _):
            "Running · OpenCode \(version)"
        }
    }

    private var computerUseRegistrationDetail: String {
        switch openCodeSettings.computerUseRegistration {
        case .serverStopped:
            "Server stopped"
        case .disabled:
            settingsStore.computerUseEnabled ? "Not registered" : "Disabled"
        case .registered:
            "Connected"
        case .failed(let message):
            message
        }
    }

    private var computerUseNeedsRestart: Bool {
        guard isOpenCodeServerRunning else {
            return false
        }

        // İzin seviyesi burada sayılmaz: her istekte okunur, o yüzden bir
        // seviye değişikliği çalışan sunucuda yeniden başlatma gerektirmez.
        return settingsStore.computerUseEnabled != openCodeSettings.runningComputerUseEnabled
    }

    private var nodeStatusDetail: String {
        guard let readiness = computerUseStatus.readiness else {
            return "Checking…"
        }

        switch readiness.decision {
        case .disabled:
            return ComputerUseConfiguration.locateNode(
                environment: ProcessInfo.processInfo.environment,
                fileManager: .default,
                candidatePaths: ComputerUseConfiguration.nodeExecutableCandidates
            )?.path ?? "Not found"
        case .invalid(let message):
            return message.contains("Node.js") ? message : "Found"
        case .ready(let configuration):
            return configuration.nodeExecutableURL.path
        }
    }

    private var nodeStatusHealthy: Bool {
        guard let readiness = computerUseStatus.readiness else {
            return true
        }

        switch readiness.decision {
        case .disabled:
            return ComputerUseConfiguration.locateNode(
                environment: ProcessInfo.processInfo.environment,
                fileManager: .default,
                candidatePaths: ComputerUseConfiguration.nodeExecutableCandidates
            ) != nil
        case .invalid(let message):
            return !message.contains("Node.js")
        case .ready:
            return true
        }
    }

    private var cliStatusDetail: String {
        guard let readiness = computerUseStatus.readiness else {
            return "Checking…"
        }

        switch readiness.decision {
        case .disabled:
            return "Not checked until the folder is set"
        case .invalid(let message):
            return message.contains("Node.js") ? "dist/cli.js" : message
        case .ready(let configuration):
            return configuration.cliURL.path
        }
    }

    private var cliStatusHealthy: Bool {
        guard let readiness = computerUseStatus.readiness else {
            return true
        }

        switch readiness.decision {
        case .disabled:
            return true
        case .invalid(let message):
            return message.contains("Node.js")
        case .ready:
            return true
        }
    }

    private var helperStatusDetail: String {
        guard let helper = computerUseStatus.readiness?.helper else {
            return "Checking…"
        }
        guard helper.isInstalled else {
            return "Missing at \(helper.bundleURL.path). Run “Install the signed helper” below."
        }

        var detail = helper.bundleURL.path
        if !helper.bundleIdentifierMatches {
            detail += " · unexpected bundle identifier"
        }
        if helper.isAdHocSigned {
            detail += " · ad-hoc signature: grants must be given again after every rebuild"
        } else if let identity = helper.signingIdentity {
            detail += " · \(identity)"
        }
        return detail
    }

    private var helperStatusHealthy: Bool {
        guard let helper = computerUseStatus.readiness?.helper else {
            return true
        }
        return helper.isInstalled && helper.bundleIdentifierMatches
    }

    @ViewBuilder
    private func computerUseStatusRow(
        symbol: String,
        title: String,
        detail: String,
        isHealthy: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHealthy ? Color.green : Color.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func computerUseSafetyBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(currentTheme.accentGradient.first ?? .secondary)
                .padding(.top, 6)

            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One refresh for the whole card: the helper's own answer plus the MCP
    /// registration the server reports.
    func refreshComputerUseReadiness() async {
        await openCodeSettings.refreshComputerUseStatus()
        await computerUseStatus.refresh(
            isEnabled: settingsStore.computerUseEnabled,
            rootPath: settingsStore.chatgptSystemRootPath
        )
    }
}

extension ComputerUseReadiness {
    /// Appended to the green line so the user knows whether their two switches
    /// will still be there after the next `npm run setup:computer:macos`.
    var permissionsSurviveRebuildDescription: String {
        if keepsPermissionsAcrossRebuilds {
            return "; the helper is signed, so a rebuild keeps them."
        }
        return "; the helper is ad-hoc signed, so a rebuild asks for them again."
    }
}
