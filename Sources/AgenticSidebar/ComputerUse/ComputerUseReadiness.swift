import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

// MARK: - Permissions

/// The macOS privacy grants the computer runtime needs, in the order System
/// Settings lists them for the user.
enum ComputerUsePermission: String, CaseIterable, Equatable, Sendable {
    case accessibility
    case screenRecording
    case inputMonitoring
    case eventPosting

    var title: String {
        switch self {
        case .accessibility:
            "Accessibility"
        case .screenRecording:
            "Screen Recording"
        case .inputMonitoring:
            "Input Monitoring"
        case .eventPosting:
            "Posting input events"
        }
    }

    /// What the agent loses while the grant is missing, in the user's terms.
    var consequence: String {
        switch self {
        case .accessibility:
            "Reading and driving other apps' controls"
        case .screenRecording:
            "Screenshots and vision"
        case .inputMonitoring:
            "Watching keys and clicks"
        case .eventPosting:
            "Typing and clicking on the agent's behalf"
        }
    }

    /// The System Settings pane that owns the grant. Posting events is granted
    /// through Accessibility, so it shares that pane.
    var settingsPane: ComputerUseSettingsPane {
        switch self {
        case .accessibility, .eventPosting:
            .accessibility
        case .screenRecording:
            .screenCapture
        case .inputMonitoring:
            .listenEvent
        }
    }

    /// Which process macOS actually asks for this grant.
    ///
    /// Screen Recording is the odd one out: `tccd` answers
    /// `kTCCServiceScreenCapture` for the **responsible process** — whoever
    /// launched the helper — and never reads the helper's own row in the list.
    /// The tccd log shows it plainly: the same helper binary reports
    /// `screenCaptureAuthorized: true` when a granted process starts it, and
    /// `false` when this app does, even with the helper switched on in System
    /// Settings. So the switch that matters for that one grant is this app's.
    var subject: ComputerUsePermissionSubject {
        self == .screenRecording ? .app : .helper
    }
}

/// The process a grant has to be given to for macOS to honour it.
enum ComputerUsePermissionSubject: Equatable, Sendable {
    /// Enforced on the process that launches the helper, so this app holds it.
    case app
    /// Read from the signed helper's own TCC identity.
    case helper
}

/// A Privacy & Security pane the app can deep-link to.
enum ComputerUseSettingsPane: String, CaseIterable, Equatable, Sendable {
    case accessibility = "Privacy_Accessibility"
    case screenCapture = "Privacy_ScreenCapture"
    case listenEvent = "Privacy_ListenEvent"

    var title: String {
        switch self {
        case .accessibility:
            "Accessibility"
        case .screenCapture:
            "Screen Recording"
        case .listenEvent:
            "Input Monitoring"
        }
    }

    /// `x-apple.systempreferences` is the documented way to land on one pane;
    /// the app cannot grant anything itself, only put the user in front of the
    /// switch.
    var url: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")
    }
}

/// The four booleans the helper reports about itself.
struct ComputerUsePermissions: Equatable, Sendable {
    var accessibilityTrusted: Bool
    var screenCaptureAuthorized: Bool
    var eventListenAuthorized: Bool
    var eventPostAuthorized: Bool

    static let denied = ComputerUsePermissions(
        accessibilityTrusted: false,
        screenCaptureAuthorized: false,
        eventListenAuthorized: false,
        eventPostAuthorized: false
    )

    func isGranted(_ permission: ComputerUsePermission) -> Bool {
        switch permission {
        case .accessibility:
            accessibilityTrusted
        case .screenRecording:
            screenCaptureAuthorized
        case .inputMonitoring:
            eventListenAuthorized
        case .eventPosting:
            eventPostAuthorized
        }
    }

    /// Missing grants in the order the card lists them.
    var missing: [ComputerUsePermission] {
        ComputerUsePermission.allCases.filter { !isGranted($0) }
    }

    var isComplete: Bool {
        missing.isEmpty
    }
}

// MARK: - The helper's health reply

/// Decoding for the helper's `health` response.
///
/// The app has to ask the helper rather than check itself: macOS ties these
/// grants to the signed binary, so the only process whose answer means anything
/// is `ChatGPTSystemComputerRuntime`.
enum ComputerUseHealthReply {
    /// The request line the helper expects. It decodes strictly, so the
    /// envelope carries exactly these four keys.
    static func requestLine(requestId: String) -> Data {
        let payload = """
        {"protocolVersion":\(protocolVersion),"requestId":"\(requestId)","method":"health","params":{}}
        """
        return Data((payload + "\n").utf8)
    }

