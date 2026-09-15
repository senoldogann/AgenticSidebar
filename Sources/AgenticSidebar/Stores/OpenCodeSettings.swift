import Foundation
import Observation

@MainActor
@Observable
final class OpenCodeSettings {
    @ObservationIgnored
    private let executableLocator: any OpenCodeExecutableLocating

    @ObservationIgnored
    private let serverManager: any OpenCodeServerManaging

    @ObservationIgnored
    private let clientFactory: @Sendable (OpenCodeServerConnection) -> any OpenCodeClientProtocol

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

    init(
        executableLocator: any OpenCodeExecutableLocating,
        serverManager: any OpenCodeServerManaging,
        clientFactory: @escaping @Sendable (OpenCodeServerConnection) -> any OpenCodeClientProtocol
    ) {
        self.executableLocator = executableLocator
        self.serverManager = serverManager
        self.clientFactory = clientFactory
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
        isInstalled = executableLocator.locate() != nil
        guard isInstalled else {
            serverStatus = .stopped
            errorMessage = "OpenCode executable was not found."
            return false
        }

        do {
            let connection = try await serverManager.start()
            serverStatus = await serverManager.status()
            let resolvedClient = clientFactory(connection)
            client = resolvedClient
            await loadAuthMethods(using: resolvedClient)
            return true
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
        clearRuntimeState()
        errorMessage = nil
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
        }
    }
}
