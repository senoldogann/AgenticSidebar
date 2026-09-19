import AppKit
import Foundation
import Observation

/// The Computer Use card's view model: what the app can prove about the
/// integration, and the two setup commands it can run for the user.
///
/// It rebuilds readiness from scratch on every refresh — the folder, the helper
/// on disk and the grants the helper holds are all things the user can change
/// outside the app while the settings window is open.
@MainActor
@Observable
final class ComputerUseStatus {
    /// A running or finished setup command and the tail of its output.
    struct SetupRun: Equatable, Sendable {
        var step: ComputerUseSetupStep
        var output: [String]
        var isRunning: Bool
        var outcome: ComputerUseSetupOutcome?

        /// Newest last, trimmed: the tail is what says whether it worked.
        static let outputLineLimit = 120

        mutating func append(_ line: String) {
            output.append(line)
            if output.count > Self.outputLineLimit {
                output.removeFirst(output.count - Self.outputLineLimit)
            }
        }
    }

    private(set) var readiness: ComputerUseReadiness?
    private(set) var isChecking = false
    private(set) var setupRun: SetupRun?
    /// True while macOS is being asked for Screen Recording, so the button can
    /// show that the prompt is on screen rather than looking dead.
    private(set) var isRequestingScreenRecording = false

    @ObservationIgnored
    private let permissionProbe: any ComputerUsePermissionProbing

    @ObservationIgnored
    private let appPermissionReader: any ComputerUseAppPermissionReading

    @ObservationIgnored
    private let signatureReader: any ComputerUseSignatureReading

    @ObservationIgnored
    private let setupRunner: any ComputerUseSetupRunning

    @ObservationIgnored
    private let fileManager: FileManager

    @ObservationIgnored
    private let homeDirectoryURL: URL

    @ObservationIgnored
    private let environment: [String: String]

    @ObservationIgnored
    private let permissionProbeTimeout: Duration

    /// The parameters of the last refresh, so a finished setup can re-check
    /// without the view having to hand them over again.
    @ObservationIgnored
    private var lastRequest: Request?

    /// A refresh asked for while one was already running. Dropped silently
    /// before; now coalesced so the card never shows a stale answer when the
    /// user toggles twice in a row.
    @ObservationIgnored
    private var pendingRefresh: Request?

    private struct Request: Equatable {
        var isEnabled: Bool
        var rootPath: String
    }

    init(
        permissionProbe: any ComputerUsePermissionProbing = ComputerUseHelperProbe(),
        appPermissionReader: any ComputerUseAppPermissionReading = SystemComputerUseAppPermissionReader(),
        signatureReader: any ComputerUseSignatureReading = SystemComputerUseSignatureReader(),
        setupRunner: any ComputerUseSetupRunning = SystemComputerUseSetupRunner(),
        fileManager: FileManager = .default,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        permissionProbeTimeout: Duration = .seconds(6)
    ) {
        self.permissionProbe = permissionProbe
        self.appPermissionReader = appPermissionReader
        self.signatureReader = signatureReader
        self.setupRunner = setupRunner
        self.fileManager = fileManager
        self.homeDirectoryURL = homeDirectoryURL
        self.environment = environment
        self.permissionProbeTimeout = permissionProbeTimeout
    }

    var isRunningSetup: Bool {
        setupRun?.isRunning == true
    }

    var setupInFlight: ComputerUseSetupStep? {
        guard let setupRun, setupRun.isRunning else {
            return nil
        }
        return setupRun.step
    }

    // MARK: - Checking

    /// Resolves the configuration, inspects the installed helper and asks it
    /// what macOS has granted it.
    func refresh(isEnabled: Bool, rootPath: String) async {
        let request = Request(isEnabled: isEnabled, rootPath: rootPath)
        lastRequest = request

        guard !isChecking else {
            pendingRefresh = request
            return
        }
        isChecking = true
        defer { isChecking = false }

        var current = request
        while true {
            await performRefresh(request: current)
            guard let pending = pendingRefresh else {
                return
            }
            pendingRefresh = nil
            guard pending != current else {
                return
            }
            current = pending
            lastRequest = pending
        }
    }

    private func performRefresh(request: Request) async {
        let decision = ComputerUseConfiguration.decision(
            enabled: request.isEnabled,
            rootPath: request.rootPath,
            workingDirectoryURL: ManagedOpenCodeServerManager.managedWorkingDirectoryURL(),
            environment: environment,
            fileManager: fileManager
        )

        // Two steps on purpose: the filesystem check is cheap, and the signing
        // read spawns `codesign` — which must not happen on the main actor, this
        // being the settings card.
        var helper = ComputerUseHelperStatus.inspect(
            homeDirectoryURL: homeDirectoryURL,
            fileManager: fileManager
        )
        if helper.isInstalled {
            helper = helper.addingSigning(
                await signatureReader.signingStatus(bundleURL: helper.bundleURL)
            )
        }

        var permissions: ComputerUsePermissions?
        if case .ready = decision, helper.isInstalled {
            permissions = await permissionProbe.probe(
                helperExecutableURL: helper.executableURL,
                timeout: permissionProbeTimeout
            )
        }

        let readiness = ComputerUseReadiness(
            decision: decision,
            helper: helper,
            permissions: permissions,
            appScreenRecordingGranted: appPermissionReader.permissions().screenCaptureAuthorized,
            checkedAt: Date()
        )
        logReadiness(readiness)
        self.readiness = readiness
    }

