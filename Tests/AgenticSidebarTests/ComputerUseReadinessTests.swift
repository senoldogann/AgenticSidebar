import Foundation
import XCTest

@testable import AgenticSidebar

// MARK: - Fakes

private actor FakePermissionProbe: ComputerUsePermissionProbing {
    private let answer: ComputerUsePermissions?
    private var calls: [URL] = []

    init(answer: ComputerUsePermissions?) {
        self.answer = answer
    }

    func probe(helperExecutableURL: URL, timeout: Duration) async -> ComputerUsePermissions? {
        calls.append(helperExecutableURL)
        return answer
    }

    func probedURLs() -> [URL] { calls }
}

/// The app's own grants.
///
/// Injected into every status the suite builds: calling the real preflights
/// would make the outcome depend on whoever launched the test runner, which is
/// precisely the confusion these tests exist to pin down. `true` by default, so
/// a test only has to say so when the app's grant is the subject.
private final class FakeAppPermissionReader: ComputerUseAppPermissionReading, @unchecked Sendable {
    private let lock = NSLock()
    private var screenRecording: Bool
    private let grantsOnRequest: Bool
    private var requests = 0

    init(screenRecordingAuthorized: Bool = true, grantsOnRequest: Bool? = nil) {
        self.screenRecording = screenRecordingAuthorized
        self.grantsOnRequest = grantsOnRequest ?? screenRecordingAuthorized
    }

    func permissions() -> ComputerUsePermissions {
        ComputerUsePermissions(
            accessibilityTrusted: false,
            screenCaptureAuthorized: lock.withLock { screenRecording },
            eventListenAuthorized: false,
            eventPostAuthorized: false
        )
    }

    func requestScreenRecording() async -> Bool {
        lock.withLock {
            requests += 1
            screenRecording = grantsOnRequest
        }
        return grantsOnRequest
    }

    func requestCount() -> Int { lock.withLock { requests } }
}

private struct FakeSignatureReader: ComputerUseSignatureReading {
    var identity: String?
    var isAdHoc = false

    func signingStatus(bundleURL: URL) async -> ComputerUseSigningStatus {
        ComputerUseSigningStatus(identity: identity, isAdHoc: isAdHoc)
    }
}

private final class FakeSetupRunner: ComputerUseSetupRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let exitCode: Int32
    private let lines: [String]
    private let blocksUntilCancelled: Bool
    private var runs: [(step: ComputerUseSetupStep, directory: URL)] = []
    private var cancels = 0
    private var release: (() -> Void)?

    init(exitCode: Int32 = 0, lines: [String] = [], blocksUntilCancelled: Bool = false) {
        self.exitCode = exitCode
        self.lines = lines
        self.blocksUntilCancelled = blocksUntilCancelled
    }

    func run(
        step: ComputerUseSetupStep,
        in directoryURL: URL,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> ComputerUseSetupOutcome {
        lock.withLock {
            runs.append((step, directoryURL))
        }
        for line in lines {
            onLine(line)
        }

        if blocksUntilCancelled {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    release = { continuation.resume() }
                }
            }
        }

        return ComputerUseSetupOutcome(
            step: step,
            exitCode: exitCode,
            didLaunch: true,
            didCancel: false
        )
    }

    func cancel() {
        let release = lock.withLock { () -> (() -> Void)? in
            cancels += 1
            let pending = self.release
            self.release = nil
            return pending
        }
        release?()
    }

    func recordedRuns() -> [(step: ComputerUseSetupStep, directory: URL)] { lock.withLock { runs } }
    func cancelCount() -> Int { lock.withLock { cancels } }
}

// MARK: - Tests

