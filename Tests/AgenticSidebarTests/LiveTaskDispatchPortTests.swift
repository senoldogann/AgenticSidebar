import Foundation
import Synchronization
import XCTest

@testable import AgenticSidebar

/// Canlı gönderim yolunun (üretim portu, uygunluk kapısı, kurtarma portları ve
/// parmak izi sağlayıcısı) sözleşmelerini sınayan testler.
final class LiveTaskDispatchPortTests: XCTestCase {

    // MARK: - Port eşlemesi ve iptal

    func testPortMapsTaskRunRequestIntoExecutionRequest() async throws {
        let runtime = StubCodingAgentRuntime(runtimeID: "stub-runtime")
        await runtime.scriptTerminalSuccess()
        let registry = CodingAgentRegistry()
        registry.register(runtime: runtime)
        let port = LiveOpenCodeTaskRunningPort(
            registry: registry,
            workspaceServerFactory: nil,
            clientFactory: { _ in PortTestOpenCodeClient() }
        )

        let taskID = UUID()
        let attemptID = UUID()
        let attempt = TaskAttempt(
            id: attemptID,
            taskID: taskID,
            attemptSequence: 2,
            role: .developer,
            providerID: "stub-runtime",
            modelID: "stub-model",
            generation: 3,
            startedAt: Date()
        )
        let task = CodingTask(
            id: taskID,
            projectID: UUID(),
            title: "Live dispatch",
            objective: "Map every field",
            status: .running,
            stage: .implementation,
            criteria: [CodingAcceptanceCriterion(taskID: taskID, description: "mapped")]
        )
        let workspace = TaskWorkspaceDescriptor(
            workspaceID: UUID(),
            workspacePath: "/tmp/workspace",
            repositoryPath: "/tmp/repository"
        )
        let deadline = Date().addingTimeInterval(120)
        let request = TaskRunRequest(
            task: task,
            attempt: attempt,
            workspace: workspace,
            approvalPolicy: .approveSafe,
            deadline: deadline
        )

        let session = try await port.start(request, approvalResolver: { _ in .approveOnce })
        var events: [CodingAgentEvent] = []
        for await event in session.events {
            events.append(event)
        }

        let capturedValue = await runtime.capturedRequest()
        let captured = try XCTUnwrap(capturedValue)
        XCTAssertEqual(captured.taskID, taskID)
        XCTAssertEqual(captured.attemptID, attemptID)
        XCTAssertEqual(captured.generation, 3)
        XCTAssertEqual(captured.role, .developer)
        XCTAssertEqual(captured.configuration.providerID, ProviderID("stub-runtime"))
        XCTAssertEqual(captured.configuration.modelID, ProviderModelID("stub-model"))
        XCTAssertEqual(captured.objective, "Map every field")
        XCTAssertEqual(captured.acceptanceCriteria.map(\.description), ["mapped"])
        XCTAssertEqual(captured.workspacePath, "/tmp/workspace")
        XCTAssertEqual(captured.stage, .implementation)
        XCTAssertEqual(captured.deadline, deadline)
        XCTAssertTrue(CodingAgentRun.isTerminatedSuccessfully(events: events))
    }

    func testPortHonorsCancelAndFinishesTheStream() async throws {
        let runtime = StubCodingAgentRuntime(runtimeID: "stub-runtime")
        await runtime.scriptHangingRun()
        let registry = CodingAgentRegistry()
        registry.register(runtime: runtime)
        let port = LiveOpenCodeTaskRunningPort(
            registry: registry,
            workspaceServerFactory: nil,
            clientFactory: { _ in PortTestOpenCodeClient() }
        )
        let request = makePortRequest(runtimeID: "stub-runtime")

        let session = try await port.start(request, approvalResolver: { _ in .approveOnce })
        let collector = Task { () -> [CodingAgentEvent] in
            var events: [CodingAgentEvent] = []
            for await event in session.events {
                events.append(event)
            }
            return events
        }
        // İlk olay akışa girene kadar bekle, sonra iptal et: iptal akışı bitirmelidir.
        try await waitUntil { await runtime.sawStartedEvent }
        await session.cancel()
        let events = await collector.value
        let cancelCount = await runtime.cancelCallCount
        XCTAssertGreaterThan(cancelCount, 0)
        guard case .interrupted = try XCTUnwrap(events.last).kind else {
            return XCTFail("A cancelled run must finish its stream with .interrupted, got \(String(describing: events.last))")
        }
    }

