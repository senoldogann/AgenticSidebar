import Foundation
import XCTest

@testable import AgenticSidebar

final class OpenCodeServerManagerTests: XCTestCase {
    func testStartFailsWhenExecutableIsUnavailable() async {
        let launcher = RecordingOpenCodeProcessLauncher()
        let manager = ManagedOpenCodeServerManager(
            executableLocator: StubOpenCodeExecutableLocator(url: nil),
            processLauncher: launcher,
            healthChecker: StubOpenCodeHealthChecker(result: .success("1.18.31")),
            portAllocator: StubOpenCodePortAllocator(port: 51160),
            listenerVerifier: StubListenerVerifier(owns: true),
            credentialStore: InMemoryOpenCodeCredentialStore(),
            workingDirectoryURL: makeWorkingDirectory(),
            passwordGenerator: { "generated-password" }
        )

        await assertThrowsErrorAsync(
            try await manager.start(computerUse: nil)
        ) { error in
            XCTAssertEqual(error as? ProviderRuntimeError, .executableUnavailable)
        }
        let launchCount = await launcher.launchCount()
        XCTAssertEqual(launchCount, 0)
    }

    func testStartLaunchesAuthenticatedLoopbackServerAndReportsVersion() async throws {
        let launcher = RecordingOpenCodeProcessLauncher()
        let credentialStore = InMemoryOpenCodeCredentialStore()
        let workingDirectoryURL = makeWorkingDirectory()
        let manager = ManagedOpenCodeServerManager(
            executableLocator: StubOpenCodeExecutableLocator(
                url: URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
            ),
            processLauncher: launcher,
            healthChecker: StubOpenCodeHealthChecker(result: .success("1.18.31")),
            portAllocator: StubOpenCodePortAllocator(port: 51161),
            listenerVerifier: StubListenerVerifier(owns: true),
            credentialStore: credentialStore,
            workingDirectoryURL: workingDirectoryURL,
            passwordGenerator: { "generated-password" }
        )

        let connection = try await manager.start(computerUse: nil)
        let lastRequest = await launcher.lastRequest()
        let request = try XCTUnwrap(lastRequest)

        XCTAssertEqual(request.executableURL.path, "/opt/homebrew/bin/opencode")
        XCTAssertEqual(
            request.arguments,
            ["serve", "--hostname", "127.0.0.1", "--port", "51161"],
            "`--pure` means \"no external plugins\": it would disable every plugin the app configures"
        )
        XCTAssertEqual(request.environment["OPENCODE_SERVER_USERNAME"], "opencode")
        XCTAssertEqual(request.environment["OPENCODE_SERVER_PASSWORD"], "generated-password")
        XCTAssertEqual(request.workingDirectoryURL, workingDirectoryURL)
        XCTAssertEqual(
            request.environment["OPENCODE_CONFIG"],
            workingDirectoryURL.appendingPathComponent(ManagedOpenCodeConfiguration.fileName).path,
            "Injected working directory must also scope the generated configuration"
        )
        XCTAssertEqual(connection.baseURL.absoluteString, "http://127.0.0.1:51161")
        XCTAssertEqual(connection.username, "opencode")
        XCTAssertEqual(connection.password, "generated-password")
        XCTAssertEqual(
            try credentialStore.read(.openCodeServerPassword),
            "generated-password"
        )
        let status = await manager.status()
        XCTAssertEqual(status, .running(version: "1.18.31", baseURL: connection.baseURL))
    }

