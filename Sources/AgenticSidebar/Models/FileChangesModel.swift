import CryptoKit
import Foundation

/// Represents a single file created or modified in an agent turn.
struct FileChangeItem: Identifiable, Equatable, Hashable, Sendable, Codable {
    let id: UUID
    let path: String
    let additions: Int
    let deletions: Int
    let isNewFile: Bool
    let diff: String?

    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var directoryPath: String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if parent.hasPrefix(home) {
            return "~" + parent.dropFirst(home.count)
        }
        return parent
    }

    var fileExtension: String {
        URL(fileURLWithPath: path).pathExtension.lowercased()
    }
}

/// Consolidated summary of all file changes produced in an agent turn.
struct TurnFileChangesSummary: Identifiable, Equatable, Hashable, Sendable, Codable {
    let id: UUID
    let files: [FileChangeItem]

    var totalAdditions: Int {
        files.reduce(0) { $0 + $1.additions }
    }

    var totalDeletions: Int {
        files.reduce(0) { $0 + $1.deletions }
    }

    var fileCount: Int {
        files.count
    }

    var isEmpty: Bool {
        files.isEmpty
    }

    private static func stableID(for groupID: UUID, path: String) -> UUID {
        let key = "\(groupID.uuidString):\(path)"
        let digest = SHA256.hash(data: Data(key.utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    /// Extracts file modifications from an activity group.
    static func from(group: AgentTurnActivityGroup) -> TurnFileChangesSummary {
        var itemsByPath: [String: (additions: Int, deletions: Int, isNewFile: Bool, diffs: [String])] = [:]
        var pathOrder: [String] = []

        for activity in group.activities {
            // Must have a path or detail representing a file
            guard let rawPath = activity.detail, !rawPath.isEmpty, rawPath.contains("/") else {
                continue
            }

            // Exclude non-file activities like subagent summaries or bash commands
            if activity.kind != .edit && activity.kind != .update && activity.diff == nil {
                continue
            }

            let canonicalPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path

            let diffText = activity.diff ?? ""
            let lines = diffText.components(separatedBy: "\n")
            let addedCount = lines.filter { ($0.hasPrefix("+ ") || $0.hasPrefix("+")) && !$0.hasPrefix("+++") }.count
            let removedCount = lines.filter { ($0.hasPrefix("- ") || $0.hasPrefix("-")) && !$0.hasPrefix("---") }.count

            let titleLower = activity.title?.lowercased() ?? ""
            let isNew =
                titleLower.contains("created")
                || (titleLower.contains("wrote") && removedCount == 0 && addedCount > 0)
                || (removedCount == 0 && addedCount > 0 && !diffText.isEmpty)

            if var existing = itemsByPath[canonicalPath] {
                existing.additions += addedCount
                existing.deletions += removedCount
                if isNew {
                    existing.isNewFile = true
                }
                if !diffText.isEmpty {
                    existing.diffs.append(diffText)
                }
                itemsByPath[canonicalPath] = existing
            } else {
                pathOrder.append(canonicalPath)
                itemsByPath[canonicalPath] = (
                    additions: addedCount,
                    deletions: removedCount,
                    isNewFile: isNew,
                    diffs: diffText.isEmpty ? [] : [diffText]
                )
            }
        }

        let changeItems = pathOrder.compactMap { path -> FileChangeItem? in
            guard let data = itemsByPath[path] else {
                return nil
            }
            return FileChangeItem(
                id: stableID(for: group.id, path: path),
                path: path,
                additions: data.additions,
                deletions: data.deletions,
                isNewFile: data.isNewFile,
                diff: data.diffs.isEmpty ? nil : data.diffs.joined(separator: "\n\n")
            )
        }

        return TurnFileChangesSummary(
            id: group.id,
            files: changeItems
        )
    }

    /// Tüm turun (oturumun) dosya değişikliklerini tek özette birleştirir.
    ///
    /// Oturum bitiminde en altta duran kart bunu gösterir: her grup kendi
    /// kartını satır içinde tutar, bu özet yola göre toplayıp sayıları toplar.
    /// Sıra, dosyanın ilk görüldüğü turdur.
    static func merged(from groups: [AgentTurnActivityGroup]) -> TurnFileChangesSummary {
        var itemsByPath: [String: (additions: Int, deletions: Int, isNewFile: Bool, diffs: [String], id: UUID)] = [:]
        var pathOrder: [String] = []

        for group in groups {
            let summary = from(group: group)
            for file in summary.files {
                if var existing = itemsByPath[file.path] {
                    existing.additions += file.additions
                    existing.deletions += file.deletions
                    existing.isNewFile = existing.isNewFile || file.isNewFile
                    if let diff = file.diff, !diff.isEmpty {
                        existing.diffs.append(diff)
                    }
                    itemsByPath[file.path] = existing
                } else {
                    pathOrder.append(file.path)
                    itemsByPath[file.path] = (
                        additions: file.additions,
                        deletions: file.deletions,
                        isNewFile: file.isNewFile,
                        diffs: file.diff.map { [$0] } ?? [],
                        id: file.id
                    )
                }
            }
        }

        let changeItems = pathOrder.compactMap { path -> FileChangeItem? in
            guard let data = itemsByPath[path] else {
                return nil
            }
            return FileChangeItem(
                id: data.id,
                path: path,
                additions: data.additions,
                deletions: data.deletions,
                isNewFile: data.isNewFile,
                diff: data.diffs.isEmpty ? nil : data.diffs.joined(separator: "\n\n")
            )
        }

        return TurnFileChangesSummary(
            id: groups.last?.id ?? UUID(),
            files: changeItems
        )
    }
}

/// Presentation state for the right-side review panel.
struct FileChangesReviewState: Identifiable, Equatable, Sendable {
    let id: UUID
    let summary: TurnFileChangesSummary
    let initialSelectedFile: FileChangeItem?

    init(
        id: UUID,
        summary: TurnFileChangesSummary,
        initialSelectedFile: FileChangeItem?
    ) {
        self.id = id
        self.summary = summary
        self.initialSelectedFile = initialSelectedFile
    }

    init(
        summary: TurnFileChangesSummary,
        initialSelectedFile: FileChangeItem?
    ) {
        self.id = UUID()
        self.summary = summary
        self.initialSelectedFile = initialSelectedFile
    }
}