    /// Adaptörün çalıştırmaya özel izin köprüsü: deny-unless-safe çözücüsü
    /// adaptörün sunucuya verdiği yanıta da uygulanır.
    func testAdapterBridgesPerRunPermissionResolver() async throws {
        let lines = [
            "data: {\"type\":\"permission.asked\",\"properties\":{\"id\":\"perm-1\",\"sessionID\":\"task-session\",\"permission\":\"bash\",\"patterns\":[\"rm -rf /\"],\"always\":[],\"metadata\":{}}}",
            "data: {\"type\":\"session.status\",\"properties\":{\"sessionID\":\"task-session\",\"status\":{\"type\":\"idle\"}}}",
        ]
        let streamPair = AsyncThrowingStream<String, Error>.makeStream()
        for line in lines {
            streamPair.continuation.yield(line)
        }
        streamPair.continuation.finish()
        let client = PortTestOpenCodeClient(
            sessionID: "task-session",
            streams: [OpenCodeLineStream(statusCode: 200, lines: streamPair.stream)]
        )
        let adapter = OpenCodeCodingAgentAdapter(
            serverManager: PortTestServerManager(workingDirectory: URL(fileURLWithPath: "/tmp/workspace")),
            clientFactory: { _ in client },
            permissionHandler: nil,
            cancelPendingPermissions: nil
        )
        let request = CodingAgentExecutionRequest(
            taskID: UUID(),
            attemptID: UUID(),
            generation: 1,
            role: .developer,
            configuration: SessionConfiguration(
                providerID: ProviderID("opencode"),
                modelID: ProviderModelID("stub/model"),
                variantID: nil
            ),
            objective: "Bridge permissions",
            acceptanceCriteria: [],
            workspacePath: "/tmp/workspace",
            stage: .implementation
        )

        let run = try await adapter.start(
            request: request,
            permissionReplyProvider: { _ in .reject }
        )
        for await _ in run.events {}

        try await waitUntil { await client.replies().contains { $0.reply == "reject" } }
        let replies = await client.replies()
        XCTAssertEqual(replies.map(\.reply), ["reject"])
    }

    // MARK: - Uygunluk: text-only OpenAI yazmaya uygun değil

    func testOpenAITextAdapterIsIneligibleForWritingStages() async throws {
        let registry = CodingAgentRegistry()
        registry.register(
            runtime: OpenAITextCodingAdapter(providerRuntime: PortTestProviderRuntime())
        )
        let result = await registry.checkEligibility(
            runtimeID: "openai",
            configuration: SessionConfiguration(
                providerID: ProviderID("openai"),
                modelID: ProviderModelID("gpt-4o"),
                variantID: nil
            ),
            required: [.textAnalysis, .workspaceWrite, .tools, .structuredEvents, .cancellable]
        )
        guard case .missingCapabilities(let missing, let available) = result else {
            return XCTFail("Direct OpenAI must stay ineligible for writing, got \(result)")
        }
        XCTAssertTrue(missing.contains("workspaceWrite"))
        XCTAssertTrue(missing.contains("tools"))
        XCTAssertFalse(available.contains(.workspaceWrite))
    }

    // MARK: - Kurtarma portları asla kanıtsız serbest bırakmaz

    func testRecoveryPortsReportUnknownInsteadOfFabricatedStoppedOrAbsent() async throws {
        let adapter = OpenCodeCodingAgentAdapter(
            serverManager: PortTestServerManager(workingDirectory: URL(fileURLWithPath: "/tmp/workspace")),
            clientFactory: { _ in PortTestOpenCodeClient() },
            permissionHandler: nil,
            cancelPendingPermissions: nil
        )
        let sessions = AdapterTruthProviderSessions(
            adapter: adapter,
            serverManager: PortTestServerManager(workingDirectory: URL(fileURLWithPath: "/tmp/workspace"))
        )
        let attempt = TaskAttempt(
            taskID: UUID(),
            attemptSequence: 1,
            role: .developer,
            providerID: "opencode",
            modelID: "stub/model",
            generation: 1,
            startedAt: Date()
        )
        guard case .unknown(let sessionReason) = await sessions.providerStatus(for: attempt) else {
            return XCTFail("An unprovable provider session must be .unknown")
        }
        XCTAssertFalse(sessionReason.isEmpty)
        guard case .unknown(let pid, let processReason) = await ConservativeRecoveryProcesses().processStatus(for: attempt) else {
            return XCTFail("Process ownership must stay .unknown when it cannot be proven")
        }
        XCTAssertNil(pid)
        XCTAssertFalse(processReason.isEmpty)
    }

