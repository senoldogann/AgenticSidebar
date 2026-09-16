import Foundation

actor OpenCodeProviderRuntime: ProviderRuntime {
    nonisolated let id = ProviderID("opencode")

    /// Kullanıcı kararını bekler; nil ise eski davranış korunur (otomatik onay).
    typealias PermissionHandler = @Sendable (OpenCodePermissionRequest) async -> OpenCodePermissionReply
    /// Tur iptalinde askıda kalan izinleri temizler.
    typealias PermissionCancellationHandler = @Sendable (String) async -> Void

    private let serverManager: any OpenCodeServerManaging
    private let clientFactory: @Sendable (OpenCodeServerConnection) -> any OpenCodeClientProtocol
    private let permissionHandler: PermissionHandler?
    private let cancelPendingPermissions: PermissionCancellationHandler?
    private var remoteSessionIDs: [UUID: String] = [:]

    /// The server that owns `remoteSessionIDs`. Remote sessions live inside a
    /// specific server process, so a restarted backend (new port or password)
    /// must invalidate the whole mapping.
    private var sessionConnection: OpenCodeServerConnection?

    init(
        serverManager: any OpenCodeServerManaging,
        clientFactory: @escaping @Sendable (OpenCodeServerConnection) -> any OpenCodeClientProtocol,
        permissionHandler: PermissionHandler?,
        cancelPendingPermissions: PermissionCancellationHandler?
    ) {
        self.serverManager = serverManager
        self.clientFactory = clientFactory
        self.permissionHandler = permissionHandler
        self.cancelPendingPermissions = cancelPendingPermissions
    }

    static func live(
        serverManager: any OpenCodeServerManaging,
        transport: any OpenCodeTransport,
        permissionHandler: PermissionHandler?,
        cancelPendingPermissions: PermissionCancellationHandler?
    ) -> OpenCodeProviderRuntime {
        OpenCodeProviderRuntime(
            serverManager: serverManager,
            clientFactory: { connection in
                OpenCodeClient(
                    transport: transport,
                    connection: connection
                )
            },
            permissionHandler: permissionHandler,
            cancelPendingPermissions: cancelPendingPermissions
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
        guard
            let lastUserMessage = request.messages.last(where: { $0.role == .user }),
            !lastUserMessage.text.isEmpty
        else {
            throw ProviderRuntimeError.unexpectedResponse
        }

        let client = clientFactory(connection)
        var remoteSessionID = try await remoteSessionID(
            for: request.sessionID,
            client: client,
            connection: connection
        )
        let parts = OpenCodePromptBuilder.parts(
            for: lastUserMessage,
            speedMode: request.speedMode,
            mode: request.mode
        )

        // Subscribe before submitting so fast backend events cannot be missed.
        let lineStream = try await client.eventStream()
        do {
            try await client.sendPromptAsync(
                sessionID: remoteSessionID,
                model: model,
                variant: request.configuration.variantID?.rawValue,
                parts: parts
            )
        } catch let error as ProviderRuntimeError where error == .unexpectedResponse {
            // The backend no longer knows this session (for example after a restart
            // that kept the same loopback address). Recreate it once and retry on
            // the subscription that is already open.
            AppLog.openCode.error(
                "OpenCode rejected the remote session; recreating it once"
            )
            remoteSessionIDs[request.sessionID] = nil
            do {
                remoteSessionID = try await self.remoteSessionID(
                    for: request.sessionID,
                    client: client,
                    connection: connection
                )
                try await client.sendPromptAsync(
                    sessionID: remoteSessionID,
                    model: model,
                    variant: request.configuration.variantID?.rawValue,
                    parts: parts
                )
            } catch {
                await lineStream.cancel()
                throw error
            }
        } catch {
            await lineStream.cancel()
            throw error
        }

        let activeSessionID = remoteSessionID
        // Bounded: a burst of backend events suspends the reader instead of
        // piling up while the session applies them one by one.
        let channel = BoundedChannel<ProviderEvent>(capacity: 128)
        let permissionHandler = self.permissionHandler
        let forwardingTask = Task {
            var normalizer = OpenCodeStreamNormalizer(
                sessionID: activeSessionID,
                onPermissionRequest: { request in
                    Task {
                        let reply: OpenCodePermissionReply
                        if let permissionHandler {
                            reply = await permissionHandler(request)
                        } else {
                            // Fail closed. A missing decision surface is not consent,
                            // and `.always` is not "just this once": OpenCode keeps
                            // it for the rest of the server session. A runtime
                            // constructed without a handler is a wiring mistake, and
                            // it must not read as blanket approval.
                            reply = .reject
                        }
                        do {
                            try await client.replyPermission(
                                requestID: request.id,
                                reply: reply.rawValue
                            )
                        } catch {
                            AppLog.openCode.error(
                                "Could not deliver the permission reply for \(request.toolName, privacy: .public)"
                            )
                        }
                    }
                }
            )
            do {
                streamLoop: for try await line in lineStream.lines {
                    try Task.checkCancellation()
                    for event in try normalizer.consume(line: line) {
                        try await channel.send(event)
                        if event == .completed {
                            break streamLoop
                        }
                    }
                }
                await lineStream.cancel()
                await channel.finish()
            } catch is CancellationError {
                await channel.finish(throwing: CancellationError())
            } catch let error as ProviderRuntimeError {
                await lineStream.cancel()
                await channel.finish(throwing: error)
            } catch {
                await lineStream.cancel()
                await channel.finish(throwing: ProviderRuntimeError.transport)
            }
        }

        return ProviderStream(
            events: channel.makeStream(),
            cancellation: {
                forwardingTask.cancel()
                await self.cancelPendingPermissions?(activeSessionID)
                try? await client.abort(sessionID: activeSessionID)
                await lineStream.cancel()
                await channel.finish(throwing: CancellationError())
            }
        )
    }

    /// Silinen sohbetin uzak oturumunu kapatır.
    ///
    /// Eşleme yalnızca sunucu yeniden başladığında temizlenirdi; sunucudaki
    /// oturum ise hiç silinmiyordu. Sunucu ulaşılamıyorsa yerel eşleme yine de
    /// düşürülür: ölü bir kimliği saklamanın değeri yok.
    func releaseSession(_ sessionID: UUID) async {
        guard let remoteSessionID = remoteSessionIDs.removeValue(forKey: sessionID) else {
            return
        }

        guard let connection = await serverManager.currentConnection() else {
            return
        }

        do {
            try await clientFactory(connection).deleteSession(sessionID: remoteSessionID)
        } catch {
            AppLog.openCode.error(
                "Could not delete the remote session for a removed conversation: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func remoteSessionID(
        for appSessionID: UUID,
        client: any OpenCodeClientProtocol,
        connection: OpenCodeServerConnection
    ) async throws -> String {
        if sessionConnection != connection {
            remoteSessionIDs.removeAll()
            sessionConnection = connection
        }

        if let existing = remoteSessionIDs[appSessionID] {
            return existing
        }

        let created = try await client.createSession()
        remoteSessionIDs[appSessionID] = created
        return created
    }
}
