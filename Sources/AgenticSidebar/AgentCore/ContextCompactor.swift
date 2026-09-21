import Foundation

/// Bağlam sıkıştırma (`/compact` + otomatik): pencere dışına düşen ön eki
/// tek-atımlık bir özet turuyla yoğunlaştırır. Özet sonraki isteklerin başına
/// eklenir, sunucu tarafı döndürülür; ekrandaki transkript (arşiv) el değmez.
///
/// Saf planlama buradadır, orkestrasyon `AgentSession` tarafındadır;
/// penceresiz test edilir.
enum ContextCompactor {
    /// Özet bloğunun tavanı: isteğin başına eklenen metin bu boyu aşmaz.
    static let maximumSummaryCharacters = 6_000
    /// Özetlenecek ham girdinin tavanı: devasa çıktı yığınları modele ham
    /// taşınmaz, mesaj başına kırpılır, toplam burada kesilir.
    static let maximumStaleInputCharacters = 30_000
    static let maximumStaleMessageCharacters = 2_000

    struct Plan: Equatable, Sendable {
        /// Pencereden düşmüş, henüz özetlenmemiş ön ek (okuma sırasıyla).
        let staleMessages: [ChatMessage]
    }

    /// Özetlenmemiş düşen ön ek: bütçe penceresinin dışında kalanlar eksi
    /// daha önce özetlenenler (`summarizedThroughMessageID` dahil). Kapsanacak
    /// bir şey yoksa `nil` — ne nag ne özet turu gerekir.
    static func plan(
        messages: [ChatMessage],
        budget: TranscriptBudget = TranscriptBudget(),
        summarizedThroughMessageID: UUID? = nil
    ) -> Plan? {
        let keptIDs = Set(budget.select(from: messages).messages.map(\.id))
        var stale = messages.filter { !keptIDs.contains($0.id) }
        if let covered = summarizedThroughMessageID,
            let coveredIndex = stale.firstIndex(where: { $0.id == covered })
        {
            stale.removeFirst(coveredIndex + 1)
        }
        guard !stale.isEmpty else {
            return nil
        }
        return Plan(staleMessages: stale)
    }

    /// Özet turunun sorusu: önceki özet (varsa) + ham ön ek. Modelden tam,
    /// kendi kendine yeterli bir özet istenir; özet bir sonrakinin girdisi
    /// olur (yuvarlanan özet).
    static func summarizationPrompt(
        priorSummary: String,
        staleMessages: [ChatMessage]
    ) -> String {
        var lines: [String] = []
        var used = 0
        for message in staleMessages {
            let speaker = message.role == .user ? "User" : "Assistant"
            var text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Boy ölçümleri `utf8.count` ile: grapheme sayımı her özet turunda
            // bütün ön eki dolaşırdı. Kesme karakter sınırında yapılır.
            if text.utf8.count > maximumStaleMessageCharacters {
                text = String(text.prefix(maximumStaleMessageCharacters)) + "…"
            }
            let line = "\(speaker): \(text)"
            guard used + line.utf8.count <= maximumStaleInputCharacters else {
                break
            }
            lines.append(line)
            used += line.utf8.count
        }
        var sections = [
            """
            Summarize the earlier part of this conversation into a compact \
            handoff note (decisions made, key facts, agreed plan, open items, \
            anything the next turn must not forget). Reply with ONLY the \
            summary, no tools, no questions, no preamble.
            """
        ]
        let prior = priorSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prior.isEmpty {
            sections.append("Previous summary to fold in:\n\(prior)")
        }
        sections.append("Conversation to summarize:\n\(lines.joined(separator: "\n\n"))")
        return sections.joined(separator: "\n\n")
    }

    /// İsteğin başına eklenen özet bloğu: model için yerleşik tarihçe sayılır.
    static func summaryBlock(_ summary: String) -> String {
        """
        [Compacted context: the summary below replaces earlier turns that no \
        longer fit the model context window. Treat it as established history.]
        \(summary.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    /// Özet bloğunu istek mesajı olarak: durumsuz sağlayıcılar (OpenAI) her
    /// turda tam listeyi gönderir, özet en başa eklenir.
    static func summaryMessage(_ summary: String) -> ChatMessage? {
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return ChatMessage(role: .user, text: summaryBlock(summary))
    }

    /// Ham özet yanıtını boyuna indirir: model taştığında blok büyümez.
    static func boundSummary(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count > maximumSummaryCharacters else {
            return trimmed
        }
        return String(trimmed.prefix(maximumSummaryCharacters)) + "…"
    }
}
