import Foundation
import Security

actor ManagedOpenCodeServerManager: OpenCodeServerManaging {
    private static let startupAttempts = 2

    private let executableLocator: any OpenCodeExecutableLocating
    private let processLauncher: any OpenCodeProcessLaunching
    private let healthChecker: any OpenCodeHealthChecking
    private let portAllocator: any OpenCodePortAllocating
    /// Runs before the first credentialed request, so the server password cannot
    /// be delivered to whichever process happened to take the freed port.
    private let listenerVerifier: any OpenCodeListenerVerifying
    private let credentialStore: any CredentialStore
    private let workingDirectoryURL: URL
    private let passwordGenerator: @Sendable () async throws -> String

    private var processHandle: (any OpenCodeProcessHandling)?

    /// Reaping runs once per app launch: it is a scan of the process table, and
    /// the answer cannot change while this process is starting servers.
    private var hasReapedOrphans = false
    private var connection: OpenCodeServerConnection?
    private var serverStatus: OpenCodeServerStatus = .stopped

    /// The extensions the app wants loaded. Applied at the next start, because
    /// OpenCode reads its configuration once and an MCP server's tools are
    /// registered from it.
    private var extensionConfiguration: ExtensionRuntimeSnapshot = .empty

    /// Asked for the snapshot at start time rather than trusting a value pushed
    /// earlier: the user may have installed something while the server was
    /// stopped, and a start that ignored it would look like a failed install.
    private var extensionConfigurationProvider: (@Sendable () async -> ExtensionRuntimeSnapshot)?

    init(
        executableLocator: any OpenCodeExecutableLocating,
        processLauncher: any OpenCodeProcessLaunching,
        healthChecker: any OpenCodeHealthChecking,
        portAllocator: any OpenCodePortAllocating,
        listenerVerifier: any OpenCodeListenerVerifying = LibprocListenerVerifier(),
        credentialStore: any CredentialStore,
        workingDirectoryURL: URL,
        passwordGenerator: @escaping @Sendable () async throws -> String,
        extensionSnapshotProvider: (@Sendable () async -> ExtensionRuntimeSnapshot)? = nil
    ) {
        self.executableLocator = executableLocator
        self.processLauncher = processLauncher
        self.healthChecker = healthChecker
        self.portAllocator = portAllocator
        self.listenerVerifier = listenerVerifier
        self.credentialStore = credentialStore
        self.workingDirectoryURL = workingDirectoryURL
        self.passwordGenerator = passwordGenerator
        // Set here, not by a later call: a provider installed after construction
        // leaves a window in which a start writes a configuration with no
        // silencing patterns at all.
        self.extensionConfigurationProvider = extensionSnapshotProvider
    }

    static func live(
        credentialStore: any CredentialStore,
        extensionSnapshot: (@Sendable () async -> ExtensionRuntimeSnapshot)? = nil
    ) -> ManagedOpenCodeServerManager {
        ManagedOpenCodeServerManager(
            executableLocator: SystemOpenCodeExecutableLocator.current(),
            processLauncher: FoundationOpenCodeProcessLauncher(),
            healthChecker: URLSessionOpenCodeHealthChecker.shared(),
            portAllocator: SystemOpenCodePortAllocator(),
            listenerVerifier: LibprocListenerVerifier(),
            credentialStore: credentialStore,
            workingDirectoryURL: managedWorkingDirectoryURL(),
            passwordGenerator: generateSecurePassword,
            extensionSnapshotProvider: extensionSnapshot
        )
    }

    private var activeComputerUse: ComputerUseConfiguration?

    func setExtensionConfiguration(_ configuration: ExtensionRuntimeSnapshot) async {
        extensionConfiguration = configuration
        _ = try? Self.writeManagedConfiguration(
            computerUse: activeComputerUse,
            extensions: configuration,
            workingDirectoryURL: workingDirectoryURL
        )
    }

    func setExtensionConfigurationProvider(
        _ provider: @escaping @Sendable () async -> ExtensionRuntimeSnapshot
    ) {
        extensionConfigurationProvider = provider
    }

    func status() async -> OpenCodeServerStatus {
        if case .running = serverStatus {
            let isAlive = await currentProcessIsRunning()
            if !isAlive {
                // The child can exit without telling us (crash, external kill).
                // Report the real state instead of the last known one.
                AppLog.openCode.error("Managed OpenCode process is no longer running")
                processHandle = nil
                connection = nil
                serverStatus = .stopped
            }
        }

        return serverStatus
    }

    func currentConnection() -> OpenCodeServerConnection? {
        connection
    }

    func start(
        computerUse: ComputerUseConfiguration?
    ) async throws -> OpenCodeServerConnection {
        activeComputerUse = computerUse
        let hasLiveChild = await currentProcessIsRunning()

        if let connection, hasLiveChild {
            return connection
        }

        if connection != nil || processHandle != nil {
            AppLog.openCode.error(
                "Discarding stale OpenCode server state before restart"
            )
            await stop()
        }

        // Before a new server is started, any server an earlier launch left
        // behind is ended. A relaunch (the development script, a crash, a forced
        // shutdown) is the normal case here, not the exception: without this, each
        // one added a whole MCP tree that nothing would ever stop.
        if !hasReapedOrphans {
            hasReapedOrphans = true
            OpenCodeServerLedger.reapOrphans(in: workingDirectoryURL)
        }

        guard let executableURL = executableLocator.locate() else {
            throw ProviderRuntimeError.executableUnavailable
        }

        let password = try await resolveServerPassword()
        try Self.writeBaseConfiguration(at: workingDirectoryURL)

        if let extensionConfigurationProvider {
            extensionConfiguration = await extensionConfigurationProvider()
        }

        // One file carries everything the app configures — the approval policy,
        // which MCP servers may reach the model, the plugin list — and it is always
        // written: a server with no extensions still needs the file to silence the
        // ones it must not load.
        let configurationPath = try Self.writeManagedConfiguration(
            computerUse: computerUse,
            extensions: extensionConfiguration,
            workingDirectoryURL: workingDirectoryURL
        )

        var lastError = ProviderRuntimeError.startupFailure

        // The free port is discovered by probing and then released, so another
        // process can win the race before the child binds it. Retrying once on a
        // fresh port keeps startup reliable without changing the protocol.
        for attempt in 1...Self.startupAttempts {
            let port: UInt16
            do {
                port = try portAllocator.allocate()
            } catch let error as ProviderRuntimeError {
                throw error
            } catch {
                throw ProviderRuntimeError.startupFailure
            }

            guard let baseURL = URL(string: "http://127.0.0.1:\(port)") else {
                throw ProviderRuntimeError.startupFailure
            }
            let candidateConnection = OpenCodeServerConnection(
                baseURL: baseURL,
                username: "opencode",
                password: password
            )
            let request = OpenCodeProcessLaunchRequest(
                executableURL: executableURL,
                // No `--pure`: that flag means "run without external plugins",
                // so it silently disabled every plugin the app writes into the
                // managed configuration. The app's own servers are recognised by
                // `OPENCODE_CONFIG` instead (``OpenCodeProcessTree/isManagedServer``).
                arguments: [
                    "serve",
                    "--hostname", "127.0.0.1",
                    "--port", String(port)
                ],
                environment: Self.launchEnvironment(
                    connection: candidateConnection,
                    configurationPath: configurationPath
                ),
                workingDirectoryURL: workingDirectoryURL
            )

            serverStatus = .starting
            let launchedHandle: any OpenCodeProcessHandling
            do {
                launchedHandle = try await processLauncher.launch(request)
            } catch let error as ProviderRuntimeError {
                serverStatus = .stopped
                throw error
            } catch {
                serverStatus = .stopped
                throw ProviderRuntimeError.startupFailure
            }

            processHandle = launchedHandle
            let launchedPID = await launchedHandle.processIdentifier() ?? 0

            do {
                // Before the first request that carries the password: the child
                // must be the process that owns the port. A start that skipped
                // this could hand `Basic base64("opencode:<keychain password>")`
                // to a process that merely won the race for the freed port, and
                // the impostor only has to answer a plausible health check.
                let isChildListener = await listenerVerifier
                    .waitUntilProcessOwnsListeningPort(
                        port,
                        processIdentifier: await launchedHandle.processIdentifier()
                    )
                guard isChildListener else {
                    AppLog.openCode.error(
                        "The port \(port, privacy: .public) is not held by the child; retrying on a fresh port instead of sending the server password"
                    )
                    throw ProviderRuntimeError.startupFailure
                }

                let version = try await healthChecker.waitUntilHealthy(
                    connection: candidateConnection
                )
                connection = candidateConnection
                serverStatus = .running(version: version, baseURL: baseURL)
                // Written down while it is known to be ours: if this process is
                // killed before it can stop the server, the next launch reads the
                // lease and ends it instead of leaving a second server behind.
                OpenCodeServerLedger.record(
                    OpenCodeServerLease(
                        pid: launchedPID,
                        port: port,
                        executablePath: executableURL.path,
                        startedAt: Date()
                    ),
                    in: workingDirectoryURL
                )
                AppLog.openCode.info(
                    "OpenCode \(version, privacy: .public) listening on authenticated loopback"
                )
                return candidateConnection
            } catch let error as ProviderRuntimeError {
                await launchedHandle.terminate()
                OpenCodeServerLedger.release(pid: launchedPID, in: workingDirectoryURL)
                processHandle = nil
                connection = nil
                serverStatus = .stopped

                guard error != .authenticationFailure else {
                    throw error
                }

                lastError = error
                AppLog.openCode.error(
                    "OpenCode health check failed on attempt \(attempt, privacy: .public)"
                )
            } catch is CancellationError {
                // The owner is gone — the user stopped the engine, or the scene
                // holding the `.task` was torn down. Launching a second child for a
                // start nobody is waiting for and then reporting it as a failure
                // was both wasteful and misleading.
                await launchedHandle.terminate()
                OpenCodeServerLedger.release(pid: launchedPID, in: workingDirectoryURL)
                processHandle = nil
                connection = nil
                serverStatus = .stopped
                throw CancellationError()
            } catch {
                await launchedHandle.terminate()
                OpenCodeServerLedger.release(pid: launchedPID, in: workingDirectoryURL)
                processHandle = nil
                connection = nil
                serverStatus = .stopped
                lastError = .startupFailure
            }
        }

        throw lastError
    }

    func stop() async {
        if let processHandle {
            let pid = await processHandle.processIdentifier() ?? 0
            await processHandle.terminate()
            OpenCodeServerLedger.release(pid: pid, in: workingDirectoryURL)
        }

        processHandle = nil
        connection = nil
        serverStatus = .stopped
    }

    private func currentProcessIsRunning() async -> Bool {
        guard let processHandle else {
            return false
        }

        return await processHandle.isRunning()
    }

    private func resolveServerPassword() async throws -> String {
        do {
            // Her başlatmada rotasyon: eski şifre süresiz geçerli kalmasın.
            // `opencode serve` harici binary'si stdin ile şifre almadığı için
            // şifre `OPENCODE_SERVER_PASSWORD` ortam değişkeniyle taşınmaya
            // devam eder; daralan pencere rotasyondan gelir, aktarımdan değil.
            let generated = try await passwordGenerator()
            guard !generated.isEmpty else {
                throw ProviderRuntimeError.authenticationFailure
            }
            try credentialStore.write(generated, for: .openCodeServerPassword)
            return generated
        } catch let error as ProviderRuntimeError {
            throw error
        } catch {
            throw ProviderRuntimeError.authenticationFailure
        }
    }


    private static func launchEnvironment(
        connection: OpenCodeServerConnection,
        configurationPath: String
    ) -> [String: String] {
        [
            "OPENCODE_SERVER_USERNAME": connection.username,
            "OPENCODE_SERVER_PASSWORD": connection.password,
            // Uygulamanın ürettiği izin/talimat/MCP dosyası; kullanıcının
            // opencode.json dosyasına dokunulmaz, OpenCode yapılandırmaları
            // birleştirir.
            "OPENCODE_CONFIG": configurationPath
        ]
    }

    /// Uygulamanın yapılandırmasını yazar ve OpenCode'a verilecek
    /// `OPENCODE_CONFIG` yolunu döndürür.
    ///
    /// Bilgisayar kullanımı kapalıysa yalnızca yönlendirme kuralları ve uzantı
    /// bölümleri yazılır: talimatlar ve bilgisayar kullanımı kuralları ona ait bir
    /// katkıdır, dosyanın tamamı değil. Seviye buraya hiç girmez — her istekte
    /// okunur, böylece tur ortasında değiştirilebilir.
    private static func writeManagedConfiguration(
        computerUse: ComputerUseConfiguration?,
        extensions: ExtensionRuntimeSnapshot,
        workingDirectoryURL: URL
    ) throws -> String {
        do {
            if let computerUse {
                return try ComputerUseFiles.write(
                    configuration: computerUse,
                    extensions: extensions,
                    fileManager: .default
                ).path
            }

            return try ManagedOpenCodeConfiguration.write(
                in: workingDirectoryURL,
                instructionPaths: [],
                permissionRules: [],
                extensions: extensions
            ).path
        } catch {
            AppLog.openCode.error(
                "Could not write the managed OpenCode configuration: \(error.localizedDescription, privacy: .public)"
            )
            throw ProviderRuntimeError.startupFailure
        }
    }

    static func managedWorkingDirectoryURL() -> URL {
        ManagedAppDirectories.openCodeWorkingDirectory()
    }

    /// Creates the managed working directory and its default OpenCode project
    /// config, and upgrades a file an earlier version of this app wrote.
    ///
    /// The approval decision used to live in *this* file. It now lives in the
    /// managed configuration (``ManagedOpenCodeConfiguration``), so one file
    /// carries the whole policy and changing levels is a single write. A leftover
    /// `permission` block here would still be merged by OpenCode and could outrank
    /// that policy, so a file this app wrote is rewritten with the schema alone.
    ///
    /// A file whose keys are not the ones this app writes belongs to somebody else
    /// and is never modified — not even to "fix" it.
    ///
    /// Failures are surfaced instead of being swallowed: a silent failure would
    /// leave the server running with settings the user never chose.
    private static func writeBaseConfiguration(at workingDirectoryURL: URL) throws {
        let configFileURL = workingDirectoryURL.appendingPathComponent("opencode.json")
        let appWrittenKeys: Set<String> = ["$schema", "permission"]

        if let existing = try? String(contentsOf: configFileURL, encoding: .utf8) {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(existing.utf8))
                    as? [String: Any],
                Set(object.keys).isSubset(of: appWrittenKeys)
            else {
                return
            }

            // Already upgraded, nothing to do.
            guard object["permission"] != nil else {
                return
            }

            AppLog.openCode.info(
                "Upgrading the managed project config: permission rules now live in the managed configuration"
            )
        } else if FileManager.default.fileExists(atPath: configFileURL.path) {
            // Present but unreadable. Rewriting it blind could discard something
            // this app does not understand, and the server still starts without it.
            AppLog.openCode.error(
                "A project config exists but could not be read; leaving it in place"
            )
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: workingDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            AppLog.openCode.error(
                "Could not create the OpenCode working directory: \(error.localizedDescription, privacy: .public)"
            )
            throw ProviderRuntimeError.startupFailure
        }

        // No `permission` key: the policy is written once, in the managed
        // configuration, and this file only exists so OpenCode treats the folder
        // as a project root.
        let configContent = """
        {
          "$schema": "https://opencode.ai/config.json"
        }
        """
        do {
            try configContent.write(
                to: configFileURL,
                atomically: true,
                encoding: .utf8
            )
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configFileURL.path
            )
        } catch {
            AppLog.openCode.error(
                "Could not write the OpenCode configuration: \(error.localizedDescription, privacy: .public)"
            )
            throw ProviderRuntimeError.startupFailure
        }
    }

    private static func generateSecurePassword() async throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw ProviderRuntimeError.authenticationFailure
        }
        return Data(bytes).base64EncodedString()
    }
}

