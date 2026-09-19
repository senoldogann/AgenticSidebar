import Foundation

/// On-disk provenance record for one managed workspace.
///
/// The manifest ties a workspace to the exact project, task, attempt, baseline
/// commit, Git common dir and random ownership nonce that created it. It is the
/// only authority the retirement path trusts, and it is written atomically before
/// the workspace is announced to callers.
struct WorkspaceManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let workspaceID: UUID
    let projectID: UUID
    let taskID: UUID
    let attemptID: UUID
    let repositoryPath: String
    let workspacePath: String
    let commonDirIdentity: String
    let baseSHA: String
    let nonce: String
    let createdAt: Date

    init(record: WorkspaceRecord) {
        self.schemaVersion = Self.currentSchemaVersion
        self.workspaceID = record.workspaceID
        self.projectID = record.projectID
        self.taskID = record.taskID
        self.attemptID = record.attemptID
        self.repositoryPath = record.repositoryPath
        self.workspacePath = record.workspacePath
        self.commonDirIdentity = record.commonDirIdentity
        self.baseSHA = record.baseSHA
        self.nonce = record.nonce
        self.createdAt = record.createdAt
    }

    /// The immutable provenance carried by this manifest.
    var record: WorkspaceRecord {
        WorkspaceRecord(
            workspaceID: workspaceID,
            projectID: projectID,
            taskID: taskID,
            attemptID: attemptID,
            repositoryPath: repositoryPath,
            workspacePath: workspacePath,
            commonDirIdentity: commonDirIdentity,
            baseSHA: baseSHA,
            nonce: nonce,
            createdAt: createdAt
        )
    }

    /// Deterministic JSON used both for the atomic manifest file and the store event payload.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Compact JSON string stored as the redacted event payload.
    func payloadString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw WorkspaceGuardError.storeRecordFailed(reason: "manifest payload is not valid UTF-8")
        }
        return string
    }

    static func decode(from data: Data) throws -> WorkspaceManifest {
        try JSONDecoder().decode(WorkspaceManifest.self, from: data)
    }
}