    // MARK: - Parmac izi sağlayıcısı

    func testExecutionFingerprintProviderRefusesWhenNoWorkspaceIsOwned() async {
        let provider = LiveExecutionFingerprintProvider(
            workspaces: PortTestPreflight(result: .notOwned(reason: "missing manifest")),
            probe: WorkspaceFingerprintProbe(runner: makeFingerprintRunner())
        )
        do {
            _ = try await provider.executionFingerprint(projectID: UUID(), taskID: UUID())
            XCTFail("A missing owned workspace must refuse the fingerprint")
        } catch let error as TaskExecutionFingerprintError {
            guard case .workspaceNotOwned(_, let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(reason, "missing manifest")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExecutionFingerprintProviderReadsTheOwnedWorkspace() async throws {
        let root = try makeTemporaryGitRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = LiveExecutionFingerprintProvider(
            workspaces: PortTestPreflight(
                result: .owned(
                    TaskWorkspaceDescriptor(
                        workspaceID: UUID(),
                        workspacePath: root.path,
                        repositoryPath: root.path
                    )
                )
            ),
            probe: WorkspaceFingerprintProbe(runner: makeFingerprintRunner())
        )
        let fingerprint = try await provider.executionFingerprint(projectID: UUID(), taskID: UUID())
        XCTAssertFalse(fingerprint.isEmpty)
    }

    // MARK: - Yardımcılar

    private func makePortRequest(runtimeID: String) -> TaskRunRequest {
        let taskID = UUID()
        return TaskRunRequest(
            task: CodingTask(
                id: taskID,
                projectID: UUID(),
                title: "Cancel",
                objective: "Cancel honestly",
                status: .running,
                stage: .implementation
            ),
            attempt: TaskAttempt(
                taskID: taskID,
                attemptSequence: 1,
                role: .developer,
                providerID: runtimeID,
                modelID: "stub-model",
                generation: 1,
                startedAt: Date()
            ),
            workspace: TaskWorkspaceDescriptor(
                workspaceID: UUID(),
                workspacePath: "/tmp/workspace",
                repositoryPath: "/tmp/repository"
            ),
            approvalPolicy: .approveSafe,
            deadline: nil
        )
    }

    private func makeFingerprintRunner() -> VerificationRunner {
        VerificationRunner(
            maxOutputBytes: 65_536,
            maxDetailsCharacters: 2_048,
            terminationGrace: 1,
            drainGrace: 1,
            gitExecutableDirectory: URL(fileURLWithPath: "/usr/bin")
        )
    }

    private func makeTemporaryGitRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentic-port-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main"], in: root)
        try runGit(["config", "user.email", "port-tests@agentic-sidebar.local"], in: root)
        try runGit(["config", "user.name", "Port Tests"], in: root)
        try Data("fixture\n".utf8).write(to: root.appendingPathComponent("README.md"))
        try runGit(["add", "-A"], in: root)
        try runGit(["commit", "-q", "-m", "initial"], in: root)
        return root
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "LiveTaskDispatchPortTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"]
            )
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met before timeout")
    }
}

// MARK: - Çalışma alanına köklenmiş canlı gönderim

/// Üretim gönderim yolunun çalışma alanına köklenmiş sunucu yaşam döngüsü:
/// koşu başına ayrı sunucu, terminal/iptal/hata yollarında bırakma, sözleşmeye
/// uymayan kablolamada kapalı kalma.
final class WorkspaceRootedLiveDispatchPortTests: XCTestCase {

    // MARK: - Yetenek doğruluğu