    func testServerPasswordRotatesOnEveryStart() async throws {
        let launcher = RecordingOpenCodeProcessLauncher()
        let credentialStore = InMemoryOpenCodeCredentialStore(
            values: [.openCodeServerPassword: "stored-password"]
        )
        let generator = RotatingPasswordGenerator(passwords: ["first-password", "second-password"])
        let manager = ManagedOpenCodeServerManager(
            executableLocator: StubOpenCodeExecutableLocator(
                url: URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
            ),
            processLauncher: launcher,
            healthChecker: StubOpenCodeHealthChecker(result: .success("1.18.31")),
            portAllocator: StubOpenCodePortAllocator(port: 51162),
            listenerVerifier: StubListenerVerifier(owns: true),
            credentialStore: credentialStore,
            workingDirectoryURL: makeWorkingDirectory(),
            passwordGenerator: {
                await generator.next()
            }
        )

        let first = try await manager.start(computerUse: nil)
        await manager.stop()
        let second = try await manager.start(computerUse: nil)

        XCTAssertEqual(first.password, "first-password")
        XCTAssertEqual(second.password, "second-password")
        let requests = await launcher.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].environment["OPENCODE_SERVER_PASSWORD"], "first-password")
        XCTAssertEqual(requests[1].environment["OPENCODE_SERVER_PASSWORD"], "second-password")
        XCTAssertEqual(
            try credentialStore.read(.openCodeServerPassword),
            "second-password"
        )
    }

    func testHealthFailureTerminatesChildAndClearsConnection() async {
        let launcher = RecordingOpenCodeProcessLauncher()
        let manager = ManagedOpenCodeServerManager(
            executableLocator: StubOpenCodeExecutableLocator(
                url: URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
            ),
            processLauncher: launcher,
            healthChecker: StubOpenCodeHealthChecker(result: .failure(.startupFailure)),
            portAllocator: StubOpenCodePortAllocator(port: 51163),
            listenerVerifier: StubListenerVerifier(owns: true),
            credentialStore: InMemoryOpenCodeCredentialStore(),
            workingDirectoryURL: makeWorkingDirectory(),
            passwordGenerator: { "generated-password" }
        )

        await assertThrowsErrorAsync(
            try await manager.start(computerUse: nil)
        ) { error in
            XCTAssertEqual(error as? ProviderRuntimeError, .startupFailure)
        }

        // A failed health check is retried once on a fresh port, so two children
        // are launched and both must be terminated.
        let launchCount = await launcher.requests().count
        XCTAssertEqual(launchCount, 2)

        let handle = await launcher.lastHandle()
        if let handle {
            let terminationCount = await handle.terminationCount()
            XCTAssertEqual(terminationCount, 1)
        } else {
            XCTFail("Expected launched process handle")
        }
        let currentConnection = await manager.currentConnection()
        XCTAssertNil(currentConnection)
        let status = await manager.status()
        XCTAssertEqual(status, .stopped)
    }

    /// The password is only sent to a port the child owns. When the verifier says
    /// the port belongs to somebody else, no credentialed request may go out at
    /// all — the start has to fail instead.
    func testAStartRefusesToSendCredentialsToAPortTheChildDoesNotOwn() async {
        let launcher = RecordingOpenCodeProcessLauncher()
        let healthChecker = CountingOpenCodeHealthChecker()
        let manager = ManagedOpenCodeServerManager(
            executableLocator: StubOpenCodeExecutableLocator(
                url: URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
            ),
            processLauncher: launcher,
            healthChecker: healthChecker,
            portAllocator: StubOpenCodePortAllocator(port: 51165),
            listenerVerifier: StubListenerVerifier(owns: false),
            credentialStore: InMemoryOpenCodeCredentialStore(),
            workingDirectoryURL: makeWorkingDirectory(),
            passwordGenerator: { "generated-password" }
        )

        await assertThrowsErrorAsync(
            try await manager.start(computerUse: nil)
        ) { error in
            XCTAssertEqual(error as? ProviderRuntimeError, .startupFailure)
        }

        let healthChecks = await healthChecker.attempts()
        XCTAssertEqual(
            healthChecks,
            0,
            "The health request carries the password, so it must not be sent before ownership is proven"
        )

        let handle = await launcher.lastHandle()
        if let handle {
            let terminationCount = await handle.terminationCount()
            XCTAssertEqual(terminationCount, 1, "The child it did launch is not left running")
        } else {
            XCTFail("Expected launched process handle")
        }
    }

    func testStopTerminatesOwnedProcess() async throws {
        let launcher = RecordingOpenCodeProcessLauncher()
        let manager = ManagedOpenCodeServerManager(
            executableLocator: StubOpenCodeExecutableLocator(
                url: URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
            ),
            processLauncher: launcher,
            healthChecker: StubOpenCodeHealthChecker(result: .success("1.18.31")),
            portAllocator: StubOpenCodePortAllocator(port: 51164),
            listenerVerifier: StubListenerVerifier(owns: true),
            credentialStore: InMemoryOpenCodeCredentialStore(),
            workingDirectoryURL: makeWorkingDirectory(),
            passwordGenerator: { "generated-password" }
        )

        _ = try await manager.start(computerUse: nil)
        let handle = await launcher.lastHandle()

        await manager.stop()

        if let handle {
            let terminationCount = await handle.terminationCount()
            XCTAssertEqual(terminationCount, 1)
        } else {
            XCTFail("Expected launched process handle")
        }
        let currentConnection = await manager.currentConnection()
        XCTAssertNil(currentConnection)
        let status = await manager.status()
        XCTAssertEqual(status, .stopped)
    }
}

