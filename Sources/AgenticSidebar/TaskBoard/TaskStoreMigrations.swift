import Foundation
import SQLite3

/// Single schema migration definition.
public struct TaskStoreMigration: @unchecked Sendable {
    public let version: Int
    public let name: String
    public let apply: @Sendable (OpaquePointer) throws -> Void

    public init(
        version: Int,
        name: String,
        apply: @escaping @Sendable (OpaquePointer) throws -> Void
    ) {
        self.version = version
        self.name = name
        self.apply = apply
    }
}

/// Migration manager enforcing atomic version progression and transactional rollback.
public enum TaskStoreMigrations {
    public static let standardMigrations: [TaskStoreMigration] = [
        initialSchema,
        attemptNullableUsage,
        repositoryLeaseAttemptBinding,
    ]

    private static let initialSchema = TaskStoreMigration(version: 1, name: "InitialSchema_v1") { db in
        try execute(
            """
            CREATE TABLE IF NOT EXISTS projects (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                repository_path TEXT NOT NULL,
                git_identity TEXT NOT NULL,
                protected_refs TEXT NOT NULL,
                created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS tasks (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                title TEXT NOT NULL,
                objective TEXT NOT NULL,
                priority INTEGER NOT NULL,
                status TEXT NOT NULL,
                stage TEXT NOT NULL,
                block_reason TEXT,
                previous_stage TEXT,
                version INTEGER NOT NULL,
                budget TEXT NOT NULL,
                current_attempt_id TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS criteria (
                id TEXT PRIMARY KEY,
                task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                description TEXT NOT NULL,
                is_completed INTEGER NOT NULL,
                evidence_id TEXT
            );

            CREATE TABLE IF NOT EXISTS task_dependencies (
                project_id TEXT NOT NULL,
                prerequisite_task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE RESTRICT,
                dependent_task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                PRIMARY KEY (prerequisite_task_id, dependent_task_id)
            );

            CREATE TABLE IF NOT EXISTS task_attempts (
                id TEXT PRIMARY KEY,
                task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                attempt_sequence INTEGER NOT NULL,
                role TEXT NOT NULL,
                provider_id TEXT NOT NULL,
                model_id TEXT NOT NULL,
                variant_snapshot TEXT,
                workspace_id TEXT,
                generation INTEGER NOT NULL,
                lease_owner TEXT,
                lease_token TEXT,
                lease_expiry REAL,
                started_at REAL NOT NULL,
                ended_at REAL,
                outcome TEXT NOT NULL,
                tool_call_count INTEGER NOT NULL DEFAULT 0,
                duration_seconds INTEGER
            );

            CREATE TABLE IF NOT EXISTS task_events (
                id TEXT PRIMARY KEY,
                task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                attempt_id TEXT,
                timestamp REAL NOT NULL,
                kind TEXT NOT NULL,
                redacted_payload TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS verification_evidence (
                id TEXT PRIMARY KEY,
                task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                attempt_id TEXT NOT NULL,
                recipe_name TEXT NOT NULL,
                passed INTEGER NOT NULL,
                details_redacted TEXT NOT NULL,
                recorded_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS agent_profiles (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                role TEXT NOT NULL,
                capabilities TEXT NOT NULL,
                created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS repository_leases (
                repository_path TEXT PRIMARY KEY,
                task_id TEXT NOT NULL,
                acquired_at REAL NOT NULL,
                lease_expiry REAL NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_tasks_project ON tasks(project_id);
            CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
            CREATE INDEX IF NOT EXISTS idx_criteria_task ON criteria(task_id);
            CREATE INDEX IF NOT EXISTS idx_attempts_task ON task_attempts(task_id);
            CREATE INDEX IF NOT EXISTS idx_events_task ON task_events(task_id);
            CREATE INDEX IF NOT EXISTS idx_evidence_task ON verification_evidence(task_id);
            """,
            on: db
        )
    }