    static let protocolVersion = 1

    /// Parses one NDJSON reply. Unknown fields are ignored, a failed envelope
    /// is not a permission answer.
    static func permissions(fromLine line: Data) -> ComputerUsePermissions? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            object["ok"] as? Bool == true,
            let result = object["result"] as? [String: Any]
        else {
            return nil
        }

        func flag(_ key: String) -> Bool {
            (result[key] as? Bool) ?? false
        }

        return ComputerUsePermissions(
            accessibilityTrusted: flag("accessibilityTrusted"),
            screenCaptureAuthorized: flag("screenCaptureAuthorized"),
            eventListenAuthorized: flag("eventListenAuthorized"),
            eventPostAuthorized: flag("eventPostAuthorized")
        )
    }
}

/// Asks the helper what macOS has granted it.
protocol ComputerUsePermissionProbing: Sendable {
    /// `nil` means "could not find out" — never "denied".
    func probe(helperExecutableURL: URL, timeout: Duration) async -> ComputerUsePermissions?
}

/// The grants this app holds itself.
///
/// Only Screen Recording is acted on from here — it is the one macOS enforces on
/// the responsible process — but the whole set is read so the two answers can be
/// compared instead of guessed at.
protocol ComputerUseAppPermissionReading: Sendable {
    /// In-process preflights: no process is spawned and nothing is prompted.
    func permissions() -> ComputerUsePermissions

    /// Asks macOS to register this app in the Screen Recording list. Returns
    /// whether the grant is held once the user has answered; the prompt, and the
    /// decision, are macOS's.
    func requestScreenRecording() async -> Bool
}

/// The real preflights, read from the app's own process.
struct SystemComputerUseAppPermissionReader: ComputerUseAppPermissionReading {
    func permissions() -> ComputerUsePermissions {
        ComputerUsePermissions(
            accessibilityTrusted: AXIsProcessTrusted(),
            screenCaptureAuthorized: CGPreflightScreenCaptureAccess(),
            eventListenAuthorized: CGPreflightListenEventAccess(),
            eventPostAuthorized: CGPreflightPostEventAccess()
        )
    }

    func requestScreenRecording() async -> Bool {
        // `CGRequestScreenCaptureAccess` shows the prompt and can block until the
        // user answers, so it must not run on the caller's executor — the caller
        // is the settings card.
        await Task.detached(priority: .utility) { () -> Bool in
            CGRequestScreenCaptureAccess()
        }.value
    }
}

/// Spawns the installed helper for a single `health` request and shuts it down
/// again.
///
/// This is what the MCP server does at the start of every turn, so it is safe
/// while a helper is already running: each host is a separate stdio process.
/// Nothing is written and no action is performed — `health` only reads the four
/// TCC answers.
struct ComputerUseHelperProbe: ComputerUsePermissionProbing {
    func probe(helperExecutableURL: URL, timeout: Duration) async -> ComputerUsePermissions? {
        let milliseconds = Self.milliseconds(timeout)
        return await Task.detached(priority: .utility) { () -> ComputerUsePermissions? in
            Self.run(executableURL: helperExecutableURL, timeoutMilliseconds: milliseconds)
        }.value
    }

    private static func run(
        executableURL: URL,
        timeoutMilliseconds: Int32
    ) -> ComputerUsePermissions? {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }

