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
        guard
            let model = OpenCodeModelReference(
                flattenedID: request.configuration.modelID
            )
        else {
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
                    maximumCharacters: preambleBudget,
                    contextSummary: request.contextSummary
                )
                : nil
        )
        // Plan, Review, Exam ve Ask salt-okunur backend ajanıyla çalışır: dördü de dosya
        // değiştirmeyen işlerdir (plan önerir, review denetler, exam çözer, ask yanıtlar).
        // Özellikle Exam, pano/ekran görüntüsü gibi güvenilmez girdileri otomatik
        // kuyruğa aldığı için `build` yetkisiyle koşması prompt-injection yüzeyidir.
        // Review ve Ask de aynı sınırda koşar: kuyruğa bu kipler seçiliyken giren
        // bir mesaj build yetkisiyle çalışırsa kullanıcının seçimi sessizce delinir.
        let agentName =
            (request.mode == .plan || request.mode == .exam || request.mode == .review || request.mode == .ask)
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
            // that kept the same loopback address). Delete the orphan before
            // forgetting it, then recreate once and retry on the subscription
            // that is already open.
            AppLog.openCode.error(
                "OpenCode rejected the remote session; recreating it once"
            )
            let orphanedSessionID = remoteSessionIDs[request.sessionID]
            remoteSessionIDs[request.sessionID] = nil
            if let orphanedSessionID {
                do {
                    try await client.deleteSession(sessionID: orphanedSessionID)
                } catch {
                    AppLog.openCode.error(
                        "Could not delete the remote session for a removed conversation: \(String(describing: error), privacy: .public)"
                    )
                }
            }
            do {
                // Yeniden denemeden önce bağlantıyı tazele: sunucu yeniden
                // başladıysa eski soket ölüdür.
                let freshConnection = await serverManager.currentConnection() ?? connection
                let freshClient = clientFactory(freshConnection)
                resolution = try await self.remoteSessionID(
                    for: request.sessionID,
                    client: freshClient,
                    connection: freshConnection
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
                        maximumCharacters: preambleBudget,
                        contextSummary: request.contextSummary
                    )
                )
                try await freshClient.sendPromptAsync(
                    sessionID: resolution.id,
                    model: model,
                    variant: request.configuration.variantID?.rawValue,
                    parts: parts,
                    agent: agentName
                )
            } catch {
                await lineStream.cancel()
                // The retry never landed either: the same stale-mapping hazard
                // as the first failure, one level deeper. Drop the recreated
                // mapping (and the orphan) so the next turn starts fresh.
                let orphanedSessionID = remoteSessionIDs[request.sessionID]
                remoteSessionIDs[request.sessionID] = nil
                if let orphanedSessionID {
                    do {
                        try await client.deleteSession(sessionID: orphanedSessionID)
                    } catch {
                        AppLog.openCode.error(
                            "Could not delete the remote session for a removed conversation: \(String(describing: error), privacy: .public)"
                        )
                    }
                }
                throw error
            }
        } catch {
            await lineStream.cancel()
            // The prompt never landed, so this mapping points at a backend-empty
            // session: keeping it would make the next turn reuse it without the
            // history preamble. Drop it (and the orphan) so the next turn starts
            // fresh with the preamble.
            let orphanedSessionID = remoteSessionIDs[request.sessionID]
            remoteSessionIDs[request.sessionID] = nil
            if let orphanedSessionID {
                do {
                    try await client.deleteSession(sessionID: orphanedSessionID)
                } catch {
                    AppLog.openCode.error(
                        "Could not delete the remote session for a removed conversation: \(String(describing: error), privacy: .public)"
                    )
                }
            }
            throw error
        }

        let activeSessionID = resolution.id
        // Bounded: a burst of backend events suspends the reader instead of
        // piling up while the session applies them one by one.
        let channel = BoundedChannel<ProviderEvent>(capacity: 128)
        let permissionHandler = self.permissionHandler
        let appSessionID = request.sessionID
        let auditLog = self.auditLog
        let handledPermissionIDs = Mutex<HandledPermissionIDs>(HandledPermissionIDs())
        let reconciliationManager = self.serverManager
        let reconciliationClientFactory = self.clientFactory
        // İzin yanıtı tur-yerel `client` ile atılırdı; yeniden başlatma sonrası
        // ölü bağlantıya POST askıda kalır. Yanıt anında bağlantı tazelenir.
        let permissionServerManager = self.serverManager
        let permissionClientFactory = self.clientFactory

        let handlePermissionRequest: @Sendable (OpenCodePermissionRequest) -> Void = { request in
            let isNew = handledPermissionIDs.withLock { $0.insert(request.id) }
            guard isNew else { return }

            Task {
                let reply: OpenCodePermissionReply
                if let permissionHandler {
                    // Sahiplik her iki kaynaktan gelen istek için yeniden hesaplanır:
                    // olay akışı zaten işaretli gelir, yoklama ham gelir. İkisi de
                    // aynı kuraldan geçerse delege etiketi yalan söylemez.
                    var attributedRequest = request.marked(ownedBy: activeSessionID)
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
                    if let freshConnection = await permissionServerManager.currentConnection() {
                        try await permissionClientFactory(freshConnection).replyPermission(
                            requestID: request.id,
                            reply: reply.rawValue
                        )
                    } else {
                        try await client.replyPermission(
                            requestID: request.id,
                            reply: reply.rawValue
                        )
                    }
                } catch {
                    AppLog.openCode.error(
                        "Could not deliver the permission reply for \(request.toolName, privacy: .public)"
                    )
                }
            }
        }

        let reconciliationTask = Task {
            // Yoklama yalnızca bu turun oturumunu kapsar: `/permission` bütün
            // sohbetlerin bekleyenlerini döner, başka turun iznini bu tura
            // atfetmek çift yanıt ve yanlış-sohbet onayı demektir. Delege çocuk
            // oturumlar olay akışından (tamponlu) gelir; yoklama yedeği ana
            // oturum içindir.
            var consecutiveFailures = 0
            while !Task.isCancelled {
                let delayNanoseconds: UInt64 =
                    consecutiveFailures == 0
                    ? 1_500_000_000
                    : min(12_000_000_000, 1_500_000_000 * UInt64(1 << min(consecutiveFailures, 3)))
                try? await Task.sleep(nanoseconds: delayNanoseconds)
                guard !Task.isCancelled else { break }
                do {
                    // The client is resolved fresh every round: the turn-local
                    // one points at the server that was current when the turn
                    // started, and after a restart it would poll a dead socket
                    // forever. A changed (or vanished) connection ends the poll
                    // instead — the turn's stream already died with the server.
                    guard let liveConnection = await reconciliationManager.currentConnection(),
                        liveConnection == connection
                    else {
                        break
                    }
                    let pending = try await reconciliationClientFactory(liveConnection).pendingPermissions()
                    consecutiveFailures = 0
                    for req in pending where req.remoteSessionID == activeSessionID {
                        handlePermissionRequest(req)
                    }
                } catch is CancellationError {
                    break
                } catch {
                    consecutiveFailures += 1
                    AppLog.openCode.error(
                        "Permission reconciliation failed (\(consecutiveFailures, privacy: .public) in a row): \(error.localizedDescription, privacy: .public)"
                    )
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
                            case .activityStarted(let activity):
                                auditActivities[activity.id] = activity
                                await auditLog.recordExecution(
                                    ToolAuditLog.ExecutionRecord(
                                        timestamp: Date(), sessionID: activeSessionID,
                                        activityID: activity.id.rawValue, toolKind: activity.kind,
                                        // Titles and details originate in model/tool input and
                                        // may contain credentials. Keep only safe identifiers.
                                        title: nil, detail: nil,
                                        event: .started
                                    ))
                            case .activityFinished(let activityID, let outcome, _, _):
                                let activity = auditActivities.removeValue(forKey: activityID)
                                await auditLog.recordExecution(
                                    ToolAuditLog.ExecutionRecord(
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
                await lineStream.cancel()
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

    /// Yan soru (`/btw`): geçici uzak oturumda tek-atımlık, araçsız yanıt.
    ///
    /// Ana turun oturumuna dokunulmaz: geçici kimlik `remoteSessionIDs`
    /// haritasına yazılmaz, soru/cevap yerel transkripte girmez, turn durumu
    /// değişmez. Bağlam ana turla aynı inşadan geçer
    /// (`OpenCodeHistoryPreamble`), böylece önbellek öneki paylaşılır.
    /// Salt-okunur ajan + izin-otomatik-reddi sıfır-araç sözleşmesidir;
    /// metin-dışı olaylar (araç, soru) panele taşınmaz.
    func answerSideQuestion(_ query: SideQuestionQuery) async throws -> ProviderStream {
        guard query.configuration.providerID == id else {
            throw ProviderRuntimeError.unexpectedResponse
        }
        guard let connection = await serverManager.currentConnection() else {
            throw ProviderRuntimeError.unavailable
        }
        guard
            let model = OpenCodeModelReference(
                flattenedID: query.configuration.modelID
            )
        else {
            throw ProviderRuntimeError.unexpectedResponse
        }

        let client = clientFactory(connection)
        let ephemeralSessionID = try await client.createSession()
        let cleanedUp = Mutex(false)
        let cleanupOnce: @Sendable () async -> Void = {
            let shouldRun = cleanedUp.withLock { done -> Bool in
                guard !done else { return false }
                done = true
                return true
            }
            guard shouldRun else { return }
            try? await client.deleteSession(sessionID: ephemeralSessionID)
        }

        let questionMessage = ChatMessage(
            role: .user,
            text: Self.sideQuestionText(query.question)
        )
        let contextMessages =
            query.historyMessages
            + query.followups.flatMap { $0.messages() }
            + [questionMessage]
        let preambleBudget = max(
            20_000,
            OpenCodeHistoryPreamble.maximumCharacters - questionMessage.text.count
        )
        let parts = OpenCodePromptBuilder.parts(
            for: questionMessage,
            speedMode: query.speedMode,
            mode: query.mode,
            historyPreamble: OpenCodeHistoryPreamble.make(
                from: contextMessages,
                activityGroups: query.activityGroups,
                newMessageID: questionMessage.id,
                maximumCharacters: preambleBudget,
                contextSummary: query.contextSummary
            )
        )

        // Subscribe before submitting so fast backend events cannot be missed.
        // The ephemeral session already exists here, so a failed subscription
        // must still run the cleanup: otherwise every such throw leaks a
        // server-side session nobody will ever delete.
        let lineStream: OpenCodeLineStream
        do {
            lineStream = try await client.eventStream()
        } catch {
            await cleanupOnce()
            throw error
        }
        do {
            try await client.sendPromptAsync(
                sessionID: ephemeralSessionID,
                model: model,
                variant: query.configuration.variantID?.rawValue,
                parts: parts,
                agent: ManagedOpenCodeConfiguration.planAgentName
            )
        } catch {
            await lineStream.cancel()
            await cleanupOnce()
            throw error
        }

        let channel = BoundedChannel<ProviderEvent>(capacity: 128)
        let forwardingTask = Task {
            var normalizer = OpenCodeStreamNormalizer(
                sessionID: ephemeralSessionID,
                onPermissionRequest: { request in
                    // Sıfır-araç sözleşmesi: panele asla onay kartı çıkmaz,
                    // reddedilen araçsız model yanıtına devam eder.
                    Task {
                        try? await client.replyPermission(
                            requestID: request.id,
                            reply: OpenCodePermissionReply.reject.rawValue
                        )
                    }
                }
            )
            var questionRouter = OpenCodeQuestionEventRouter(sessionID: ephemeralSessionID)
            do {
                streamLoop: for try await line in lineStream.lines {
                    try Task.checkCancellation()
                    for question in questionRouter.consume(line: line) {
                        // Yan soru etkileşimsizdir: modelin ara sorusu
                        // reddedilir, akış cevaba devam eder.
                        try? await client.rejectQuestion(requestID: question.requestID)
                    }
                    for event in try normalizer.consume(line: line) {
                        switch event {
                        case .assistantTextDelta, .completed:
                            try await channel.send(event)
                        case .turnUsage,
                            .activityStarted, .activityUpdated, .activityFinished,
                            .questionAsked, .waiting,
                            .thinkingDelta:
                            // Yan soru geçicidir: jeton sayımı ana oturumun
                            // bağlamına yazılmaz, yoksayılır. Thinking de
                            // panele taşınmaz: yanıt tek-atımlık metindir.
                            break
                        }
                        if event == .completed {
                            break streamLoop
                        }
                    }
                }
                await cleanupOnce()
                await lineStream.cancel()
                await channel.finish()
            } catch is CancellationError {
                await cleanupOnce()
                await lineStream.cancel()
                await channel.finish(throwing: CancellationError())
            } catch let error as ProviderRuntimeError {
                await cleanupOnce()
                await lineStream.cancel()
                await channel.finish(throwing: error)
            } catch {
                await cleanupOnce()
                await lineStream.cancel()
                await channel.finish(throwing: ProviderRuntimeError.transport)
            }
        }

        return ProviderStream(
            events: channel.makeStream(),
            cancellation: {
                forwardingTask.cancel()
                try? await client.abort(sessionID: ephemeralSessionID)
                await cleanupOnce()
                await lineStream.cancel()
                await channel.finish(throwing: CancellationError())
            }
        )
    }

    /// Yan soru çerçevesi: ana görevi değiştirmez, kısa ve doğrudan yanıt
    /// ister. Salt-okunur ajan yine de dosya okuyabilir; izne takılan her
    /// araç reddedilir.
    nonisolated static func sideQuestionText(_ question: String) -> String {
        """
        [Side question — it does not change the main task. Answer directly \
        and concisely from context; any permission-gated tool will be rejected.]

        \(question)
        """
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

/// Turn-bounded permission dedup with an evict-oldest cap, same pattern as the
/// normalizer's bounded buffers: a permission storm must not grow the turn's
/// memory without bound.
private struct HandledPermissionIDs: Sendable {
    private static let maximumIDs = 128

    private var ids: Set<String> = []
    private var order: [String] = []

    mutating func insert(_ id: String) -> Bool {
        if ids.contains(id) {
            return false
        }
        ids.insert(id)
        order.append(id)
        if order.count > Self.maximumIDs {
            ids.remove(order.removeFirst())
        }
        return true
    }
}
