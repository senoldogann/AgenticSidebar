import Foundation

actor OpenAITextCodingAdapter: CodingAgentRuntime {
    nonisolated let runtimeID: String = "openai"

    private let providerRuntime: any ProviderRuntime
    private var activeStreams: [UUID: ProviderStream] = [:]
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    init(providerRuntime: any ProviderRuntime) {
        self.providerRuntime = providerRuntime
    }

    func capabilities(configuration: SessionConfiguration) async -> CodingAgentCapabilities {
        guard configuration.providerID.rawValue == runtimeID else {
            return []
        }

        do {
            let caps = try await providerRuntime.capabilities()
            guard caps.models.contains(where: { $0.id == configuration.modelID }) else {
                return []
            }

            return [
                .textAnalysis,
                .cancellable,
                .structuredEvents,
                .usageReporting,
            ]
        } catch {
            return []
        }
    }

    func start(request: CodingAgentExecutionRequest) async throws -> CodingAgentRun {
        guard request.configuration.providerID.rawValue == runtimeID else {
            throw CodingAgentAdapterError.invalidProvider
        }

        switch request.stage {
        case .plan, .analysis:
            break
        case .implementation, .verification, .codeReview, .qa, .acceptance:
            throw CodingAgentAdapterError.unsupportedStage(request.stage)
        }

        if request.policySnapshot["workspaceWrite"] == "true" {
            throw CodingAgentAdapterError.unsupportedCapability("workspaceWrite")
        }
        if request.policySnapshot["workspaceRead"] == "true" {
            throw CodingAgentAdapterError.unsupportedCapability("workspaceRead")
        }
        if request.policySnapshot["tools"] == "true" {
            throw CodingAgentAdapterError.unsupportedCapability("tools")
        }

        var promptText = "Objective:\n\(request.objective)\n"
        if !request.acceptanceCriteria.isEmpty {
            promptText += "\nAcceptance Criteria:\n"
            for criterion in request.acceptanceCriteria {
                promptText += "- \(criterion.description)\n"
            }
        }
        if !request.relevantFiles.isEmpty {
            promptText += "\nRelevant Files (Bounded Context):\n"
            for file in request.relevantFiles {
                promptText += "- \(file)\n"
            }
        }

        let message = ChatMessage(role: .user, text: promptText)
        let providerRequest = ProviderRequest(
            sessionID: request.taskID,
            configuration: request.configuration,
            messages: [message],
            speedMode: .normal,
            mode: .plan
        )

        let providerStream = try await providerRuntime.startStream(for: providerRequest)
        activeStreams[request.attemptID] = providerStream

        let channel = BoundedChannel<CodingAgentEvent>(capacity: 128)

        let forwardingTask = Task {
            var sawCompletion = false

            try? await channel.send(
                CodingAgentEvent(
                    taskID: request.taskID,
                    attemptID: request.attemptID,
                    generation: request.generation,
                    kind: .started
                )
            )

            do {
                streamLoop: for try await event in providerStream.events {
                    try Task.checkCancellation()

                    switch event {
                    case .assistantTextDelta(let delta):
                        try await channel.send(
                            CodingAgentEvent(
                                taskID: request.taskID,
                                attemptID: request.attemptID,
                                generation: request.generation,
                                kind: .textDelta(delta)
                            )
                        )
                    case .thinkingDelta(let delta):
                        try await channel.send(
                            CodingAgentEvent(
                                taskID: request.taskID,
                                attemptID: request.attemptID,
                                generation: request.generation,
                                kind: .textDelta(delta)
                            )
                        )
                    case .turnUsage(let usage):
                        try await channel.send(
                            CodingAgentEvent(
                                taskID: request.taskID,
                                attemptID: request.attemptID,
                                generation: request.generation,
                                kind: .usage(
                                    inputTokens: usage.inputTokens,
                                    outputTokens: usage.outputTokens
                                )
                            )
                        )
                    case .completed:
                        sawCompletion = true
                        try await channel.send(
                            CodingAgentEvent(
                                taskID: request.taskID,
                                attemptID: request.attemptID,
                                generation: request.generation,
                                kind: .terminalSuccess
                            )
                        )
                        break streamLoop
                    default:
                        break
                    }
                }

                if !sawCompletion {
                    try? await channel.send(
                        CodingAgentEvent(
                            taskID: request.taskID,
                            attemptID: request.attemptID,
                            generation: request.generation,
                            kind: .terminalError("Premature stream EOF without completion event")
                        )
                    )
                }

                await channel.finish()
            } catch is CancellationError {
                try? await channel.send(
                    CodingAgentEvent(
                        taskID: request.taskID,
                        attemptID: request.attemptID,
                        generation: request.generation,
                        kind: .interrupted("Execution cancelled")
                    )
                )
                await channel.finish()
            } catch {
                try? await channel.send(
                    CodingAgentEvent(
                        taskID: request.taskID,
                        attemptID: request.attemptID,
                        generation: request.generation,
                        kind: .terminalError(error.localizedDescription)
                    )
                )
                await channel.finish()
            }
        }

        activeTasks[request.attemptID] = forwardingTask

        let stream = AsyncStream<CodingAgentEvent>(unfolding: {
            try? await channel.receive()
        })

        let run = CodingAgentRun(events: stream) { [weak self] in
            forwardingTask.cancel()
            if let self {
                await self.cancelAttempt(attemptID: request.attemptID)
            }
        }

        return run
    }

    func cancelAttempt(attemptID: UUID) async {
        if let stream = activeStreams[attemptID] {
            await stream.cancel()
        }
        if let task = activeTasks[attemptID] {
            task.cancel()
        }
    }

    func release(attemptID: UUID) async {
        if let stream = activeStreams.removeValue(forKey: attemptID) {
            await stream.cancel()
        }
        if let task = activeTasks.removeValue(forKey: attemptID) {
            task.cancel()
        }
    }
}
