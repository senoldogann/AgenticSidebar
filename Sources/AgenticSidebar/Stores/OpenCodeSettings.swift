import Foundation
import Observation

@MainActor
@Observable
final class OpenCodeSettings {
    /// MCP kaydının yönetilen sunucudaki son durumu.
    enum ComputerUseRegistrationState: Equatable, Sendable {
        case serverStopped
        case disabled
        case registered
        case failed(message: String)
    }

    @ObservationIgnored
    private let executableLocator: any OpenCodeExecutableLocating

    @ObservationIgnored
    private let serverManager: any OpenCodeServerManaging

    @ObservationIgnored
    private let clientFactory: @Sendable (OpenCodeServerConnection) -> any OpenCodeClientProtocol

    /// Etkin ayarları yönetilen sunucu için çözümler; App tarafından enjekte edilir.
    @ObservationIgnored
    private let computerUseProvider: @MainActor () -> ComputerUseLaunchDecision

    @ObservationIgnored
    private var client: (any OpenCodeClientProtocol)?

    private(set) var isInstalled = false
    private(set) var serverStatus: OpenCodeServerStatus = .stopped
    private(set) var authMethods: [String: [OpenCodeAuthMethod]] = [:]
    var selectedProviderID: String?
    var selectedMethodIndex = 0
    var apiKeyDraft = ""
    var metadataDrafts: [String: String] = [:]
    private(set) var errorMessage: String?
    private(set) var computerUseRegistration: ComputerUseRegistrationState = .serverStopped
    private(set) var computerUseErrorMessage: String?
    /// Çalışan sunucunun bilgisayar kullanımı ile başlatılıp başlatılmadığı;
    /// ayar sonradan değişirse yeniden başlatma gerekir.
    private(set) var runningComputerUseEnabled = false

    init(
        executableLocator: any OpenCodeExecutableLocating,
        serverManager: any OpenCodeServerManaging,
        clientFactory: @escaping @Sendable (OpenCodeServerConnection) -> any OpenCodeClientProtocol,
        computerUseProvider: @escaping @MainActor () -> ComputerUseLaunchDecision
    ) {
        self.executableLocator = executableLocator
        self.serverManager = serverManager
        self.clientFactory = clientFactory
        self.computerUseProvider = computerUseProvider
        isInstalled = executableLocator.locate() != nil
    }

    var apiProviderIDs: [String] {
        authMethods
            .filter { _, methods in methods.contains(where: { $0.type == .api }) }
            .map(\.key)
            .sorted()
    }

    var selectedAPIMethods: [OpenCodeAuthMethod] {
        guard let selectedProviderID else {
            return []
        }
        return (authMethods[selectedProviderID] ?? []).filter { $0.type == .api }
    }

    var selectedAPIMethod: OpenCodeAuthMethod? {
        let methods = selectedAPIMethods
        guard methods.indices.contains(selectedMethodIndex) else {
            return nil
        }
        return methods[selectedMethodIndex]
    }

    var activePrompts: [OpenCodeAuthPrompt] {
        (selectedAPIMethod?.prompts ?? []).filter { prompt in
            guard let condition = prompt.when else {
                return true
            }
            guard condition.op == "eq" else {
                return false
            }
            return metadataDrafts[condition.key] == condition.value
        }
    }

    func refreshStatus() async {
        isInstalled = executableLocator.locate() != nil
        if case let .untrusted(path, reason) = executableLocator.resolution() {
            errorMessage = "The opencode at \(path) was not run because \(reason)."
        }
        serverStatus = await serverManager.status()

        guard
            case .running = serverStatus,
            let connection = await serverManager.currentConnection()
        else {
            clearRuntimeState()
            return
        }

        let resolvedClient = clientFactory(connection)
        client = resolvedClient
        await loadAuthMethods(using: resolvedClient)
    }