        let process = Process()
        process.executableURL = executableURL
        let standardInput = Pipe()
        let standardOutput = Pipe()
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            AppLog.automation.error(
                "Computer-use helper probe could not launch the helper: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let request = ComputerUseHealthReply.requestLine(requestId: UUID().uuidString)
        do {
            try standardInput.fileHandleForWriting.write(contentsOf: request)
        } catch {
            AppLog.automation.error(
                "Computer-use helper probe could not write the health request: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        guard
            let line = readLine(
                from: standardOutput.fileHandleForReading,
                timeoutMilliseconds: timeoutMilliseconds
            )
        else {
            AppLog.automation.error(
                "Computer-use helper probe received no answer within the budget"
            )
            return nil
        }

        return ComputerUseHealthReply.permissions(fromLine: line)
    }

    /// One line of output, or `nil` if the helper went quiet, closed its output
    /// or never answered inside the budget. `poll` waits for data, so the read
    /// that follows cannot block past the deadline.
    private static func readLine(
        from handle: FileHandle,
        timeoutMilliseconds: Int32
    ) -> Data? {
        let descriptor = handle.fileDescriptor
        var buffer = Data()
        var remaining = timeoutMilliseconds

        while true {
            guard remaining > 0 else {
                return nil
            }

            var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&entry, 1, remaining)

            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                return nil
            }
            if ready == 0 {
                return nil
            }

            let start = DispatchTime.now().uptimeNanoseconds
            var chunk = [UInt8](repeating: 0, count: 4_096)
            let count = read(descriptor, &chunk, chunk.count)
            let elapsed = DispatchTime.now().uptimeNanoseconds &- start
            remaining -= Int32(min(UInt64(Int32.max), elapsed / 1_000_000))

            if count <= 0 {
                // Output closed. A partial line is not an answer.
                return nil
            }

            if let newline = chunk[0..<count].firstIndex(of: 0x0A) {
                buffer.append(contentsOf: chunk[0..<newline])
                return buffer
            }

            buffer.append(contentsOf: chunk[0..<count])
            if buffer.count > 262_144 {
                return nil
            }
        }
    }

    static func milliseconds(_ duration: Duration) -> Int32 {
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let milliseconds = max(1, Int((seconds * 1_000).rounded()))
        return Int32(min(Int64(Int32.max), Int64(milliseconds)))
    }
}

// MARK: - The installed helper

/// What `codesign` says about the installed helper.
struct ComputerUseSigningStatus: Equatable, Sendable {
    /// e.g. `Apple Development: Ada (TEAMID)`; `nil` for ad-hoc or unsigned.
    var identity: String?
    var isAdHoc: Bool

    static let unknown = ComputerUseSigningStatus(identity: nil, isAdHoc: true)

    /// Ad-hoc signatures change on every rebuild, and macOS drops the grants
    /// with the previous signature — the one case where re-installing costs the
    /// user their two permission switches again.
    var keepsPermissionsAcrossRebuilds: Bool {
        !isAdHoc
    }
}

/// Reads the code-signing state of the installed helper bundle. Injected so the
/// readiness logic can be tested without a signed app on disk.
///
/// The requirement is `async` on purpose: the only implementation spawns
/// `codesign`, and this runs every time the Computer Use card appears. A
/// synchronous requirement would invite the call on the main actor, where a
/// process launch and `waitUntilExit` cost the UI its next frames.
protocol ComputerUseSignatureReading: Sendable {
    func signingStatus(bundleURL: URL) async -> ComputerUseSigningStatus
}

/// What the app can tell about the helper without asking the agent anything.
struct ComputerUseHelperStatus: Equatable, Sendable {
    var bundleURL: URL
    var isInstalled: Bool
    var bundleIdentifierMatches: Bool
    /// e.g. `Apple Development: Ada (TEAMID)`; `nil` for ad-hoc or unsigned.
    var signingIdentity: String?
    var isAdHocSigned: Bool

    /// The bundle the user sees, before it has been signed or inspected.
    static func bundleURL(homeDirectoryURL: URL) -> URL {
        ComputerUseConfiguration.helperBundleURL(homeDirectoryURL: homeDirectoryURL)
    }

    static let expectedBundleIdentifier = "com.senoldogann.chatgpt-system.computer-runtime"

    var executableURL: URL {
        bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("chatgpt-system-computer-runtime")
    }

    var permissionsSurviveRebuild: Bool {
        isInstalled && !isAdHocSigned
    }

    /// The cheap half: does the bundle exist, and is it ours. Pure filesystem
    /// reads, so it is safe wherever it is called from.
    static func inspect(
        homeDirectoryURL: URL,
        fileManager: FileManager = .default
    ) -> ComputerUseHelperStatus {
        let bundleURL = ComputerUseHelperStatus.bundleURL(homeDirectoryURL: homeDirectoryURL)
        let isInstalled = fileManager.fileExists(atPath: bundleURL.path)
        let bundleIdentifier = isInstalled ? Bundle(url: bundleURL)?.bundleIdentifier : nil

        return ComputerUseHelperStatus(
            bundleURL: bundleURL,
            isInstalled: isInstalled,
            bundleIdentifierMatches: bundleIdentifier == expectedBundleIdentifier,
            signingIdentity: nil,
            isAdHocSigned: false
        )
    }

    /// The expensive half, once the reader has answered.
    func addingSigning(_ status: ComputerUseSigningStatus) -> ComputerUseHelperStatus {
        guard isInstalled else {
            return self
        }

        var copy = self
        copy.signingIdentity = status.identity
        copy.isAdHocSigned = status.isAdHoc
        return copy
    }
}