private func makeWorkingDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("AgenticSidebar-OpenCode-tests-\(UUID().uuidString)", isDirectory: true)
}

private struct StubOpenCodeExecutableLocator: OpenCodeExecutableLocating {
    let url: URL?
    func resolution() -> OpenCodeExecutableResolution {
        url.map { .found($0) } ?? .notFound
    }
}

/// Reporting every port as the child's own keeps these tests about startup
/// bookkeeping; the refusal path has its own test.
private struct StubListenerVerifier: OpenCodeListenerVerifying {
    let owns: Bool

    func waitUntilProcessOwnsListeningPort(
        _ port: UInt16,
        processIdentifier: Int32?
    ) async -> Bool {
        owns
    }
}

private struct StubOpenCodePortAllocator: OpenCodePortAllocating {
    let port: UInt16
    func allocate() throws -> UInt16 { port }
}

private struct StubOpenCodeHealthChecker: OpenCodeHealthChecking {
    let result: Result<String, ProviderRuntimeError>

    func waitUntilHealthy(connection: OpenCodeServerConnection) async throws -> String {
        try result.get()
    }
}

/// Counts the credentialed requests it was asked to make.
private actor CountingOpenCodeHealthChecker: OpenCodeHealthChecking {
    private var count = 0

    func attempts() -> Int {
        count
    }

    func waitUntilHealthy(connection: OpenCodeServerConnection) async throws -> String {
        count += 1
        return "1.18.31"
    }
}

private actor RecordingOpenCodeProcessHandle: OpenCodeProcessHandling {
    private var terminations = 0
    private var crashed = false
    private let reportedPID: Int32?

    init(reportedPID: Int32? = 4242) {
        self.reportedPID = reportedPID
    }

    /// The child exited without telling the manager (crash, external kill).
    func crash() {
        crashed = true
    }

    func isRunning() async -> Bool {
        terminations == 0 && !crashed
    }

    func processIdentifier() async -> Int32? {
        terminations == 0 && !crashed ? reportedPID : nil
    }

    func terminate() async {
        terminations += 1
    }

    func terminationCount() -> Int {
        terminations
    }
}

private actor RecordingOpenCodeProcessLauncher: OpenCodeProcessLaunching {
    private var recordedRequests: [OpenCodeProcessLaunchRequest] = []
    private var handles: [RecordingOpenCodeProcessHandle] = []
    private let reportedPID: Int32?

    init(reportedPID: Int32? = 4242) {
        self.reportedPID = reportedPID
    }

    func launch(_ request: OpenCodeProcessLaunchRequest) async throws -> any OpenCodeProcessHandling {
        recordedRequests.append(request)
        let handle = RecordingOpenCodeProcessHandle(reportedPID: reportedPID)
        handles.append(handle)
        return handle
    }

    func launchCount() -> Int { recordedRequests.count }
    func lastRequest() -> OpenCodeProcessLaunchRequest? { recordedRequests.last }
    func requests() -> [OpenCodeProcessLaunchRequest] { recordedRequests }
    func lastHandle() -> RecordingOpenCodeProcessHandle? { handles.last }
    func recordedHandles() -> [RecordingOpenCodeProcessHandle] { handles }
}

private final class InMemoryOpenCodeCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CredentialKey: String]

    init(values: [CredentialKey: String] = [:]) {
        self.values = values
    }

    func contains(_ key: CredentialKey) throws -> Bool {
        lock.withLock { values[key] != nil }
    }

    func read(_ key: CredentialKey) throws -> String? {
        lock.withLock { values[key] }
    }

    func write(_ value: String, for key: CredentialKey) throws {
        lock.withLock { values[key] = value }
    }

    func delete(_ key: CredentialKey) throws {
        _ = lock.withLock { values.removeValue(forKey: key) }
    }
}

private actor RotatingPasswordGenerator {
    private var passwords: [String]
    init(passwords: [String]) {
        self.passwords = passwords
    }
    func next() -> String {
        guard !passwords.isEmpty else {
            return "fallback-password"
        }
        return passwords.removeFirst()
    }
}

