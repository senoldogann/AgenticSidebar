import Foundation
import Observation

/// Tool onaylarını askıya alıp UI'dan gelen kararla çözen merkez.
///
/// Önceki davranış `permission.asked` olayına koşulsuz `"always"` cevabı
/// veriyordu; bilgisayar kontrolü veren bir modelde bu kabul edilemez. Şimdi her
/// istek ya kullanıcıya gösterilir, ya da karar anında geçerli izin seviyesi
/// (``ToolApprovalPolicy``) o an için karar verir.
///
/// Seviye tur başında anlık görüntülenir: tur ortasında besteciden seviye
/// değişirse koşan tur başladığı kuralla devam eder, yeni kural sonraki turda
/// geçerli olur. Delege alt-ajan istekleri sahibin oturum kimliğini taşıdığı
/// için aynı turun kuralına tabidir.
///
/// Otomatik cevaplar `.once`'tır, `.always` değil: OpenCode `always` cevabını
/// sunucu oturumu boyunca hatırlar, dolayısıyla otomatik onayda onu kullanmak
/// kullanıcı daha sıkı bir seviyeye döndüğünde sessizce onay vermeye devam
/// ederdi. Kullanıcının "Always allow" seçimi yalnızca uygulama içinde
/// saklanır; OpenCode'a bu istek için `.once` gönderilir. Böylece "Revoke all"
/// sunucuda geri alınamayacak bir izin bırakmaz.
@MainActor
@Observable
final class PermissionApprovalCenter {
    struct PendingRequest: Identifiable, Equatable, Sendable {
        let id: String
        let remoteSessionID: String
        let appSessionID: UUID?
        /// Raised by a session this turn delegated to — a subagent.
        let isDelegatedSession: Bool
        let toolName: String
        let title: String
        let detail: String?
        let patterns: [String]
        let alwaysPatterns: [String]
        let requestedAt: Date

        /// A glyph for the family of capability being asked about.
        var symbolName: String {
            let name = toolName.lowercased()

            if name.contains("computer") || name.contains("session_authority") {
                return "cursorarrow.motionlines"
            }
            // `task` is the subagent delegation tool: a branch, not a shell.
            if name == "task" {
                return "arrow.triangle.branch"
            }
            if name.contains("bash") || name.contains("shell") {
                return "terminal"
            }
            if name.contains("webfetch") || name.contains("websearch") {
                return "globe"
            }
            if name.contains("external_directory")
                || name.contains("edit")
                || name.contains("write")
                || name.contains("patch")
            {
                return "doc.text"
            }

            return "lock.shield"
        }
    }

    /// Kullanıcının "Always allow" dediği bir karar.
    ///
    /// OpenCode'a `.always` göndermek sunucuda geri alınamayan bir izin
    /// bırakır. Bu liste izinlerin tek uygulama kaynağıdır; backend her istekte
    /// yalnız `.once` alır, böylece liste temizlendiğinde izin gerçekten kalkar.
    ///
    /// Eşleşme **aynı oturum + aynı araç + aynı desenler** üzerinedir.
    /// `alwaysPatterns` (OpenCode'un "her zaman" için kapsayacağı kalıp)
    /// saklanır ama eşleşmede kullanılmaz: kullanıcı `ls` için izin verdiyse
    /// bu bir `rm -rf` izni değildir. Oturum kapsamı da aynı sebeptendir: A
    /// sohbetindeki izin B sohbetinde sessizce geçmemelidir.
    struct Grant: Identifiable, Equatable, Sendable {
        let toolName: String
        let patterns: [String]
        let alwaysPatterns: [String]
        /// İznin verildiği sohbet; `nil` sahipsiz (backend) istektir.
        let appSessionID: UUID?

        var id: String {
            (appSessionID?.uuidString ?? "-") + "|" + toolName + "|" + patterns.joined(separator: "\u{1}")
        }

        /// Görüntülenecek kısa hâli.
        var displayText: String {
            let shown = patterns.isEmpty ? alwaysPatterns : patterns
            return shown.isEmpty ? toolName : toolName + " · " + shown.joined(separator: ", ")
        }
    }

