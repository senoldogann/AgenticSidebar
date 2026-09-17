import Foundation
import Synchronization

actor OpenCodeProviderRuntime: ProviderRuntime {
    nonisolated let id = ProviderID("opencode")

    /// Kullanıcı kararını bekler; işleyici yoksa istek güvenli biçimde reddedilir.
    typealias PermissionHandler = @Sendable (OpenCodePermissionRequest) async -> OpenCodePermissionReply
    /// Tur iptalinde askıda kalan izinleri temizler.
    ///
    /// Both identities are handed over because a turn's requests are not all
    /// tagged with its own remote session: a subagent's request carries the child
    /// session's id instead, and only the conversation it was attributed to can
    /// recognise it. A cancellation that knew merely the parent's remote session
    /// left a subagent's prompt on screen — and its waiter unreleased — until the
    /// decision timeout expired on its own.
    typealias PermissionCancellationHandler = @Sendable (String, UUID) async -> Void

    private let serverManager: any OpenCodeServerManaging
    private let clientFactory: @Sendable (OpenCodeServerConnection) -> any OpenCodeClientProtocol
    private let permissionHandler: PermissionHandler?
    private let cancelPendingPermissions: PermissionCancellationHandler?
    private let auditLog: ToolAuditLog?
    private var remoteSessionIDs: [UUID: String] = [:]

    /// The server that owns `remoteSessionIDs`. Remote sessions live inside a
    /// specific server process, so a restarted backend (new port or password)
    /// must invalidate the whole mapping.
    private var sessionConnection: OpenCodeServerConnection?

    init(
        serverManager: any OpenCodeServerManaging,
        clientFactory: @escaping @Sendable (OpenCodeServerConnection) -> any OpenCodeClientProtocol,
        permissionHandler: PermissionHandler?,
        cancelPendingPermissions: PermissionCancellationHandler?,
        auditLog: ToolAuditLog? = nil
    ) {
        self.serverManager = serverManager
        self.clientFactory = clientFactory
        self.permissionHandler = permissionHandler
        self.cancelPendingPermissions = cancelPendingPermissions
        self.auditLog = auditLog
    }

    static func live(
        serverManager: any OpenCodeServerManaging,
        transport: any OpenCodeTransport,
        permissionHandler: PermissionHandler?,
        cancelPendingPermissions: PermissionCancellationHandler?,
        auditLog: ToolAuditLog? = nil
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
            cancelPendingPermissions: cancelPendingPermissions,
            auditLog: auditLog
        )
    }

    func capabilities() async throws -> ProviderCapabilities {
        guard let connection = await serverManager.currentConnection() else {
            throw ProviderRuntimeError.unavailable
        }

        return try await clientFactory(connection).capabilities()
    }

    func sessionTodos(sessionID: UUID) async -> [AgentTodo]? {
        guard
            let remoteSessionID = remoteSessionIDs[sessionID],
            let connection = await serverManager.currentConnection()
        else {
            return nil
        }

        // A missing list is not an error worth surfacing: an older backend has no
        // such endpoint, and the checklist is an addition to the transcript, not
        // part of the turn. The failure is still logged so an empty checklist
        // stays diagnosable.
        do {
            return try await clientFactory(connection).sessionTodos(sessionID: remoteSessionID)
        } catch {
            AppLog.openCode.error(
                "Session todo list could not be read; showing no checklist: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
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
        var resolution = try await remoteSessionID(
            for: request.sessionID,
            client: client,
            connection: connection
        )
        // A backend session that starts now has none of the shared past, so the
        // first turn carries the transcript as quoted history. Without it the
        // agent answers a restored conversation with a fresh memory.
        let preambleBudget = max(
            20_000,
            OpenCodeHistoryPreamble.maximumCharacters - lastUserMessage.text.count
        )
        var parts = OpenCodePromptBuilder.parts(
            for: lastUserMessage,
            speedMode: request.speedMode,
            mode: request.mode,
            historyPreamble: resolution.isFresh
                ? OpenCodeHistoryPreamble.make(
                    from: request.messages,
                    activityGroups: request.activityGroups,
                    newMessageID: lastUserMessage.id,
                    maximumCharacters: preambleBudget
                )
                : nil
        )
        let agentName = request.mode == .plan
            ? ManagedOpenCodeConfiguration.planAgentName : "build"

        // Subscribe before submitting so fast backend events cannot be missed.
        let lineStream = try await client.eventStream()
        do {
            try await client.sendPromptAsync(
                sessionID: resolution.id,
                model: model,
                variant: request.configuration.variantID?.rawValue,
                parts: parts,
                agent: agentName
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
                resolution = try await self.remoteSessionID(
                    for: request.sessionID,
                    client: client,
                    connection: connection
                )
                // The recreated session is fresh by construction: the history
                // that the rejected session held has to ride along again.
                parts = OpenCodePromptBuilder.parts(
                    for: lastUserMessage,
                    speedMode: request.speedMode,
                    mode: request.mode,
                    historyPreamble: OpenCodeHistoryPreamble.make(
                        from: request.messages,
                        activityGroups: request.activityGroups,
                        newMessageID: lastUserMessage.id,
                        maximumCharacters: preambleBudget
                    )
                )
                try await client.sendPromptAsync(
                    sessionID: resolution.id,
                    model: model,
                    variant: request.configuration.variantID?.rawValue,
                    parts: parts,
                    agent: agentName
                )
            } catch {
                await lineStream.cancel()
                throw error
            }
        } catch {
            await lineStream.cancel()
            throw error
        }

        let activeSessionID = resolution.id
        // Bounded: a burst of backend events suspends the reader instead of
        // piling up while the session applies them one by one.
        let channel = BoundedChannel<ProviderEvent>(capacity: 128)
        let permissionHandler = self.permissionHandler
        let appSessionID = request.sessionID
        let auditLog = self.auditLog
        let handledPermissionIDs = Mutex<Set<String>>(Set())

        let handlePermissionRequest: @Sendable (OpenCodePermissionRequest) -> Void = { request in
            let isNew = handledPermissionIDs.withLock { ids -> Bool in
                if ids.contains(request.id) {
                    return false
                }
                ids.insert(request.id)
                return true
            }
            guard isNew else { return }

            Task {
                let reply: OpenCodePermissionReply
                if let permissionHandler {
                    var attributedRequest = request
                    attributedRequest.appSessionID = appSessionID
                    reply = await permissionHandler(attributedRequest)
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

        let reconciliationTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { break }
                guard let pending = try? await client.pendingPermissions() else { continue }
                for req in pending {
                    handlePermissionRequest(req)
                }
            }
        }

        let forwardingTask = Task {
            var auditActivities: [ProviderActivityID: ProviderActivityDescriptor] = [:]
            var normalizer = OpenCodeStreamNormalizer(
                sessionID: activeSessionID,
                onPermissionRequest: { request in
                    handlePermissionRequest(request)
                }
            )
            var questionRouter = OpenCodeQuestionEventRouter(sessionID: activeSessionID)
            do {
                streamLoop: for try await line in lineStream.lines {
                    try Task.checkCancellation()
                    for question in questionRouter.consume(line: line) {
                        try await channel.send(.questionAsked(question))
                    }
                    for event in try normalizer.consume(line: line) {
                        // The provider emits execution even for tools pre-allowed by
                        // configuration. Permission decisions alone cannot audit them.
                        if let auditLog {
                            switch event {
                            case let .activityStarted(activity):
                                auditActivities[activity.id] = activity
                                await auditLog.recordExecution(ToolAuditLog.ExecutionRecord(
                                    timestamp: Date(), sessionID: activeSessionID,
                                    activityID: activity.id.rawValue, toolKind: activity.kind,
                                    // Titles and details originate in model/tool input and
                                    // may contain credentials. Keep only safe identifiers.
                                    title: nil, detail: nil,
                                    event: .started
                                ))
                            case let .activityFinished(activityID, outcome, _, _):
                                let activity = auditActivities.removeValue(forKey: activityID)
                                await auditLog.recordExecution(ToolAuditLog.ExecutionRecord(
                                    timestamp: Date(), sessionID: activeSessionID,
                                    activityID: activityID.rawValue,
                                    toolKind: activity?.kind ?? .tool,
                                    title: nil, detail: nil,
                                    event: outcome == .completed ? .completed : .failed
                                ))
                            default:
                                break
                            }
                        }
                        try await channel.send(event)
                        if event == .completed {
                            break streamLoop
                        }
                    }
                }
                reconciliationTask.cancel()
                await lineStream.cancel()
                await channel.finish()
            } catch is CancellationError {
                reconciliationTask.cancel()
                await channel.finish(throwing: CancellationError())
            } catch let error as ProviderRuntimeError {
                reconciliationTask.cancel()
                await lineStream.cancel()
                await channel.finish(throwing: error)
            } catch {
                reconciliationTask.cancel()
                await lineStream.cancel()
                await channel.finish(throwing: ProviderRuntimeError.transport)
            }
        }

        return ProviderStream(
            events: channel.makeStream(),
            cancellation: {
                forwardingTask.cancel()
                reconciliationTask.cancel()
                await self.cancelPendingPermissions?(activeSessionID, appSessionID)
                try? await client.abort(sessionID: activeSessionID)
                await lineStream.cancel()
                await channel.finish(throwing: CancellationError())
            },
            questionReply: { requestID, answers in
                try await client.replyQuestion(requestID: requestID, answers: answers)
            },
            questionRejection: { requestID in
                try await client.rejectQuestion(requestID: requestID)
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
    ) async throws -> (id: String, isFresh: Bool) {
        if sessionConnection != connection {
            remoteSessionIDs.removeAll()
            sessionConnection = connection
        }

        if let existing = remoteSessionIDs[appSessionID] {
            return (existing, false)
        }

        let created = try await client.createSession()
        remoteSessionIDs[appSessionID] = created
        return (created, true)
    }
}