private func assertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

/// Çalışma alanına köklenmiş sunucu fabrikasının sözleşmesi: her koşu kendi
/// kökünde, kendi portunda, kendi durum ad alanında bir sunucu alır; aynı
/// çalışma alanı için ikinci sunucu açılmaz; bırakma çocuğu sonlandırır ve
/// hiçbir kalıntı bırakmaz.
final class OpenCodeWorkspaceServerFactoryTests: XCTestCase {
    func testAcquireRootsServerAtWorkspaceWithIsolatedStateNamespaceAndReleasesOnStop() async throws {
        let workspace = try makeExistingWorkspace()
        let stateRoot = makeWorkingDirectory()
        let launcher = RecordingOpenCodeProcessLauncher(reportedPID: 7_001)
        let factory = makeFactory(
            launcher: launcher,
            ports: [52_101],
            passwords: ["workspace-password"],
            stateRoot: stateRoot
        )

        let session = try await factory.acquire(workspacePath: workspace.path)
        let canonicalWorkspace = canonicalPath(workspace.path)
        XCTAssertEqual(session.workspacePath, canonicalWorkspace)
        XCTAssertEqual(session.connection.baseURL.absoluteString, "http://127.0.0.1:52101")
        XCTAssertEqual(session.connection.password, "workspace-password")

        let lastRequest = await launcher.lastRequest()
        let request = try XCTUnwrap(lastRequest)
        XCTAssertEqual(canonicalPath(request.workingDirectoryURL.path), canonicalWorkspace)
        let stateDirectory = await factory.stateDirectoryURL(forWorkspacePath: workspace.path)
        XCTAssertEqual(
            request.environment["OPENCODE_CONFIG"],
            stateDirectory.appendingPathComponent(ManagedOpenCodeConfiguration.fileName).path
        )
        XCTAssertFalse(
            request.environment["OPENCODE_CONFIG"]?.hasPrefix(canonicalWorkspace + "/") ?? true,
            "The managed configuration must not be written into the owned worktree"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workspace.appendingPathComponent("opencode.json").path
            ),
            "A workspace-rooted server must not pollute the worktree with a project config"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workspace.appendingPathComponent(ManagedOpenCodeConfiguration.fileName).path
            ),
            "A workspace-rooted server must not pollute the worktree with the managed config"
        )
        XCTAssertEqual(
            request.logDirectoryURL.resolvingSymlinksInPath().standardized.path,
            stateDirectory.resolvingSymlinksInPath().standardized.path,
            "The server log must live in the workspace state namespace, not in the owned worktree"
        )
        XCTAssertEqual(
            OpenCodeServerLedger.leases(in: stateDirectory).map(\.pid),
            [7_001],
            "The lease belongs to the workspace state namespace"
        )
        XCTAssertTrue(
            OpenCodeServerLedger.leases(in: workspace).isEmpty,
            "The owned worktree never holds server leases"
        )
        let activeAfterAcquire = await factory.activeWorkspacePaths()
        XCTAssertEqual(activeAfterAcquire, [canonicalWorkspace])

        await session.release()

        let lastHandle = await launcher.lastHandle()
        let handle = try XCTUnwrap(lastHandle)
        let terminationCountAfterRelease = await handle.terminationCount()
        XCTAssertEqual(terminationCountAfterRelease, 1)
        let connectionAfterRelease = await session.manager.currentConnection()
        XCTAssertNil(connectionAfterRelease)
        XCTAssertTrue(OpenCodeServerLedger.leases(in: stateDirectory).isEmpty)
        let activeAfterRelease = await factory.activeWorkspacePaths()
        XCTAssertTrue(activeAfterRelease.isEmpty)

        await session.release()
        let terminationCountAfterSecondRelease = await handle.terminationCount()
        XCTAssertEqual(
            terminationCountAfterSecondRelease,
            1,
            "A second release is a no-op, not a second termination"
        )
    }

    func testSecondAcquireForTheSameWorkspaceIsRefusedWhileActive() async throws {
        let workspace = try makeExistingWorkspace()
        let launcher = RecordingOpenCodeProcessLauncher()
        let factory = makeFactory(
            launcher: launcher,
            ports: [52_110, 52_111],
            passwords: ["first-password", "second-password"],
            stateRoot: makeWorkingDirectory()
        )

        let first = try await factory.acquire(workspacePath: workspace.path)
        do {
            _ = try await factory.acquire(workspacePath: workspace.path)
            XCTFail("A second server for one active workspace must be refused")
        } catch let error as OpenCodeWorkspaceServerError {
            guard case .workspaceServerAlreadyActive(let path) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, canonicalPath(workspace.path))
        }
        let launchCountAfterFirst = await launcher.launchCount()
        XCTAssertEqual(launchCountAfterFirst, 1)

        await first.release()
        let second = try await factory.acquire(workspacePath: workspace.path)
        let launchCountAfterSecond = await launcher.launchCount()
        XCTAssertEqual(launchCountAfterSecond, 2)
        XCTAssertEqual(second.connection.baseURL.absoluteString, "http://127.0.0.1:52111")
        await second.release()
    }

    func testAcquireFailsClosedWhenTheWorkspaceCannotBeRooted() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgenticSidebar-missing-\(UUID().uuidString)", isDirectory: true)
        let launcher = RecordingOpenCodeProcessLauncher()
        let factory = makeFactory(
            launcher: launcher,
            ports: [52_120],
            passwords: ["unused-password"],
            stateRoot: makeWorkingDirectory()
        )

        do {
            _ = try await factory.acquire(workspacePath: missing.path)
            XCTFail("A workspace that does not exist must not be rooted")
        } catch let error as OpenCodeWorkspaceServerError {
            guard case .workspaceNotRootable(let path, let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, canonicalPath(missing.path))
            XCTAssertFalse(reason.isEmpty)
        }
        let launchCount = await launcher.launchCount()
        XCTAssertEqual(launchCount, 0, "Nothing may be launched for an unrootable workspace")
        let activePaths = await factory.activeWorkspacePaths()
        XCTAssertTrue(activePaths.isEmpty)
    }

    func testDistinctWorkspacesGetDistinctPortsPasswordsAndStateNamespaces() async throws {
        let firstWorkspace = try makeExistingWorkspace()
        let secondWorkspace = try makeExistingWorkspace()
        let launcher = RecordingOpenCodeProcessLauncher()
        let stateRoot = makeWorkingDirectory()
        let factory = makeFactory(
            launcher: launcher,
            ports: [52_130, 52_131],
            passwords: ["password-a", "password-b"],
            stateRoot: stateRoot
        )

        let first = try await factory.acquire(workspacePath: firstWorkspace.path)
        let second = try await factory.acquire(workspacePath: secondWorkspace.path)

        XCTAssertNotEqual(first.connection.baseURL, second.connection.baseURL)
        XCTAssertNotEqual(first.connection.password, second.connection.password)
        let firstState = await factory.stateDirectoryURL(forWorkspacePath: firstWorkspace.path)
        let secondState = await factory.stateDirectoryURL(forWorkspacePath: secondWorkspace.path)
        XCTAssertNotEqual(firstState, secondState)
        XCTAssertTrue(firstState.path.hasPrefix(stateRoot.path))
        XCTAssertTrue(secondState.path.hasPrefix(stateRoot.path))

        await first.release()
        let secondConnection = await second.manager.currentConnection()
        XCTAssertNotNil(secondConnection, "Stopping one workspace server must not touch another")
        let activePaths = await factory.activeWorkspacePaths()
        XCTAssertEqual(activePaths, [canonicalPath(secondWorkspace.path)])
        await second.release()
    }

    func testStartupFailureLeavesNoActiveSlotAndTerminatesEveryChild() async throws {
        let workspace = try makeExistingWorkspace()
        let launcher = RecordingOpenCodeProcessLauncher()
        let healthChecker = ScriptedOpenCodeHealthChecker(
            results: [.failure(.startupFailure), .failure(.startupFailure), .success("1.18.31")]
        )
        let factory = OpenCodeWorkspaceServerFactory(
            executableLocator: StubOpenCodeExecutableLocator(
                url: URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
            ),
            processLauncher: launcher,
            healthChecker: healthChecker,
            portAllocator: SequencedOpenCodePortAllocator(ports: [52_140, 52_141, 52_142]),
            listenerVerifier: StubListenerVerifier(owns: true),
            credentialStore: InMemoryOpenCodeCredentialStore(),
            stateRootURL: makeWorkingDirectory(),
            passwordGenerator: { "generated-password" }
        )

        do {
            _ = try await factory.acquire(workspacePath: workspace.path)
            XCTFail("A server that never becomes healthy must fail closed")
        } catch let error as OpenCodeWorkspaceServerError {
            guard case .startupFailed(let path, let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, canonicalPath(workspace.path))
            XCTAssertFalse(reason.isEmpty)
        }

        let activeAfterFailure = await factory.activeWorkspacePaths()
        XCTAssertTrue(
            activeAfterFailure.isEmpty,
            "A failed start must not leave the workspace reserved"
        )
        // Health is retried once on a fresh port; both children must be terminated.
        let handles = await launcher.recordedHandles()
        XCTAssertEqual(handles.count, 2)
        for handle in handles {
            let terminationCount = await handle.terminationCount()
            XCTAssertEqual(terminationCount, 1)
        }

        // The slot is free again: the next acquire (health now succeeds) works.
        let session = try await factory.acquire(workspacePath: workspace.path)
        XCTAssertEqual(session.connection.baseURL.absoluteString, "http://127.0.0.1:52142")
        await session.release()
        let activeAfterSuccess = await factory.activeWorkspacePaths()
        XCTAssertTrue(activeAfterSuccess.isEmpty)
    }

    func testStaleReleaseCannotStopAServerStartedLaterForTheSameWorkspace() async throws {
        let workspace = try makeExistingWorkspace()
        let launcher = RecordingOpenCodeProcessLauncher()
        let factory = makeFactory(
            launcher: launcher,
            ports: [52_150, 52_151],
            passwords: ["password-one", "password-two"],
            stateRoot: makeWorkingDirectory()
        )

        let first = try await factory.acquire(workspacePath: workspace.path)
        await first.release()
        let second = try await factory.acquire(workspacePath: workspace.path)

        // Eski oturumun bırakması yeni sunucuya dokunmamalı.
        await first.release()
        let secondConnection = await second.manager.currentConnection()
        XCTAssertNotNil(secondConnection)
        let activePaths = await factory.activeWorkspacePaths()
        XCTAssertEqual(activePaths, [canonicalPath(workspace.path)])
        await second.release()
    }

    func testWorkspaceServersDoNotTouchTheChatServerLifecycle() async throws {
        let workspace = try makeExistingWorkspace()
        let chatLauncher = RecordingOpenCodeProcessLauncher(reportedPID: 7_100)
        let chatManager = ManagedOpenCodeServerManager(
            executableLocator: StubOpenCodeExecutableLocator(
                url: URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
            ),
            processLauncher: chatLauncher,
            healthChecker: StubOpenCodeHealthChecker(result: .success("1.18.31")),
            portAllocator: StubOpenCodePortAllocator(port: 52_300),
            listenerVerifier: StubListenerVerifier(owns: true),
            credentialStore: InMemoryOpenCodeCredentialStore(),
            workingDirectoryURL: makeWorkingDirectory(),
            passwordGenerator: { "chat-password" }
        )
        let chatConnection = try await chatManager.start(computerUse: nil)

        let workspaceLauncher = RecordingOpenCodeProcessLauncher(reportedPID: 7_101)
        let factory = makeFactory(
            launcher: workspaceLauncher,
            ports: [52_301],
            passwords: ["workspace-password"],
            stateRoot: makeWorkingDirectory()
        )
        let session = try await factory.acquire(workspacePath: workspace.path)

        XCTAssertNotEqual(session.connection.baseURL, chatConnection.baseURL)
        XCTAssertNotEqual(session.connection.password, chatConnection.password)
        let workspaceRequest = await workspaceLauncher.lastRequest()
        let chatRequest = await chatLauncher.lastRequest()
        XCTAssertNotEqual(workspaceRequest?.workingDirectoryURL, chatRequest?.workingDirectoryURL)

        let lastChatHandle = await chatLauncher.lastHandle()
        let chatHandle = try XCTUnwrap(lastChatHandle)
        let chatTerminationsBefore = await chatHandle.terminationCount()
        XCTAssertEqual(chatTerminationsBefore, 0)
        let chatConnectionWhileWorkspaceRuns = await chatManager.currentConnection()
        XCTAssertEqual(chatConnectionWhileWorkspaceRuns, chatConnection)

        await session.release()

        let chatConnectionAfterRelease = await chatManager.currentConnection()
        XCTAssertEqual(
            chatConnectionAfterRelease,
            chatConnection,
            "Releasing a workspace server must leave the chat server exactly as it was"
        )
        let chatTerminationsAfter = await chatHandle.terminationCount()
        XCTAssertEqual(chatTerminationsAfter, 0)

        await chatManager.stop()
    }
    func testStopAllEndsEveryActiveWorkspaceServerAndIsIdempotent() async throws {
        let firstWorkspace = try makeExistingWorkspace()
        let secondWorkspace = try makeExistingWorkspace()
        let launcher = RecordingOpenCodeProcessLauncher()
        let stateRoot = makeWorkingDirectory()
        let factory = makeFactory(
            launcher: launcher,
            ports: [52_160, 52_161],
            passwords: ["password-one", "password-two"],
            stateRoot: stateRoot
        )

        _ = try await factory.acquire(workspacePath: firstWorkspace.path)
        _ = try await factory.acquire(workspacePath: secondWorkspace.path)

        let stopped = await factory.stopAll()
        XCTAssertEqual(stopped.stopped, 2)
        XCTAssertFalse(stopped.timedOut)
        let handles = await launcher.recordedHandles()
        XCTAssertEqual(handles.count, 2)
        for handle in handles {
            let terminations = await handle.terminationCount()
            XCTAssertEqual(terminations, 1)
        }
        let activeAfterStop = await factory.activeWorkspacePaths()
        XCTAssertTrue(activeAfterStop.isEmpty)
        let firstState = await factory.stateDirectoryURL(forWorkspacePath: firstWorkspace.path)
        let secondState = await factory.stateDirectoryURL(forWorkspacePath: secondWorkspace.path)
        XCTAssertTrue(OpenCodeServerLedger.leases(in: firstState).isEmpty)
        XCTAssertTrue(OpenCodeServerLedger.leases(in: secondState).isEmpty)

        let stoppedAgain = await factory.stopAll()
        XCTAssertEqual(stoppedAgain.stopped, 0)
        XCTAssertFalse(stoppedAgain.timedOut)
    }

    // MARK: - Yardımcılar

    private func makeFactory(
        launcher: RecordingOpenCodeProcessLauncher,
        ports: [UInt16],
        passwords: [String],
        stateRoot: URL
    ) -> OpenCodeWorkspaceServerFactory {
        let generator = RotatingPasswordGenerator(passwords: passwords)
        return OpenCodeWorkspaceServerFactory(
            executableLocator: StubOpenCodeExecutableLocator(
                url: URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
            ),
            processLauncher: launcher,
            healthChecker: StubOpenCodeHealthChecker(result: .success("1.18.31")),
            portAllocator: SequencedOpenCodePortAllocator(ports: ports),
            listenerVerifier: StubListenerVerifier(owns: true),
            credentialStore: InMemoryOpenCodeCredentialStore(),
            stateRootURL: stateRoot,
            passwordGenerator: { await generator.next() }
        )
    }

    private func makeExistingWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgenticSidebar-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    }
}