    func testAdapterAdvertisesWorkspaceWriteOnlyWhenServerIsRootedAtTheWorkspace() async {
        let config = SessionConfiguration(
            providerID: ProviderID("opencode"),
            modelID: ProviderModelID("stub/model"),
            variantID: nil
        )

        let rootedManager = PortTestServerManager(
            workingDirectory: URL(fileURLWithPath: "/workspace/project-a")
        )
        let rooted = OpenCodeCodingAgentAdapter(
            serverManager: rootedManager,
            clientFactory: { _ in PortTestOpenCodeClient() },
            permissionHandler: nil,
            cancelPendingPermissions: nil
        )
        let rootedCapabilities = await rooted.capabilities(configuration: config)
        XCTAssertTrue(
            rootedCapabilities.contains(.workspaceWrite),
            "A server rooted at the workspace may write"
        )

        let chatRooted = OpenCodeCodingAgentAdapter(
            serverManager: PortTestServerManager(
                workingDirectory: ManagedAppDirectories.openCodeWorkingDirectory()
            ),
            clientFactory: { _ in PortTestOpenCodeClient() },
            permissionHandler: nil,
            cancelPendingPermissions: nil
        )
        let chatCapabilities = await chatRooted.capabilities(configuration: config)
        XCTAssertFalse(
            chatCapabilities.contains(.workspaceWrite),
            "The shared chat server root is not the task workspace; writing must fail closed"
        )

        let managedRooted = OpenCodeCodingAgentAdapter(
            serverManager: PortTestServerManager(
                workingDirectory: URL(fileURLWithPath: "/managed/app/directory")
            ),
            clientFactory: { _ in PortTestOpenCodeClient() },
            permissionHandler: nil,
            cancelPendingPermissions: nil
        )
        let managedCapabilities = await managedRooted.capabilities(configuration: config)
        XCTAssertFalse(managedCapabilities.contains(.workspaceWrite))
    }

    /// Gönderim hattı koşu başına çalışma alanına kökleniyorsa yetenek bunu
    /// söyler: aksi hâlde uygulama içi uygulama aşaması kapıda reddedilirdi.
    func testAdapterWithRootedPerRunAccessAdvertisesWorkspaceWriteOnTheSharedConnection() async {
        let config = SessionConfiguration(
            providerID: ProviderID("opencode"),
            modelID: ProviderModelID("stub/model"),
            variantID: nil
        )
        let adapter = OpenCodeCodingAgentAdapter(
            serverManager: PortTestServerManager(
                workingDirectory: ManagedAppDirectories.openCodeWorkingDirectory()
            ),
            clientFactory: { _ in PortTestOpenCodeClient() },
            permissionHandler: nil,
            cancelPendingPermissions: nil,
            workspaceAccess: .rootedPerRun
        )
        let capabilities = await adapter.capabilities(configuration: config)
        XCTAssertTrue(capabilities.contains(.workspaceWrite))
    }

    @MainActor
    func testLiveProviderRegistryTreatsRootedPerRunOpenCodeAsWritingEligible() async {
        let configuration = SessionConfiguration(
            providerID: ProviderID("opencode"),
            modelID: ProviderModelID("stub/model"),
            variantID: nil
        )
        let task = CodingTask(
            id: UUID(),
            projectID: UUID(),
            title: "Registry eligibility",
            objective: "Write in the owned workspace",
            status: .ready,
            stage: .implementation
        )

        let rootedRegistry = CodingAgentRegistry()
        rootedRegistry.register(
            runtime: OpenCodeCodingAgentAdapter(
                serverManager: PortTestServerManager(
                    workingDirectory: ManagedAppDirectories.openCodeWorkingDirectory()
                ),
                clientFactory: { _ in PortTestOpenCodeClient() },
                permissionHandler: nil,
                cancelPendingPermissions: nil,
                workspaceAccess: .rootedPerRun
            )
        )
        let rootedProvider = LiveTaskProviderRegistry(
            registry: rootedRegistry,
            configuration: { configuration }
        )
        let eligible = await rootedProvider.candidate(for: task, stage: .implementation)
        XCTAssertEqual(eligible, .eligible(runtimeID: "opencode", modelID: "stub/model"))

        let sharedRegistry = CodingAgentRegistry()
        sharedRegistry.register(
            runtime: OpenCodeCodingAgentAdapter(
                serverManager: PortTestServerManager(
                    workingDirectory: ManagedAppDirectories.openCodeWorkingDirectory()
                ),
                clientFactory: { _ in PortTestOpenCodeClient() },
                permissionHandler: nil,
                cancelPendingPermissions: nil
            )
        )
        let sharedProvider = LiveTaskProviderRegistry(
            registry: sharedRegistry,
            configuration: { configuration }
        )
        let refused = await sharedProvider.candidate(for: task, stage: .implementation)
        guard case .unsupported(let missing) = refused else {
            return XCTFail("A chat-server adapter must fail closed for writing, got \(refused)")
        }
        XCTAssertEqual(missing, ["workspaceWrite"])
    }

