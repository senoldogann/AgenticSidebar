import Foundation

/// Append-only record of every tool decision the app made.
///
/// The approval prompt is the only moment the app knows, in full, what the agent
/// is about to do: the tool, the command or path, and who allowed it. The
/// transcript trims activities (120 per conversation, 4,000-character outputs) and
/// the archive is byte-bounded, because those stores exist to keep the *context*
/// small — which is correct for them and useless for the question "which commands
/// ran on this machine yesterday?". This file answers that question instead, and
/// nothing about it is rendered into a prompt.
///
/// It is the accountability half of an autonomous agent: on a level that does not
/// ask, the record is the substitute for the prompt, not a second copy of it.
///
/// JSON Lines rather than a database: appending one line cannot corrupt what was
/// written before it, a partial final line is simply ignored on read, and the file
/// stays legible in any editor. Bounded by rotation, because a long session is
/// exactly the case it exists for.
actor ToolAuditLog {
    struct Record: Codable, Equatable, Sendable, Identifiable {
        let timestamp: Date
        /// The remote (provider-side) session id, so a line can be tied back to a
        /// conversation without storing anything about its content.
        let sessionID: String
        let toolName: String
        let title: String
        let detail: String?
        let patterns: [String]
        let source: Source
        let reply: ProviderPermissionReply

        var id: String {
            "\(timestamp.timeIntervalSince1970)-\(toolName)-\(patterns.joined(separator: ","))"
        }
    }

    /// Observed tool lifecycle, not a permission decision. Outputs and diffs are
    /// intentionally excluded; the event records what ran without copying data.
    struct ExecutionRecord: Codable, Equatable, Sendable, Identifiable {
        enum Event: String, Codable, Sendable {
            case started
            case completed
            case failed
        }

        let timestamp: Date
        let sessionID: String
        let activityID: String
        let toolKind: ProviderActivityKind
        /// Optional human-readable title. Intentionally omitted (nil) by the runtime
        /// to prevent potential credentials or arguments from leaking into audit files.
        let title: String?
        /// Optional detail summary. Intentionally omitted (nil) by the runtime for privacy.
        let detail: String?
        let event: Event

        var id: String {
            "\(sessionID)-\(activityID)-\(event.rawValue)-\(timestamp.timeIntervalSince1970)"
        }
    }

    /// Why a decision was made the way it was.
    enum Source: String, Codable, Sendable {
        /// The selected level answered on the user's behalf.
        case policy
        /// An "Always allow" the user made earlier in this session.
        case grant
        /// The user answered the prompt.
        case user
        /// Nobody answered within the timeout, so it was refused.
        case timeout
        /// The turn was cancelled while the request was pending.
        case cancellation

        var label: String {
            switch self {
            case .policy: "Level"
            case .grant: "Your earlier choice"
            case .user: "You"
            case .timeout: "Timed out"
            case .cancellation: "Cancelled"
            }
        }
    }

    nonisolated let fileURL: URL

    private let maximumBytes: Int
    private let maximumFiles: Int
    private let fileManager: FileManager

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(
        fileURL: URL,
        maximumBytes: Int = 20 * 1024 * 1024,
        maximumFiles: Int = 5,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.maximumBytes = maximumBytes
        self.maximumFiles = maximumFiles
        self.fileManager = fileManager
    }

    /// Inside the app's own OpenCode directory: created `0700`, and the file the
    /// app owns. Command text lives here, so it is kept out of the unified log
    /// (which is `.public` by design) and out of the user's own files.
    static func live() -> ToolAuditLog {
        ToolAuditLog(
            fileURL: ManagedAppDirectories.openCodeWorkingDirectory()
                .appendingPathComponent("audit.jsonl")
        )
    }

    func record(_ record: Record) {
        append(record)
    }

    func recordExecution(_ record: ExecutionRecord) {
        append(record)
    }

    private func append<Entry: Encodable>(_ record: Entry) {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            var line = try Self.encoder.encode(record)
            line.append(0x0A)

            try rotateIfNeeded(adding: line.count)

            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(
                    atPath: fileURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            }

            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            AppLog.openCode.error(
                "Could not append to the tool audit log: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// The most recent records, oldest first, so a list reads as a timeline.
    func recent(limit: Int) -> [Record] {
        guard limit > 0 else {
            return []
        }

        guard let data = tailData(maximumBytes: 512 * 1024) else {
            return []
        }

        var records: [Record] = []
        for line in data.split(separator: 0x0A) {
            guard
                !line.isEmpty,
                let record = try? Self.decoder.decode(Record.self, from: Data(line))
            else {
                // A line cut in half by an interrupted write is skipped rather than
                // reported: the record before it is still valid.
                continue
            }
            records.append(record)
        }

        return Array(records.suffix(limit))
    }

    /// Tool starts and completions share the same bounded JSONL file as decisions,
    /// but have their own schema so an approval is never mistaken for execution.
    func recentExecutions(limit: Int) -> [ExecutionRecord] {
        guard limit > 0, let data = tailData(maximumBytes: 512 * 1024) else {
            return []
        }

        let records = data.split(separator: 0x0A).compactMap { line in
            try? Self.decoder.decode(ExecutionRecord.self, from: Data(line))
        }
        return Array(records.suffix(limit))
    }

    private func tailData(maximumBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }

        do {
            let size = try handle.seekToEnd()
            let start = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
            try handle.seek(toOffset: start)
            return try handle.readToEnd() ?? Data()
        } catch {
            return nil
        }
    }

    /// Keeps the file bounded by size, discarding the oldest file whole.
    private func rotateIfNeeded(adding bytes: Int) throws {
        guard
            let size = try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber,
            size.intValue + bytes > maximumBytes
        else {
            return
        }

        let oldest = Self.rotatedURL(for: fileURL, index: maximumFiles - 1)
        try? fileManager.removeItem(at: oldest)

        for index in stride(from: maximumFiles - 2, through: 1, by: -1) {
            let source = Self.rotatedURL(for: fileURL, index: index)
            guard fileManager.fileExists(atPath: source.path) else {
                continue
            }
            try? fileManager.moveItem(
                at: source,
                to: Self.rotatedURL(for: fileURL, index: index + 1)
            )
        }

        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.moveItem(at: fileURL, to: Self.rotatedURL(for: fileURL, index: 1))
        }
    }

    private static func rotatedURL(for fileURL: URL, index: Int) -> URL {
        fileURL.deletingPathExtension()
            .appendingPathExtension("\(index).jsonl")
    }
}