final class ComputerUseHealthReplyTests: XCTestCase {
    func testRequestLineCarriesTheEnvelopeTheHelperDecodesStrictly() throws {
        let line = ComputerUseHealthReply.requestLine(requestId: "abc")
        let text = try XCTUnwrap(String(data: line, encoding: .utf8))

        XCTAssertTrue(text.hasSuffix("\n"), "NDJSON needs the trailing newline")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: line) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["protocolVersion", "requestId", "method", "params"])
        XCTAssertEqual(object["protocolVersion"] as? Int, 1)
        XCTAssertEqual(object["requestId"] as? String, "abc")
        XCTAssertEqual(object["method"] as? String, "health")
        XCTAssertEqual((object["params"] as? [String: Any])?.isEmpty, true)
    }

    func testPermissionsAreDecodedFromAHealthReply() throws {
        let line = Data(
            """
            {"protocolVersion":1,"requestId":"abc","ok":true,"result":{"state":"running","accessibilityTrusted":true,"screenCaptureAuthorized":false,"eventListenAuthorized":true,"eventPostAuthorized":false}}
            """.utf8
        )

        let permissions = try XCTUnwrap(ComputerUseHealthReply.permissions(fromLine: line))

        XCTAssertTrue(permissions.accessibilityTrusted)
        XCTAssertFalse(permissions.screenCaptureAuthorized)
        XCTAssertTrue(permissions.eventListenAuthorized)
        XCTAssertFalse(permissions.eventPostAuthorized)
        XCTAssertEqual(permissions.missing, [.screenRecording, .eventPosting])
    }

    /// A failure envelope is an error, not a permission answer: reporting it as
    /// "denied" would send the user to System Settings for nothing.
    func testFailedReplyIsNotAPermissionAnswer() {
        let line = Data(
            """
            {"protocolVersion":1,"requestId":"abc","ok":false,"error":{"code":"X","message":"no"}}
            """.utf8
        )
        XCTAssertNil(ComputerUseHealthReply.permissions(fromLine: line))
    }

    func testGarbageAndEmptyRepliesAreRejected() {
        XCTAssertNil(ComputerUseHealthReply.permissions(fromLine: Data("not json".utf8)))
        XCTAssertNil(ComputerUseHealthReply.permissions(fromLine: Data()))
        XCTAssertNil(
            ComputerUseHealthReply.permissions(
                fromLine: Data(#"{"protocolVersion":1,"ok":true,"result":"running"}"#.utf8)
            )
        )
    }

    func testMissingFlagsCountAsNotGranted() throws {
        let line = Data(#"{"ok":true,"result":{"state":"running"}}"#.utf8)
        let permissions = try XCTUnwrap(ComputerUseHealthReply.permissions(fromLine: line))
        XCTAssertEqual(permissions.missing.count, ComputerUsePermission.allCases.count)
    }

    func testTimeoutConversionNeverProducesAZeroPoll() {
        XCTAssertEqual(ComputerUseHelperProbe.milliseconds(.seconds(6)), 6_000)
        XCTAssertEqual(ComputerUseHelperProbe.milliseconds(.zero), 1)
        XCTAssertGreaterThan(ComputerUseHelperProbe.milliseconds(.seconds(600)), 0)
    }
}

final class ComputerUsePermissionMappingTests: XCTestCase {
    func testEveryGrantMapsToThePaneThatOwnsIt() {
        XCTAssertEqual(ComputerUsePermission.accessibility.settingsPane, .accessibility)
        XCTAssertEqual(ComputerUsePermission.eventPosting.settingsPane, .accessibility)
        XCTAssertEqual(ComputerUsePermission.screenRecording.settingsPane, .screenCapture)
        XCTAssertEqual(ComputerUsePermission.inputMonitoring.settingsPane, .listenEvent)
    }

    /// The distinction that makes the card honest: one of the four switches
    /// lives in this app, and System Settings' helper row does not replace it.
    func testScreenRecordingIsTheGrantEnforcedOnTheApp() {
        XCTAssertEqual(ComputerUsePermission.screenRecording.subject, .app)
        XCTAssertEqual(ComputerUsePermission.accessibility.subject, .helper)
        XCTAssertEqual(ComputerUsePermission.inputMonitoring.subject, .helper)
        XCTAssertEqual(ComputerUsePermission.eventPosting.subject, .helper)
    }

    func testPaneURLsAreTheSystemSettingsDeepLinks() throws {
        let accessibility = try XCTUnwrap(ComputerUseSettingsPane.accessibility.url)
        XCTAssertEqual(
            accessibility.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
        XCTAssertEqual(ComputerUseSettingsPane.screenCapture.url?.absoluteString.hasSuffix("Privacy_ScreenCapture"), true)
        XCTAssertEqual(ComputerUseSettingsPane.listenEvent.url?.absoluteString.hasSuffix("Privacy_ListenEvent"), true)
    }

    func testMissingIsReportedInListOrder() {
        let permissions = ComputerUsePermissions(
            accessibilityTrusted: false,
            screenCaptureAuthorized: true,
            eventListenAuthorized: false,
            eventPostAuthorized: true
        )
        XCTAssertEqual(permissions.missing, [.accessibility, .inputMonitoring])
        XCTAssertFalse(permissions.isComplete)
        XCTAssertTrue(ComputerUsePermissions.denied.missing.count == 4)
    }
}

final class ComputerUseReadinessStateTests: XCTestCase {
    private let helper = ComputerUseHelperStatus(
        bundleURL: URL(fileURLWithPath: "/Users/tester/.chatgpt-system/ChatGPTSystemComputerRuntime.app"),
        isInstalled: true,
        bundleIdentifierMatches: true,
        signingIdentity: "Apple Development: Ada (TEAMID)",
        isAdHocSigned: false
    )

    private let ready = ComputerUseLaunchDecision.ready(
        ComputerUseConfiguration(
            projectRootURL: URL(fileURLWithPath: "/repo"),
            nodeExecutableURL: URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            workingDirectoryURL: URL(fileURLWithPath: "/managed")
        )
    )

    func testReadyNeedsConfigurationHelperAndEveryGrant() {
        var readiness = ComputerUseReadiness(
            decision: ready,
            helper: helper,
            permissions: nil,
            checkedAt: nil
        )
        XCTAssertEqual(readiness.state, .permissionsUnknown)

        readiness.permissions = .denied
        XCTAssertEqual(
            readiness.state,
            .missingPermissions([.accessibility, .screenRecording, .inputMonitoring, .eventPosting])
        )

        // Screen Recording is the app's, so the helper answering `true` for it
        // is not enough — and the helper answering `false` is not a problem.
        readiness.permissions = ComputerUsePermissions(
            accessibilityTrusted: true,
            screenCaptureAuthorized: true,
            eventListenAuthorized: true,
            eventPostAuthorized: false
        )
        XCTAssertEqual(readiness.state, .missingPermissions([.screenRecording, .eventPosting]))
        XCTAssertFalse(readiness.isReady)

        readiness.appScreenRecordingGranted = true
        XCTAssertEqual(readiness.state, .missingPermissions([.eventPosting]))

        readiness.permissions = ComputerUsePermissions(
            accessibilityTrusted: true,
            screenCaptureAuthorized: false,
            eventListenAuthorized: true,
            eventPostAuthorized: true
        )
        XCTAssertEqual(
            readiness.state,
            .ready,
            "the helper's own Screen Recording row is never the one tccd consults"
        )
        XCTAssertTrue(readiness.isReady)
    }

    /// tccd answers `kTCCServiceScreenCapture` for the responsible process, so a
    /// missing app grant is the only thing that may block screenshots — and a
    /// present one may not be reported as missing because the helper said so.
    func testScreenRecordingComesFromTheAppAndTheRestFromTheHelper() {
        let readiness = ComputerUseReadiness(
            decision: ready,
            helper: helper,
            permissions: ComputerUsePermissions(
                accessibilityTrusted: true,
                screenCaptureAuthorized: true,
                eventListenAuthorized: true,
                eventPostAuthorized: true
            ),
            appScreenRecordingGranted: false,
            checkedAt: nil
        )

        XCTAssertEqual(readiness.state, .missingPermissions([.screenRecording]))
        XCTAssertEqual(readiness.missingAppPermissions, [.screenRecording])
        XCTAssertEqual(readiness.missingHelperPermissions, [])
        XCTAssertTrue(readiness.isGranted(.accessibility))
        XCTAssertTrue(readiness.isGranted(.inputMonitoring))
        XCTAssertFalse(readiness.isGranted(.screenRecording))
    }

    func testConfigurationProblemsComeFirst() {
        let missingCLI = ComputerUseReadiness(
            decision: .invalid(message: "dist/cli.js was not found at /repo/dist/cli.js."),
            helper: helper,
            permissions: nil,
            checkedAt: nil
        )
        XCTAssertEqual(
            missingCLI.state,
            .misconfigured(message: "dist/cli.js was not found at /repo/dist/cli.js.")
        )

        XCTAssertEqual(
            ComputerUseReadiness(decision: .disabled, helper: helper, permissions: nil, checkedAt: nil).state,
            .disabled
        )
    }

    /// The distinction the card reports: a real signing identity survives a
    /// rebuild (macOS keys the grant to the certificate), an ad-hoc one does not.
    func testSigningStatusDecidesWhetherGrantsSurviveARebuild() {
        XCTAssertTrue(
            ComputerUseSigningStatus(identity: "Apple Development: Ada (TEAMID)", isAdHoc: false)
                .keepsPermissionsAcrossRebuilds
        )
        XCTAssertFalse(ComputerUseSigningStatus(identity: nil, isAdHoc: true).keepsPermissionsAcrossRebuilds)
        XCTAssertFalse(ComputerUseSigningStatus.unknown.keepsPermissionsAcrossRebuilds)
    }

    /// The cheap half must not claim a signing identity, and the expensive half
    /// must not be applied to a bundle that is not installed.
    func testSigningIsOnlyAttachedToAnInstalledHelper() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-home-\(UUID().uuidString)", isDirectory: true)
        let missing = ComputerUseHelperStatus.inspect(homeDirectoryURL: home, fileManager: .default)
        XCTAssertFalse(missing.isInstalled)
        XCTAssertEqual(
            missing.addingSigning(ComputerUseSigningStatus(identity: "Apple Development: Ada", isAdHoc: false)),
            missing
        )
    }

    func testAdHocSignatureMeansTheGrantsMustBeGivenAgainAfterARebuild() {
        let adHoc = ComputerUseHelperStatus(
            bundleURL: helper.bundleURL,
            isInstalled: true,
            bundleIdentifierMatches: true,
            signingIdentity: nil,
            isAdHocSigned: true
        )

        XCTAssertFalse(
            ComputerUseReadiness(decision: ready, helper: adHoc, permissions: .denied, checkedAt: nil)
                .keepsPermissionsAcrossRebuilds
        )
        XCTAssertTrue(
            ComputerUseReadiness(decision: ready, helper: helper, permissions: .denied, checkedAt: nil)
                .keepsPermissionsAcrossRebuilds
        )
    }
}

@MainActor
final class ComputerUseStatusTests: XCTestCase {
    func testRefreshReportsReadyWhenTheHelperHoldsEveryGrant() async throws {
        let fixture = try ComputerUseFixture()
        defer { fixture.remove() }

        let status = ComputerUseStatus(
            permissionProbe: FakePermissionProbe(
                answer: ComputerUsePermissions(
                    accessibilityTrusted: true,
                    screenCaptureAuthorized: true,
                    eventListenAuthorized: true,
                    eventPostAuthorized: true
                )
            ),
            appPermissionReader: FakeAppPermissionReader(),
            signatureReader: FakeSignatureReader(identity: "ComputerUse Dev"),
            setupRunner: FakeSetupRunner(),
            fileManager: .default,
            homeDirectoryURL: fixture.home,
            environment: fixture.environment,
            bundlePath: fixture.root.path
        )

        await status.refresh(isEnabled: true, rootPath: fixture.repo.path)

        XCTAssertEqual(status.readiness?.state, .ready)
        XCTAssertEqual(
            status.readiness?.helper.bundleIdentifierMatches,
            true,
            "the fixture bundle declares the identifier macOS granted"
        )
    }

    func testRefreshNamesTheGrantsThatAreMissing() async throws {
        let fixture = try ComputerUseFixture()
        defer { fixture.remove() }

        let status = ComputerUseStatus(
            permissionProbe: FakePermissionProbe(
                answer: ComputerUsePermissions(
                    accessibilityTrusted: true,
                    screenCaptureAuthorized: false,
                    eventListenAuthorized: true,
                    eventPostAuthorized: false
                )
            ),
            appPermissionReader: FakeAppPermissionReader(),
            signatureReader: FakeSignatureReader(identity: "ComputerUse Dev"),
            setupRunner: FakeSetupRunner(),
            fileManager: .default,
            homeDirectoryURL: fixture.home,
            environment: fixture.environment,
            bundlePath: fixture.root.path
        )

        await status.refresh(isEnabled: true, rootPath: fixture.repo.path)

        XCTAssertEqual(
            status.readiness?.missingPermissions,
            [.eventPosting],
            "the helper's own screenCapture flag is not the operative one"
        )
    }

    /// The production reading that started this: the helper's own Screen
    /// Recording switch is on in System Settings, every one of its own four
    /// answers is `true`, and screenshots still fail because the app that
    /// launched it has no grant. The card has to say so.
    func testAMissingAppGrantIsReportedEvenWhenTheHelperSaysTrue() async throws {
        let fixture = try ComputerUseFixture()
        defer { fixture.remove() }

        let status = ComputerUseStatus(
            permissionProbe: FakePermissionProbe(
                answer: ComputerUsePermissions(
                    accessibilityTrusted: true,
                    screenCaptureAuthorized: true,
                    eventListenAuthorized: true,
                    eventPostAuthorized: true
                )
            ),
            appPermissionReader: FakeAppPermissionReader(screenRecordingAuthorized: false),
            signatureReader: FakeSignatureReader(identity: "ComputerUse Dev"),
            setupRunner: FakeSetupRunner(),
            fileManager: .default,
            homeDirectoryURL: fixture.home,
            environment: fixture.environment,
            bundlePath: fixture.root.path
        )

        await status.refresh(isEnabled: true, rootPath: fixture.repo.path)

        XCTAssertEqual(status.readiness?.state, .missingPermissions([.screenRecording]))
        XCTAssertEqual(status.readiness?.missingAppPermissions, [.screenRecording])
    }

    /// Asking is all the app can do: macOS registers it in the list and the user
    /// makes the decision. The card must then show the new answer without the
    /// user having to press re-check.
    func testGrantingScreenRecordingAsksMacOSAndReadsTheAnswerBack() async throws {
        let fixture = try ComputerUseFixture()
        defer { fixture.remove() }

        let reader = FakeAppPermissionReader(
            screenRecordingAuthorized: false,
            grantsOnRequest: true
        )
        let status = ComputerUseStatus(
            permissionProbe: FakePermissionProbe(
                answer: ComputerUsePermissions(
                    accessibilityTrusted: true,
                    screenCaptureAuthorized: false,
                    eventListenAuthorized: true,
                    eventPostAuthorized: true
                )
            ),
            appPermissionReader: reader,
            signatureReader: FakeSignatureReader(identity: "ComputerUse Dev"),
            setupRunner: FakeSetupRunner(),
            fileManager: .default,
            homeDirectoryURL: fixture.home,
            environment: fixture.environment,
            bundlePath: fixture.root.path
        )

        await status.refresh(isEnabled: true, rootPath: fixture.repo.path)
        XCTAssertEqual(status.readiness?.state, .missingPermissions([.screenRecording]))

        status.requestScreenRecording()
        await waitUntil { reader.requestCount() == 1 && status.readiness?.isReady == true }

        XCTAssertEqual(status.readiness?.state, .ready)
        XCTAssertFalse(status.isRequestingScreenRecording)
    }

    func testASecondGrantPressWhileMacOSIsAskingIsIgnored() async throws {
        let fixture = try ComputerUseFixture()
        defer { fixture.remove() }

        let reader = FakeAppPermissionReader(screenRecordingAuthorized: false, grantsOnRequest: false)
        let status = ComputerUseStatus(
            permissionProbe: FakePermissionProbe(answer: .denied),
            appPermissionReader: reader,
            signatureReader: FakeSignatureReader(identity: "ComputerUse Dev"),
            setupRunner: FakeSetupRunner(),
            fileManager: .default,
            homeDirectoryURL: fixture.home,
            environment: fixture.environment,
            bundlePath: fixture.root.path
        )
        await status.refresh(isEnabled: true, rootPath: fixture.repo.path)

        status.requestScreenRecording()
        status.requestScreenRecording()
        await waitUntil { status.isRequestingScreenRecording == false }
        await waitUntil { reader.requestCount() == 1 }

        XCTAssertEqual(
            status.readiness?.state,
            .missingPermissions([.accessibility, .screenRecording, .inputMonitoring, .eventPosting]),
            "the second press must not ask macOS twice"
        )
    }

    func testAnUnansweredHelperIsUnknownNotDenied() async throws {
        let fixture = try ComputerUseFixture()
        defer { fixture.remove() }

        let status = ComputerUseStatus(
            permissionProbe: FakePermissionProbe(answer: nil),
            appPermissionReader: FakeAppPermissionReader(),
            signatureReader: FakeSignatureReader(identity: "ComputerUse Dev"),
            setupRunner: FakeSetupRunner(),
            fileManager: .default,
            homeDirectoryURL: fixture.home,
            environment: fixture.environment,
            bundlePath: fixture.root.path
        )

        await status.refresh(isEnabled: true, rootPath: fixture.repo.path)

        XCTAssertEqual(status.readiness?.state, .permissionsUnknown)
        XCTAssertEqual(status.readiness?.missingPermissions, [])
    }

    /// Asking about a helper that is not there would report four missing grants
    /// and send the user to System Settings, when the real fix is installing it.
    func testTheHelperIsNotProbedWhenItIsNotInstalled() async throws {
        let fixture = try ComputerUseFixture(installHelper: false)
        defer { fixture.remove() }

        let probe = FakePermissionProbe(answer: .denied)
        let status = ComputerUseStatus(
            permissionProbe: probe,
            appPermissionReader: FakeAppPermissionReader(),
            signatureReader: FakeSignatureReader(identity: nil),
            setupRunner: FakeSetupRunner(),
            fileManager: .default,
            homeDirectoryURL: fixture.home,
            environment: fixture.environment,
            bundlePath: fixture.root.path
        )

        await status.refresh(isEnabled: true, rootPath: fixture.repo.path)

        XCTAssertEqual(status.readiness?.state, .helperMissing)
        let probedURLs = await probe.probedURLs()
        XCTAssertTrue(probedURLs.isEmpty)
    }

    func testOffMeansNothingIsChecked() async throws {
        let fixture = try ComputerUseFixture()
        defer { fixture.remove() }

        let probe = FakePermissionProbe(answer: .denied)
        let status = ComputerUseStatus(
            permissionProbe: probe,
            appPermissionReader: FakeAppPermissionReader(),
            signatureReader: FakeSignatureReader(identity: "ComputerUse Dev"),
            setupRunner: FakeSetupRunner(),
            fileManager: .default,
            homeDirectoryURL: fixture.home,
            environment: fixture.environment,
            bundlePath: fixture.root.path
        )

        await status.refresh(isEnabled: false, rootPath: fixture.repo.path)

        XCTAssertEqual(status.readiness?.state, .disabled)
        let probedURLs = await probe.probedURLs()
        XCTAssertTrue(probedURLs.isEmpty)
    }

    func testAMissingCLIIsReportedBeforePermissionsAreAskedFor() async throws {
        let fixture = try ComputerUseFixture(writeCLI: false)
        defer { fixture.remove() }

        let probe = FakePermissionProbe(answer: .denied)
        let status = ComputerUseStatus(
            permissionProbe: probe,
            appPermissionReader: FakeAppPermissionReader(),
            signatureReader: FakeSignatureReader(identity: "ComputerUse Dev"),
            setupRunner: FakeSetupRunner(),
            fileManager: .default,
            homeDirectoryURL: fixture.home,
            environment: fixture.environment,
            bundlePath: fixture.root.path
        )

        await status.refresh(isEnabled: true, rootPath: fixture.repo.path)

        guard case .misconfigured(let message) = status.readiness?.state else {
            return XCTFail("Expected a configuration problem, got \(String(describing: status.readiness?.state))")
        }
        XCTAssertTrue(message.contains("dist/cli.js"))
        let probedURLs = await probe.probedURLs()
        XCTAssertTrue(probedURLs.isEmpty)
    }

    func testSetupRunsInTheConfiguredFolderWithTheFixedArguments() async throws {
        let fixture = try ComputerUseFixture()
        defer { fixture.remove() }

        let runner = FakeSetupRunner(lines: ["added 12 packages", "done"])
        let status = ComputerUseStatus(
            permissionProbe: FakePermissionProbe(answer: .denied),
            appPermissionReader: FakeAppPermissionReader(),
            signatureReader: FakeSignatureReader(identity: "ComputerUse Dev"),
            setupRunner: runner,
            fileManager: .default,
            homeDirectoryURL: fixture.home,
            environment: fixture.environment,
            bundlePath: fixture.root.path
        )
        await status.refresh(isEnabled: true, rootPath: fixture.repo.path)

        status.runSetup(.buildCLI)
        await waitUntil { status.setupRun?.isRunning == false && status.setupRun?.output.count == 2 }

        let runs = runner.recordedRuns()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.step, .buildCLI)
        XCTAssertEqual(runs.first?.directory, fixture.repo)
        XCTAssertEqual(status.setupRun?.outcome?.didSucceed, true)
        XCTAssertEqual(status.setupRun?.output, ["added 12 packages", "done"])
    }

    /// Two setup commands write the same `dist` and `.build`, so the second
    /// press must be a no-op rather than a race.
    func testASecondSetupStepIsRefusedWhileOneIsRunning() async throws {
        let fixture = try ComputerUseFixture()
        defer { fixture.remove() }

        let runner = FakeSetupRunner(blocksUntilCancelled: true)
        let status = ComputerUseStatus(
            permissionProbe: FakePermissionProbe(answer: .denied),
            appPermissionReader: FakeAppPermissionReader(),
            signatureReader: FakeSignatureReader(identity: "ComputerUse Dev"),
            setupRunner: runner,
            fileManager: .default,
            homeDirectoryURL: fixture.home,
            environment: fixture.environment,
            bundlePath: fixture.root.path
        )
        await status.refresh(isEnabled: true, rootPath: fixture.repo.path)

        status.runSetup(.installHelper)
        await waitUntil { status.isRunningSetup }
        XCTAssertEqual(status.setupInFlight, .installHelper)

        status.runSetup(.buildCLI)
        status.cancelSetup()
        await waitUntil { status.setupRun?.isRunning == false }

        XCTAssertEqual(runner.recordedRuns().count, 1)
        XCTAssertEqual(runner.cancelCount(), 1)
    }

    func testASuccessfulSetupRechecksTheHelper() async throws {
        let fixture = try ComputerUseFixture()
        defer { fixture.remove() }

        let probe = FakePermissionProbe(answer: .denied)
        let status = ComputerUseStatus(
            permissionProbe: probe,
            appPermissionReader: FakeAppPermissionReader(),
            signatureReader: FakeSignatureReader(identity: "ComputerUse Dev"),
            setupRunner: FakeSetupRunner(),
            fileManager: .default,
            homeDirectoryURL: fixture.home,
            environment: fixture.environment,
            bundlePath: fixture.root.path
        )
        await status.refresh(isEnabled: true, rootPath: fixture.repo.path)

        status.runSetup(.installHelper)
        await waitUntil { await probe.probedURLs().count == 2 }

        let probedURLs = await probe.probedURLs()
        XCTAssertEqual(probedURLs.count, 2, "a finished install changes what is on disk")
    }

    func testSetupStepsAreTheTwoFixedCommands() {
        XCTAssertEqual(ComputerUseSetupStep.buildCLI.arguments, ["run", "build"])
        XCTAssertEqual(ComputerUseSetupStep.installHelper.arguments, ["run", "setup:computer:macos"])
        XCTAssertEqual(ComputerUseSetupStep.buildCLI.command, "npm run build")
        XCTAssertEqual(ComputerUseSetupStep.installHelper.command, "npm run setup:computer:macos")
        XCTAssertEqual(ComputerUseSetupStep.allCases.count, 2)
        XCTAssertTrue(ComputerUseSetupStep.installHelper.isSlow)
        XCTAssertFalse(ComputerUseSetupStep.buildCLI.isSlow)
    }

    func testOutcomeSuccessIsOnlyAZeroStatusThatWasNotCancelled() {
        XCTAssertTrue(
            ComputerUseSetupOutcome(step: .buildCLI, exitCode: 0, didLaunch: true, didCancel: false).didSucceed
        )
        XCTAssertFalse(
            ComputerUseSetupOutcome(step: .buildCLI, exitCode: 1, didLaunch: true, didCancel: false).didSucceed
        )
        XCTAssertFalse(
            ComputerUseSetupOutcome(step: .buildCLI, exitCode: 0, didLaunch: false, didCancel: false).didSucceed
        )
        XCTAssertFalse(
            ComputerUseSetupOutcome(step: .buildCLI, exitCode: 0, didLaunch: true, didCancel: true).didSucceed
        )
    }

    /// Opt in with `AGENTIC_SIDEBAR_LIVE_COMPUTER_USE=1`: this one spawns the
    /// real signed helper, which is the only way to prove the protocol still
    /// matches the app.
    ///
    /// It proves the *protocol*, not the grants. tccd answers Screen Recording
    /// for the responsible process, so a helper started by this test runner
    /// reports whatever the runner's own grant is — which is how a green run
    /// here once coexisted with a perfectly correct "Screen Recording missing"
    /// in the app. The app's own answer is the one that counts, and
    /// `ComputerUseStatusTests` pins that down with fakes instead.
    func testTheProbeSpeaksTheInstalledHelpersProtocol() async throws {
        guard ProcessInfo.processInfo.environment["AGENTIC_SIDEBAR_LIVE_COMPUTER_USE"] == "1" else {
            throw XCTSkip("Set AGENTIC_SIDEBAR_LIVE_COMPUTER_USE=1 to probe the installed helper")
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let helper = ComputerUseHelperStatus.inspect(homeDirectoryURL: home, fileManager: .default)
        try XCTSkipUnless(helper.isInstalled, "the signed helper is not installed")

        let signing = await SystemComputerUseSignatureReader()
            .signingStatus(bundleURL: helper.bundleURL)
        print("live helper signing: identity=\(signing.identity ?? "ad-hoc") adHoc=\(signing.isAdHoc)")

        let permissions = await ComputerUseHelperProbe().probe(
            helperExecutableURL: helper.executableURL,
            timeout: .seconds(10)
        )

        let answered = try XCTUnwrap(permissions, "the helper answered no health request")
        print("live helper permissions: \(answered)")
        print(
            "note: screenCaptureAuthorized above is the caller's grant, not the helper's own row — run inside AgenticSidebar for the answer that matters"
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () async -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

// MARK: - Fixture

/// A checkout on disk: a `dist/cli.js`, an executable `node` on `PATH`, and an
/// installed helper bundle in a private home directory.
private struct ComputerUseFixture {
    let root: URL
    let home: URL
    let repo: URL
    let environment: [String: String]

    init(installHelper: Bool = true, writeCLI: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("computer-use-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        repo = root.appendingPathComponent("chatgpt-system", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)

        for directory in [home, repo, bin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        if writeCLI {
            let dist = repo.appendingPathComponent("dist", isDirectory: true)
            try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
            try Data("// cli".utf8).write(to: dist.appendingPathComponent("cli.js"))
        }

        let node = bin.appendingPathComponent("node")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: node)

        if installHelper {
            let contents =
                home
                .appendingPathComponent(".chatgpt-system", isDirectory: true)
                .appendingPathComponent("ChatGPTSystemComputerRuntime.app", isDirectory: true)
                .appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(
                at: contents.appendingPathComponent("MacOS", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("// helper".utf8).write(to: contents.appendingPathComponent("MacOS/chatgpt-system-computer-runtime"))
            let plist = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>CFBundleIdentifier</key>
                    <string>com.senoldogann.chatgpt-system.computer-runtime</string>
                    <key>CFBundleExecutable</key>
                    <string>chatgpt-system-computer-runtime</string>
                    <key>CFBundlePackageType</key>
                    <string>APPL</string>
                    <key>CFBundleName</key>
                    <string>ChatGPTSystemComputerRuntime</string>
                </dict>
                </plist>
                """
            try Data(plist.utf8).write(to: contents.appendingPathComponent("Info.plist"))
        }

        environment = ["PATH": bin.path, "HOME": home.path]
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