/// Üretim başlatıcının günlük konumu: sunucu günlüğü çalışma dizinine değil
/// isteğin günlük dizinine yazılır. Çalışma alanına köklenmiş sunucularda
/// çalışma dizini sahipli çalışma kopyasıdır; günlük oraya düşerse izlenmeyen
/// dosya olarak parmak izini bozar ve çalışma kopyasını kirletir.
final class FoundationOpenCodeProcessLauncherLogTests: XCTestCase {
    func testLaunchWritesServerLogToLogDirectoryNotWorkingDirectory() async throws {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgenticSidebar-workdir-\(UUID().uuidString)", isDirectory: true)
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgenticSidebar-logdir-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workingDirectory)
            try? FileManager.default.removeItem(at: logDirectory)
        }

        let launcher = FoundationOpenCodeProcessLauncher()
        let request = OpenCodeProcessLaunchRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            environment: [:],
            workingDirectoryURL: workingDirectory,
            logDirectoryURL: logDirectory
        )
        let handle = try await launcher.launch(request)
        await handle.terminate()

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: logDirectory.appendingPathComponent("opencode-server.log").path
            ),
            "The server log must be written to the request's log directory"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workingDirectory.appendingPathComponent("opencode-server.log").path
            ),
            "The server log must not pollute the working directory"
        )
    }
}

