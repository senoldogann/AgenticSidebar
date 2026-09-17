import Foundation

enum AgentActivityPhase: String, Equatable, Codable, Sendable {
    case running
    case completed
    case failed
    case cancelled
}

struct AgentActivity: Identifiable, Equatable, Codable, Sendable {
    let id: ProviderActivityID
    let kind: ProviderActivityKind
    var phase: AgentActivityPhase
    var title: String?
    var detail: String?
    var output: String?
    /// `+`/`-` preview of the change this activity made, when it has one.
    var diff: String?
    let startedAt: Date
    var completedAt: Date?

    init(
        id: ProviderActivityID,
        kind: ProviderActivityKind,
        phase: AgentActivityPhase,
        title: String?,
        detail: String?,
        output: String?,
        diff: String?,
        startedAt: Date,
        completedAt: Date?
    ) {
        self.id = id
        self.kind = kind
        self.phase = phase
        self.title = title
        self.detail = detail
        self.output = output
        self.diff = diff
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    init(
        id: ProviderActivityID,
        kind: ProviderActivityKind,
        phase: AgentActivityPhase,
        title: String?,
        detail: String?,
        output: String?,
        startedAt: Date,
        completedAt: Date?
    ) {
        self.init(
            id: id,
            kind: kind,
            phase: phase,
            title: title,
            detail: detail,
            output: output,
            diff: nil,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    init(
        id: ProviderActivityID,
        kind: ProviderActivityKind,
        phase: AgentActivityPhase
    ) {
        self.id = id
        self.kind = kind
        self.phase = phase
        self.title = nil
        self.detail = nil
        self.output = nil
        self.diff = nil
        self.startedAt = Date()
        self.completedAt = nil
    }

    /// Terminal version of an activity that was still running.
    ///
    /// Every rendered field (title, detail, tool output, start time) is kept:
    /// rebuilding a running activity from its id alone used to drop the output
    /// panel and rebase the start time, so finished tools showed no results.
    func finishing(with phase: AgentActivityPhase, at date: Date) -> AgentActivity {
        AgentActivity(
            id: id,
            kind: kind,
            phase: phase,
            title: title,
            detail: detail,
            output: output,
            diff: diff,
            startedAt: startedAt,
            completedAt: date
        )
    }
}

extension AgentActivity {
    /// A tool that was still running when the app went away can never finish, so
    /// a restored activity is closed at its last known instant.
    func normalizedForRestore() -> AgentActivity {
        guard phase == .running else {
            return self
        }

        var restored = self
        restored.phase = .cancelled
        restored.completedAt = completedAt ?? startedAt
        return restored
    }

    /// The archive keeps a bounded preview: file contents and terminal scrollback
    /// are unbounded, and a bloated archive is refused wholesale on the next
    /// launch, which would cost the whole conversation.
    func boundedForArchive(maxOutputLength: Int) -> AgentActivity {
        var bounded = self
        bounded.output = output?.boundedForArchive(maxLength: maxOutputLength)
        bounded.diff = diff?.boundedForArchive(maxLength: maxOutputLength)
        return bounded
    }
}

struct AgentTurnActivityGroup: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let anchorMessageID: UUID
    var activities: [AgentActivity]
}

extension AgentTurnActivityGroup {
    func normalizedForRestore() -> AgentTurnActivityGroup {
        var restored = self
        restored.activities = activities.map { $0.normalizedForRestore() }
        return restored
    }
}

extension Array where Element == AgentTurnActivityGroup {
    /// Zaman çizelgesini verilen sınırlara indirir.
    ///
    /// En yeniden başlanır — saklamaya değer olan yakın geçmiştir — ve bir grup
    /// bütün hâlde tutulur, böylece hiçbir tur yarım açıklanmış kalmaz.
    /// Transkriptte artık bulunmayan bir mesaja bağlı grubun asılacağı yer
    /// yoktur; o grup düşer.
    ///
    /// Aynı kural hem arşiv hem de bellek için geçerlidir: budanmayan bir
    /// geçmiş, uzun bir sohbette bütün dosya içeriklerini ve terminal
    /// çıktılarını RAM'de biriktirir.
    func bounded(
        toActivityCount maximumActivities: Int,
        anchoredTo messageIDs: Set<UUID>
    ) -> [AgentTurnActivityGroup] {
        guard !isEmpty else {
            return self
        }

        var remaining = maximumActivities
        var kept: [AgentTurnActivityGroup] = []

        for group in reversed() {
            guard remaining > 0 else {
                break
            }

            guard messageIDs.contains(group.anchorMessageID) else {
                continue
            }

            let activities = group.activities

            let storedActivities: [AgentActivity]
            if activities.count <= remaining {
                storedActivities = activities
            } else if kept.isEmpty {
                // Bütün bütçeden uzun tek bir tur da zaman çizelgesini korur:
                // saklanmaya değer olan en yeni adımlarıdır.
                storedActivities = [AgentActivity](activities.suffix(remaining))
            } else {
                break
            }

            remaining -= storedActivities.count
            kept.append(
                AgentTurnActivityGroup(
                    id: group.id,
                    anchorMessageID: group.anchorMessageID,
                    activities: storedActivities
                )
            )
        }

        return Array(kept.reversed())
    }

    /// Araç sonuçlarını arşiv sınırına indirir.
    ///
    /// Grup budamasından ayrı tutulur: budama belleğe geri yazıldığı için, aynı
    /// metni her turda yeniden kırpmak kırpma işaretini her seferinde yeniden
    /// üretip sayısını yanlışlar.
    func boundingOutputs(to maximumOutputLength: Int) -> [AgentTurnActivityGroup] {
        map { group in
            var bounded = group
            bounded.activities = group.activities.map {
                $0.boundedForArchive(maxOutputLength: maximumOutputLength)
            }
            return bounded
        }
    }
}

private extension String {
    /// Keeps the head of a long tool result and says so, rather than dropping
    /// the tail silently.
    func boundedForArchive(maxLength: Int) -> String {
        guard count > maxLength else {
            return self
        }

        let marker = "\n… (\(count - maxLength) more characters were not stored)"
        return String(prefix(maxLength)) + marker
    }
}
