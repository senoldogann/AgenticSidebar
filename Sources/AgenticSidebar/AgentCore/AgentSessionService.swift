import Foundation
import Observation

@MainActor
@Observable
final class AgentSessionService {
    @ObservationIgnored
    private let runtimes: [any ProviderRuntime]

    @ObservationIgnored
    private var activeTask: Task<Void, Never>?

    @ObservationIgnored
    private var activeStream: ProviderStream?

    @ObservationIgnored
    private var activeTurnID: UUID?

    private(set) var providers: [ProviderCapabilities] = []
    private(set) var state: AgentSessionState

    init(
        runtimes: [any ProviderRuntime],
        state: AgentSessionState = AgentSessionState()
    ) {
        self.runtimes = runtimes
        self.state = state
    }

    var availableModels: [ProviderModelCapability] {
        guard
            let configuration = state.configuration,
            let provider = providers.first(where: { $0.id == configuration.providerID })
        else {
            return []
        }

        return provider.models
    }

    var availableVariants: [ProviderVariant] {
        guard
            let configuration = state.configuration,
            let provider = providers.first(where: { $0.id == configuration.providerID }),
            let model = provider.model(id: configuration.modelID)
        else {
            return []
        }

        return model.variants
    }

    var isBusy: Bool {
        switch state.status {
        case .streaming, .runningTool, .waiting, .cancelling:
            true
        case .idle, .completed, .cancelled, .failed:
            false
        }
    }

    var canSubmit: Bool {
        guard let configuration = state.configuration else {
            return false
        }

        return runtime(for: configuration.providerID) != nil && !isBusy
    }

    func refreshCapabilities() async {
        guard !isBusy else {
            return
        }

        var loadedProviders: [ProviderCapabilities] = []
        var capabilityErrors: [AgentSessionError] = []

        for runtime in runtimes {
            do {
                let capabilities = try await runtime.capabilities()
                guard capabilities.id == runtime.id else {
                    continue
                }
                loadedProviders.append(capabilities)
            } catch let error as ProviderRuntimeError {
                capabilityErrors.append(sessionError(for: error))
            } catch {
                capabilityErrors.append(.providerUnavailable)
                continue
            }
        }

        providers = loadedProviders

        if runtimes.isEmpty {
            state.configuration = nil
            state.status = .idle
            state.error = nil
            return
        }

        guard !loadedProviders.isEmpty else {
            state.configuration = nil
            state.status = .failed
            state.error = capabilityErrors.count == runtimes.count
                && capabilityErrors.allSatisfy { $0 == .missingCredential }
                ? .missingCredential
                : .providerUnavailable
            return
        }

        state.status = .idle
        state.error = nil
        normalizeConfiguration()
    }

    func selectProvider(_ providerID: ProviderID) throws {
        guard !isBusy else {
            return
        }

        guard
            let provider = providers.first(where: { $0.id == providerID }),
            let model = provider.models.first
        else {
            throw AgentSessionError.unsupportedCapability
        }

        state.configuration = SessionConfiguration(
            providerID: provider.id,
            modelID: model.id,
            variantID: nil
        )
        state.error = nil
    }

    func selectModel(_ modelID: ProviderModelID) throws {
        guard !isBusy else {
            return
        }

        guard
            var configuration = state.configuration,
            let provider = providers.first(where: { $0.id == configuration.providerID }),
            let model = provider.model(id: modelID)
        else {
            throw AgentSessionError.unsupportedCapability
        }

        configuration.modelID = model.id
        if !provider.supports(
            variantID: configuration.variantID,
            for: model.id
        ) {
            configuration.variantID = nil
        }
        state.configuration = configuration
        state.error = nil
    }

    func selectVariant(_ variantID: ProviderVariantID?) throws {
        guard !isBusy else {
            return
        }

        guard
            var configuration = state.configuration,
            let provider = providers.first(where: { $0.id == configuration.providerID }),
            provider.supports(
                variantID: variantID,
                for: configuration.modelID
            )
        else {
            throw AgentSessionError.unsupportedCapability
        }

        configuration.variantID = variantID
        state.configuration = configuration
        state.error = nil
    }