    // MARK: - Port yaşam döngüsü

    func testPortRootsWorkspaceServerForOpenCodeRunAndReleasesOnTerminal() async throws {
        let workspace = try makeExistingWorkspace()
        let stateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("port-factory-state-\(UUID().uuidString)", isDirectory: true)
        let launcher = PortTestProcessLauncher()
        let factory = makePortWorkspaceFactory(stateRoot: stateRoot, launcher: launcher)
        let client = PortTestOpenCodeClient(
            sessionID: "task-session",
            streams: [completedIdleStream(sessionID: "task-session")]
        )
        let port = makePort(factory: factory, client: client)
        let request = makeRootingPortRequest(workspacePath: workspace.path)

        let session = try await port.start(request, approvalResolver: { _ in .approveOnce })
        var events: [CodingAgentEvent] = []
        for await event in session.events {
            events.append(event)
        }

        XCTAssertTrue(
            CodingAgentRun.isTerminatedSuccessfully(events: events),
            "A completed run must finish its stream with terminal success: \(events)"
        )
        try await waitUntil { await factory.activeWorkspacePaths().isEmpty }
        let handle = try XCTUnwrap(launcher.recordedHandles.last)
        XCTAssertEqual(handle.terminationCount, 1, "The workspace server is stopped after the terminal event")

        let calls = await client.calls()
        XCTAssertTrue(calls.contains("createSession"))
        XCTAssertTrue(
            OpenCodeServerLedger.leases(in: stateRoot).isEmpty,
            "No lease may survive a completed run"
        )
    }

    func testPortStopsWorkspaceServerWhenRunIsCancelled() async throws {
        let workspace = try makeExistingWorkspace()
        let stateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("port-factory-state-\(UUID().uuidString)", isDirectory: true)
        let launcher = PortTestProcessLauncher()
        let factory = makePortWorkspaceFactory(stateRoot: stateRoot, launcher: launcher)
        let hangingStream = AsyncThrowingStream<String, Error>.makeStream()
        let client = PortTestOpenCodeClient(
            sessionID: "task-session",
            streams: [OpenCodeLineStream(statusCode: 200, lines: hangingStream.stream)]
        )
        let port = makePort(factory: factory, client: client)
        let request = makeRootingPortRequest(workspacePath: workspace.path)

        let session = try await port.start(request, approvalResolver: { _ in .approveOnce })
        await session.cancel()

        try await waitUntil { await factory.activeWorkspacePaths().isEmpty }
        let handle = try XCTUnwrap(launcher.recordedHandles.last)
        XCTAssertEqual(handle.terminationCount, 1, "A cancelled run must stop its workspace server")
        hangingStream.continuation.finish()
    }

    func testPortStopsWorkspaceServerWhenAdapterStartFails() async throws {
        let workspace = try makeExistingWorkspace()
        let stateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("port-factory-state-\(UUID().uuidString)", isDirectory: true)
        let launcher = PortTestProcessLauncher()
        let factory = makePortWorkspaceFactory(stateRoot: stateRoot, launcher: launcher)
        let client = PortTestOpenCodeClient(promptError: PortTestPromptFailure())
        let port = makePort(factory: factory, client: client)
        let request = makeRootingPortRequest(workspacePath: workspace.path)

        do {
            _ = try await port.start(request, approvalResolver: { _ in .approveOnce })
            XCTFail("An adapter start failure must propagate")
        } catch is PortTestPromptFailure {
            // Beklenen: hata yolu sunucuyu bırakır.
        }

        try await waitUntil { await factory.activeWorkspacePaths().isEmpty }
        let handle = try XCTUnwrap(launcher.recordedHandles.last)
        XCTAssertEqual(handle.terminationCount, 1, "A failed start must not leak its server")
    }

