import Foundation
import Security

actor ManagedOpenCodeServerManager: OpenCodeServerManaging {
    private let executableLocator: any OpenCodeExecutableLocating
    private let processLauncher: any OpenCodeProcessLaunching
    private let healthChecker: any OpenCodeHealthChecking
    private let portAllocator: any OpenCodePortAllocating
    private let credentialStore: any CredentialStore
    private let workingDirectoryURL: URL
    private let passwordGenerator: @Sendable () async throws -> String

    private var processHandle: (any OpenCodeProcessHandling)?
    private var connection: OpenCodeServerConnection?
    private var serverStatus: OpenCodeServerStatus = .stopped

    init(
        executableLocator: any OpenCodeExecutableLocating,
        processLauncher: any OpenCodeProcessLaunching,
        healthChecker: any OpenCodeHealthChecking,
        portAllocator: any OpenCodePortAllocating,
        credentialStore: any CredentialStore,
        workingDirectoryURL: URL,
        passwordGenerator: @escaping @Sendable () async throws -> String
    ) {
        self.executableLocator = executableLocator
        self.processLauncher = processLauncher
        self.healthChecker = healthChecker
        self.portAllocator = portAllocator
        self.credentialStore = credentialStore
        self.workingDirectoryURL = workingDirectoryURL
        self.passwordGenerator = passwordGenerator
    }

    static func live(credentialStore: any CredentialStore) -> ManagedOpenCodeServerManager {
        ManagedOpenCodeServerManager(
            executableLocator: SystemOpenCodeExecutableLocator.current(),
            processLauncher: FoundationOpenCodeProcessLauncher(),
            healthChecker: URLSessionOpenCodeHealthChecker.shared(),
            portAllocator: SystemOpenCodePortAllocator(),
            credentialStore: credentialStore,
            workingDirectoryURL: defaultWorkingDirectoryURL(),
            passwordGenerator: generateSecurePassword
        )
    }

    func status() -> OpenCodeServerStatus {
        serverStatus
    }

    func currentConnection() -> OpenCodeServerConnection? {
        connection
    }

    func start() async throws -> OpenCodeServerConnection {
        if let connection {
            return connection
        }

        guard let executableURL = executableLocator.locate() else {
            throw ProviderRuntimeError.executableUnavailable
        }

        let password = try await resolveServerPassword()
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
            arguments: [
                "serve",
                "--hostname", "127.0.0.1",
                "--port", String(port),
                "--pure"
            ],
            environment: [
                "OPENCODE_SERVER_USERNAME": candidateConnection.username,
                "OPENCODE_SERVER_PASSWORD": candidateConnection.password
            ],
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

        do {
            let version = try await healthChecker.waitUntilHealthy(
                connection: candidateConnection
            )
            connection = candidateConnection
            serverStatus = .running(version: version, baseURL: baseURL)
            return candidateConnection
        } catch let error as ProviderRuntimeError {
            await launchedHandle.terminate()
            processHandle = nil
            connection = nil
            serverStatus = .stopped
            throw error
        } catch {
            await launchedHandle.terminate()
            processHandle = nil
            connection = nil
            serverStatus = .stopped
            throw ProviderRuntimeError.startupFailure
        }
    }

    func stop() async {
        if let processHandle {
            await processHandle.terminate()
        }
        processHandle = nil
        connection = nil
        serverStatus = .stopped
    }

    private func resolveServerPassword() async throws -> String {
        do {
            if let existing = try credentialStore.read(.openCodeServerPassword),
               !existing.isEmpty
            {
                return existing
            }

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


    private static func defaultWorkingDirectoryURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return applicationSupport
            .appendingPathComponent(AppIdentity.name, isDirectory: true)
            .appendingPathComponent("OpenCode", isDirectory: true)
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
