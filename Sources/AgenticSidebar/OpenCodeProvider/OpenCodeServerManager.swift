import CryptoKit
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
    /// Uygulamanın kendi defteri: üretilen yapılandırma dosyaları ve sunucu
    /// kiraları burada yaşar. Çalışma dizini ajanın çalıştığı yerdir; ikisi
    /// ayrıldığında çalışma alanına köklenmiş bir sunucu sahipli çalışma
    /// kopyasına kendi dosyalarını yazmaz. Varsayılan, sohbet sunucusunun
    /// mevcut davranışıdır: durum dizini çalışma dizinidir.
    private let stateDirectoryURL: URL
    private let passwordGenerator: @Sendable () async throws -> String

    private var processHandle: (any OpenCodeProcessHandling)?
    private var activePID: Int32?

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
        stateDirectoryURL: URL? = nil,
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
        self.stateDirectoryURL = stateDirectoryURL ?? workingDirectoryURL
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
            workingDirectoryURL: stateDirectoryURL
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
                if let processHandle {
                    let handlePID = await processHandle.processIdentifier()
                    let pid = activePID ?? handlePID ?? 0
                    await processHandle.terminate()
                    if pid > 0 {
                        OpenCodeServerLedger.release(pid: pid, in: stateDirectoryURL)
                    }
                }
                activePID = nil
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

    func workingDirectory() -> URL? {
        workingDirectoryURL
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
        //
        // Süreç taraması (`sysctl` turu) actor'ı kilitlemesin diye ayrı
        // görevde koşar; sonuç beklenir çünkü yeni sunucu eski kalıntının
        // portunu almadan süpürme bitmelidir.
        if !hasReapedOrphans {
            hasReapedOrphans = true
            let directory = stateDirectoryURL
            _ = await Task.detached(priority: .utility) {
                OpenCodeServerLedger.reapOrphans(in: directory)
            }.value
        }

        guard let executableURL = executableLocator.locate() else {
            throw ProviderRuntimeError.executableUnavailable
        }

        let password = try await resolveServerPassword()
        try Self.writeBaseConfiguration(at: stateDirectoryURL)

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
            workingDirectoryURL: stateDirectoryURL
        )

        var lastError = ProviderRuntimeError.startupFailure

        // The free port is discovered by probing and then released, so another
        // process can win the race before the child binds it. Retrying once on a
        // fresh port keeps startup reliable without changing the protocol.
        for attempt in 1...Self.startupAttempts {
            let port: UInt16
            do {
                port = try portAllocator.allocate()
            } catch {
                serverStatus = .stopped
                throw ProviderRuntimeError.startupFailure
            }

            guard let baseURL = URL(string: "http://127.0.0.1:\(port)") else {
                serverStatus = .stopped
                throw ProviderRuntimeError.startupFailure
            }

            let candidateConnection = OpenCodeServerConnection(
                baseURL: baseURL,
                username: "opencode",
                password: password
            )

            let request = OpenCodeProcessLaunchRequest(
                executableURL: executableURL,
                arguments: [
                    "serve",
                    "--hostname",
                    "127.0.0.1",
                    "--port",
                    "\(port)",
                ],
                environment: Self.launchEnvironment(
                    connection: candidateConnection,
                    configurationPath: configurationPath
                ),
                workingDirectoryURL: workingDirectoryURL,
                // Süreç çalışma dizini ajanın çalıştığı yerdir, günlük ise
                // uygulamanın defterine düşer. İkisi ayrıldığında (çalışma
                // alanına köklenmiş sunucu) sahipli çalışma kopyasına
                // `opencode-server.log` yazılmaz.
                logDirectoryURL: stateDirectoryURL
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
            let launchedPID = await launchedHandle.processIdentifier()
            activePID = launchedPID

            do {
                // Before the first request that carries the password: the child
                // must be the process that owns the port. A start that skipped
                // this could hand `Basic base64("opencode:<keychain password>")`
                // to a process that merely won the race for the freed port, and
                // the impostor only has to answer a plausible health check.
                let isChildListener =
                    await listenerVerifier
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
                if let launchedPID, launchedPID > 0 {
                    OpenCodeServerLedger.record(
                        OpenCodeServerLease(
                            pid: launchedPID,
                            port: port,
                            executablePath: executableURL.path,
                            startedAt: Date()
                        ),
                        in: stateDirectoryURL
                    )
                }
                AppLog.openCode.info(
                    "OpenCode \(version, privacy: .public) listening on authenticated loopback"
                )
                // Sabitlenen sürümden sapma şema kayması demektir; kayıt düşülür,
                // başlatma engellenmez.
                ManagedOpenCodeConfiguration.validateRuntimeVersion(version)
                return candidateConnection
            } catch let error as ProviderRuntimeError {
                await launchedHandle.terminate()
                if let launchedPID, launchedPID > 0 {
                    OpenCodeServerLedger.release(pid: launchedPID, in: stateDirectoryURL)
                }
                activePID = nil
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
                if let launchedPID, launchedPID > 0 {
                    OpenCodeServerLedger.release(pid: launchedPID, in: stateDirectoryURL)
                }
                activePID = nil
                processHandle = nil
                connection = nil
                serverStatus = .stopped
                throw CancellationError()
            } catch {
                await launchedHandle.terminate()
                if let launchedPID, launchedPID > 0 {
                    OpenCodeServerLedger.release(pid: launchedPID, in: stateDirectoryURL)
                }
                activePID = nil
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
            let handlePID = await processHandle.processIdentifier()
            let pid = activePID ?? handlePID ?? 0
            await processHandle.terminate()
            if pid > 0 {
                OpenCodeServerLedger.release(pid: pid, in: stateDirectoryURL)
            }
        }

        activePID = nil
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
            "OPENCODE_CONFIG": configurationPath,
        ]
    }

    /// Uygulamanın yapılandırmasını yazar ve OpenCode'a verilecek
    /// `OPENCODE_CONFIG` yolunu döndürür.
    ///
    /// Bilgisayar kullanımı kapalıysa yalnızca yönlendirme kuralları ve uzantı
    /// bölümleri yazılır: talimatlar ve bilgisayar kullanımı kuralları ona ait bir
    /// katkıdır, dosyanın tamamı değil. Seviye buraya hiç girmez — tur başında
    /// okunur, böylece yeniden başlatmadan bir sonraki turda geçerli olur.
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

    static func generateSecurePassword() async throws -> String {
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

/// Bir görev çalışma alanına köklenmiş sunucunun tek kullanımlık oturumu.
///
/// `release` idempotenttir: terminal tamamlanma, iptal, kapanış ve başlatma
/// hatası aynı yolu kullanır; ikinci çağrı hiçbir şeye dokunmaz.
struct OpenCodeWorkspaceServerSession: Sendable {
    /// Kanonik çalışma alanı yolu; sunucunun çalışma dizini budur.
    let workspacePath: String
    let manager: any OpenCodeServerManaging
    let connection: OpenCodeServerConnection
    /// Sunucuyu durdurur ve çalışma alanı slotunu serbest bırakır.
    let release: @Sendable () async -> Void
}

/// Çalışma alanına köklenmiş sunucu üretiminin kapalı kalma hataları.
enum OpenCodeWorkspaceServerError: Error, Equatable, LocalizedError {
    /// Sahipli çalışma alanı gerçek bir dizin değil; köklenemez.
    case workspaceNotRootable(path: String, reason: String)
    /// Bu çalışma alanı için zaten etkin bir sunucu var.
    case workspaceServerAlreadyActive(path: String)
    /// Sunucu süreci ayağa kalkamadı.
    case startupFailed(path: String, reason: String)
    /// Gönderim hattı çalışma alanına köklenmiş sunucu üretemiyor.
    case rootingUnavailable(workspacePath: String)

    var errorDescription: String? {
        switch self {
        case .workspaceNotRootable(let path, let reason):
            return "The owned workspace at \(path) cannot be rooted: \(reason)"
        case .workspaceServerAlreadyActive(let path):
            return "A workspace-rooted OpenCode server is already active for \(path)"
        case .startupFailed(let path, let reason):
            return "The workspace-rooted OpenCode server for \(path) failed to start: \(reason)"
        case .rootingUnavailable(let workspacePath):
            return
                "No workspace-rooted OpenCode server factory is wired; refusing to run task dispatch against a server that is not rooted at \(workspacePath)"
        }
    }
}

/// Her canlı koşu için sahipli çalışma alanına köklenmiş ayrı bir OpenCode
/// sunucusu açar.
///
/// Sunucu uygulaması yeniden yazılmaz: her çalışma alanı, mevcut
/// ``ManagedOpenCodeServerManager``'ın kendi kökü (süreç çalışma dizini) ve
/// kendi durum ad alanı (yapılandırma + kiralar) ile kurulmuş bir örneğini
/// alır. Durum ad alanı çalışma alanının kanonik yolundan türetilir, böylece
/// aynı çalışma alanının çökme artıkları sonraki açılışta yalnızca kendi
/// defterinden süpürülür; sohbet sunucusunun defterine karışılmaz.
///
/// Eşzamanlılık sınırı: etkin çalışma alanı başına en fazla bir sunucu. Farklı
/// çalışma alanları paralel koşabilir; portlar işletim sisteminin boş port
/// dağıtımından, parolalar her başlatmada üretilen rastgele değerlerden gelir.
actor OpenCodeWorkspaceServerFactory {
    private struct ActiveServer {
        let id: UUID
        let manager: any OpenCodeServerManaging
    }

    private let executableLocator: any OpenCodeExecutableLocating
    private let processLauncher: any OpenCodeProcessLaunching
    private let healthChecker: any OpenCodeHealthChecking
    private let portAllocator: any OpenCodePortAllocating
    private let listenerVerifier: any OpenCodeListenerVerifying
    private let credentialStore: any CredentialStore
    private let stateRootURL: URL
    private let passwordGenerator: @Sendable () async throws -> String

    private var activeServers: [String: ActiveServer] = [:]
    /// `acquire` askıya alındığında (süreç başlatma) aynı çalışma alanı için
    /// ikinci bir çağrının ikinci bir sunucu açmasını engelleyen rezervasyon.
    private var reservations: Set<String> = []

    init(
        executableLocator: any OpenCodeExecutableLocating,
        processLauncher: any OpenCodeProcessLaunching,
        healthChecker: any OpenCodeHealthChecking,
        portAllocator: any OpenCodePortAllocating,
        listenerVerifier: any OpenCodeListenerVerifying,
        credentialStore: any CredentialStore,
        stateRootURL: URL,
        passwordGenerator: @escaping @Sendable () async throws -> String
    ) {
        self.executableLocator = executableLocator
        self.processLauncher = processLauncher
        self.healthChecker = healthChecker
        self.portAllocator = portAllocator
        self.listenerVerifier = listenerVerifier
        self.credentialStore = credentialStore
        self.stateRootURL = stateRootURL
        self.passwordGenerator = passwordGenerator
    }

    /// Sistem ikilisini ve gerçek süreç altyapısını kullanan üretim fabrikası.
    static func live(
        credentialStore: any CredentialStore,
        stateRootURL: URL
    ) -> OpenCodeWorkspaceServerFactory {
        OpenCodeWorkspaceServerFactory(
            executableLocator: SystemOpenCodeExecutableLocator.current(),
            processLauncher: FoundationOpenCodeProcessLauncher(),
            healthChecker: URLSessionOpenCodeHealthChecker.shared(),
            portAllocator: SystemOpenCodePortAllocator(),
            listenerVerifier: LibprocListenerVerifier(),
            credentialStore: credentialStore,
            stateRootURL: stateRootURL,
            passwordGenerator: ManagedOpenCodeServerManager.generateSecurePassword
        )
    }

    /// Sahipli çalışma alanı için bir sunucu açar.
    ///
    /// - Throws: `workspaceNotRootable` (dizin yok), `workspaceServerAlreadyActive`
    ///   (aynı çalışma alanı için etkin/rezerve sunucu var) ya da
    ///   `startupFailed` (süreç ayağa kalkmadı). Her hata yolu çocuk süreçleri
    ///   sonlandırır; slot serbest kalır.
    func acquire(workspacePath: String) async throws -> OpenCodeWorkspaceServerSession {
        let canonicalPath = Self.canonicalPath(workspacePath)

        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: canonicalPath, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw OpenCodeWorkspaceServerError.workspaceNotRootable(
                path: canonicalPath,
                reason: "the owned workspace path is not an existing directory"
            )
        }

        guard activeServers[canonicalPath] == nil, !reservations.contains(canonicalPath) else {
            throw OpenCodeWorkspaceServerError.workspaceServerAlreadyActive(path: canonicalPath)
        }
        reservations.insert(canonicalPath)
        defer { reservations.remove(canonicalPath) }

        let manager = ManagedOpenCodeServerManager(
            executableLocator: executableLocator,
            processLauncher: processLauncher,
            healthChecker: healthChecker,
            portAllocator: portAllocator,
            listenerVerifier: listenerVerifier,
            credentialStore: credentialStore,
            workingDirectoryURL: URL(fileURLWithPath: canonicalPath, isDirectory: true),
            stateDirectoryURL: stateDirectoryURL(forCanonicalPath: canonicalPath),
            passwordGenerator: passwordGenerator
        )

        let connection: OpenCodeServerConnection
        do {
            connection = try await manager.start(computerUse: nil)
        } catch {
            // Manager kendi çocuğunu ve kirasını temizler; burada yalnızca
            // rezervasyon serbest kalır (defer) ve hata tiplenir.
            throw OpenCodeWorkspaceServerError.startupFailed(
                path: canonicalPath,
                reason: String(describing: error)
            )
        }

        let id = UUID()
        activeServers[canonicalPath] = ActiveServer(id: id, manager: manager)
        let release: @Sendable () async -> Void = { [weak self] in
            await self?.release(workspacePath: canonicalPath, serverID: id)
        }
        return OpenCodeWorkspaceServerSession(
            workspacePath: canonicalPath,
            manager: manager,
            connection: connection,
            release: release
        )
    }

    /// Sunucuyu durdurur ve slotu serbest bırakır; yalnızca aynı oturum için
    /// etkilidir, sonradan açılmış bir sunucuya dokunmaz.
    func release(workspacePath: String, serverID: UUID) async {
        guard let active = activeServers[workspacePath], active.id == serverID else {
            return
        }
        activeServers[workspacePath] = nil
        await active.manager.stop()
    }

    /// Bu süreçte etkin sunucu bulunan çalışma alanlarının kanonik yolları.
    func activeWorkspacePaths() -> Set<String> {
        Set(activeServers.keys)
    }

    /// Kapanış yolu: hâlâ etkin olan bütün çalışma alanı sunucularını durdurur.
    ///
    /// Terminal tamamlanmadan sonra bırakma asenkron tamamlanır; uygulama
    /// kapanırken bu pencere kapatılır. Bırakma yolları idempotenttir, geç
    /// gelen bir `release` artık hiçbir şeye dokunmaz.
    ///
    /// Durdurmalar paralel koşar (`TaskGroup`) ve 10 sn üst sınırı vardır:
    /// süre dolarsa bekleme bırakılır, kalan durdurmalar iptal edilir.
    /// Slotlar önceden boşaltıldığı için geç gelen `release` yine de
    /// hiçbir şeye dokunmaz.
    static let stopAllTimeout: Duration = .seconds(10)

    @discardableResult
    func stopAll() async -> Int {
        let servers = Array(activeServers.values)
        activeServers.removeAll()
        guard !servers.isEmpty else {
            return 0
        }
        let finished = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                await withTaskGroup(of: Void.self) { inner in
                    for server in servers {
                        inner.addTask { await server.manager.stop() }
                    }
                }
                return !Task.isCancelled
            }
            group.addTask {
                try? await Task.sleep(for: Self.stopAllTimeout)
                return false
            }
            guard let first = await group.next() else {
                return true
            }
            group.cancelAll()
            return first
        }
        if !finished {
            AppLog.openCode.error("stopAll exceeded its 10s budget; remaining stops were cancelled")
        }
        return servers.count
    }

    /// Bir çalışma alanının yapılandırma/kiralama ad alanı.
    func stateDirectoryURL(forWorkspacePath workspacePath: String) async -> URL {
        stateDirectoryURL(forCanonicalPath: Self.canonicalPath(workspacePath))
    }

    private func stateDirectoryURL(forCanonicalPath canonicalPath: String) -> URL {
        let digest = SHA256.hash(data: Data(canonicalPath.utf8))
        let namespace = digest.map { String(format: "%02x", $0) }.joined()
        return stateRootURL.appendingPathComponent(namespace, isDirectory: true)
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    }
}