/// Sırayla farklı portlar dağıtır; tükenirse başlatma hatası verir.
private final class SequencedOpenCodePortAllocator: OpenCodePortAllocating, @unchecked Sendable {
    private let lock = NSLock()
    private var ports: [UInt16]

    init(ports: [UInt16]) {
        self.ports = ports
    }

    func allocate() throws -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        guard !ports.isEmpty else {
            throw ProviderRuntimeError.startupFailure
        }
        return ports.removeFirst()
    }
}

/// Sıradaki sağlık yanıtını döndürür; script tükenirse son sonucu yineler.
private actor ScriptedOpenCodeHealthChecker: OpenCodeHealthChecking {
    private var results: [Result<String, ProviderRuntimeError>]

    init(results: [Result<String, ProviderRuntimeError>]) {
        self.results = results
    }

    func waitUntilHealthy(connection: OpenCodeServerConnection) async throws -> String {
        let result: Result<String, ProviderRuntimeError>
        if results.count > 1 {
            result = results.removeFirst()
        } else {
            result = results.first ?? .failure(.startupFailure)
        }
        return try result.get()
    }
}

/// Runtime lifecycle (T3): noticing a dead child must end its tree and forget
/// its lease, like stop() does — not just drop the handles.
final class OpenCodeServerManagerDeadChildTests: XCTestCase {
    func testStatusAfterChildDeathTerminatesTreeAndReleasesLease() async throws {
        let launcher = RecordingOpenCodeProcessLauncher()
        let workingDirectoryURL = makeWorkingDirectory()
        let manager = ManagedOpenCodeServerManager(
            executableLocator: StubOpenCodeExecutableLocator(
                url: URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
            ),
            processLauncher: launcher,
            healthChecker: StubOpenCodeHealthChecker(result: .success("1.18.31")),
            portAllocator: StubOpenCodePortAllocator(port: 51170),
            listenerVerifier: StubListenerVerifier(owns: true),
            credentialStore: InMemoryOpenCodeCredentialStore(),
            workingDirectoryURL: workingDirectoryURL,
            passwordGenerator: { "generated-password" }
        )

        _ = try await manager.start(computerUse: nil)
        let launchedHandle = await launcher.lastHandle()
        let handle = try XCTUnwrap(launchedHandle)
        XCTAssertEqual(OpenCodeServerLedger.leases(in: workingDirectoryURL).count, 1)

        await handle.crash()

        let status = await manager.status()
        XCTAssertEqual(status, .stopped)
        let connectionAfterDeath = await manager.currentConnection()
        XCTAssertNil(connectionAfterDeath)
        let terminationCount = await handle.terminationCount()
        XCTAssertEqual(
            terminationCount,
            1,
            "The dead child's MCP tree must be terminated, not left behind"
        )
        XCTAssertTrue(
            OpenCodeServerLedger.leases(in: workingDirectoryURL).isEmpty,
            "The stale lease must be released so the next launch starts clean"
        )
    }