    @discardableResult
    func submit(_ prompt: String) -> Task<Void, Never>? {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            !trimmedPrompt.isEmpty,
            canSubmit,
            let configuration = state.configuration,
            let runtime = runtime(for: configuration.providerID)
        else {
            return nil
        }

        state.messages.append(
            ChatMessage(role: .user, text: trimmedPrompt)
        )
        state.status = .streaming
        state.error = nil
        state.startedAt = Date()
        state.completedAt = nil

        let request = ProviderRequest(
            sessionID: state.id,
            configuration: configuration,
            messages: state.messages
        )
        let turnID = UUID()
        activeTurnID = turnID

        let task = Task { [weak self] in
            guard let self else {
                return
            }

            await self.consume(
                runtime: runtime,
                request: request,
                turnID: turnID
            )
        }
        activeTask = task
        return task
    }

    func cancel() async {
        guard let task = activeTask else {
            return
        }

        state.status = .cancelling
        state.error = nil
        task.cancel()

        if let activeStream {
            await activeStream.cancel()
        }

        await task.value

        if state.status == .cancelling {
            state.status = .cancelled
            state.completedAt = Date()
        }

        activeTask = nil
        activeStream = nil
        activeTurnID = nil
    }

    private func consume(
        runtime: any ProviderRuntime,
        request: ProviderRequest,
        turnID: UUID
    ) async {
        do {
            let stream = try await runtime.startStream(for: request)

            if Task.isCancelled {
                await stream.cancel()
                throw CancellationError()
            }

            guard activeTurnID == turnID else {
                await stream.cancel()
                return
            }

            activeStream = stream
            var assistantMessageID: UUID?
            var didComplete = false

            for try await event in stream.events {
                try Task.checkCancellation()

                guard activeTurnID == turnID else {
                    return
                }

                switch event {
                case let .assistantTextDelta(delta):
                    if
                        let assistantMessageID,
                        let index = state.messages.firstIndex(where: { $0.id == assistantMessageID })
                    {
                        state.messages[index].text += delta
                    } else {
                        let message = ChatMessage(role: .assistant, text: delta)
                        assistantMessageID = message.id
                        state.messages.append(message)
                    }
                    state.status = .streaming

                case let .toolStarted(toolName):
                    state.status = .runningTool(toolName)

                case .toolFinished:
                    state.status = .streaming

                case .waiting:
                    state.status = .waiting

                case .completed:
                    didComplete = true
                }

                if didComplete {
                    break
                }
            }

            if Task.isCancelled {
                throw CancellationError()
            }

            guard activeTurnID == turnID else {
                return
            }

            if didComplete {
                state.status = .completed
                state.completedAt = Date()
            } else {
                state.status = .failed
                state.error = .streamInterrupted
                state.completedAt = Date()
            }
        } catch is CancellationError {
            guard activeTurnID == turnID else {
                return
            }

            state.status = .cancelled
            state.completedAt = Date()
        } catch let error as ProviderRuntimeError {
            guard activeTurnID == turnID else {
                return
            }

            state.status = .failed
            state.error = sessionError(for: error)
            state.completedAt = Date()
        } catch {
            guard activeTurnID == turnID else {
                return
            }

            state.status = .failed
            state.error = .transportFailure
            state.completedAt = Date()
        }

        if activeTurnID == turnID {
            activeTask = nil
            activeStream = nil
            activeTurnID = nil
        }
    }

    private func normalizeConfiguration() {
        if
            var configuration = state.configuration,
            let provider = providers.first(where: { $0.id == configuration.providerID }),
            provider.model(id: configuration.modelID) != nil
        {
            if !provider.supports(
                variantID: configuration.variantID,
                for: configuration.modelID
            ) {
                configuration.variantID = nil
                state.configuration = configuration
            }
            return
        }

        guard
            let provider = providers.first(where: { !$0.models.isEmpty }),
            let model = provider.models.first
        else {
            state.configuration = nil
            return
        }

        state.configuration = SessionConfiguration(
            providerID: provider.id,
            modelID: model.id,
            variantID: nil
        )
    }

    private func runtime(for providerID: ProviderID) -> (any ProviderRuntime)? {
        runtimes.first { $0.id == providerID }
    }

    private func sessionError(for error: ProviderRuntimeError) -> AgentSessionError {
        switch error {
        case .missingCredential:
            .missingCredential
        case .unavailable:
            .providerUnavailable
        case .transport:
            .transportFailure
        case .unexpectedResponse:
            .unexpectedBackendResponse
        }
    }
}
