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
            credentialStore: InMemoryOpenCodeCredentialStore(),
            workingDirectoryURL: URL(fileURLWithPath: "/tmp/AgenticSidebar-OpenCode-tests", isDirectory: true),
            passwordGenerator: { "generated-password" }
        )

        await XCTAssertThrowsErrorAsync(
            try await manager.start()
        ) { error in
            XCTAssertEqual(error as? ProviderRuntimeError, .executableUnavailable)
        }
        let launchCount = await launcher.launchCount()
        XCTAssertEqual(launchCount, 0)
    }

    func testStartLaunchesAuthenticatedLoopbackServerAndReportsVersion() async throws {
        let launcher = RecordingOpenCodeProcessLauncher()
        let credentialStore = InMemoryOpenCodeCredentialStore()
        let workingDirectoryURL = URL(
            fileURLWithPath: "/tmp/AgenticSidebar-OpenCode-tests",
            isDirectory: true
        )
        let manager = ManagedOpenCodeServerManager(
            executableLocator: StubOpenCodeExecutableLocator(
                url: URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
            ),
            processLauncher: launcher,
            healthChecker: StubOpenCodeHealthChecker(result: .success("1.18.31")),
            portAllocator: StubOpenCodePortAllocator(port: 51161),
            credentialStore: credentialStore,
            workingDirectoryURL: workingDirectoryURL,
            passwordGenerator: { "generated-password" }
        )

        let connection = try await manager.start()
        let lastRequest = await launcher.lastRequest()
        let request = try XCTUnwrap(lastRequest)

        XCTAssertEqual(request.executableURL.path, "/opt/homebrew/bin/opencode")
        XCTAssertEqual(
            request.arguments,
            ["serve", "--hostname", "127.0.0.1", "--port", "51161", "--pure"]
        )
        XCTAssertEqual(request.environment["OPENCODE_SERVER_USERNAME"], "opencode")
        XCTAssertEqual(request.environment["OPENCODE_SERVER_PASSWORD"], "generated-password")
        XCTAssertEqual(request.workingDirectoryURL, workingDirectoryURL)
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

    func testStoredServerPasswordIsReusedAcrossManagedRestarts() async throws {
        let launcher = RecordingOpenCodeProcessLauncher()
        let credentialStore = InMemoryOpenCodeCredentialStore(
            values: [.openCodeServerPassword: "stored-password"]
        )
        let generator = PasswordGenerationProbe()
        let manager = ManagedOpenCodeServerManager(
            executableLocator: StubOpenCodeExecutableLocator(
                url: URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
            ),
            processLauncher: launcher,
            healthChecker: StubOpenCodeHealthChecker(result: .success("1.18.31")),
            portAllocator: StubOpenCodePortAllocator(port: 51162),
            credentialStore: credentialStore,
            workingDirectoryURL: URL(fileURLWithPath: "/tmp/AgenticSidebar-OpenCode-tests", isDirectory: true),
            passwordGenerator: {
                await generator.record()
                return "new-password"
            }
        )

        _ = try await manager.start()
        await manager.stop()
        _ = try await manager.start()

        let requests = await launcher.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(
            requests.allSatisfy {
                $0.environment["OPENCODE_SERVER_PASSWORD"] == "stored-password"
            }
        )
        let generationCount = await generator.count()
        XCTAssertEqual(generationCount, 0)
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
            credentialStore: InMemoryOpenCodeCredentialStore(),
            workingDirectoryURL: URL(fileURLWithPath: "/tmp/AgenticSidebar-OpenCode-tests", isDirectory: true),
            passwordGenerator: { "generated-password" }
        )

        await XCTAssertThrowsErrorAsync(
            try await manager.start()
        ) { error in
            XCTAssertEqual(error as? ProviderRuntimeError, .startupFailure)
        }

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

    func testStopTerminatesOwnedProcess() async throws {
        let launcher = RecordingOpenCodeProcessLauncher()
        let manager = ManagedOpenCodeServerManager(
            executableLocator: StubOpenCodeExecutableLocator(
                url: URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
            ),
            processLauncher: launcher,
            healthChecker: StubOpenCodeHealthChecker(result: .success("1.18.31")),
            portAllocator: StubOpenCodePortAllocator(port: 51164),
            credentialStore: InMemoryOpenCodeCredentialStore(),
            workingDirectoryURL: URL(fileURLWithPath: "/tmp/AgenticSidebar-OpenCode-tests", isDirectory: true),
            passwordGenerator: { "generated-password" }
        )

        _ = try await manager.start()
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

private struct StubOpenCodeExecutableLocator: OpenCodeExecutableLocating {
    let url: URL?
    func locate() -> URL? { url }
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

private actor RecordingOpenCodeProcessHandle: OpenCodeProcessHandling {
    private var terminations = 0

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

    func launch(_ request: OpenCodeProcessLaunchRequest) async throws -> any OpenCodeProcessHandling {
        recordedRequests.append(request)
        let handle = RecordingOpenCodeProcessHandle()
        handles.append(handle)
        return handle
    }

    func launchCount() -> Int { recordedRequests.count }
    func lastRequest() -> OpenCodeProcessLaunchRequest? { recordedRequests.last }
    func requests() -> [OpenCodeProcessLaunchRequest] { recordedRequests }
    func lastHandle() -> RecordingOpenCodeProcessHandle? { handles.last }
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

private actor PasswordGenerationProbe {
    private var generationCount = 0
    func record() { generationCount += 1 }
    func count() -> Int { generationCount }
}

private func XCTAssertThrowsErrorAsync<T>(
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