    func testUnknownPidRecordsNoLeaseAndReleasesNothing() async throws {
        let launcher = RecordingOpenCodeProcessLauncher(reportedPID: nil)
        let workingDirectoryURL = makeWorkingDirectory()
        let manager = ManagedOpenCodeServerManager(
            executableLocator: StubOpenCodeExecutableLocator(
                url: URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
            ),
            processLauncher: launcher,
            healthChecker: StubOpenCodeHealthChecker(result: .success("1.18.31")),
            portAllocator: StubOpenCodePortAllocator(port: 51171),
            listenerVerifier: StubListenerVerifier(owns: true),
            credentialStore: InMemoryOpenCodeCredentialStore(),
            workingDirectoryURL: workingDirectoryURL,
            passwordGenerator: { "generated-password" }
        )

        _ = try await manager.start(computerUse: nil)
        XCTAssertTrue(
            OpenCodeServerLedger.leases(in: workingDirectoryURL).isEmpty,
            "An unknown pid must not leave a 0.json lease behind"
        )
        let status = await manager.status()
        XCTAssertEqual(
            status,
            .running(
                version: "1.18.31",
                baseURL: URL(string: "http://127.0.0.1:51171")!
            )
        )

        await manager.stop()
        XCTAssertTrue(
            OpenCodeServerLedger.leases(in: workingDirectoryURL).isEmpty,
            "Stopping without a known pid releases nothing, and crashes nothing"
        )
    }
}
