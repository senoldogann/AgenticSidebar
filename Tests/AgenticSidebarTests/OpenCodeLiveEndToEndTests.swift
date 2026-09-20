import Foundation
import XCTest

@testable import AgenticSidebar

/// E2E ön koşul eksikliği: yalnızca gerçekten eksik ortam bu hatayla temsil
/// edilir (OpenCode ikilisi yok, sunucu ayağa kalkmadı, sağlayıcı/model
/// yetkilendirmesi yok, geçici mağaza açılamadı). Gönderim reddi ya da akış
/// ihlali bu tiple asla temsil edilmez.
struct E2EPreconditionFailure: Error, CustomStringConvertible {
    let description: String
}

/// Gerçek koşu sırasında oluşan başarısızlık: atlanmaz, test başarısız olur.
struct E2EFlowFailure: Error, CustomStringConvertible {
    let description: String
}

/// E2E hatasının dürüst sonucu: ortam eksikliği atlanır, her akış hatası testi
/// başarısız kılar. Sınıflandırma saf tutulur; gerçek E2E koşusu olmadan
/// birim testiyle sabitlenebilir.
enum E2EFailureDisposition: Equatable, Sendable {
    case skip(reason: String)
    case fail(reason: String)
}

enum E2EFailureClassifier {
    /// Tip sözleşmesi belirleyicidir: akış hatası her zaman başarısızlıktır,
    /// ön koşul hatası atlanır, tip dışı her hata başarısızlıktır. Böylece bir
    /// gönderim reddi ya da düzenleme üretmeyen koşu asla `XCTSkip`'e dönüşemez.
    static func disposition(for error: Error) -> E2EFailureDisposition {
        if let flowFailure = error as? E2EFlowFailure {
            return .fail(reason: flowFailure.description)
        }
        if let preconditionFailure = error as? E2EPreconditionFailure {
            return .skip(reason: preconditionFailure.description)
        }
        return .fail(reason: String(describing: error))
    }
}

/// Gerçek OpenCode E2E koşusu; varsayılan olarak kapalıdır.
///
/// `RUN_OPENCODE_E2E=1` verilmedikçe atlanır. Koşu, kullanıcının kendi kopyasına
/// ve çalışan uygulamasına dokunmaz: her şey tek kullanımlık bir geçici kökün
/// içinde kurulur (depo, çalışma kopyası, SQLite mağazası, yönetilen OpenCode
/// sunucusu). Ön koşullardan biri (ikili, sağlayıcı/model yetkilendirmesi, sunucu
/// başlangıcı) yoksa test bunu gerekçesiyle atlar; başarı asla taklit edilmez.
final class OpenCodeLiveEndToEndTests: XCTestCase {

    private struct E2EStack {
        let composition: TaskBoardComposition
        let repository: SQLiteTaskStore
        let serverManager: ManagedOpenCodeServerManager
        let counter: E2EEventCounter
        let registry: E2EProviderRegistry
        let projectID: UUID
        let worktreePath: String
    }