    func testPortFailsClosedWithoutWorkspaceServerFactory() async throws {
        let client = PortTestOpenCodeClient()
        let registry = CodingAgentRegistry()
        registry.register(
            runtime: OpenCodeCodingAgentAdapter(
                serverManager: PortTestServerManager(
                    workingDirectory: ManagedAppDirectories.openCodeWorkingDirectory()
                ),
                clientFactory: { _ in client },
                permissionHandler: nil,
                cancelPendingPermissions: nil,
                workspaceAccess: .rootedPerRun
            )
        )
        let port = LiveOpenCodeTaskRunningPort(
            registry: registry,
            workspaceServerFactory: nil,
            clientFactory: { _ in client }
        )

        do {
            _ = try await port.start(
                makeRootingPortRequest(workspacePath: "/tmp/whatever"),
                approvalResolver: { _ in .approveOnce }
            )
            XCTFail("Without a rooting factory the OpenCode run must be refused, not run on the chat server")
        } catch let error as OpenCodeWorkspaceServerError {
            guard case .rootingUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let calls = await client.calls()
        XCTAssertTrue(calls.isEmpty, "A refused run must not create a remote session")
    }

    func testPortFailsClosedWhenWorkspaceCannotBeRooted() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("port-missing-\(UUID().uuidString)", isDirectory: true)
        let launcher = PortTestProcessLauncher()
        let factory = makePortWorkspaceFactory(
            stateRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("port-factory-state-\(UUID().uuidString)", isDirectory: true),
            launcher: launcher
        )
        let client = PortTestOpenCodeClient()
        let port = makePort(factory: factory, client: client)

        do {
            _ = try await port.start(
                makeRootingPortRequest(workspacePath: missing.path),
                approvalResolver: { _ in .approveOnce }
            )
            XCTFail("A workspace that cannot be rooted must fence the dispatch")
        } catch let error as OpenCodeWorkspaceServerError {
            guard case .workspaceNotRootable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let calls = await client.calls()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(launcher.recordedHandles.isEmpty)
    }

    // MARK: - Yardımcılar

    private func makePort(
        factory: OpenCodeWorkspaceServerFactory,
        client: PortTestOpenCodeClient
    ) -> LiveOpenCodeTaskRunningPort {
        let registry = CodingAgentRegistry()
        registry.register(
            runtime: OpenCodeCodingAgentAdapter(
                serverManager: PortTestServerManager(
                    workingDirectory: ManagedAppDirectories.openCodeWorkingDirectory()
                ),
                clientFactory: { _ in client },
                permissionHandler: nil,
                cancelPendingPermissions: nil,
                workspaceAccess: .rootedPerRun
            )
        )
        return LiveOpenCodeTaskRunningPort(
            registry: registry,
            workspaceServerFactory: factory,
            clientFactory: { _ in client }
        )
    }

    private func makePortWorkspaceFactory(
        stateRoot: URL,
        launcher: PortTestProcessLauncher
    ) -> OpenCodeWorkspaceServerFactory {
        OpenCodeWorkspaceServerFactory(
            executableLocator: PortTestExecutableLocator(),
            processLauncher: launcher,
            healthChecker: PortTestHealthChecker(),
            portAllocator: PortTestPortAllocator(ports: [52_201, 52_202, 52_203]),
            listenerVerifier: PortTestListenerVerifier(),
            credentialStore: PortTestCredentialStore(),
            stateRootURL: stateRoot,
            passwordGenerator: { "port-workspace-password" }
        )
    }

    private func completedIdleStream(sessionID: String) -> OpenCodeLineStream {
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        pair.continuation.yield(
            "data: {\"type\":\"session.status\",\"properties\":{\"sessionID\":\"\(sessionID)\",\"status\":{\"type\":\"idle\"}}}"
        )
        pair.continuation.finish()
        return OpenCodeLineStream(statusCode: 200, lines: pair.stream)
    }

    private func makeRootingPortRequest(workspacePath: String) -> TaskRunRequest {
        let taskID = UUID()
        return TaskRunRequest(
            task: CodingTask(
                id: taskID,
                projectID: UUID(),
                title: "Rooted",
                objective: "Write in the owned workspace",
                status: .running,
                stage: .implementation
            ),
            attempt: TaskAttempt(
                taskID: taskID,
                attemptSequence: 1,
                role: .developer,
                providerID: "opencode",
                modelID: "stub/model",
                generation: 1,
                startedAt: Date()
            ),
            workspace: TaskWorkspaceDescriptor(
                workspaceID: UUID(),
                workspacePath: workspacePath,
                repositoryPath: workspacePath
            ),
            approvalPolicy: .approveSafe,
            deadline: nil
        )
    }

    private func makeExistingWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("port-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met before timeout")
    }
}