    /// The first thing a reader of the log asks is why the card says the
    /// permissions are missing, so the answer is recorded — and nothing else is.
    private func logReadiness(_ readiness: ComputerUseReadiness) {
        switch readiness.state {
        case .disabled:
            AppLog.settings.info("Computer Use is off; readiness not checked")
        case .misconfigured(let message):
            AppLog.settings.error(
                "Computer Use is enabled but its configuration is invalid: \(message, privacy: .public)"
            )
        case .helperMissing:
            AppLog.settings.error("Computer Use: the signed helper is not installed")
        case .permissionsUnknown:
            AppLog.settings.error(
                "Computer Use: the helper did not answer its permission check"
            )
        case .missingPermissions(let missing):
            let names =
                missing
                .map { "\($0.rawValue)(\($0.subject == .app ? "this app" : "helper"))" }
                .joined(separator: ", ")
            AppLog.settings.error(
                "Computer Use: missing macOS grants: \(names, privacy: .public)"
            )
        case .ready:
            AppLog.settings.info("Computer Use: the helper has every permission it needs")
        }
    }

    // MARK: - Acting on what was found

    /// Deep-links to the Privacy & Security pane that owns the grant. The app
    /// cannot grant anything itself; it can only put the user in front of the
    /// switch, which is the difference between a working setup and a scavenger
    /// hunt through System Settings.
    func openSettingsPane(_ pane: ComputerUseSettingsPane) {
        guard let url = pane.url else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Reveals the helper in Finder so it can be dragged into a permission list
    /// with the "+" button, which is the only route when macOS never prompted.
    func revealHelper() {
        guard let readiness else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([readiness.helper.bundleURL])
    }

    /// Asks macOS to register this app for Screen Recording.
    ///
    /// Screen Recording is enforced on the responsible process — the app that
    /// launched the helper — so the helper's own switch in System Settings is
    /// never consulted. That makes this app the one that has to ask, and macOS
    /// only adds an app to the list once it does.
    func requestScreenRecording() {
        guard !isRequestingScreenRecording else {
            return
        }
        isRequestingScreenRecording = true
        AppLog.settings.info("Computer Use: asking macOS to register this app for Screen Recording")

        Task { [weak self] in
            let granted = await self?.appPermissionReader.requestScreenRecording() ?? false

            guard let self else {
                return
            }
            self.isRequestingScreenRecording = false
            AppLog.settings.info(
                "Computer Use: the Screen Recording request came back as \(granted ? "granted" : "not granted yet", privacy: .public)"
            )

            guard let lastRequest = self.lastRequest else {
                return
            }
            await self.refresh(isEnabled: lastRequest.isEnabled, rootPath: lastRequest.rootPath)
        }
    }

    func copySetupCommand(for step: ComputerUseSetupStep, rootPath: String) {
        let command = "cd \(rootPath) && \(step.command)"
        Pasteboard.copy(command)
    }

    // MARK: - Setup

    /// Runs one of the two fixed setup commands in the configured folder.
    ///
    /// Only one at a time: both write into the same `dist` and `.build`, and two
    /// concurrent `swift build`s would fight over the same package directory.
    func runSetup(_ step: ComputerUseSetupStep) {
        guard !isRunningSetup, let rootURL = resolvedRootURL() else {
            return
        }

        setupRun = SetupRun(step: step, output: [], isRunning: true, outcome: nil)
        AppLog.settings.info("Running the Computer Use setup step: \(step.rawValue, privacy: .public)")

        // The line callback arrives from the reader task, so it hops back to the
        // main actor; the run itself is awaited here so the caller keeps its
        // sequencing.
        let onLine: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in
                self?.appendSetupLine(line)
            }
        }

        Task { [weak self] in
            let outcome = await self?.setupRunner.run(
                step: step,
                in: rootURL,
                onLine: onLine
            )

            guard let self else {
                return
            }
            self.finishSetup(
                outcome
                    ?? ComputerUseSetupOutcome(
                        step: step,
                        exitCode: 127,
                        didLaunch: false,
                        didCancel: false
                    )
            )
        }
    }

    func cancelSetup() {
        guard isRunningSetup else {
            return
        }
        setupRunner.cancel()
    }

    private func appendSetupLine(_ line: String) {
        guard setupRun != nil else {
            return
        }
        setupRun?.append(line)
    }

    private func finishSetup(_ outcome: ComputerUseSetupOutcome) {
        setupRun?.isRunning = false
        setupRun?.outcome = outcome

        if outcome.didSucceed {
            AppLog.settings.info(
                "The Computer Use setup step succeeded: \(outcome.step.rawValue, privacy: .public)"
            )
        } else if !outcome.didCancel {
            AppLog.settings.error(
                "The Computer Use setup step failed with status \(outcome.exitCode): \(outcome.step.rawValue, privacy: .public)"
            )
        }

        // A finished install changes the helper on disk, and possibly its
        // signature, so what is on screen is stale the moment it returns.
        guard let lastRequest, !outcome.didCancel else {
            return
        }
        Task { [weak self] in
            guard let self, self.setupRun?.isRunning == false else {
                return
            }
            await self.refresh(isEnabled: lastRequest.isEnabled, rootPath: lastRequest.rootPath)
        }
    }

    /// The configured folder as an existing directory. Everything about setup
    /// hangs off it, so it is validated once here rather than at each use.
    private func resolvedRootURL() -> URL? {
        guard let lastRequest else {
            return nil
        }
        let expanded = ComputerUseConfiguration.expand(
            rootPath: lastRequest.rootPath,
            homeDirectoryURL: homeDirectoryURL
        )
        guard !expanded.isEmpty else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return nil
        }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }
}