    @MainActor
    func testRealOpenCodeEditsOwnedWorktreeAndReachesDoneExactlyOnce() async throws {
        guard ProcessInfo.processInfo.environment["RUN_OPENCODE_E2E"] == "1" else {
            throw XCTSkip("RUN_OPENCODE_E2E is not set; the real OpenCode E2E stays gated")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentic-opencode-e2e-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executableResolution = SystemOpenCodeExecutableLocator.current().resolution()
        guard case .found(let executableURL) = executableResolution else {
            throw XCTSkip("OpenCode prerequisite failed: executable resolution is \(executableResolution)")
        }
        print("E2E prerequisite: opencode executable=\(executableURL.path)")

        let repositoryURL = root.appendingPathComponent("repository", isDirectory: true)
        let worktreeURL = root.appendingPathComponent("worktree", isDirectory: true)
        try E2EGitFixture.makeRepository(at: repositoryURL)
        let baseSHA = try E2EGitFixture.headSHA(at: repositoryURL)
        try E2EGitFixture.addWorktree(at: worktreeURL, to: repositoryURL, baseSHA: baseSHA)
        print("E2E fixture: repository=\(repositoryURL.path) worktree=\(worktreeURL.path) base=\(baseSHA)")

        // Yönetilen sunucu kökü tek kullanımlık çalışma kopyasıdır; adaptörün
        // çalışma alanı kapsama denetimi sunucu cwd'sinin çalışma alanına eşit
        // olmasını şart koşar. Kullanıcının çalışan sunucusuna dokunulmaz.
        let serverManager = ManagedOpenCodeServerManager(
            executableLocator: SystemOpenCodeExecutableLocator.current(),
            processLauncher: FoundationOpenCodeProcessLauncher(),
            healthChecker: URLSessionOpenCodeHealthChecker.shared(),
            portAllocator: SystemOpenCodePortAllocator(),
            listenerVerifier: LibprocListenerVerifier(),
            credentialStore: E2ECredentialStore(),
            workingDirectoryURL: worktreeURL,
            passwordGenerator: { "e2e-\(UUID().uuidString)" }
        )

        var stack: E2EStack?
        do {
            let connection = try await serverManager.start(computerUse: nil)
            let transport = URLSessionOpenCodeTransport.streaming()
            let discoveryClient = OpenCodeClient(transport: transport, connection: connection)
            let capabilities = try await discoveryClient.capabilities()
            let candidates = Self.orderedCandidates(from: capabilities.models)
            guard let firstCandidate = candidates.first else {
                throw XCTSkip(
                    "OpenCode prerequisite failed: server is up but no authenticated provider/model is available (GET /provider returned no connected models)"
                )
            }
            let serverStatus = await serverManager.status()
            var version = "unknown"
            if case .running(let reportedVersion, _) = serverStatus {
                version = reportedVersion
            }
            print(
                "E2E candidate models (first 12): " + candidates.prefix(12).map(\.id.rawValue).joined(separator: ",")
            )

            stack = try await makeStack(
                root: root,
                repositoryURL: repositoryURL,
                worktreeURL: worktreeURL,
                baseSHA: baseSHA,
                serverManager: serverManager,
                transport: transport,
                modelID: firstCandidate.id.rawValue
            )
            let stack = try XCTUnwrap(stack)
            print(
                "E2E backend: runtime=opencode version=\(version) model=\(firstCandidate.id.rawValue) display=\(firstCandidate.displayName)"
            )

            let adapterCapabilities = await OpenCodeCodingAgentAdapter(
                serverManager: serverManager,
                clientFactory: { connection in
                    OpenCodeClient(transport: transport, connection: connection)
                },
                permissionHandler: nil,
                cancelPendingPermissions: nil
            ).capabilities(
                configuration: SessionConfiguration(
                    providerID: ProviderID("opencode"),
                    modelID: firstCandidate.id,
                    variantID: nil
                )
            )
            let capabilityNames = [
                ("textAnalysis", adapterCapabilities.contains(.textAnalysis)),
                ("workspaceRead", adapterCapabilities.contains(.workspaceRead)),
                ("workspaceWrite", adapterCapabilities.contains(.workspaceWrite)),
                ("tools", adapterCapabilities.contains(.tools)),
                ("interactiveApproval", adapterCapabilities.contains(.interactiveApproval)),
                ("sessionResume", adapterCapabilities.contains(.sessionResume)),
                ("cancellable", adapterCapabilities.contains(.cancellable)),
                ("structuredEvents", adapterCapabilities.contains(.structuredEvents)),
                ("usageReporting", adapterCapabilities.contains(.usageReporting)),
            ]
            print("E2E capabilities: " + capabilityNames.map { "\($0.0)=\($0.1)" }.joined(separator: ","))

            let recipe = try await VerificationResolver(toolchain: .detected())
                .resolve(repository: worktreeURL)
            for step in recipe.steps {
                print("E2E recipe step: \(step.name) command=\(step.executable) \(step.arguments.joined(separator: " "))")
            }

            try await runHappyPath(stack: stack, candidates: candidates, worktreeURL: worktreeURL)
            try await exerciseCancellation(stack: stack)
        } catch {
            // Dürüst sonuç: yalnızca gerçekten eksik ortam atlanır; gönderim
            // reddi, düzenleme/terminal üretmeyen koşu ve tüm adayların gerçek
            // denemeden sonra düşmesi testi başarısız kılar.
            let disposition = E2EFailureClassifier.disposition(for: error)
            switch disposition {
            case .skip(let reason):
                print("E2E result: prerequisite-blocked (\(reason))")
            case .fail(let reason):
                print("E2E result: failed (\(reason))")
            }
            if let stack {
                await cleanup(stack: stack)
            } else {
                await serverManager.stop()
            }
            switch disposition {
            case .skip(let reason):
                throw XCTSkip("OpenCode E2E prerequisite failed: \(reason)")
            case .fail(let reason):
                XCTFail("OpenCode E2E flow failed: \(reason)")
                return
            }
        }

        if let stack {
            await cleanup(stack: stack)
        }
    }

    // MARK: - Sınıflandırma sözleşmesi

    /// Gerçek koşu olmadan sabitlenen sözleşme: yalnızca ön koşul (ortam
    /// eksikliği) atlanır; gönderim reddi, akış hatası ve tip dışı her hata
    /// testi başarısız kılar.
    func testFailureClassifierSkipsOnlyMissingEnvironmentAndFailsFlowProblems() {
        XCTAssertEqual(
            E2EFailureClassifier.disposition(
                for: E2EPreconditionFailure(description: "opencode executable resolution is missing")
            ),
            .skip(reason: "opencode executable resolution is missing")
        )
        XCTAssertEqual(
            E2EFailureClassifier.disposition(
                for: E2EPreconditionFailure(description: "no authenticated provider/model is available")
            ),
            .skip(reason: "no authenticated provider/model is available")
        )
        XCTAssertEqual(
            E2EFailureClassifier.disposition(
                for: E2EFlowFailure(description: "startRun did not claim an attempt: deferred(activeAttempt)")
            ),
            .fail(reason: "startRun did not claim an attempt: deferred(activeAttempt)")
        )
        XCTAssertEqual(
            E2EFailureClassifier.disposition(
                for: E2EFlowFailure(description: "no discovered model completed the real flow; attempts: model=a")
            ),
            .fail(reason: "no discovered model completed the real flow; attempts: model=a")
        )
        guard
            case .fail(let refusalReason) = E2EFailureClassifier.disposition(
                for: TaskDispatchRefusal.budgetExhausted(taskID: UUID(), reason: "timeBudgetExhausted")
            )
        else {
            return XCTFail("A dispatch refusal must never be classified as a skip")
        }
        XCTAssertTrue(refusalReason.contains("timeBudgetExhausted"))
        guard case .fail = E2EFailureClassifier.disposition(for: NSError(domain: "e2e", code: 1)) else {
            return XCTFail("An untyped failure must never be classified as a skip")
        }
    }

    // MARK: - Mutlu yol

    @MainActor
    private func runHappyPath(
        stack: E2EStack,
        candidates: [ProviderModelCapability],
        worktreeURL: URL
    ) async throws {
        let service = stack.composition.service
        let proofURL = worktreeURL.appendingPathComponent("Sources/FixtureKit/AgentProof.swift")
        var candidateFailures: [String] = []

        for candidate in candidates.prefix(8) {
            // Her aday temiz bir çalışma kopyasıyla başlar: önceki adayın
            // yarım düzenlemesi sonrakinin işi gibi görünemez.
            try E2EGitFixture.resetWorktree(at: worktreeURL)
            await stack.registry.setModel(candidate.id.rawValue)
            let task = try await service.createTask(
                projectID: stack.projectID,
                title: "Real OpenCode edit",
                objective: """
                    Create a new Swift file at Sources/FixtureKit/AgentProof.swift with exactly this content:
                    public func agentProof() -> String { "agent-proof" }
                    Do not change any other file. Use the edit or write tool for that path.
                    """,
                priority: 1,
                criteria: ["Sources/FixtureKit/AgentProof.swift defines agentProof()"]
            )
            let startResult = try await service.startRun(
                taskID: task.id,
                expectedVersion: task.version,
                actor: "e2e-human"
            )
            guard case .claimed(let attemptID, _) = startResult else {
                throw E2EFlowFailure(description: "startRun did not claim an attempt: \(startResult)")
            }
            print(
                "E2E dispatch: model=\(candidate.id.rawValue) task=\(task.id.uuidString) attempt=\(attemptID.uuidString) started"
            )

            let terminal = try await waitForTerminalTask(
                service: service,
                projectID: stack.projectID,
                taskID: task.id,
                timeout: 600
            )
            let details = await stack.counter.terminalDetails()
            let activityStarted = await stack.counter.count(named: "activityStarted")
            let approvalSummary = await stack.counter.approvalSummary()
            print("E2E approvals for \(candidate.id.rawValue): \(approvalSummary)")

            let fileWritten = FileManager.default.fileExists(atPath: proofURL.path)
            let content = (try? String(contentsOf: proofURL, encoding: .utf8)) ?? ""
            let objectiveMet = fileWritten && content.contains("agentProof")
            if terminal.status == .review && objectiveMet {
                try await completeAcceptance(
                    stack: stack,
                    task: terminal,
                    proofURL: proofURL,
                    modelID: candidate.id.rawValue
                )
                return
            }

            // Aday başarısızlığında sıradaki model denenir; her denemenin
            // sonucu rapor edilir. Aday, işi bitirip incelemeye ulaşamadıysa
            // (kota/kimlik reddi, reddedilen araç yüzünden iptal, doğrulama
            // düşüşü ya da hiç yazmama) bu bir sonraki adayın işidir.
            let detail = details.last ?? "no terminal detail"
            let providerDetail = ProviderResponseDiagnostics.shared.detail() ?? "no provider response recorded"
            let reason =
                "model=\(candidate.id.rawValue) status=\(terminal.status.rawValue) "
                + "block=\(String(describing: terminal.blockReason)) objectiveMet=\(objectiveMet) "
                + "activityStarted=\(activityStarted) detail=\(detail) | \(providerDetail)"
            candidateFailures.append(reason)
            print("E2E candidate failed, trying next: \(reason)")
        }
        throw E2EFlowFailure(
            description: "no discovered model completed the real flow; attempts: " + candidateFailures.joined(separator: " || ")
        )
    }

    @MainActor
    private func completeAcceptance(
        stack: E2EStack,
        task: CodingTask,
        proofURL: URL,
        modelID: String
    ) async throws {
        let service = stack.composition.service
        print("E2E terminal: status=\(task.status.rawValue) model=\(modelID)")
        print("E2E events: \(await stack.counter.describe())")
        print("E2E approvals: \(await stack.counter.approvalSummary())")
        for detail in await stack.counter.terminalDetails() {
            print("E2E terminal detail: \(detail)")
        }
        if let providerDetail = ProviderResponseDiagnostics.shared.detail() {
            print("E2E provider diagnostic: \(providerDetail)")
        }

        let attempts = try await service.attemptHistory(taskID: task.id)
        guard let attempt = attempts.first else {
            throw E2EFlowFailure(description: "attempt history is empty after dispatch")
        }
        print(
            "E2E attempt: id=\(attempt.id.uuidString) provider=\(attempt.providerID) model=\(attempt.modelID) outcome=\(attempt.outcome.rawValue) toolCalls=\(attempt.toolCallCount.map(String.init) ?? "unknown")"
        )

        let proofExists = FileManager.default.fileExists(atPath: proofURL.path)
        let proofContent = (try? String(contentsOf: proofURL, encoding: .utf8)) ?? ""
        let proofComplete = proofExists && proofContent.contains("agentProof")
        print("E2E worktree edit: AgentProof.swift exists=\(proofExists) contentMatches=\(proofComplete)")
        guard proofComplete else {
            throw E2EFlowFailure(
                description: "the agent reached review without creating Sources/FixtureKit/AgentProof.swift with the requested content"
            )
        }

        for criterion in task.criteria where !criterion.isCompleted {
            _ = try await service.setCriterionCompletion(
                taskID: task.id,
                criterionID: criterion.id,
                isCompleted: true,
                expectedVersion: task.version
            )
        }
        let fetchedSnapshot = try await service.snapshot(projectID: stack.projectID)
        let fetchedTask = fetchedSnapshot.tasks.first { $0.id == task.id }
        let readyForAccept = try XCTUnwrap(fetchedTask)
        let accepted = try await service.accept(
            taskID: task.id,
            expectedVersion: readyForAccept.version,
            actor: "e2e-human"
        )
        XCTAssertEqual(accepted.status, .done)
        print("E2E accept: task reached done at version \(accepted.version)")

        do {
            _ = try await service.accept(
                taskID: task.id,
                expectedVersion: accepted.version,
                actor: "e2e-human"
            )
            XCTFail("A second human accept must be refused: done is produced exactly once")
        } catch let error as CodingTaskServiceError {
            XCTAssertEqual(error, .actionNotAvailable(taskID: task.id, status: .done))
        }
        print("E2E done-once: second accept refused with actionNotAvailable(done)")
    }

    /// Konuşma değil, görsel/gömme/ses üreten modelleri baştan eler ve önce her
    /// sağlayıcıdan birer aday sıralar: tümü tükenmiş tek bir sağlayıcının
    /// arkasında takılıp kalmak yerine diğerleri de denenir.
    private static func orderedCandidates(from models: [ProviderModelCapability]) -> [ProviderModelCapability] {
        let nonCodingMarkers = [
            "image", "embedding", "tts", "whisper", "realtime", "audio", "video",
            "lyria", "moderation", "guard", "safety", "rerank", "morph", "vision-exp",
        ]
        let preferred = ["opencode-go", "deepseek", "minimax", "github-copilot", "nvidia", "ollama-cloud", "openai", "openrouter"]
        let codingMarkers = ["codex", "coder", "code", "kimi", "qwen", "glm", "claude", "gpt-5", "deepseek-v4"]
        let codingModels = models.filter { model in
            let name = model.id.rawValue.lowercased()
            return !nonCodingMarkers.contains { name.contains($0) }
        }

        func providerKey(_ model: ProviderModelCapability) -> String {
            String(model.id.rawValue.split(separator: "/").first ?? Substring(model.id.rawValue))
        }

        func codingRank(_ model: ProviderModelCapability) -> Int {
            let name = model.id.rawValue.lowercased()
            return codingMarkers.firstIndex(where: { name.contains($0) }) ?? codingMarkers.count
        }

        return codingModels.sorted { lhs, rhs in
            let lhsProvider = preferred.firstIndex(where: { providerKey(lhs).hasPrefix($0) }) ?? preferred.count
            let rhsProvider = preferred.firstIndex(where: { providerKey(rhs).hasPrefix($0) }) ?? preferred.count
            if lhsProvider != rhsProvider {
                return lhsProvider < rhsProvider
            }
            if codingRank(lhs) != codingRank(rhs) {
                return codingRank(lhs) < codingRank(rhs)
            }
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }

    // MARK: - İptal

    @MainActor
    private func exerciseCancellation(stack: E2EStack) async throws {
        let service = stack.composition.service
        let task = try await service.createTask(
            projectID: stack.projectID,
            title: "Real OpenCode cancellation",
            objective: """
                Create a new Swift file at Sources/FixtureKit/CancelledProof.swift with exactly this content:
                public func cancelledProof() -> String { "cancelled" }
                Then run the full test suite and report the result before finishing.
                """,
            priority: 1,
            criteria: ["cancellation exercised"]
        )
        let startResult = try await service.startRun(
            taskID: task.id,
            expectedVersion: task.version,
            actor: "e2e-human"
        )
        guard case .claimed(let attemptID, _) = startResult else {
            throw E2EFlowFailure(description: "cancellation run did not claim an attempt: \(startResult)")
        }
        let startedBefore = await stack.counter.count(named: "started")
        try await waitUntil(timeout: 120) {
            await stack.counter.count(named: "started") > startedBefore
        }
        let runningSnapshot = try await service.snapshot(projectID: stack.projectID)
        let runningTask = runningSnapshot.tasks.first { $0.id == task.id }
        let running = try XCTUnwrap(runningTask)
        try await service.stop(
            taskID: task.id,
            expectedVersion: running.version,
            expectedAttemptID: attemptID
        )
        let stoppedSnapshot = try await service.snapshot(projectID: stack.projectID)
        let stoppedTask = stoppedSnapshot.tasks.first { $0.id == task.id }
        let stopped = try XCTUnwrap(stoppedTask)
        XCTAssertEqual(stopped.status, .blocked)
        XCTAssertEqual(stopped.blockReason, .custom(TaskScheduler.stoppedBlockReason))
        let attempts = try await service.attemptHistory(taskID: task.id)
        XCTAssertEqual(attempts.map(\.outcome), [.cancelled])
        let eventSummary = await stack.counter.describe()
        print(
            "E2E cancellation: status=\(stopped.status.rawValue) reason=\(String(describing: stopped.blockReason)) attempt=\(attempts.first?.outcome.rawValue ?? "missing") events=\(eventSummary)"
        )
    }

    // MARK: - Yığın

    @MainActor
    private func makeStack(
        root: URL,
        repositoryURL: URL,
        worktreeURL: URL,
        baseSHA: String,
        serverManager: ManagedOpenCodeServerManager,
        transport: any OpenCodeTransport,
        modelID: String
    ) async throws -> E2EStack {
        let repository: SQLiteTaskStore
        do {
            repository = try SQLiteTaskStore.open(at: root.appendingPathComponent("taskboard.sqlite"))
        } catch {
            throw E2EPreconditionFailure(description: "temporary SQLite store could not be opened: \(error)")
        }

        let registry = CodingAgentRegistry()
        registry.register(
            runtime: OpenCodeCodingAgentAdapter(
                serverManager: serverManager,
                clientFactory: { connection in
                    OpenCodeClient(transport: transport, connection: connection)
                },
                permissionHandler: nil,
                cancelPendingPermissions: nil
            )
        )

        let counter = E2EEventCounter()
        let port = CountingTaskRunningPort(
            inner: LiveOpenCodeTaskRunningPort(
                registry: registry,
                serverManager: serverManager,
                clientFactory: { connection in
                    OpenCodeClient(transport: transport, connection: connection)
                }
            ),
            counter: counter
        )

        let runner = VerificationRunner(
            maxOutputBytes: 262_144,
            maxDetailsCharacters: 8_192,
            terminationGrace: 5,
            drainGrace: 2,
            gitExecutableDirectory: URL(fileURLWithPath: "/usr/bin")
        )
        let ledger = TaskEvidenceLedger(probe: WorkspaceFingerprintProbe(runner: runner))
        let verifier = RecipeTaskVerifier(
            resolver: VerificationResolver(toolchain: .detected()),
            runner: runner,
            repository: repository,
            ledger: ledger
        )
        let workspaceID = UUID()
        let provisioning = E2EWorkspaceProvisioning(
            record: WorkspaceRecord(
                workspaceID: workspaceID,
                projectID: UUID(),
                taskID: UUID(),
                attemptID: UUID(),
                repositoryPath: repositoryURL.path,
                workspacePath: worktreeURL.path,
                commonDirIdentity: "e2e-common-dir",
                baseSHA: baseSHA,
                nonce: UUID().uuidString,
                createdAt: Date()
            )
        )
        let preflight = E2EFixedPreflight(
            workspaceID: workspaceID,
            workspacePath: worktreeURL.path,
            repositoryPath: repositoryURL.path
        )
        let providerRegistry = E2EProviderRegistry(runtimeID: "opencode", modelID: modelID)
        let composition = TaskBoardComposition.make(
            repository: repository,
            providers: providerRegistry,
            workspacePreflight: preflight,
            provisioning: provisioning,
            dispatchPort: port,
            recoveryProviders: E2EUnknownProviderSessions(),
            recoveryWorkspaces: E2EUnknownWorkspaceOwnership(),
            recoveryProcesses: ConservativeRecoveryProcesses(),
            verifier: verifier,
            acceptanceEvidence: ledger,
            executionFingerprints: LiveExecutionFingerprintProvider(
                workspaces: preflight,
                probe: WorkspaceFingerprintProbe(runner: runner)
            ),
            clock: SystemTaskSchedulerClock(),
            schedulerID: "e2e-scheduler",
            recoveryID: "e2e-recovery",
            requiredSteps: AcceptanceGate.swiftPMRequiredSteps
        )
        let project = try await composition.service.createProject(
            name: "OpenCode E2E",
            repositoryPath: repositoryURL.path,
            gitIdentity: "e2e@agentic-sidebar.local",
            protectedRefs: ["main"]
        )
        composition.register(projectID: project.id)

        return E2EStack(
            composition: composition,
            repository: repository,
            serverManager: serverManager,
            counter: counter,
            registry: providerRegistry,
            projectID: project.id,
            worktreePath: worktreeURL.path
        )
    }

    // MARK: - Bitiş ve temizlik

    @MainActor
    private func waitForTerminalTask(
        service: CodingTaskService,
        projectID: UUID,
        taskID: UUID,
        timeout: TimeInterval
    ) async throws -> CodingTask {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = try await service.snapshot(projectID: projectID)
            if let task = snapshot.tasks.first(where: { $0.id == taskID }),
                task.status == .review || task.status == .blocked || task.status.isTerminal
            {
                return task
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw E2EFlowFailure(description: "the real agent run did not reach a terminal state within \(Int(timeout))s")
    }

    @MainActor
    private func cleanup(stack: E2EStack) async {
        await stack.composition.shutdown()
        await stack.serverManager.stop()
        let status = await stack.serverManager.status()
        print("E2E cleanup: server status=\(String(describing: status))")
        XCTAssertEqual(status, .stopped)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw E2EFlowFailure(description: "condition was not met within \(Int(timeout))s")
    }
}

// MARK: - Sayaç portu

/// Olay türlerini sayan sarmalayıcı port: E2E raporu gerçek olay sayılarını
/// taşır. İç akış yine sınırlıdır (`.bufferingNewest`).
actor E2EEventCounter {
    private var counts: [String: Int] = [:]
    private var terminals: [String] = []
    private var approvals: [String] = []

    func record(_ kind: CodingAgentEvent.Kind) {
        counts[Self.name(of: kind), default: 0] += 1
        switch kind {
        case .terminalError(let message):
            terminals.append("terminalError: \(message)")
        case .interrupted(let message):
            terminals.append("interrupted: \(message)")
        default:
            break
        }
    }

    func terminalDetails() -> [String] {
        terminals
    }

    func recordApproval(_ request: TaskRunApprovalRequest, reply: TaskRunApprovalReply) {
        let decision: String
        switch reply {
        case .approveOnce:
            decision = "approveOnce"
        case .deny(let reason):
            decision = "deny:\(reason)"
        }
        approvals.append("\(request.toolName)[\(request.patterns.joined(separator: "|"))]→\(decision)")
    }

    func approvalSummary() -> String {
        approvals.isEmpty ? "none" : approvals.joined(separator: "; ")
    }

    func count(of kind: CodingAgentEvent.Kind) -> Int {
        counts[Self.name(of: kind), default: 0]
    }

    func count(named name: String) -> Int {
        counts[name, default: 0]
    }

    func describe() -> String {
        counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    private static func name(of kind: CodingAgentEvent.Kind) -> String {
        switch kind {
        case .started: return "started"
        case .textDelta: return "textDelta"
        case .activityStarted: return "activityStarted"
        case .activityUpdated: return "activityUpdated"
        case .activityFinished: return "activityFinished"
        case .approvalRequested: return "approvalRequested"
        case .questionAsked: return "questionAsked"
        case .usage: return "usage"
        case .terminalSuccess: return "terminalSuccess"
        case .terminalError: return "terminalError"
        case .interrupted: return "interrupted"
        }
    }
}

struct CountingTaskRunningPort: TaskRunningPort {
    let inner: any TaskRunningPort
    let counter: E2EEventCounter

    func start(
        _ request: TaskRunRequest,
        approvalResolver: @escaping TaskRunApprovalResolver
    ) async throws -> TaskRunSession {
        let recordingResolver: TaskRunApprovalResolver = { approvalRequest in
            let reply = await approvalResolver(approvalRequest)
            await counter.recordApproval(approvalRequest, reply: reply)
            return reply
        }
        let session = try await inner.start(request, approvalResolver: recordingResolver)
        let (stream, continuation) = AsyncStream<CodingAgentEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        let pump = Task {
            for await event in session.events {
                await counter.record(event.kind)
                continuation.yield(event)
            }
            continuation.finish()
        }
        return CountingRunSession(events: stream) {
            pump.cancel()
            await session.cancel()
        }
    }
}

private struct CountingRunSession: TaskRunSession {
    let events: AsyncStream<CodingAgentEvent>
    let cancelHandler: @Sendable () async -> Void

    func cancel() async {
        await cancelHandler()
    }
}

// MARK: - E2E portları

/// Aday modeli E2E sırasında değiştirilebilen sağlayıcı kaydı: kimlik bilgisi
/// reddedilen bir modelden sonra sıradaki aday denenir. Deneme satırı talep
/// anındaki modeli taşır, bu yüzden değişiklik yalnızca sonraki talebi etkiler.
actor E2EProviderRegistry: TaskProviderRegistryPort {
    private let runtimeID: String
    private var modelID: String

    init(runtimeID: String, modelID: String) {
        self.runtimeID = runtimeID
        self.modelID = modelID
    }

    func setModel(_ modelID: String) {
        self.modelID = modelID
    }

    func candidate(for task: CodingTask, stage: TaskStage) async -> TaskProviderCandidate {
        .eligible(runtimeID: runtimeID, modelID: modelID)
    }
}

/// E2E'de çalışma kopyası tek ve önceden hazırlanmıştır: ön kontrol her zaman
/// aynı sahipli çalışma alanını döndürür, böylece hem talep hem gönderim kapısı
/// aynı kimliği görür.
private struct E2EFixedPreflight: TaskWorkspacePreflightPort {
    let workspaceID: UUID
    let workspacePath: String
    let repositoryPath: String

    func preflight(projectID: UUID, taskID: UUID) async -> TaskWorkspacePreflightResult {
        .owned(
            TaskWorkspaceDescriptor(
                workspaceID: workspaceID,
                workspacePath: workspacePath,
                repositoryPath: repositoryPath
            )
        )
    }
}

/// Tek kullanımlık çalışma kopyasını olduğu gibi teslim eder; E2E öncesi
/// `git worktree add` ile gerçek bir çalışma kopyası hazırlanmıştır.
private struct E2EWorkspaceProvisioning: TaskWorkspaceProvisioningPort {
    let record: WorkspaceRecord

    func resolveBase(for task: CodingTask) async throws -> WorkspaceBase {
        WorkspaceBase(commitSHA: record.baseSHA)
    }

    func create(task: CodingTask, attempt: TaskAttempt, base: WorkspaceBase) async throws -> WorkspaceRecord {
        WorkspaceRecord(
            workspaceID: record.workspaceID,
            projectID: task.projectID,
            taskID: task.id,
            attemptID: attempt.id,
            repositoryPath: record.repositoryPath,
            workspacePath: record.workspacePath,
            commonDirIdentity: record.commonDirIdentity,
            baseSHA: record.baseSHA,
            nonce: record.nonce,
            createdAt: record.createdAt
        )
    }

    func discardUnclaimed(workspaceID: UUID, attemptID: UUID) async throws {}
}

private struct E2EUnknownProviderSessions: TaskProviderSessionInspecting {
    func providerStatus(for attempt: TaskAttempt) async -> TaskProviderSessionStatus {
        .unknown(reason: "e2e recovery is conservative")
    }
}

private struct E2EUnknownWorkspaceOwnership: TaskWorkspaceOwnershipInspecting {
    func workspaceStatus(for attempt: TaskAttempt) async -> TaskWorkspaceOwnershipStatus {
        .unknown(reason: "e2e recovery is conservative")
    }
}

private final class E2ECredentialStore: CredentialStore, @unchecked Sendable {
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

// MARK: - Git fixture

enum E2EGitFixture {
    struct ToolResult: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    enum FixtureError: Error, CustomStringConvertible {
        case gitFailed(arguments: [String], stderr: String)

        var description: String {
            switch self {
            case .gitFailed(let arguments, let stderr):
                return "git \(arguments.joined(separator: " ")) failed: \(stderr)"
            }
        }
    }

    /// Küçük, bağımsız bir SwiftPM paketi: kütüphane + çalıştırılabilir ürün
    /// (tarif çözümleyicisi çalıştırılabilir ürün ister) + test hedefi.
    static func makeRepository(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main"], in: url)
        try runGit(["config", "user.email", "e2e@agentic-sidebar.local"], in: url)
        try runGit(["config", "user.name", "OpenCode E2E"], in: url)

        let package = """
            // swift-tools-version: 5.9
            import PackageDescription

            let package = Package(
                name: "Fixture",
                products: [
                    .executable(name: "Fixture", targets: ["Fixture"]),
                ],
                targets: [
                    .target(name: "FixtureKit"),
                    .executableTarget(name: "Fixture", dependencies: ["FixtureKit"]),
                    .testTarget(name: "FixtureKitTests", dependencies: ["FixtureKit"]),
                ]
            )
            """
        try write(package, to: url.appendingPathComponent("Package.swift"))
        try write(
            "public func greeting() -> String { \"hello\" }\n",
            to: url.appendingPathComponent("Sources/FixtureKit/Greeting.swift")
        )
        try write(
            "import FixtureKit\nprint(greeting())\n",
            to: url.appendingPathComponent("Sources/Fixture/main.swift")
        )
        try write(
            """
            import XCTest
            @testable import FixtureKit

            final class GreetingTests: XCTestCase {
                func testGreeting() {
                    XCTAssertEqual(greeting(), "hello")
                }
            }
            """,
            to: url.appendingPathComponent("Tests/FixtureKitTests/GreetingTests.swift")
        )
        try write(
            """
            .build/
            .swiftpm/
            opencode.json
            managed-config.json
            """,
            to: url.appendingPathComponent(".gitignore")
        )
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-q", "-m", "initial fixture"], in: url)
    }

    static func headSHA(at url: URL) throws -> String {
        let result = try runGit(["rev-parse", "HEAD"], in: url)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func addWorktree(at worktree: URL, to repository: URL, baseSHA: String) throws {
        _ = try runGit(["worktree", "add", "--detach", worktree.path, baseSHA], in: repository)
    }

    /// Çalışma kopyasını temel revizyona döndürür ve izlenmeyen dosyaları
    /// siler; sonraki aday model her zaman aynı temiz zeminde başlar.
    static func resetWorktree(at worktree: URL) throws {
        _ = try runGit(["checkout", "-f", "HEAD"], in: worktree)
        _ = try runGit(["clean", "-fd"], in: worktree)
    }

    private static func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    @discardableResult
    private static func runGit(_ arguments: [String], in directory: URL) throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let result = ToolResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
        guard result.exitCode == 0 else {
            throw FixtureError.gitFailed(arguments: arguments, stderr: result.stderr)
        }
        return result
    }
}