    /// Kullanıcı yanıtlamazsa isteğin reddedileceği süre.
    ///
    /// Bekleyen bir izin turu — ve arkasındaki kuyruğu — durdurur; kullanıcı
    /// pencereye bakmıyorsa oturum süresiz meşgul kalırdı.
    static let defaultDecisionTimeout = Duration.seconds(180)

    private(set) var pending: [PendingRequest] = []
    /// This session's "Always allow" decisions, newest last.
    private(set) var grants: [Grant] = []

    /// Otomatik cevap üretici: `nil` döndürürse istek kullanıcıya sorulur.
    /// Araç adı ve isteğin desenleri (komut ya da yol) verilir, çünkü seviye artık
    /// komut sınıflandırmasını kendisi yapıyor.
    @ObservationIgnored
    private let automaticReplyProvider: @MainActor (String, [String]) -> ProviderPermissionReply?

    @ObservationIgnored
    private let decisionTimeout: Duration

    /// Karar kaydı; `nil` ise yalnızca günlüğe yazılmaz.
    @ObservationIgnored
    private let auditLog: ToolAuditLog?

    @ObservationIgnored
    private var continuations: [String: [CheckedContinuation<OpenCodePermissionReply, Never>]] = [:]

    /// Aynı isteğin kaç kez ikinci bir koşudan ulaştığı; testler karar
    /// paylaşımını bununla kanıtlar.
    @ObservationIgnored
    private(set) var duplicateJoinCount = 0

    @ObservationIgnored
    private var timeoutTasks: [String: Task<Void, Never>] = [:]

    /// Koşan turun izin seviyesi anlık görüntüsü: tur başında alınır, tur
    /// bitene kadar kararlar buna göre verilir. Tur ortası seviye değişimi
    /// koşan tura işlemez; yeni kural sonraki turdadır.
    private struct TurnPolicy: Equatable {
        let turnID: UUID
        let policy: ToolApprovalPolicy
    }

    @ObservationIgnored
    private var turnPolicies: [UUID: TurnPolicy] = [:]

    init(
        automaticReplyProvider: @escaping @MainActor (String, [String]) -> ProviderPermissionReply?,
        decisionTimeout: Duration,
        auditLog: ToolAuditLog? = nil
    ) {
        self.automaticReplyProvider = automaticReplyProvider
        self.decisionTimeout = decisionTimeout
        self.auditLog = auditLog
    }

    /// Runtime bu çağrıda kararı bekler; tur bu sırada duraklar.
    func submit(_ request: OpenCodePermissionRequest) async -> OpenCodePermissionReply {
        if grantCovering(request) != nil {
            let reply = OpenCodePermissionReply.once
            await record(request, source: .grant, reply: reply)
            return reply
        }

        if let automaticReply = automaticReply(
            toolName: request.toolName,
            patterns: request.patterns,
            appSessionID: request.appSessionID
        ) {
            let reply = OpenCodePermissionReply(automaticReply)
            await record(request, source: .policy, reply: reply)
            return reply
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if continuations[request.id] != nil {
                    // Aynı istek ikinci bir koşudan da ulaşabilir (alt ajan izinleri üst
                    // oturumun akışına düşer). Erken bir yanıt üretmek kullanıcının
                    // kararını ezebileceği için ikinci çağrı aynı karara ortak olur.
                    duplicateJoinCount += 1
                    continuations[request.id]?.append(continuation)
                } else {
                    continuations[request.id] = [continuation]
                    pending.append(
                        PendingRequest(
                            id: request.id,
                            remoteSessionID: request.remoteSessionID,
                            appSessionID: request.appSessionID,
                            isDelegatedSession: request.isDelegatedSession,
                            toolName: request.toolName,
                            title: OpenCodePermissionRequest.title(for: request.toolName),
                            detail: request.detail,
                            patterns: request.patterns,
                            alwaysPatterns: request.alwaysPatterns,
                            requestedAt: Date()
                        )
                    )
                    startTimeout(for: request)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(id: request.id, reply: .reject, source: .policy)
            }
        }
    }

    func resolve(id: String, reply: OpenCodePermissionReply) {
        resolve(id: id, reply: reply, source: .user)
    }

