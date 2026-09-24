import Foundation

/// Tek-tık prompt iyileştirmenin saf metin katmanı: bestecideki ham taslağı,
/// oturum bağlamına göre daha verimli bir ajan promptuna çevirecek model
/// talimatını kurar.
///
/// Qoder-benzeri davranış: kullanıcı yazar, tek düğmeye basar, sağlayıcıdaki
/// model saniyeler içinde taslağın düzeltilmiş hâlini verir ve taslak onunla
/// değişir. Ağ yok, durum yok — yalnızca metin inşası; gönderim ve akış
/// `PromptEnhanceService` ve mevcut `answerSideQuestion` yolundadır.
enum PromptEnhancer {
    /// İyileştirme çağrısına giren taslağın üst sınırı: üstü model
    /// penceresini şişirir, düğme o taslakta iyileştirmeyi kapatır.
    static let maximumDraftCharacters = 8_000
    /// Bağlama taşınan etiket/ek adı sayısı: komut satırı şişmesin diye sınırlı.
    static let maximumContextNames = 12

    /// Taslak iyileştirmeye uygun mu: boş değil, üst sınırı aşmıyor ve ajan
    /// komutu değil (`/btw`, `/goal` gibi önekler aynen gönderilmelidir).
    static func isEnhanceable(_ draft: String) -> Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumDraftCharacters else {
            return false
        }
        guard !trimmed.hasPrefix("/") else {
            return false
        }
        return true
    }

    /// İyileşmiş metin taslağın üzerine yazılmalı mı: kullanıcı iyileştirme
    /// akarken yazmaya devam ettiyse (`currentDraft` istek anındaki
    /// `originalDraft`tan farklıysa) üzerine yazma sessizce atılır; yazılan
    /// düşünce kaybolmamalıdır. Karşılaştırma kırpılmış metinledir, böylece
    /// baştaki/sondaki boşluk farkı sahte çakışma sayılmaz.
    static func shouldApplyEnhancement(currentDraft: String, originalDraft: String) -> Bool {
        currentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            == originalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Model çağrısına giden iyileştirme talimatı: ham taslak + sıradaki
    /// adımın bağlamı (ajan modu, etiketler, ekler). Dönen metin doğrudan
    /// taslağın yerine geçtiği için talimat çıktıyı tek metne kilitler:
    /// açıklama yok, selamlama yok, taslağın dilinde.
    static func enhanceInstruction(
        draft: String,
        mode: AgentMode,
        tagNames: [String] = [],
        attachmentNames: [String] = []
    ) -> String {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [String] = []
        sections.append(
            """
            Rewrite the user's draft below into a better prompt for the coding assistant. \
            Return ONLY the improved prompt text, nothing else: no greeting, no explanation, \
            no preamble, no summary of what you changed. Write the improved prompt in the \
            same language as the draft.
            """
        )
        sections.append("The assistant will run in \(mode.displayName) mode (\(mode.helpText)). Shape the prompt for that mode.")
        sections.append(
            """
            Rules for the improved prompt: keep the user's intent exactly, never add new \
            requirements they did not ask for; make vague verbs concrete (which files, what \
            behavior, what is out of scope). Structure the improved prompt with an explicit \
            goal, the constraints the assistant must respect, and short implementation \
            guidance; if the draft looks like a task, end the prompt with explicit \
            acceptance criteria as a short checklist; if the draft is a question, keep it \
            a question but add the missing context the assistant would need.
            """
        )
        let tags = Array(tagNames.prefix(maximumContextNames)).filter { !$0.isEmpty }
        if !tags.isEmpty {
            sections.append(
                "Turn context the user already tagged: \(tags.joined(separator: ", ")). Refer to them, do not ask for them again.")
        }
        let attachments = Array(attachmentNames.prefix(maximumContextNames)).filter { !$0.isEmpty }
        if !attachments.isEmpty {
            sections.append(
                "Attached files the assistant can already read: \(attachments.joined(separator: ", ")). Refer to them by name, do not ask for their content."
            )
        }
        sections.append("User draft:\n\(trimmed)")
        return sections.joined(separator: "\n\n")
    }
}
