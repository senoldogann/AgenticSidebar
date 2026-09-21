import Foundation
import Synchronization

/// Adaptörün sahipli çalışma alanına erişim biçimi.
///
/// Yazma yeteneği yalnızca sunucu kökü çalışma alanı olduğunda doğrudur. Sohbet
/// sunucusunun kökü yönetilen dizindir; görev gönderimi ise her koşu için
/// çalışma alanına köklenmiş ayrı bir sunucu açar. İkinci durumda yetenek, koşu
/// anındaki sunucu kökü sorulmadan da dürüstçe söylenebilir; kapsama denetimi
/// yine `start` içinde kapalı kalır.
enum OpenCodeWorkspaceAccess: Sendable, Equatable {
    /// Gönderim hattı koşu başına çalışma alanına köklenmiş sunucu açar.
    case rootedPerRun
    /// Yalnızca enjekte edilen sunucu kullanılabilir; yazma, o sunucu
    /// yönetilen dizinin dışında bir köke sahipse ilan edilir.
    case injectedServerOnly
}

actor OpenCodeCodingAgentAdapter: CodingAgentRuntime {
    nonisolated let runtimeID: String = "opencode"

    typealias PermissionHandler = @Sendable (OpenCodePermissionRequest) async -> OpenCodePermissionReply
    typealias PermissionCancellationHandler = @Sendable (String, UUID) async -> Void
    /// Çalıştırmaya özel izin yanıtı üreticisi; `nil` ise adaptörün sohbet
    /// izin merkezi kullanılır.
    typealias PermissionReplyProvider = @Sendable (OpenCodePermissionRequest) async -> OpenCodePermissionReply

    private let serverManager: any OpenCodeServerManaging
    private let clientFactory: @Sendable (OpenCodeServerConnection) -> any OpenCodeClientProtocol
    private let permissionHandler: PermissionHandler?
    private let cancelPendingPermissions: PermissionCancellationHandler?
    private let auditLog: ToolAuditLog?
    private let workspaceAccess: OpenCodeWorkspaceAccess

    private var attemptRemoteSessions: [UUID: String] = [:]
    private var attemptConnections: [UUID: OpenCodeServerConnection] = [:]
    private var cancelledAttemptIDs: Set<UUID> = []

    /// İptal damgası taşıyan kimliklerin üst sınırı. Eskiden bu küme süreç
    /// ömrü boyunca sınırsız büyüyordu (iptal edilen her attempt kalıcıydı).
    /// Sınır aşılınca yalnız uzak eşlemesi kalmamış — yani terminal —
    /// kimlikler atılır: eşlemesi duran bir kimliği atmak, geç gelen bir izin
    /// yanıtını yeniden geçerli kılardı. Hepsi canlıysa sınır esner: yanlış
    /// bir onaya kapı aralamak yerine bellek seçilir (ret yönü güvenlidir).
    private static let maximumCancelledAttemptIDs = 1_024

    /// Testlerin terminal temizliğinin izleme durumunu sınırladığını
    /// kanıtlaması için; üretim akışı kullanmaz.
    var trackedAttemptCount: Int {
        attemptRemoteSessions.count + attemptConnections.count + cancelledAttemptIDs.count
    }

    init(
        serverManager: any OpenCodeServerManaging,
        clientFactory: @escaping @Sendable (OpenCodeServerConnection) -> any OpenCodeClientProtocol,
        permissionHandler: PermissionHandler? = nil,
        cancelPendingPermissions: PermissionCancellationHandler? = nil,
        auditLog: ToolAuditLog? = nil,
        workspaceAccess: OpenCodeWorkspaceAccess = .injectedServerOnly
    ) {
        self.serverManager = serverManager
        self.clientFactory = clientFactory
        self.permissionHandler = permissionHandler
        self.cancelPendingPermissions = cancelPendingPermissions
        self.auditLog = auditLog
        self.workspaceAccess = workspaceAccess
    }

    /// Bu adaptörün aynı politika kablolamasıyla, belirli bir sunucuya bağlı
    /// kopyası. Canlı gönderim her koşu için çalışma alanına köklenmiş sunucuyu
    /// bu yolla adaptöre verir.
    func bound(to serverManager: any OpenCodeServerManaging) -> OpenCodeCodingAgentAdapter {
        OpenCodeCodingAgentAdapter(
            serverManager: serverManager,
            clientFactory: clientFactory,
            permissionHandler: permissionHandler,
            cancelPendingPermissions: cancelPendingPermissions,
            auditLog: auditLog,
            workspaceAccess: workspaceAccess
        )
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

            if await advertisesWorkspaceWrite() {
                capabilities.insert(.workspaceWrite)
            }

            return capabilities
        } catch {
            return []
        }
    }

    /// Yazma yeteneği yalnızca sunucunun sahipli çalışma alanına köklenmiş
    /// olmasıyla doğrudur. Koşu başına kökleme kablolandıysa bu, her koşu için
    /// geçerlidir ve `start` kapsama denetimiyle kapalı kalır.
    private func advertisesWorkspaceWrite() async -> Bool {
        if workspaceAccess == .rootedPerRun {
            return true
        }

        guard let serverDir = await serverManager.workingDirectory(), !serverDir.path.isEmpty else {
            return false
        }
        let canonicalRoot = serverDir.resolvingSymlinksInPath().standardized.path
        let canonicalManaged =
            ManagedAppDirectories.openCodeWorkingDirectory()
            .resolvingSymlinksInPath().standardized.path
        return canonicalRoot != canonicalManaged && !canonicalRoot.contains("/managed/")
    }

    func remoteSessionID(for attemptID: UUID) -> String? {
        attemptRemoteSessions[attemptID]
    }

    func start(request: CodingAgentExecutionRequest) async throws -> CodingAgentRun {
        try await start(request: request, permissionReplyProvider: nil)
    }

    /// Gözetimsiz koşu kısıt notu: deny-unless-safe çözücünün reddedeceği
    /// delegasyonu modele önceden söyler, boşa reddedilen `task` çağrılarını
    /// azaltır. Yalnız koşuya özel izin sağlayıcılı başlatmada eklenir; sohbet
    /// akışının istemi değişmez.
    private static var unattendedRunConstraints: String {
        "\nUnattended run constraints:\n"
            + "- Do the work yourself in this workspace with the edit/write tools; do not delegate via the task tool.\n"
            + "- Subagent delegation is denied unattended; only read-only research delegation to `\(ManagedOpenCodeConfiguration.researchAgentName)` is allowed and it cannot edit files.\n"
            + "- File edits outside this workspace are denied; stay inside and do not ask.\n"
    }

    /// Çalıştırmaya özel izin yanıtı sağlayıcısıyla başlatır.
    ///
    /// Sağlayıcı verildiğinde her izin isteği ondan yanıtlanır ve sohbet izin
    /// merkezi bu koşu için kullanılmaz; böylece görev panosunun deny-unless-safe
    /// çözücüsü adaptörün kendi yanıtına da uygulanır. Sağlayıcı yoksa mevcut
    /// sohbet davranışı aynen sürer.
    func start(
        request: CodingAgentExecutionRequest,
        permissionReplyProvider: PermissionReplyProvider?
    ) async throws -> CodingAgentRun {
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
        if permissionReplyProvider != nil {
            promptText += Self.unattendedRunConstraints
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

        let forwardingTask = Task { [self] in
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
                        // Delegasyon hedefi olay üzerinden de yapısal taşınır:
                        // zamanlayıcının olay-döngüsü kararı aynı kuralla verir.
                        if permReq.toolName.lowercased() == "task", let target = permReq.delegationTarget {
                            params["delegationTarget"] = target
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
                            if let permissionReplyProvider {
                                reply = await permissionReplyProvider(permReq)
                            } else if let permissionHandler {
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
        // Bilinmeyen attempt: ne eşleme var ne damga. Terminal temizlikten
        // sonra gelen geç bir iptal (örn. bitmiş bir koşunun kapatılması)
        // kümeye yeni damga yazmasın diye erken dönülür.
        guard attemptRemoteSessions[attemptID] != nil || cancelledAttemptIDs.contains(attemptID) else {
            return
        }
        cancelledAttemptIDs.insert(attemptID)
        pruneDeadCancelledAttemptIDs()
        guard let remoteID = attemptRemoteSessions[attemptID] else { return }
        if let connection = attemptConnections[attemptID] {
            try? await clientFactory(connection).abort(sessionID: remoteID)
        }
        await cancelPendingPermissions?(remoteID, attemptID)
    }

    func release(attemptID: UUID) async {
        // Terminal durum tek noktadan unutulur: uzak oturum silinirken iptal
        // damgası da kalkar. Eskiden burası damga *ekliyordu*, o yüzden
        // bırakılan her attempt kümede sonsuza dek kalıyordu.
        guard let remoteID = attemptRemoteSessions.removeValue(forKey: attemptID) else {
            attemptConnections.removeValue(forKey: attemptID)
            cancelledAttemptIDs.remove(attemptID)
            return
        }
        let connection = attemptConnections.removeValue(forKey: attemptID)
        cancelledAttemptIDs.remove(attemptID)
        await cancelPendingPermissions?(remoteID, attemptID)
        if let connection {
            try? await clientFactory(connection).deleteSession(sessionID: remoteID)
        }
    }

    /// Uzak eşlemesi kalmamış damgaları atar; eşlemesi duran damgaya
    /// dokunulmaz (`permissionReplyIsCurrent` ona dayanır).
    private func pruneDeadCancelledAttemptIDs() {
        guard cancelledAttemptIDs.count > Self.maximumCancelledAttemptIDs else {
            return
        }
        let overflow = cancelledAttemptIDs.count - Self.maximumCancelledAttemptIDs
        let dead = cancelledAttemptIDs.filter { attemptRemoteSessions[$0] == nil }.prefix(overflow)
        for id in dead {
            cancelledAttemptIDs.remove(id)
        }
    }
}
