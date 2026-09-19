import Foundation
import Synchronization

actor OpenCodeCodingAgentAdapter: CodingAgentRuntime {
    nonisolated let runtimeID: String = "opencode"

    typealias PermissionHandler = @Sendable (OpenCodePermissionRequest) async -> OpenCodePermissionReply
    typealias PermissionCancellationHandler = @Sendable (String, UUID) async -> Void

    private let serverManager: any OpenCodeServerManaging
    private let clientFactory: @Sendable (OpenCodeServerConnection) -> any OpenCodeClientProtocol
    private let permissionHandler: PermissionHandler?
    private let cancelPendingPermissions: PermissionCancellationHandler?
    private let auditLog: ToolAuditLog?

    private var attemptRemoteSessions: [UUID: String] = [:]
    private var attemptConnections: [UUID: OpenCodeServerConnection] = [:]
    private var cancelledAttemptIDs: Set<UUID> = []

    init(
        serverManager: any OpenCodeServerManaging,
        clientFactory: @escaping @Sendable (OpenCodeServerConnection) -> any OpenCodeClientProtocol,
        permissionHandler: PermissionHandler? = nil,
        cancelPendingPermissions: PermissionCancellationHandler? = nil,
        auditLog: ToolAuditLog? = nil
    ) {
        self.serverManager = serverManager
        self.clientFactory = clientFactory
        self.permissionHandler = permissionHandler
        self.cancelPendingPermissions = cancelPendingPermissions
        self.auditLog = auditLog
    }

    func capabilities(configuration: SessionConfiguration) async -> CodingAgentCapabilities {
        guard configuration.providerID.rawValue == runtimeID else {
            return []
        }
        guard let connection = await serverManager.currentConnection() else {
            return []
        }

        do {
            let client = clientFactory(connection)
            let caps = try await client.capabilities()
            guard caps.models.contains(where: { $0.id == configuration.modelID }) else {
                return []
            }

            var capabilities: CodingAgentCapabilities = [
                .textAnalysis,
                .workspaceRead,
                .tools,
                .interactiveApproval,
                .sessionResume,
                .cancellable,
                .structuredEvents,
                .usageReporting,
            ]

            let serverDir = await serverManager.workingDirectory()
            if let serverDir,
                !serverDir.path.isEmpty,
                serverDir != ManagedAppDirectories.openCodeWorkingDirectory(),
                !serverDir.path.contains("/managed/")
            {
                capabilities.insert(.workspaceWrite)
            }

            return capabilities
        } catch {
            return []
        }
    }

    func remoteSessionID(for attemptID: UUID) -> String? {
        attemptRemoteSessions[attemptID]
    }

    func start(request: CodingAgentExecutionRequest) async throws -> CodingAgentRun {
        guard request.configuration.providerID.rawValue == runtimeID else {
            throw CodingAgentAdapterError.invalidProvider
        }
        guard let connection = await serverManager.currentConnection() else {
            throw CodingAgentAdapterError.serverUnavailable
        }

        let serverDir = await serverManager.workingDirectory()
        let canonicalWorkspace = URL(fileURLWithPath: request.workspacePath).resolvingSymlinksInPath().standardized.path
        let canonicalServer = serverDir?.resolvingSymlinksInPath().standardized.path

        guard canonicalServer == canonicalWorkspace else {
            throw CodingAgentAdapterError.workspaceNotContained(
                expected: canonicalWorkspace,
                actual: canonicalServer
            )
        }

        guard let model = OpenCodeModelReference(flattenedID: request.configuration.modelID) else {
            throw CodingAgentAdapterError.invalidModel
        }

        let client = clientFactory(connection)
        let remoteSessionID = try await client.createSession()
        attemptRemoteSessions[request.attemptID] = remoteSessionID
        attemptConnections[request.attemptID] = connection
        cancelledAttemptIDs.remove(request.attemptID)

        var promptText = "Objective:\n\(request.objective)\n"
        if !request.acceptanceCriteria.isEmpty {
            promptText += "\nAcceptance Criteria:\n"
            for criterion in request.acceptanceCriteria {
                promptText += "- \(criterion.description)\n"
            }
        }
        if !request.relevantFiles.isEmpty {
            promptText += "\nRelevant Files:\n"
            for file in request.relevantFiles {
                promptText += "- \(file)\n"
            }
        }

        let parts: [OpenCodePromptPart] = [.text(promptText)]
        let agentName =
            (request.stage == .analysis || request.stage == .plan || request.stage == .codeReview)
            ? ManagedOpenCodeConfiguration.planAgentName : "build"

        let lineStream = try await client.eventStream()
        do {
            try await client.sendPromptAsync(
                sessionID: remoteSessionID,
                model: model,
                variant: request.configuration.variantID?.rawValue,
                parts: parts,
                agent: agentName
            )
        } catch {
            await lineStream.cancel()
            try? await client.deleteSession(sessionID: remoteSessionID)
            attemptRemoteSessions[request.attemptID] = nil
            attemptConnections[request.attemptID] = nil
            throw error
        }

        let channel = BoundedChannel<CodingAgentEvent>(capacity: 128)
        let permissionHandler = self.permissionHandler
        let queuedPermissions = Mutex<[OpenCodePermissionRequest]>([])

        let onPermissionRequest: @Sendable (OpenCodePermissionRequest) -> Void = { permReq in
            var attributed = permReq.marked(ownedBy: remoteSessionID)
            attributed.appSessionID = request.attemptID
            queuedPermissions.withLock { $0.append(attributed) }
        }

        let forwardingTask = Task {
            var normalizer = OpenCodeStreamNormalizer(
                sessionID: remoteSessionID,
                onPermissionRequest: onPermissionRequest
            )
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
                streamLoop: for try await line in lineStream.lines {
                    try Task.checkCancellation()
                    let events = try normalizer.consume(line: line)

                    let drainedPermissions = queuedPermissions.withLock { queue -> [OpenCodePermissionRequest] in
                        let items = queue
                        queue.removeAll()
                        return items
                    }

                    for permReq in drainedPermissions {
                        var params: [String: String] = [:]
                        if !permReq.patterns.isEmpty {
                            params["patterns"] = permReq.patterns.joined(separator: ", ")
                        }
                        if let detail = permReq.detail {
                            params["detail"] = detail
                        }

                        try await channel.send(
                            CodingAgentEvent(
                                taskID: request.taskID,
                                attemptID: request.attemptID,
                                generation: request.generation,
                                kind: .approvalRequested(
                                    id: permReq.id,
                                    tool: permReq.toolName,
                                    params: params
                                )
                            )
                        )

                        Task { [weak self] in
                            let reply: OpenCodePermissionReply
                            if let permissionHandler {
                                reply = await permissionHandler(permReq)
                            } else {
                                reply = .reject
                            }
                            guard let self,
                                await self.permissionReplyIsCurrent(
                                    attemptID: request.attemptID,
                                    remoteSessionID: remoteSessionID
                                )
                            else {
                                return
                            }
                            try? await client.replyPermission(
                                requestID: permReq.id,
                                reply: reply.rawValue
                            )
                        }
                    }

                    for event in events {
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
                        case .activityStarted(let activity):
                            try await channel.send(
                                CodingAgentEvent(
                                    taskID: request.taskID,
                                    attemptID: request.attemptID,
                                    generation: request.generation,
                                    kind: .activityStarted(id: activity.id.rawValue, title: activity.title ?? "")
                                )
                            )
                        case .activityUpdated(let activity):
                            try await channel.send(
                                CodingAgentEvent(
                                    taskID: request.taskID,
                                    attemptID: request.attemptID,
                                    generation: request.generation,
                                    kind: .activityUpdated(id: activity.id.rawValue, detail: activity.detail ?? "")
                                )
                            )
                        case .activityFinished(let activityID, _, _, _):
                            try await channel.send(
                                CodingAgentEvent(
                                    taskID: request.taskID,
                                    attemptID: request.attemptID,
                                    generation: request.generation,
                                    kind: .activityFinished(id: activityID.rawValue)
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

                await lineStream.cancel()
                await channel.finish()
            } catch is CancellationError {
                try? await channel.send(
                    CodingAgentEvent(
                        taskID: request.taskID,
                        attemptID: request.attemptID,
                        generation: request.generation,
                        kind: .interrupted("Cancelled")
                    )
                )
                await lineStream.cancel()
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
                await lineStream.cancel()
                await channel.finish()
            }
        }

        let stream = AsyncStream<CodingAgentEvent>(unfolding: {
            try? await channel.receive()
        })

        let run = CodingAgentRun(events: stream) { [weak self] in
            forwardingTask.cancel()
            await lineStream.cancel()
            if let self {
                await self.cancelAttempt(attemptID: request.attemptID)
            }
        }

        return run
    }

    private func permissionReplyIsCurrent(attemptID: UUID, remoteSessionID: String) -> Bool {
        !cancelledAttemptIDs.contains(attemptID)
            && attemptRemoteSessions[attemptID] == remoteSessionID
    }

    func cancelAttempt(attemptID: UUID) async {
        cancelledAttemptIDs.insert(attemptID)
        guard let remoteID = attemptRemoteSessions[attemptID] else { return }
        if let connection = attemptConnections[attemptID] {
            try? await clientFactory(connection).abort(sessionID: remoteID)
        }
        await cancelPendingPermissions?(remoteID, attemptID)
    }

    func release(attemptID: UUID) async {
        cancelledAttemptIDs.insert(attemptID)
        guard let remoteID = attemptRemoteSessions.removeValue(forKey: attemptID) else { return }
        let connection = attemptConnections.removeValue(forKey: attemptID)
        await cancelPendingPermissions?(remoteID, attemptID)
        if let connection {
            try? await clientFactory(connection).deleteSession(sessionID: remoteID)
        }
    }
}
