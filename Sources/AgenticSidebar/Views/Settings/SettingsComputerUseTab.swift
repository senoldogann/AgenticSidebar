import AppKit
import SwiftUI

// MARK: - Computer Use Tab

extension SettingsView {
    @ViewBuilder
    var computerUseTabContent: some View {
        @Bindable var settings = settingsStore
        let decision = computerUseDecision
        let helperURL = ComputerUseConfiguration.helperBundleURL(
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )
        let helperInstalled = FileManager.default.fileExists(atPath: helperURL.path)

        settingsCard(
            title: "Computer Use (chatgpt-system)",
            subtitle: "Observe and control this Mac through the local chatgpt-system MCP server.",
            icon: "cursorarrow.rays"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable Computer Use", isOn: $settings.computerUseEnabled)
                    .tint(currentTheme.accentGradient.first ?? .accentColor)

                Text("The managed OpenCode server registers `chatgpt-system` as a local MCP server. computer_* tools observe the screen (accessibility tree + screenshots) and post pointer/keyboard input. Every action asks for your approval first; authority is an Admin lease with a one-hour maximum that the agent must renew.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

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

                    Text(settingsStore.toolApprovalPolicy.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Computer use keeps its own limits at every level: only computer_* and session_authority_* tools are exposed, and the authority lease is always yours to approve unless you chose Full access.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Text("Folder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)

                    TextField("~/Desktop/chatgpt-system", text: $settings.chatgptSystemRootPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                }

                computerUseStatusRow(
                    symbol: "shippingbox.fill",
                    title: "Node.js",
                    detail: nodeStatusDetail(for: decision),
                    isHealthy: nodeStatusHealthy(for: decision)
                )

                computerUseStatusRow(
                    symbol: "doc.text.fill",
                    title: "dist/cli.js",
                    detail: cliStatusDetail(for: decision),
                    isHealthy: cliStatusHealthy(for: decision)
                )

                computerUseStatusRow(
                    symbol: "lock.shield.fill",
                    title: "Computer Runtime helper",
                    detail: helperInstalled
                        ? helperURL.path
                        : "Missing. Run `npm run setup:computer:macos` in the chatgpt-system folder.",
                    isHealthy: helperInstalled
                )

                Divider()

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
            await openCodeSettings.refreshComputerUseStatus()
        }

        settingsCard(
            title: "Setup",
            subtitle: "One-time steps outside this app; nothing is written into the chatgpt-system repository.",
            icon: "wrench.and.screwdriver.fill"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("1. Build and install the signed helper (macOS asks for Accessibility and Screen Recording permission afterwards):")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Text("cd \(settingsStore.chatgptSystemRootPath) && npm run setup:computer:macos")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            currentTheme.surface(isDark: isDarkMode),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            "cd \(settingsStore.chatgptSystemRootPath) && npm run setup:computer:macos",
                            forType: .string
                        )
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Copy the setup command")
                }

                Text("2. Ask the agent to run `computer_health`; it reports whether Accessibility, Screen Recording and input monitoring are granted. Grant them to ChatGPTSystemComputerRuntime in System Settings → Privacy & Security.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        settingsCard(
            title: "Safety",
            subtitle: "What this integration deliberately does not do.",
            icon: "exclamationmark.shield.fill"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                computerUseSafetyBullet("Only computer_* and session_authority_* tools are exposed; filesystem, git, terminal and browser tools of the MCP server are denied by policy.")
                computerUseSafetyBullet("Full-host JavaScript (computer_run_js) stays disabled; the server is started with --personal-admin and --enable-computer-use only.")
                computerUseSafetyBullet(approvalSafetyText)
                computerUseSafetyBullet("chatgpt-system writes its own redacted audit log at ~/.chatgpt-system/audit.jsonl.")
                computerUseSafetyBullet("The setup files live in AgenticSidebar's Application Support folder; your opencode.json is never modified.")
            }
        }
    }

    private var computerUseDecision: ComputerUseLaunchDecision {
        ComputerUseConfiguration.decision(
            enabled: settingsStore.computerUseEnabled,
            rootPath: settingsStore.chatgptSystemRootPath,
            workingDirectoryURL: ManagedOpenCodeServerManager.managedWorkingDirectoryURL(),
            environment: ProcessInfo.processInfo.environment,
            fileManager: .default
        )
    }

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

    private func nodeStatusDetail(for decision: ComputerUseLaunchDecision) -> String {
        switch decision {
        case .disabled:
            ComputerUseConfiguration.locateNode(
                environment: ProcessInfo.processInfo.environment,
                fileManager: .default,
                candidatePaths: ComputerUseConfiguration.nodeExecutableCandidates
            )?.path ?? "Not found"
        case .invalid(let message):
            message.contains("Node.js") ? message : "Found"
        case .ready(let configuration):
            configuration.nodeExecutableURL.path
        }
    }

    private func nodeStatusHealthy(for decision: ComputerUseLaunchDecision) -> Bool {
        if case .disabled = decision {
            return ComputerUseConfiguration.locateNode(
                environment: ProcessInfo.processInfo.environment,
                fileManager: .default,
                candidatePaths: ComputerUseConfiguration.nodeExecutableCandidates
            ) != nil
        }
        if case .invalid(let message) = decision, message.contains("Node.js") {
            return false
        }
        return true
    }

    private func cliStatusDetail(for decision: ComputerUseLaunchDecision) -> String {
        switch decision {
        case .disabled:
            "Not checked until the folder is set"
        case .invalid(let message):
            message.contains("Node.js") ? "dist/cli.js" : message
        case .ready(let configuration):
            configuration.cliURL.path
        }
    }

    private func cliStatusHealthy(for decision: ComputerUseLaunchDecision) -> Bool {
        switch decision {
        case .disabled:
            true
        case .invalid(let message):
            message.contains("Node.js")
        case .ready:
            true
        }
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
}
