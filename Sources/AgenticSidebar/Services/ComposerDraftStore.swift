import Foundation

/// An unsent composer draft, kept across relaunches.
///
/// The archive owns sent turns; a draft was never sent, so it lives beside the
/// archive rather than inside it: a tiny JSON map from session id to text plus
/// attachment paths. Writes are debounced like the archive's — a keystroke must
/// not cost a disk write — and flushed on shutdown next to the pending archive
/// save.
struct ComposerStoredDraft: Codable, Equatable, Sendable {
    var text: String
    var attachmentPaths: [String]
    var updatedAt: Date
}

@Observable
@MainActor
final class ComposerDraftStore {
    /// Keystrokes are frequent, so writes are coalesced behind this delay.
    private static let saveDebounce = Duration.seconds(2)

    private var drafts: [String: ComposerStoredDraft]
    private let fileURL: URL?
    private var saveTask: Task<Void, Never>?
    private var hasPendingSave = false

    init(drafts: [String: ComposerStoredDraft] = [:], fileURL: URL? = nil) {
        self.drafts = drafts
        self.fileURL = fileURL
    }

    /// The application's own drafts location.
    static func live() -> ComposerDraftStore {
        guard
            let directory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            return ComposerDraftStore()
        }

        let folder = directory.appendingPathComponent(AppIdentity.name, isDirectory: true)
        let store = ComposerDraftStore(
            fileURL: folder.appendingPathComponent("drafts.json")
        )
        store.reload()
        return store
    }

    /// The draft for a session, if one was left unsent.
    func storedDraft(for sessionID: UUID) -> ComposerStoredDraft? {
        drafts[sessionID.uuidString]
    }

    /// Records the current field content. Unchanged content schedules nothing:
    /// every redraw calls this, but only an edit may cost a write.
    func update(sessionID: UUID, text: String, attachmentPaths: [String]) {
        let key = sessionID.uuidString
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty && attachmentPaths.isEmpty {
            guard drafts[key] != nil else {
                return
            }
            drafts.removeValue(forKey: key)
            scheduleSave()
            return
        }

        let next = ComposerStoredDraft(
            text: text,
            attachmentPaths: attachmentPaths,
            updatedAt: Date()
        )
        guard drafts[key]?.text != next.text
            || drafts[key]?.attachmentPaths != next.attachmentPaths
        else {
            return
        }

        drafts[key] = next
        scheduleSave()
    }

    /// Drops the draft once its message was accepted for a turn.
    func clear(sessionID: UUID) {
        guard drafts.removeValue(forKey: sessionID.uuidString) != nil else {
            return
        }
        scheduleSave()
    }

    /// Silinen sohbetlerin taslakları tutulmaz.
    func discardSessions(notIn liveIDs: Set<UUID>) {
        let liveKeys = Set(liveIDs.map(\.uuidString))
        let before = drafts.count
        drafts = drafts.filter { liveKeys.contains($0.key) }
        if drafts.count != before {
            scheduleSave()
        }
    }

    /// Bekleyen yazmayı boşaltır; kapanışta çağrılmazsa son taslak kaybolur.
    func flush() async {
        saveTask?.cancel()
        saveTask = nil
        await saveNow()
    }

    private func scheduleSave() {
        guard fileURL != nil else {
            return
        }

        hasPendingSave = true
        guard saveTask == nil else {
            return
        }

        saveTask = Task { [weak self] in
            while let self, self.hasPendingSave {
                try? await Task.sleep(for: Self.saveDebounce)
                guard !Task.isCancelled else {
                    break
                }
                self.hasPendingSave = false
                await self.saveNow()
            }

            if !Task.isCancelled {
                self?.saveTask = nil
            }
        }
    }

    private func saveNow() async {
        guard let fileURL else {
            hasPendingSave = false
            return
        }

        hasPendingSave = false

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(drafts)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            AppLog.agentSession.error(
                "Composer drafts could not be written: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func reload() {
        guard
            let fileURL,
            let data = FileManager.default.contents(atPath: fileURL.path)
        else {
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            drafts = try decoder.decode([String: ComposerStoredDraft].self, from: data)
        } catch {
            AppLog.agentSession.error(
                "Composer drafts could not be decoded; the file was moved aside"
            )
            moveAside()
        }
    }

    /// Bozuk dosya, sonraki kayıtta üzerine yazılmasın diye kenara alınır —
    /// arşivin ve kayıt defterinin izlediği yolun aynısı.
    private func moveAside() {
        guard let fileURL else {
            return
        }
        let damagedURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("corrupt.json")
        try? FileManager.default.removeItem(at: damagedURL)
        try? FileManager.default.moveItem(at: fileURL, to: damagedURL)
    }
}