private struct PortTestPromptFailure: Error {}

private struct PortTestExecutableLocator: OpenCodeExecutableLocating {
    func resolution() -> OpenCodeExecutableResolution {
        .found(URL(fileURLWithPath: "/opt/homebrew/bin/opencode"))
    }
}

private struct PortTestHealthChecker: OpenCodeHealthChecking {
    func waitUntilHealthy(connection: OpenCodeServerConnection) async throws -> String {
        "9.9.9"
    }
}

private struct PortTestListenerVerifier: OpenCodeListenerVerifying {
    func waitUntilProcessOwnsListeningPort(
        _ port: UInt16,
        processIdentifier: Int32?
    ) async -> Bool {
        true
    }
}

private final class PortTestPortAllocator: OpenCodePortAllocating, @unchecked Sendable {
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

private final class PortTestCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CredentialKey: String] = [:]

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
        lock.withLock { values[key] = nil }
    }
}

private final class PortTestProcessLauncher: OpenCodeProcessLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var handles: [PortTestProcessHandle] = []

    var recordedHandles: [PortTestProcessHandle] {
        lock.withLock { handles }
    }

    func launch(_ request: OpenCodeProcessLaunchRequest) async throws -> any OpenCodeProcessHandling {
        let handle = PortTestProcessHandle()
        lock.withLock { handles.append(handle) }
        return handle
    }
}

private final class PortTestProcessHandle: OpenCodeProcessHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var terminations = 0

    var terminationCount: Int {
        lock.withLock { terminations }
    }

    func isRunning() async -> Bool {
        lock.withLock { terminations == 0 }
    }

    func processIdentifier() async -> Int32? {
        9_001
    }

    func terminate() async {
        lock.withLock { terminations += 1 }
    }
}

// MARK: - Çalıştırıcı sahteleri

private actor StubCodingAgentRuntime: CodingAgentRuntime {
    nonisolated let runtimeID: String

    private var request: CodingAgentExecutionRequest?
    private var mode: Mode = .terminalSuccess
    private var continuation: AsyncStream<CodingAgentEvent>.Continuation?
    private(set) var sawStartedEvent = false
    private(set) var cancelCallCount = 0

    private enum Mode {
        case terminalSuccess
        case hanging
    }

    init(runtimeID: String) {
        self.runtimeID = runtimeID
    }

    func scriptTerminalSuccess() {
        mode = .terminalSuccess
    }

    func scriptHangingRun() {
        mode = .hanging
    }

    func capturedRequest() -> CodingAgentExecutionRequest? {
        request
    }

    func capabilities(configuration: SessionConfiguration) async -> CodingAgentCapabilities {
        [.textAnalysis, .workspaceRead, .workspaceWrite, .tools, .structuredEvents, .cancellable]
    }

    func start(request: CodingAgentExecutionRequest) async throws -> CodingAgentRun {
        self.request = request
        let (stream, continuation) = AsyncStream<CodingAgentEvent>.makeStream()
        self.continuation = continuation
        let event = CodingAgentEvent(
            taskID: request.taskID,
            attemptID: request.attemptID,
            generation: request.generation,
            kind: .started
        )
        continuation.yield(event)
        sawStartedEvent = true
        switch mode {
        case .terminalSuccess:
            continuation.yield(
                CodingAgentEvent(
                    taskID: request.taskID,
                    attemptID: request.attemptID,
                    generation: request.generation,
                    kind: .terminalSuccess
                )
            )
            continuation.finish()
        case .hanging:
            break
        }
        return CodingAgentRun(events: stream) { [weak self] in
            await self?.cancel()
        }
    }

    func release(attemptID: UUID) async {}

    private func cancel() {
        cancelCallCount += 1
        continuation?.yield(
            CodingAgentEvent(
                taskID: UUID(),
                attemptID: UUID(),
                generation: 0,
                kind: .interrupted("cancelled")
            )
        )
        continuation?.finish()
        continuation = nil
    }
}

private struct PortTestServerManager: OpenCodeServerManaging {
    let workingDirectory: URL?

