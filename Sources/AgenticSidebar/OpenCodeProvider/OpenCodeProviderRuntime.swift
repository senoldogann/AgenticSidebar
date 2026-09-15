import Foundation

actor OpenCodeProviderRuntime: ProviderRuntime {
    nonisolated let id = ProviderID("opencode")

    private let serverManager: any OpenCodeServerManaging
    private let clientFactory: @Sendable (OpenCodeServerConnection) -> any OpenCodeClientProtocol
    private var remoteSessionIDs: [UUID: String] = [:]

    init(
        serverManager: any OpenCodeServerManaging,
        clientFactory: @escaping @Sendable (OpenCodeServerConnection) -> any OpenCodeClientProtocol
    ) {
        self.serverManager = serverManager
        self.clientFactory = clientFactory
    }

    static func live(
        serverManager: any OpenCodeServerManaging,
        transport: any OpenCodeTransport
    ) -> OpenCodeProviderRuntime {
        OpenCodeProviderRuntime(
            serverManager: serverManager,
            clientFactory: { connection in
                OpenCodeClient(
                    transport: transport,
                    connection: connection
                )
            }
        )
    }

    func capabilities() async throws -> ProviderCapabilities {
        guard let connection = await serverManager.currentConnection() else {
            throw ProviderRuntimeError.unavailable
        }

        return try await clientFactory(connection).capabilities()
    }

    func startStream(for request: ProviderRequest) async throws -> ProviderStream {
        guard request.configuration.providerID == id else {
            throw ProviderRuntimeError.unexpectedResponse
        }
        guard let connection = await serverManager.currentConnection() else {
            throw ProviderRuntimeError.unavailable
        }
        guard let model = OpenCodeModelReference(
            flattenedID: request.configuration.modelID
        ) else {
            throw ProviderRuntimeError.unexpectedResponse
        }
        guard let prompt = request.messages.last(where: { $0.role == .user })?.text else {
            throw ProviderRuntimeError.unexpectedResponse
        }

        let client = clientFactory(connection)
        let remoteSessionID = try await remoteSessionID(
            for: request.sessionID,
            client: client
        )

        // Subscribe before submitting so fast backend events cannot be missed.
        let lineStream = try await client.eventStream()
        do {
            try await client.sendPromptAsync(
                sessionID: remoteSessionID,
                model: model,
                variant: request.configuration.variantID?.rawValue,
                text: prompt
            )
        } catch {
            await lineStream.cancel()
            throw error
        }

        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        let forwardingTask = Task {
            var normalizer = OpenCodeStreamNormalizer(sessionID: remoteSessionID)
            do {
                streamLoop: for try await line in lineStream.lines {
                    try Task.checkCancellation()
                    for event in try normalizer.consume(line: line) {
                        pair.continuation.yield(event)
                        if event == .completed {
                            break streamLoop
                        }
                    }
                }
                await lineStream.cancel()
                pair.continuation.finish()
            } catch is CancellationError {
                pair.continuation.finish(throwing: CancellationError())
            } catch let error as ProviderRuntimeError {
                await lineStream.cancel()
                pair.continuation.finish(throwing: error)
            } catch {
                await lineStream.cancel()
                pair.continuation.finish(throwing: ProviderRuntimeError.transport)
            }
        }

        return ProviderStream(
            events: pair.stream,
            cancellation: {
                forwardingTask.cancel()
                try? await client.abort(sessionID: remoteSessionID)
                await lineStream.cancel()
            }
        )
    }

    private func remoteSessionID(
        for appSessionID: UUID,
        client: any OpenCodeClientProtocol
    ) async throws -> String {
        if let existing = remoteSessionIDs[appSessionID] {
            return existing
        }

        let created = try await client.createSession()
        remoteSessionIDs[appSessionID] = created
        return created
    }
}
