import Foundation

/// A long paste becomes a file attachment instead of draft text.
///
/// Pasting a document into the field used to stall keystrokes and bloat the
/// turn; Codex and ChatGPT attach it as a file (`readme.md`-style) so the chat
/// stays fluid and the agent reads a file. Pasted text over
/// ``thresholdCharacters`` is written as markdown under Application Support and
/// attached like any dropped file — the prompt builder already inlines text
/// files, so no provider change is needed.
enum PastedTextAttachment {
    /// Pastes up to this length stay inline; longer ones spill to a file.
    static let thresholdCharacters = 1_000
    /// Pastes spanning at least this many lines spill to a file even if under character threshold.
    static let thresholdLines = 20

    /// How many spilled files are kept; older ones are pruned on write, so the
    /// folder cannot grow without bound.
    static let maximumStoredFiles = 50

    static let directoryName = "PastedTexts"
    static let fileExtension = "md"
    static let attachmentFileName = "readme.md"

    static func shouldSpillToFile(_ text: String) -> Bool {
        if text.count > thresholdCharacters {
            return true
        }
        let newlineCount = text.reduce(into: 0) { count, char in
            if char.isNewline { count += 1 }
        }
        return newlineCount >= thresholdLines
    }

    /// `pasted-text-20260916-171300-a1b2c3.md`: sortable, unique per write.
    static func fileName(date: Date = Date(), uniquifier: String = defaultUniquifier()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "pasted-text-\(formatter.string(from: date))-\(uniquifier).\(fileExtension)"
    }

    /// Sortable directory name for a single paste turn: `paste-20260916-171300-a1b2c3`.
    static func subfolderName(date: Date = Date(), uniquifier: String = defaultUniquifier()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "paste-\(formatter.string(from: date))-\(uniquifier)"
    }

    static func defaultUniquifier() -> String {
        String(UUID().uuidString.prefix(6)).lowercased()
    }

    static func directory(baseURL: URL) -> URL {
        baseURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The application's own pasted-text folder, or `nil` outside an app home.
    static func liveDirectory() -> URL? {
        guard
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            return nil
        }

        return directory(
            baseURL: support.appendingPathComponent(AppIdentity.name, isDirectory: true)
        )
    }

    /// Writes the text as a readme.md file inside an isolated subfolder, prunes older spills, returns its URL.
    ///
    /// A write failure throws and the caller inserts inline instead: losing the
    /// paste would be worse than a heavy draft.
    @discardableResult
    static func spill(
        _ text: String,
        date: Date = Date(),
        uniquifier: String = defaultUniquifier(),
        fileManager: FileManager = .default,
        baseURL: URL? = liveDirectory()
    ) throws -> URL {
        guard let baseURL else {
            throw PastedTextAttachmentError.noStorageLocation
        }

        let baseFolder = directory(baseURL: baseURL)
        let itemFolder = baseFolder.appendingPathComponent(
            subfolderName(date: date, uniquifier: uniquifier),
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: itemFolder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let url = itemFolder.appendingPathComponent(attachmentFileName)
        guard let data = text.data(using: .utf8) else {
            throw PastedTextAttachmentError.unencodableText
        }
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )

        prune(directory: baseFolder, fileManager: fileManager)
        return url
    }

    private static func prune(directory: URL, fileManager: FileManager) {
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }

        let sorted = entries.sorted {
            modificationDate(of: $0, fileManager: fileManager)
                < modificationDate(of: $1, fileManager: fileManager)
        }

        guard sorted.count > maximumStoredFiles else {
            return
        }

        for stale in sorted.prefix(sorted.count - maximumStoredFiles) {
            try? fileManager.removeItem(at: stale)
        }
    }

    private static func modificationDate(of url: URL, fileManager: FileManager) -> Date {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            ?? .distantPast
    }
}

enum PastedTextAttachmentError: Error, Equatable {
    case noStorageLocation
    case unencodableText
}