    /// Bu sohbetin bekleyen istekleri; bölmeler birbirinin kuyruğunu görmez.
    func pendingRequests(for appSessionID: UUID) -> [PendingRequest] {
        pending.filter { $0.appSessionID == appSessionID }
    }

    /// Answers what is waiting with the level as it is **now**.
    ///
    /// Koşan turun bekleyenlerine dokunulmaz: tur ortası seviye değişimi hemen
    /// etki etmez, koşan turun kuralları saklıdır.
    ///
    /// - Parameter appSessionID: Verilirse yalnız bu oturumun bekleyenleri
    ///   yeniden yorumlanır; başka bölmedeki kuyuya dokunulmaz. `nil` (Ayarlar
    ///   ekranı) tüm kuyuyu kapsar.
    func reinterpretPendingRequests(appSessionID: UUID? = nil) {
        let requests = pending
        for request in requests where continuations[request.id] != nil {
            if let appSessionID, request.appSessionID != appSessionID {
                continue
            }
            if let owner = request.appSessionID, turnPolicies[owner] != nil {
                continue
            }
            guard
                let automaticReply = automaticReply(
                    toolName: request.toolName,
                    patterns: request.patterns,
                    appSessionID: request.appSessionID
                )
            else {
                continue
            }
            resolve(id: request.id, reply: OpenCodePermissionReply(automaticReply), source: .policy)
        }
    }

    /// Tur başı: bu oturumun kararı tur bitene kadar `policy` ile verilir.
    ///
    /// Üstüne yeni tur başlarsa (önceki turun sonu görülmeden) üzerine yazar;
    /// biten turun geç `endTurn` çağrısı `turnID` uyuşmazlığında yok sayılır.
    func beginTurn(appSessionID: UUID, turnID: UUID, policy: ToolApprovalPolicy) {
        turnPolicies[appSessionID] = TurnPolicy(turnID: turnID, policy: policy)
    }

    /// Tur sonu: yalnız aynı turun kapatması kaydı düşürür ve bekleyen istekleri çözer.
    func endTurn(appSessionID: UUID, turnID: UUID) {
        guard turnPolicies[appSessionID]?.turnID == turnID else {
            return
        }
        turnPolicies.removeValue(forKey: appSessionID)
        reinterpretPendingRequests(appSessionID: appSessionID)
    }

    /// Karar önce koşan turun anlık görüntüsüne sorulur; tur yoksa güncel
    /// seviyeye. Tur ortası seviye değişimi böylece koşan tura işlemez.
    private func automaticReply(
        toolName: String,
        patterns: [String],
        appSessionID: UUID?
    ) -> ProviderPermissionReply? {
        if let appSessionID, let snapshot = turnPolicies[appSessionID] {
            return snapshot.policy.automaticReply(
                for: toolName,
                patterns: patterns
            )
        }
        return automaticReplyProvider(toolName, patterns)
    }

    private func resolve(
        id: String,
        reply: OpenCodePermissionReply,
        source: ToolAuditLog.Source
    ) {
        guard let waiters = continuations.removeValue(forKey: id) else {
            return
        }
        timeoutTasks.removeValue(forKey: id)?.cancel()
        let request = pending.first { $0.id == id }
        pending.removeAll { $0.id == id }

        if reply == .always, let request {
            rememberGrant(for: request)
        }

        // Never grant OpenCode a server-lifetime approval: there is no matching
        // backend revoke operation. Preserve the user's `.always` intent in the
        // app and audit, but send only a one-time approval over the wire.
        let backendReply: OpenCodePermissionReply = reply == .always ? .once : reply
        for waiter in waiters {
            waiter.resume(returning: backendReply)
        }

        if let request {
            // Recorded after the turn is released: the audit write must never be
            // what a running agent is waiting for.
            Task { [auditLog] in
                await auditLog?.record(
                    ToolAuditLog.Record(
                        timestamp: Date(),
                        sessionID: request.remoteSessionID,
                        toolName: request.toolName,
                        title: request.title,
                        detail: request.detail,
                        patterns: request.patterns,
                        source: source,
                        reply: reply.providerReply
                    )
                )
            }
        }
    }

    func revokeAllGrants() {
        grants.removeAll()
    }