    @discardableResult
    func start() async -> Bool {
        switch executableLocator.resolution() {
        case .found:
            isInstalled = true
        case .notFound:
            isInstalled = false
            serverStatus = .stopped
            errorMessage = "OpenCode executable was not found."
            return false
        case let .untrusted(path, reason):
            // Refusing is the point: this binary is launched with the server
            // password in its environment, so a file another account can rewrite
            // is not something to run quietly.
            isInstalled = false
            serverStatus = .stopped
            errorMessage = "The opencode at \(path) was not run because \(reason)."
            AppLog.openCode.error(
                "Refused an untrusted opencode binary at \(path, privacy: .public): \(reason, privacy: .public)"
            )
            return false
        }

        let decision = computerUseProvider()

        do {
            let connection: OpenCodeServerConnection
            switch decision {
            case .disabled:
                connection = try await serverManager.start(computerUse: nil)
                runningComputerUseEnabled = false
                computerUseRegistration = .disabled
                computerUseErrorMessage = nil
            case .invalid(let message):
                connection = try await serverManager.start(computerUse: nil)
                runningComputerUseEnabled = false
                computerUseRegistration = .failed(message: message)
                computerUseErrorMessage = message
                AppLog.settings.error(
                    "Computer Use is enabled but its configuration is invalid: \(message, privacy: .public)"
                )
            case .ready(let configuration):
                connection = try await serverManager.start(computerUse: configuration)
                runningComputerUseEnabled = true
                computerUseRegistration = .disabled
                computerUseErrorMessage = nil
                await registerComputerUse(configuration, connection: connection)
            }

            serverStatus = await serverManager.status()
            let resolvedClient = clientFactory(connection)
            client = resolvedClient
            await loadAuthMethods(using: resolvedClient)
            return true
        } catch is CancellationError {
            // A cancelled start is not a failed one: reporting "could not start" for
            // the user's own stop made an ordinary cancellation look like a defect.
            serverStatus = await serverManager.status()
            errorMessage = nil
            return false
        } catch let error as ProviderRuntimeError {
            serverStatus = await serverManager.status()
            errorMessage = safeServerMessage(for: error)
            return false
        } catch {
            serverStatus = await serverManager.status()
            errorMessage = "OpenCode could not start."
            return false
        }
    }

    func stop() async {
        await serverManager.stop()
        serverStatus = .stopped
        runningComputerUseEnabled = false
        computerUseRegistration = .serverStopped
        computerUseErrorMessage = nil
        clearRuntimeState()
        errorMessage = nil
    }

    /// Ayarlar değiştiğinde çalışan sunucuyu yeni yapılandırmayla başlatır.
    ///
    /// Bilgisayar kullanımı ve uzantılar yalnızca açılışta okunur, bu yüzden
    /// onlar bu yoldan geçer. İzin seviyesi geçmez: her istekte okunur ve tur
    /// ortasında değiştirilebilir, o yüzden yeniden başlatma gerektirmez.
    @discardableResult
    func restart() async -> Bool {
        await stop()
        return await start()
    }

    /// `GET /mcp` durumunu tazeler; kart yeniden açıldığında çağrılır.
    func refreshComputerUseStatus() async {
        serverStatus = await serverManager.status()

        guard case .running = serverStatus else {
            runningComputerUseEnabled = false
            computerUseRegistration = .serverStopped
            return
        }

        guard let client else {
            computerUseRegistration = .serverStopped
            return
        }

        do {
            let statuses = try await client.mcpServerStatuses()
            if let status = statuses[ComputerUseConfiguration.serverName] {
                computerUseRegistration = status.isConnected
                    ? .registered
                    : .failed(message: status.error ?? status.status)
                computerUseErrorMessage = status.isConnected
                    ? nil
                    : (status.error ?? "MCP server status: \(status.status)")
            } else {
                computerUseRegistration = .disabled
                computerUseErrorMessage = nil
            }
        } catch {
            computerUseRegistration = .failed(
                message: "Could not read the MCP server status."
            )
            computerUseErrorMessage = "Could not read the MCP server status."
        }
    }

