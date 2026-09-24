import Foundation

/// Kaynak sohbetten hedef besteciye taşınan devir notu.
///
/// Ham geçmiş kopyalanmaz: kaynak `contextSummary` + son mesajların
/// kısaltılmış dökümü + bitmemiş görevler tek bir metin bloğunda
/// yoğunlaştırılır. Hedef tur gönderilince bu blok olağan promptun parçası
/// olur, ajan diğer sohbetin işine buradan devam eder.
///
/// Saf fonksiyondur, görünüm çalıştırmadan test edilir.
enum SessionHandoff {
    /// Devir notuna giren en yeni mesaj sayısı.
    static let maximumMessages = 6
    /// Mesaj başına taşınan en fazla karakter.
    static let maximumMessageCharacters = 400
    /// Kaynak özetinden taşınan en fazla karakter.
    static let maximumSummaryCharacters = 2_000
    /// Görev listesinden taşınan en fazla madde.
    static let maximumTodos = 10

    /// Devir metnini kurar. Taşınacak içerik yoksa `nil` döner.
    static func handoffText(
        sourceTitle: String,
        contextSummary: String,
        messages: [ChatMessage],
        todos: [AgentTodo],
        workingDirectoryPath: String?
    ) -> String? {
        let title = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = boundSummary(contextSummary)
        let recentTurns = abridgedTurns(messages)
        let openTasks = openTaskLines(todos)
        let directory = workingDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty || !summary.isEmpty || !recentTurns.isEmpty || !openTasks.isEmpty else {
            return nil
        }
        var sections: [String] = []
        let headerTitle = title.isEmpty ? "another conversation" : "\"\(title)\""
        sections.append("[Context from \(headerTitle) — summary, not full history]")
        if !summary.isEmpty {
            sections.append(summary)
        }
        if !recentTurns.isEmpty {
            sections.append("Recent turns (abridged):\n" + recentTurns.joined(separator: "\n"))
        }
        if !openTasks.isEmpty {
            sections.append("Open tasks:\n" + openTasks.joined(separator: "\n"))
        }
        if !directory.isEmpty {
            sections.append("Working directory: \(directory)")
        }
        sections.append("Continue the task from that conversation here.")
        return sections.joined(separator: "\n\n")
    }

    /// Son mesajların kısaltılmış dökümü: konuşmacı etiketi + kırpılmış metin.
    static func abridgedTurns(_ messages: [ChatMessage]) -> [String] {
        let tail = messages.suffix(maximumMessages)
        var lines: [String] = []
        lines.reserveCapacity(tail.count)
        for message in tail {
            let text = truncated(message.text, limit: maximumMessageCharacters)
            guard !text.isEmpty else {
                continue
            }
            let speaker = message.role == .user ? "User" : "Assistant"
            lines.append("\(speaker): \(text)")
        }
        return lines
    }

    /// Bitmemiş görevlerin tek satırlık listesi.
    static func openTaskLines(_ todos: [AgentTodo]) -> [String] {
        let open = todos.filter { !$0.status.isFinished }
        guard !open.isEmpty else {
            return []
        }
        return open.prefix(maximumTodos).map { todo in
            let marker = todo.status == .inProgress ? "[in progress]" : "[pending]"
            let content = truncated(todo.content, limit: maximumMessageCharacters)
            return "- \(marker) \(content)"
        }
    }

    /// Kaynak özetini boyuna indirir.
    static func boundSummary(_ summary: String) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count > maximumSummaryCharacters else {
            return trimmed
        }
        return String(trimmed.prefix(maximumSummaryCharacters)) + "…"
    }

    /// Tek metni kırpar, boşlukları temizler.
    static func truncated(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        let collapsed = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard collapsed.utf8.count > limit else {
            return collapsed
        }
        return String(collapsed.prefix(limit)) + "…"
    }
}