/// `/usr/bin/codesign -dv` is read-only inspection of a bundle the user owns;
/// `codesign --verify` would write nothing either, but the display output is
/// enough to tell a real identity from an ad-hoc one.
struct SystemComputerUseSignatureReader: ComputerUseSignatureReading {
    func signingStatus(bundleURL: URL) async -> ComputerUseSigningStatus {
        // Off the caller's executor: `codesign` is a process launch followed by
        // `waitUntilExit`, and the caller is the settings card.
        await Task.detached(priority: .utility) { () -> ComputerUseSigningStatus in
            let lines = Self.displayLines(bundleURL: bundleURL)
            guard !lines.isEmpty else {
                return .unknown
            }

            let identity = lines
                .first { $0.hasPrefix("Authority=") }
                .map { String($0.dropFirst("Authority=".count)) }

            // An unsigned bundle has no Authority either, and needs the same
            // treatment: grant it again after every rebuild.
            let isAdHoc = lines.contains { $0.hasPrefix("Signature=adhoc") }
                || identity == nil

            return ComputerUseSigningStatus(identity: identity, isAdHoc: isAdHoc)
        }.value
    }

    private static func displayLines(bundleURL: URL) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--display", "--verbose=4", bundleURL.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            return []
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }

        return text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Readiness

/// Where the user stands, in one value: the launch decision the server uses, the
/// installed helper and the grants it holds.
struct ComputerUseReadiness: Equatable, Sendable {
    var decision: ComputerUseLaunchDecision
    var helper: ComputerUseHelperStatus
    /// The helper's own answers. `nil` = it could not be asked, which is not the
    /// same as denied.
    var permissions: ComputerUsePermissions?
    /// Whether this app holds Screen Recording — the grant macOS enforces on the
    /// responsible process, and therefore the one the helper inherits.
    var appScreenRecordingGranted: Bool = false
    var checkedAt: Date?

    var state: ComputerUseReadinessState {
        switch decision {
        case .disabled:
            return .disabled
        case .invalid(let message):
            return .misconfigured(message: message)
        case .ready:
            break
        }

        guard helper.isInstalled else {
            return .helperMissing
        }
        guard permissions != nil else {
            return .permissionsUnknown
        }
        let missing = missingPermissions
        return missing.isEmpty ? .ready : .missingPermissions(missing)
    }

    var isReady: Bool {
        state == .ready
    }

    /// Whether macOS would let the agent use this permission right now.
    ///
    /// Each grant is read from the process macOS asks for it, not from whichever
    /// process happens to be easiest to question.
    func isGranted(_ permission: ComputerUsePermission) -> Bool {
        switch permission.subject {
        case .app:
            return appScreenRecordingGranted
        case .helper:
            return permissions?.isGranted(permission) ?? false
        }
    }

    /// The grants macOS is still missing, in the order the card lists them.
    ///
    /// Nothing is listed while the helper could not be asked: an unknown answer
    /// is not a missing grant, and a list of gaps would send the user to System
    /// Settings for switches that may already be on. That state has its own
    /// branch, `.permissionsUnknown`.
    var missingPermissions: [ComputerUsePermission] {
        guard permissions != nil else {
            return []
        }
        return ComputerUsePermission.allCases.filter { !isGranted($0) }
    }

    /// Only consulted when the helper answered, so these are real gaps.
    var missingHelperPermissions: [ComputerUsePermission] {
        missingPermissions.filter { $0.subject == .helper }
    }

    var missingAppPermissions: [ComputerUsePermission] {
        missingPermissions.filter { $0.subject == .app }
    }

    /// False only for a helper whose grants macOS will drop on the next rebuild.
    var keepsPermissionsAcrossRebuilds: Bool {
        helper.permissionsSurviveRebuild
    }
}

/// The single answer the card leads with.
enum ComputerUseReadinessState: Equatable, Sendable {
    /// The user has not turned computer use on.
    case disabled
    /// The folder, Node or `dist/cli.js` is not usable.
    case misconfigured(message: String)
    /// The signed helper is not installed.
    case helperMissing
    /// The helper did not answer; permissions cannot be reported either way.
    case permissionsUnknown
    /// The helper answered: these grants are missing.
    case missingPermissions([ComputerUsePermission])
    /// Everything the app can check is in place.
    case ready
}
