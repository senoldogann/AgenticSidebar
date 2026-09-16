import Foundation
import Observation

/// Tool onaylarını askıya alıp UI'dan gelen kararla çözen merkez.
///
/// Önceki davranış `permission.asked` olayına koşulsuz `"always"` cevabı
/// veriyordu; bilgisayar kontrolü veren bir modelde bu kabul edilemez. Şimdi her
/// istek ya kullanıcıya gösterilir, ya da kullanıcının seçtiği izin seviyesi
/// (``ToolApprovalPolicy``) o an için karar verir — seviye **her istekte** yeniden
/// okunur, böylece tur ortasında değiştirilebilir.
///
/// Otomatik cevaplar `.once`'tır, `.always` değil: OpenCode `always` cevabını
/// sunucu oturumu boyunca hatırlar, dolayısıyla otomatik onayda onu kullanmak
/// kullanıcı daha sıkı bir seviyeye döndüğünde sessizce onay vermeye devam
/// ederdi. `.always` yalnızca kullanıcı tıkladığı için gönderilir.
@MainActor
@Observable
final class PermissionApprovalCenter {
    struct PendingRequest: Identifiable, Equatable, Sendable {
        let id: String
        let remoteSessionID: String
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
            if name.contains("bash") || name.contains("shell") || name.contains("task") {
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
    /// Sunucu tarafındaki `always` sunucu oturumuyla yaşar; bu liste uygulama
    /// tarafındaki kopyasıdır, böylece arka uç yeniden başladığında da geçerlidir
    /// ve kullanıcı geri alabilir.
    ///
    /// Eşleşme **aynı araç + aynı desenler** üzerinedir. `alwaysPatterns`
    /// (OpenCode'un "her zaman" için kapsayacağı kalıp) saklanır ama eşleşmede
    /// kullanılmaz: kullanıcı `ls` için izin verdiyse bu bir `rm -rf` izni değildir.
    struct Grant: Identifiable, Equatable, Sendable {
        let toolName: String
        let patterns: [String]
        let alwaysPatterns: [String]

        var id: String {
            toolName + "|" + patterns.joined(separator: "\u{1}")
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
    private let automaticReplyProvider: @MainActor (String, [String]) -> OpenCodePermissionReply?

    @ObservationIgnored
    private let decisionTimeout: Duration

    /// Karar kaydı; `nil` ise yalnızca günlüğe yazılmaz.
    @ObservationIgnored
    private let auditLog: ToolAuditLog?

    @ObservationIgnored
    private var continuations: [String: CheckedContinuation<OpenCodePermissionReply, Never>] = [:]

    @ObservationIgnored
    private var timeoutTasks: [String: Task<Void, Never>] = [:]

    init(
        automaticReplyProvider: @escaping @MainActor (String, [String]) -> OpenCodePermissionReply?,
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

        if let automaticReply = automaticReplyProvider(request.toolName, request.patterns) {
            await record(request, source: .policy, reply: automaticReply)
            return automaticReply
        }

        if continuations[request.id] != nil {
            AppLog.openCode.error(
                "Duplicate permission request id \(request.id, privacy: .public) was rejected"
            )
            return .reject
        }

        return await withCheckedContinuation { continuation in
            continuations[request.id] = continuation
            pending.append(
                PendingRequest(
                    id: request.id,
                    remoteSessionID: request.remoteSessionID,
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

    func resolve(id: String, reply: OpenCodePermissionReply) {
        resolve(id: id, reply: reply, source: .user)
    }

    /// Answers what is waiting with the level as it is **now**.
    ///
    /// Called when the user changes the level from inside a prompt: a queue of
    /// "may I run this?" questions is meaningless once the answer to the whole
    /// class of questions has changed, and leaving them to time out would refuse
    /// work the user just approved.
    func reinterpretPendingRequests() {
        let requests = pending
        for request in requests where continuations[request.id] != nil {
            guard
                let reply = automaticReplyProvider(request.toolName, request.patterns)
            else {
                continue
            }
            resolve(id: request.id, reply: reply, source: .policy)
        }
    }

    private func resolve(
        id: String,
        reply: OpenCodePermissionReply,
        source: ToolAuditLog.Source
    ) {
        guard let continuation = continuations.removeValue(forKey: id) else {
            return
        }
        timeoutTasks.removeValue(forKey: id)?.cancel()
        let request = pending.first { $0.id == id }
        pending.removeAll { $0.id == id }

        if reply == .always, let request {
            rememberGrant(for: request)
        }

        continuation.resume(returning: reply)

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
                        reply: reply
                    )
                )
            }
        }
    }

    /// Answers every pending request at once — used when the user changes the
    /// level, so a queue of prompts does not survive the decision that made them
    /// moot.
    func resolveAll(reply: OpenCodePermissionReply) {
        for id in pending.map(\.id) {
            resolve(id: id, reply: reply)
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

    /// Tur iptal edilince bekleyen istekler reddedilir; aksi halde sunucu
    /// tarafında askıda kalan bir izin bir sonraki tura taşınır.
    func rejectAll(remoteSessionID: String) {
        let ids = pending
            .filter { $0.remoteSessionID == remoteSessionID }
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
            alwaysPatterns: request.alwaysPatterns
        )

        guard !grants.contains(grant) else {
            return
        }

        grants.append(grant)
    }

    /// Whether an earlier "Always allow" already covers this request.
    ///
    /// Same tool and the same patterns, in any order. A request with no patterns
    /// is covered only by a grant that also had none: an empty pattern list means
    /// "this whole tool", and silently widening a grant to every command of a tool
    /// is exactly the kind of inference an approval prompt exists to avoid.
    private func grantCovering(_ request: OpenCodePermissionRequest) -> Grant? {
        grants.first { grant in
            grant.toolName == request.toolName
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
                reply: reply
            )
        )
    }
}