    /// Schema v2: attempt usage columns must keep "unknown" distinct from zero.
    private static let attemptNullableUsage = TaskStoreMigration(version: 2, name: "AttemptNullableUsage_v2") { db in
        try execute(
            """
            CREATE TABLE task_attempts_v2 (
                id TEXT PRIMARY KEY,
                task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                attempt_sequence INTEGER NOT NULL,
                role TEXT NOT NULL,
                provider_id TEXT NOT NULL,
                model_id TEXT NOT NULL,
                variant_snapshot TEXT,
                workspace_id TEXT,
                generation INTEGER NOT NULL,
                lease_owner TEXT,
                lease_token TEXT,
                lease_expiry REAL,
                started_at REAL NOT NULL,
                ended_at REAL,
                outcome TEXT NOT NULL,
                tool_call_count INTEGER,
                duration_seconds INTEGER
            );

            INSERT INTO task_attempts_v2 (
                id, task_id, attempt_sequence, role, provider_id, model_id,
                variant_snapshot, workspace_id, generation, lease_owner,
                lease_token, lease_expiry, started_at, ended_at, outcome,
                tool_call_count, duration_seconds
            )
            SELECT
                id, task_id, attempt_sequence, role, provider_id, model_id,
                variant_snapshot, workspace_id, generation, lease_owner,
                lease_token, lease_expiry, started_at, ended_at, outcome,
                tool_call_count, duration_seconds
            FROM task_attempts;

            DROP TABLE task_attempts;
            ALTER TABLE task_attempts_v2 RENAME TO task_attempts;
            CREATE INDEX IF NOT EXISTS idx_attempts_task ON task_attempts(task_id);
            """,
            on: db
        )
    }

    /// Schema v3: repository leases must be bound to the owning attempt, never just the task.
    private static let repositoryLeaseAttemptBinding = TaskStoreMigration(
        version: 3,
        name: "RepositoryLeaseAttemptBinding_v3"
    ) { db in
        try execute(
            """
            ALTER TABLE repository_leases ADD COLUMN attempt_id TEXT;

            UPDATE repository_leases
            SET attempt_id = (
                SELECT id FROM task_attempts
                WHERE task_attempts.task_id = repository_leases.task_id
                    AND task_attempts.ended_at IS NULL
                    AND task_attempts.outcome = 'inProgress'
                LIMIT 1
            );

            DELETE FROM repository_leases WHERE attempt_id IS NULL;
            """,
            on: db
        )
    }

    /// Validates file header if present to safeguard against corrupt stores.
    public static func validateDatabaseFile(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if fileSize > 0 {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let header = handle.readData(ofLength: 16)
            let validHeader = "SQLite format 3\0".data(using: .utf8)!
            if header != validHeader {
                throw TaskRepositoryError.storeCorrupt("Invalid SQLite header in \(url.lastPathComponent)")
            }
        }
    }

    /// Applies migrations up to date inside an atomic transaction.
    public static func apply(migrations: [TaskStoreMigration], to url: URL) throws {
        try validateDatabaseFile(at: url)

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let errorMsg = db != nil ? String(cString: sqlite3_errmsg(db)) : "Unable to open database"
            if let db { sqlite3_close(db) }
            throw TaskRepositoryError.underlying(errorMsg)
        }
        defer { sqlite3_close(db) }

        try apply(migrations: migrations, to: db)
    }

    /// Applies migrations to an open SQLite database pointer.
    public static func apply(migrations: [TaskStoreMigration], to db: OpaquePointer) throws {
        let currentVersion = getSchemaVersion(of: db)
        let sorted = migrations.sorted { $0.version < $1.version }

        for migration in sorted where migration.version > currentVersion {
            try execute("BEGIN IMMEDIATE TRANSACTION;", on: db)
            do {
                try migration.apply(db)
                try execute("PRAGMA user_version = \(migration.version);", on: db)
                try execute("COMMIT TRANSACTION;", on: db)
            } catch {
                try? execute("ROLLBACK TRANSACTION;", on: db)
                throw error
            }
        }
    }

    public static func getSchemaVersion(of db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    public static func execute(_ sql: String, on db: OpaquePointer) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errmsg) != SQLITE_OK {
            let message = errmsg.flatMap { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errmsg)
            if message.contains("FOREIGN KEY") {
                throw TaskRepositoryError.foreignKeyViolation(message)
            }
            throw TaskRepositoryError.underlying(message)
        }
    }
}