    private func registerComputerUse(
        _ configuration: ComputerUseConfiguration,
        connection: OpenCodeServerConnection
    ) async {
        let resolvedClient = clientFactory(connection)
        do {
            let statuses = try await resolvedClient.addMCPServer(
                name: ComputerUseConfiguration.serverName,
                config: configuration.mcpServerConfig()
            )

            if let status = statuses[ComputerUseConfiguration.serverName],
               !status.isConnected {
                let reason = status.error ?? "MCP server status: \(status.status)"
                computerUseRegistration = .failed(message: reason)
                computerUseErrorMessage = reason
                AppLog.openCode.error(
                    "The chatgpt-system MCP server did not connect: \(status.status, privacy: .public)"
                )
                return
            }

            computerUseRegistration = .registered
            computerUseErrorMessage = nil
            AppLog.openCode.info(
                "Registered the chatgpt-system MCP server for computer use"
            )
        } catch {
            computerUseRegistration = .failed(
                message: "Could not register the chatgpt-system MCP server."
            )
            computerUseErrorMessage = "Could not register the chatgpt-system MCP server."
            AppLog.openCode.error(
                "Could not register the chatgpt-system MCP server"
            )
        }
    }

    func selectProvider(_ providerID: String) {
        guard apiProviderIDs.contains(providerID) else {
            return
        }
        selectedProviderID = providerID
        selectedMethodIndex = 0
        apiKeyDraft = ""
        metadataDrafts = [:]
        seedSelectPromptDefaults()
    }

    func selectMethod(index: Int) {
        guard selectedAPIMethods.indices.contains(index) else {
            return
        }
        selectedMethodIndex = index
        apiKeyDraft = ""
        metadataDrafts = [:]
        seedSelectPromptDefaults()
    }

    @discardableResult
    func saveAPIKey() async -> Bool {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !key.isEmpty,
            let client,
            let selectedProviderID,
            selectedAPIMethod?.type == .api
        else {
            return false
        }

        let metadata = activePrompts.reduce(into: [String: String]()) { result, prompt in
            guard let value = metadataDrafts[prompt.key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else {
                return
            }
            result[prompt.key] = value
        }

        do {
            try await client.setAPIKey(
                providerID: selectedProviderID,
                key: key,
                metadata: metadata
            )
            apiKeyDraft = ""
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Could not update the OpenCode provider credential."
            return false
        }
    }

    private func loadAuthMethods(using client: any OpenCodeClientProtocol) async {
        do {
            authMethods = try await client.authMethods()
            normalizeSelection()
            errorMessage = nil
        } catch {
            authMethods = [:]
            selectedProviderID = nil
            selectedMethodIndex = 0
            errorMessage = "Could not load OpenCode provider authentication methods."
        }
    }

    private func normalizeSelection() {
        let providerIDs = apiProviderIDs
        if let selectedProviderID, providerIDs.contains(selectedProviderID) {
            if !selectedAPIMethods.indices.contains(selectedMethodIndex) {
                selectedMethodIndex = 0
            }
        } else {
            selectedProviderID = providerIDs.first
            selectedMethodIndex = 0
            metadataDrafts = [:]
        }
        seedSelectPromptDefaults()
    }

    private func seedSelectPromptDefaults() {
        for prompt in activePrompts where prompt.type == .select {
            guard metadataDrafts[prompt.key] == nil,
                  let first = prompt.options?.first
            else {
                continue
            }
            metadataDrafts[prompt.key] = first.value
        }
    }

    private func clearRuntimeState() {
        client = nil
        authMethods = [:]
        selectedProviderID = nil
        selectedMethodIndex = 0
        apiKeyDraft = ""
        metadataDrafts = [:]
    }

    private func safeServerMessage(for error: ProviderRuntimeError) -> String {
        switch error {
        case .executableUnavailable:
            "OpenCode executable was not found."
        case .startupFailure:
            "OpenCode could not start."
        case .authenticationFailure:
            "OpenCode server authentication failed."
        case .unavailable:
            "OpenCode is unavailable."
        case .transport:
            "Could not communicate with OpenCode."
        case .unexpectedResponse:
            "OpenCode returned an unexpected response."
        case .missingCredential:
            "OpenCode is missing a required credential."
        case .rateLimited:
            "OpenCode request was rate limited."
        case .contextLimitExceeded:
            "The request exceeded the model context window limit."
        }
    }
}