    func revokeGrant(id: String) {
        grants.removeAll { $0.id == id }
    }

    /// The last decisions the app made, newest last.
    func recentDecisions(limit: Int = 12) async -> [ToolAuditLog.Record] {
        guard let auditLog else {
            return []
        }
        return await auditLog.recent(limit: limit)
    }

    /// Actual tool starts and completions, including actions needing no prompt.
    func recentExecutions(limit: Int = 20) async -> [ToolAuditLog.ExecutionRecord] {
        guard let auditLog else {
            return []
        }
        return await auditLog.recentExecutions(limit: limit)
    }

    /// Tur iptal edilince bekleyen istekler reddedilir; aksi halde sunucu
    /// tarafında askıda kalan bir izin bir sonraki tura taşınır.
    ///
    /// A subagent's request carries the child session's id, so matching on the
    /// remote session alone would leave exactly the prompts that are easiest to
    /// miss: the user stops the turn, the subagent is aborted with it, and the
    /// question stays on screen until the timeout expires. The conversation the
    /// request was attributed to is the identity that covers both.
    func rejectAll(remoteSessionID: String, appSessionID: UUID? = nil) {
        let ids =
            pending
            .filter { request in
                request.remoteSessionID == remoteSessionID
                    || (appSessionID != nil && request.appSessionID == appSessionID)
            }
            .map(\.id)
        for id in ids {
            resolve(id: id, reply: .reject, source: .cancellation)
        }
    }

    func rejectAll() {
        for id in pending.map(\.id) {
            resolve(id: id, reply: .reject, source: .cancellation)
        }
    }

    /// Süre dolunca istek reddedilir. `resolve` tek noktadan çalıştığı için
    /// devamın iki kez sürdürülmesi mümkün değildir.
    private func startTimeout(for request: OpenCodePermissionRequest) {
        // Sözlük sınırsız büyümesin: en eski bekleyen atılır.
        if timeoutTasks.count >= 64, let oldest = timeoutTasks.keys.sorted().first {
            timeoutTasks[oldest]?.cancel()
            timeoutTasks.removeValue(forKey: oldest)
        }
        let timeout = decisionTimeout
        timeoutTasks[request.id] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else {
                return
            }
            guard let self, self.continuations[request.id] != nil else {
                return
            }

            AppLog.openCode.error(
                "Permission request \(request.id, privacy: .public) for \(request.toolName, privacy: .public) was rejected after \(timeout.components.seconds, privacy: .public)s without a decision"
            )
            self.resolve(id: request.id, reply: .reject, source: .timeout)
        }
    }

    private func rememberGrant(for request: PendingRequest) {
        let grant = Grant(
            toolName: request.toolName,
            patterns: request.patterns,
            alwaysPatterns: request.alwaysPatterns,
            appSessionID: request.appSessionID
        )

        guard !grants.contains(grant) else {
            return
        }

        grants.append(grant)
    }

    /// Whether an earlier "Always allow" already covers this request.
    ///
    /// Same session, same tool and the same patterns, in any order. A request
    /// with no patterns is covered only by a grant that also had none: an empty
    /// pattern list means "this whole tool", and silently widening a grant to
    /// every command of a tool is exactly the kind of inference an approval
    /// prompt exists to avoid. The session check keeps one conversation's grant
    /// from silently approving another's tools.
    private func grantCovering(_ request: OpenCodePermissionRequest) -> Grant? {
        grants.first { grant in
            grant.appSessionID == request.appSessionID
                && grant.toolName == request.toolName
                && Set(grant.patterns) == Set(request.patterns)
        }
    }

    private func record(
        _ request: OpenCodePermissionRequest,
        source: ToolAuditLog.Source,
        reply: OpenCodePermissionReply
    ) async {
        guard let auditLog else {
            return
        }

        await auditLog.record(
            ToolAuditLog.Record(
                timestamp: Date(),
                sessionID: request.remoteSessionID,
                toolName: request.toolName,
                title: OpenCodePermissionRequest.title(for: request.toolName),
                detail: request.detail,
                patterns: request.patterns,
                source: source,
                reply: reply.providerReply
            )
        )
    }
}