    private var connection: OpenCodeServerConnection {
        OpenCodeServerConnection(
            baseURL: URL(string: "http://127.0.0.1:51234")!,
            username: "opencode",
            password: "test-password"
        )
    }

    func status() async -> OpenCodeServerStatus {
        .running(version: "test", baseURL: connection.baseURL)
    }

    func start(computerUse: ComputerUseConfiguration?) async throws -> OpenCodeServerConnection {
        connection
    }

    func currentConnection() async -> OpenCodeServerConnection? {
        connection
    }

    func stop() async {}

    func workingDirectory() async -> URL? {
        workingDirectory
    }
}

private actor PortTestOpenCodeClient: OpenCodeClientProtocol {
    struct Reply: Equatable, Sendable {
        let requestID: String
        let reply: String
    }

    private let sessionID: String
    private var streams: [OpenCodeLineStream]
    private var recordedReplies: [Reply] = []
    private var recordedCalls: [String] = []
    private let promptError: Error?

    init(sessionID: String = "port-session", streams: [OpenCodeLineStream] = [], promptError: Error? = nil) {
        self.sessionID = sessionID
        self.streams = streams
        self.promptError = promptError
    }

    func replies() -> [Reply] {
        recordedReplies
    }

    func calls() -> [String] {
        recordedCalls
    }

    func capabilities() async throws -> ProviderCapabilities {
        ProviderCapabilities(
            id: ProviderID("opencode"),
            displayName: "OpenCode",
            models: [
                ProviderModelCapability(
                    id: ProviderModelID("stub/model"),
                    displayName: "Stub",
                    variants: []
                )
            ]
        )
    }

    func authMethods() async throws -> [String: [OpenCodeAuthMethod]] { [:] }
    func setAPIKey(providerID: String, key: String, metadata: [String: String]) async throws {}

    func createSession() async throws -> String {
        recordedCalls.append("createSession")
        return sessionID
    }

    func deleteSession(sessionID: String) async throws {}

    func sendPromptAsync(
        sessionID: String,
        model: OpenCodeModelReference,
        variant: String?,
        parts: [OpenCodePromptPart]
    ) async throws {
        try await sendPromptAsync(
            sessionID: sessionID,
            model: model,
            variant: variant,
            parts: parts,
            agent: nil
        )
    }

    func sendPromptAsync(
        sessionID: String,
        model: OpenCodeModelReference,
        variant: String?,
        parts: [OpenCodePromptPart],
        agent: String?
    ) async throws {
        recordedCalls.append("sendPromptAsync")
        if let promptError {
            throw promptError
        }
    }

    func abort(sessionID: String) async throws {}

    func eventStream() async throws -> OpenCodeLineStream {
        if !streams.isEmpty {
            return streams.removeFirst()
        }
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        pair.continuation.finish()
        return OpenCodeLineStream(statusCode: 200, lines: pair.stream)
    }

    func replyPermission(requestID: String, reply: String) async throws {
        recordedReplies.append(Reply(requestID: requestID, reply: reply))
    }

    func sessionTodos(sessionID: String) async throws -> [AgentTodo] { [] }
    func mcpServerStatuses() async throws -> [String: OpenCodeMCPServerStatus] { [:] }
    func addMCPServer(name: String, config: OpenCodeMCPServerConfig) async throws -> [String: OpenCodeMCPServerStatus] { [:] }
    func disconnectMCPServer(name: String) async throws {}
}

private struct PortTestPreflight: TaskWorkspacePreflightPort {
    let result: TaskWorkspacePreflightResult

    func preflight(projectID: UUID, taskID: UUID) async -> TaskWorkspacePreflightResult {
        result
    }
}

private struct PortTestProviderRuntime: ProviderRuntime {
    let id = ProviderID("openai")

    func capabilities() async throws -> ProviderCapabilities {
        ProviderCapabilities(
            id: id,
            displayName: "OpenAI",
            models: [
                ProviderModelCapability(
                    id: ProviderModelID("gpt-4o"),
                    displayName: "GPT-4o",
                    variants: []
                )
            ]
        )
    }

    func startStream(for request: ProviderRequest) async throws -> ProviderStream {
        let (stream, continuation) = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        continuation.finish()
        return ProviderStream(events: stream, cancellation: {})
    }
}