struct URLSessionOpenCodeHealthChecker: OpenCodeHealthChecking {
    private let session: URLSession
    private let attempts: Int
    private let delay: Duration

    init(session: URLSession, attempts: Int, delay: Duration) {
        self.session = session
        self.attempts = attempts
        self.delay = delay
    }

    static func shared() -> Self {
        Self(session: .shared, attempts: 40, delay: .milliseconds(100))
    }

    func waitUntilHealthy(connection: OpenCodeServerConnection) async throws -> String {
        let url = connection.baseURL
            .appendingPathComponent("global")
            .appendingPathComponent("health")

        for attempt in 0..<attempts {
            try Task.checkCancellation()

            var request = URLRequest(url: url)
            request.setValue(connection.authorizationHeader, forHTTPHeaderField: "Authorization")

            do {
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else {
                    throw ProviderRuntimeError.startupFailure
                }

                if response.statusCode == 401 || response.statusCode == 403 {
                    throw ProviderRuntimeError.authenticationFailure
                }

                if response.statusCode == 200,
                   let health = try? JSONDecoder().decode(HealthResponse.self, from: data),
                   health.healthy
                {
                    return health.version
                }
            } catch let error as ProviderRuntimeError {
                if error == .authenticationFailure {
                    throw error
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The child process may still be binding its loopback socket.
            }

            if attempt + 1 < attempts {
                try await Task.sleep(for: delay)
            }
        }

        throw ProviderRuntimeError.startupFailure
    }

    private struct HealthResponse: Decodable {
        let healthy: Bool
        let version: String
    }
}
