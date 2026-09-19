import Foundation
import SQLite3

/// Transactional SQLite-backed repository for tasks, dependencies, attempts, and agent profiles.
public final class SQLiteTaskStore: CodingTaskRepository, @unchecked Sendable {
    private let queue: DispatchQueue
    private var db: OpaquePointer?
    private var isClosed: Bool = false
    private let isMemory: Bool

    private init(db: OpaquePointer, isMemory: Bool) {
        self.db = db
        self.isMemory = isMemory
        self.queue = DispatchQueue(label: "com.agenticsidebar.sqlitetaskstore-\(UUID().uuidString)")
    }

    deinit {
        closeSync()
    }

    /// Opens an in-memory SQLite store with all migrations applied.
    public static func inMemory() throws -> SQLiteTaskStore {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_MEMORY
        guard sqlite3_open_v2(":memory:", &db, flags, nil) == SQLITE_OK, let db else {
            let msg = db != nil ? String(cString: sqlite3_errmsg(db)) : "Unable to open in-memory database"
            if let db { sqlite3_close(db) }
            throw TaskRepositoryError.underlying(msg)
        }

        try configurePragmas(on: db)
        try TaskStoreMigrations.apply(migrations: TaskStoreMigrations.standardMigrations, to: db)
        return SQLiteTaskStore(db: db, isMemory: true)
    }

    /// Opens a disk-backed SQLite store at url with all migrations applied.
    public static func open(at url: URL) throws -> SQLiteTaskStore {
        try TaskStoreMigrations.validateDatabaseFile(at: url)

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let msg = db != nil ? String(cString: sqlite3_errmsg(db)) : "Unable to open database"
            if let db { sqlite3_close(db) }
            throw TaskRepositoryError.underlying(msg)
        }

        try configurePragmas(on: db)
        try TaskStoreMigrations.apply(migrations: TaskStoreMigrations.standardMigrations, to: db)
        return SQLiteTaskStore(db: db, isMemory: false)
    }

    private static func configurePragmas(on db: OpaquePointer) throws {
        try TaskStoreMigrations.execute("PRAGMA foreign_keys = ON;", on: db)
        try TaskStoreMigrations.execute("PRAGMA journal_mode = WAL;", on: db)
        try TaskStoreMigrations.execute("PRAGMA synchronous = NORMAL;", on: db)
        try TaskStoreMigrations.execute("PRAGMA busy_timeout = 5000;", on: db)
    }

    public func closeSync() {
        queue.sync {
            guard !isClosed, let db = self.db else { return }
            sqlite3_close(db)
            self.db = nil
            self.isClosed = true
        }
    }

    public func close() async {
        closeSync()
    }

    public func currentSchemaVersionSync() -> Int {
        queue.sync {
            guard let db else { return 0 }
            return TaskStoreMigrations.getSchemaVersion(of: db)
        }
    }

    // MARK: - CodingTaskRepository

    public func snapshot(projectID: UUID) async throws -> CodingBoardSnapshot {
        try queue.sync {
            try checkOpen()
            let tasks = try loadTasks(projectID: projectID)
            let dependencies = try loadDependencies(projectID: projectID)
            let activeAttempts = try loadActiveAttempts(projectID: projectID)
            return CodingBoardSnapshot(
                projectID: projectID,
                tasks: tasks,
                dependencies: dependencies,
                activeAttempts: activeAttempts
            )
        }
    }

    public func createTask(_ task: CodingTask) async throws {
        try queue.sync {
            try checkOpen()
            try executeTransaction {
                try insertTask(task)
                for criterion in task.criteria {
                    try insertCriterion(criterion)
                }
            }
        }
    }

    public func addDependency(_ dependency: TaskDependency) async throws {
        try queue.sync {
            try checkOpen()
            try executeTransaction {
                let sql = """
                    INSERT INTO task_dependencies (project_id, prerequisite_task_id, dependent_task_id)
                    VALUES (?, ?, ?);
                    """
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                try prepare(sql, &stmt)
                bindText(stmt, 1, dependency.projectID.uuidString)
                bindText(stmt, 2, dependency.prerequisiteTaskID.uuidString)
                bindText(stmt, 3, dependency.dependentTaskID.uuidString)
                try stepDone(stmt)
            }
        }
    }

    public func task(id: UUID) async throws -> CodingTask? {
        try queue.sync {
            try checkOpen()
            return try loadTask(id: id)
        }
    }

    public func attemptHistory(taskID: UUID) async throws -> [TaskAttempt] {
        try queue.sync {
            try checkOpen()
            let sql = """
                SELECT
                    id, task_id, attempt_sequence, role, provider_id, model_id,
                    variant_snapshot, workspace_id, generation, lease_owner,
                    lease_token, lease_expiry, started_at, ended_at, outcome,
                    tool_call_count, duration_seconds
                FROM task_attempts
                WHERE task_id = ?
                ORDER BY attempt_sequence ASC, started_at ASC;
                """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql, &stmt)
            bindText(stmt, 1, taskID.uuidString)

            var attempts: [TaskAttempt] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let attempt = parseAttempt(from: stmt!) {
                    attempts.append(attempt)
                }
            }
            return attempts
        }
    }

    public func endAttempt(
        taskID: UUID,
        attemptID: UUID,
        expectedVersion: Int,
        outcome: AttemptOutcome,
        toolCallCount: Int?,
        durationSeconds: Int?
    ) async throws -> CodingTask {
        try queue.sync {
            try checkOpen()
            return try executeTransaction {
                guard var task = try loadTask(id: taskID) else {
                    throw TaskRepositoryError.taskNotFound(taskID)
                }
                guard task.version == expectedVersion else {
                    throw TaskRepositoryError.staleVersion(taskID: taskID, expected: expectedVersion, actual: task.version)
                }
                guard try isAttemptActive(attemptID: attemptID, taskID: taskID) else {
                    throw TaskRepositoryError.attemptNotActive(taskID: taskID, attemptID: attemptID)
                }

                let sql = """
                    UPDATE task_attempts SET
                        ended_at = ?,
                        outcome = ?,
                        tool_call_count = ?,
                        duration_seconds = ?
                    WHERE id = ? AND task_id = ?;
                    """
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                try prepare(sql, &stmt)
                sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
                bindText(stmt, 2, outcome.rawValue)
                if let toolCallCount {
                    sqlite3_bind_int(stmt, 3, Int32(toolCallCount))
                } else {
                    sqlite3_bind_null(stmt, 3)
                }
                if let durationSeconds {
                    sqlite3_bind_int(stmt, 4, Int32(durationSeconds))
                } else {
                    sqlite3_bind_null(stmt, 4)
                }
                bindText(stmt, 5, attemptID.uuidString)
                bindText(stmt, 6, taskID.uuidString)
                try stepDone(stmt)

                task.version += 1
                task.updatedAt = Date()
                try updateTask(task)
                return task
            }
        }
    }

    public func transition(
        taskID: UUID,
        expectedVersion: Int,
        action: TaskAction,
        context: TaskTransitionContext
    ) async throws -> CodingTask {
        try queue.sync {
            try checkOpen()
            return try executeTransaction {
                guard let existing = try loadTask(id: taskID) else {
                    throw TaskRepositoryError.taskNotFound(taskID)
                }
                guard existing.version == expectedVersion else {
                    throw TaskRepositoryError.staleVersion(
                        taskID: taskID,
                        expected: expectedVersion,
                        actual: existing.version
                    )
                }

                let updated = try TaskStateMachine.transition(existing, action: action, context: context)
                try updateTask(updated)
                return updated
            }
        }
    }

    public func claimAttempt(
        taskID: UUID,
        expectedVersion: Int,
        attempt: TaskAttempt
    ) async throws -> TaskAttempt {
        try queue.sync {
            try checkOpen()
            return try executeTransaction {
                guard var task = try loadTask(id: taskID) else {
                    throw TaskRepositoryError.taskNotFound(taskID)
                }
                guard task.version == expectedVersion else {
                    throw TaskRepositoryError.staleVersion(
                        taskID: taskID,
                        expected: expectedVersion,
                        actual: task.version
                    )
                }
                guard task.status == .ready || task.status == .running else {
                    throw TaskRepositoryError.taskNotClaimable(taskID: taskID, status: task.status)
                }

                // Check for existing active attempt (outcome == .inProgress and ended_at IS NULL)
                if let active = try loadActiveAttempt(for: taskID) {
                    throw TaskRepositoryError.activeAttemptConflict(
                        taskID: taskID,
                        existingAttemptID: active.id
                    )
                }

                // Invariant: attempt generations increase monotonically per task.
                let maxGeneration = try maxAttemptGeneration(for: taskID)
                guard attempt.generation > maxGeneration else {
                    throw TaskRepositoryError.nonMonotonicGeneration(
                        taskID: taskID,
                        minimumExclusive: maxGeneration,
                        actual: attempt.generation
                    )
                }

                try insertAttempt(attempt)

                task.currentAttemptID = attempt.id
                task.version += 1
                task.updatedAt = Date()
                if task.status == .ready {
                    task.status = .running
                }
                try updateTask(task)

                return attempt
            }
        }
    }

    /// Acquires or renews the exclusive repository lease for an attempt identity.
    ///
    /// The lease stays bound to the `(taskID, attemptID)` pair that acquired it: only that exact
    /// identity may renew or release it, and a non-expired lease can never be taken over by a
    /// different identity. Lease expiry marks staleness instead of granting a takeover; an expired
    /// lease is reclaimable only once ownership is reconciled:
    /// - the held attempt reached a terminal outcome (any task may reclaim), or
    /// - the held attempt row is missing and the requester is the task recorded on the lease
    ///   (the owning task re-adopts its orphaned lease).
    ///
    /// A still-active attempt keeps its lease past expiry; crash-orphaned active attempts stay
    /// protected until recovery reconciles them.
    public func acquireRepositoryLease(
        repositoryPath: String,
        taskID: UUID,
        attemptID: UUID,
        leaseTimeoutSeconds: TimeInterval
    ) async throws {
        try queue.sync {
            try checkOpen()
            try executeTransaction {
                let now = Date().timeIntervalSince1970
                let expiry = now + leaseTimeoutSeconds

                let checkSql = "SELECT task_id, attempt_id, lease_expiry FROM repository_leases WHERE repository_path = ?;"
                var checkStmt: OpaquePointer?
                defer { sqlite3_finalize(checkStmt) }
                try prepare(checkSql, &checkStmt)
                bindText(checkStmt, 1, repositoryPath)

                if sqlite3_step(checkStmt) == SQLITE_ROW {
                    let heldByTaskID = UUID(uuidString: String(cString: sqlite3_column_text(checkStmt, 0)))
                    let heldByAttemptID: UUID?
                    if let text = sqlite3_column_text(checkStmt, 1) {
                        heldByAttemptID = UUID(uuidString: String(cString: text))
                    } else {
                        heldByAttemptID = nil
                    }
                    let isSameOwner = heldByTaskID == taskID && heldByAttemptID == attemptID
                    if !isSameOwner {
                        guard let heldByTaskID else {
                            throw TaskRepositoryError.storeCorrupt("Repository lease for \(repositoryPath) has an invalid owner")
                        }
                        let heldExpiry = sqlite3_column_double(checkStmt, 2)
                        let isExpired = heldExpiry <= now
                        let canReclaim =
                            isExpired
                            ? try canReclaimExpiredLease(
                                heldByAttemptID: heldByAttemptID,
                                heldByTaskID: heldByTaskID,
                                requesterTaskID: taskID
                            )
                            : false
                        guard canReclaim else {
                            throw TaskRepositoryError.repositoryLeaseConflict(
                                repositoryPath: repositoryPath,
                                heldByTaskID: heldByTaskID
                            )
                        }
                    }
                }

                let replaceSql = """
                    INSERT INTO repository_leases (repository_path, task_id, attempt_id, acquired_at, lease_expiry)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(repository_path) DO UPDATE SET
                        task_id = excluded.task_id,
                        attempt_id = excluded.attempt_id,
                        acquired_at = excluded.acquired_at,
                        lease_expiry = excluded.lease_expiry;
                    """
                var replaceStmt: OpaquePointer?
                defer { sqlite3_finalize(replaceStmt) }
                try prepare(replaceSql, &replaceStmt)
                bindText(replaceStmt, 1, repositoryPath)
                bindText(replaceStmt, 2, taskID.uuidString)
                bindText(replaceStmt, 3, attemptID.uuidString)
                sqlite3_bind_double(replaceStmt, 4, now)
                sqlite3_bind_double(replaceStmt, 5, expiry)
                try stepDone(replaceStmt)
            }
        }
    }

    public func releaseRepositoryLease(repositoryPath: String, taskID: UUID, attemptID: UUID) async throws {
        try queue.sync {
            try checkOpen()
            try executeTransaction {
                let sql = "DELETE FROM repository_leases WHERE repository_path = ? AND task_id = ? AND attempt_id = ?;"
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                try prepare(sql, &stmt)
                bindText(stmt, 1, repositoryPath)
                bindText(stmt, 2, taskID.uuidString)
                bindText(stmt, 3, attemptID.uuidString)
                try stepDone(stmt)
            }
        }
    }

    public func appendEvent(_ event: CodingTaskEvent) async throws {
        try queue.sync {
            try checkOpen()
            try executeTransaction {
                let sql = """
                    INSERT INTO task_events (id, task_id, attempt_id, timestamp, kind, redacted_payload)
                    VALUES (?, ?, ?, ?, ?, ?);
                    """
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                try prepare(sql, &stmt)
                bindText(stmt, 1, event.id.uuidString)
                bindText(stmt, 2, event.taskID.uuidString)
                if let attemptID = event.attemptID {
                    bindText(stmt, 3, attemptID.uuidString)
                } else {
                    sqlite3_bind_null(stmt, 3)
                }
                sqlite3_bind_double(stmt, 4, event.timestamp.timeIntervalSince1970)
                bindText(stmt, 5, event.kind)
                bindText(stmt, 6, event.redactedPayload)
                try stepDone(stmt)
            }
        }
    }

    public func recordEvidence(_ evidence: VerificationEvidence) async throws {
        try queue.sync {
            try checkOpen()
            try executeTransaction {
                let sql = """
                    INSERT INTO verification_evidence (id, task_id, attempt_id, recipe_name, passed, details_redacted, recorded_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?);
                    """
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                try prepare(sql, &stmt)
                bindText(stmt, 1, evidence.id.uuidString)
                bindText(stmt, 2, evidence.taskID.uuidString)
                bindText(stmt, 3, evidence.attemptID.uuidString)
                bindText(stmt, 4, evidence.recipeName)
                sqlite3_bind_int(stmt, 5, evidence.passed ? 1 : 0)
                bindText(stmt, 6, evidence.detailsRedacted)
                sqlite3_bind_double(stmt, 7, evidence.recordedAt.timeIntervalSince1970)
                try stepDone(stmt)
            }
        }
    }

    public func saveAgentProfile(_ profile: AgentProfile) async throws {
        try queue.sync {
            try checkOpen()
            try executeTransaction {
                let capsData = try JSONEncoder().encode(profile.capabilities)
                let capsString = String(data: capsData, encoding: .utf8) ?? "[]"

                let sql = """
                    INSERT INTO agent_profiles (id, name, role, capabilities, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        role = excluded.role,
                        capabilities = excluded.capabilities;
                    """
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                try prepare(sql, &stmt)
                bindText(stmt, 1, profile.id.uuidString)
                bindText(stmt, 2, profile.name)
                bindText(stmt, 3, profile.role.rawValue)
                bindText(stmt, 4, capsString)
                sqlite3_bind_double(stmt, 5, profile.createdAt.timeIntervalSince1970)
                try stepDone(stmt)
            }
        }
    }

    public func loadAgentProfile(id: UUID) async throws -> AgentProfile? {
        try queue.sync {
            try checkOpen()
            let sql = "SELECT id, name, role, capabilities, created_at FROM agent_profiles WHERE id = ?;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql, &stmt)
            bindText(stmt, 1, id.uuidString)

            if sqlite3_step(stmt) == SQLITE_ROW {
                let idStr = String(cString: sqlite3_column_text(stmt, 0))
                let name = String(cString: sqlite3_column_text(stmt, 1))
                let roleStr = String(cString: sqlite3_column_text(stmt, 2))
                let capsStr = String(cString: sqlite3_column_text(stmt, 3))
                let createdAtSec = sqlite3_column_double(stmt, 4)

                guard let profileID = UUID(uuidString: idStr),
                    let role = AgentRole(rawValue: roleStr)
                else {
                    return nil
                }
                let caps = (try? JSONDecoder().decode([String].self, from: Data(capsStr.utf8))) ?? []
                return AgentProfile(
                    id: profileID,
                    name: name,
                    role: role,
                    capabilities: caps,
                    createdAt: Date(timeIntervalSince1970: createdAtSec)
                )
            }
            return nil
        }
    }

    // MARK: - Internal Helpers

    private func checkOpen() throws {
        guard !isClosed, db != nil else {
            throw TaskRepositoryError.readOnly("Store is closed")
        }
    }

    @discardableResult
    private func executeTransaction<T>(_ block: () throws -> T) throws -> T {
        guard let db else { throw TaskRepositoryError.readOnly("Store is closed") }
        try TaskStoreMigrations.execute("BEGIN IMMEDIATE TRANSACTION;", on: db)
        do {
            let result = try block()
            try TaskStoreMigrations.execute("COMMIT TRANSACTION;", on: db)
            return result
        } catch {
            try? TaskStoreMigrations.execute("ROLLBACK TRANSACTION;", on: db)
            throw error
        }
    }

    private func insertTask(_ task: CodingTask) throws {
        let sql = """
            INSERT INTO tasks (
                id, project_id, title, objective, priority, status, stage,
                block_reason, previous_stage, version, budget, current_attempt_id,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, &stmt)
        bindText(stmt, 1, task.id.uuidString)
        bindText(stmt, 2, task.projectID.uuidString)
        bindText(stmt, 3, task.title)
        bindText(stmt, 4, task.objective)
        sqlite3_bind_int(stmt, 5, Int32(task.priority))
        bindText(stmt, 6, task.status.rawValue)
        bindText(stmt, 7, task.stage.rawValue)

        if let blockReason = task.blockReason,
            let data = try? JSONEncoder().encode(blockReason),
            let str = String(data: data, encoding: .utf8)
        {
            bindText(stmt, 8, str)
        } else {
            sqlite3_bind_null(stmt, 8)
        }

        if let prevStage = task.previousStageBeforeBlock {
            bindText(stmt, 9, prevStage.rawValue)
        } else {
            sqlite3_bind_null(stmt, 9)
        }

        sqlite3_bind_int(stmt, 10, Int32(task.version))

        let budgetData = (try? JSONEncoder().encode(task.budget)) ?? Data()
        let budgetStr = String(data: budgetData, encoding: .utf8) ?? "{}"
        bindText(stmt, 11, budgetStr)

        if let attemptID = task.currentAttemptID {
            bindText(stmt, 12, attemptID.uuidString)
        } else {
            sqlite3_bind_null(stmt, 12)
        }

        sqlite3_bind_double(stmt, 13, task.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 14, task.updatedAt.timeIntervalSince1970)

        try stepDone(stmt)
    }

    private func updateTask(_ task: CodingTask) throws {
        let sql = """
            UPDATE tasks SET
                title = ?, objective = ?, priority = ?, status = ?, stage = ?,
                block_reason = ?, previous_stage = ?, version = ?, budget = ?,
                current_attempt_id = ?, updated_at = ?
            WHERE id = ?;
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, &stmt)
        bindText(stmt, 1, task.title)
        bindText(stmt, 2, task.objective)
        sqlite3_bind_int(stmt, 3, Int32(task.priority))
        bindText(stmt, 4, task.status.rawValue)
        bindText(stmt, 5, task.stage.rawValue)

        if let blockReason = task.blockReason,
            let data = try? JSONEncoder().encode(blockReason),
            let str = String(data: data, encoding: .utf8)
        {
            bindText(stmt, 6, str)
        } else {
            sqlite3_bind_null(stmt, 6)
        }

        if let prevStage = task.previousStageBeforeBlock {
            bindText(stmt, 7, prevStage.rawValue)
        } else {
            sqlite3_bind_null(stmt, 7)
        }

        sqlite3_bind_int(stmt, 8, Int32(task.version))

        let budgetData = (try? JSONEncoder().encode(task.budget)) ?? Data()
        let budgetStr = String(data: budgetData, encoding: .utf8) ?? "{}"
        bindText(stmt, 9, budgetStr)

        if let attemptID = task.currentAttemptID {
            bindText(stmt, 10, attemptID.uuidString)
        } else {
            sqlite3_bind_null(stmt, 10)
        }

        sqlite3_bind_double(stmt, 11, task.updatedAt.timeIntervalSince1970)
        bindText(stmt, 12, task.id.uuidString)

        try stepDone(stmt)
    }

    private func insertCriterion(_ criterion: CodingAcceptanceCriterion) throws {
        let sql = """
            INSERT INTO criteria (id, task_id, description, is_completed, evidence_id)
            VALUES (?, ?, ?, ?, ?);
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, &stmt)
        bindText(stmt, 1, criterion.id.uuidString)
        bindText(stmt, 2, criterion.taskID.uuidString)
        bindText(stmt, 3, criterion.description)
        sqlite3_bind_int(stmt, 4, criterion.isCompleted ? 1 : 0)
        if let evidenceID = criterion.evidenceID {
            bindText(stmt, 5, evidenceID.uuidString)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        try stepDone(stmt)
    }

    private func insertAttempt(_ attempt: TaskAttempt) throws {
        let sql = """
            INSERT INTO task_attempts (
                id, task_id, attempt_sequence, role, provider_id, model_id,
                variant_snapshot, workspace_id, generation, lease_owner,
                lease_token, lease_expiry, started_at, ended_at, outcome,
                tool_call_count, duration_seconds
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, &stmt)
        bindText(stmt, 1, attempt.id.uuidString)
        bindText(stmt, 2, attempt.taskID.uuidString)
        sqlite3_bind_int(stmt, 3, Int32(attempt.attemptSequence))
        bindText(stmt, 4, attempt.role.rawValue)
        bindText(stmt, 5, attempt.providerID)
        bindText(stmt, 6, attempt.modelID)

        if let variant = attempt.variantSnapshot {
            bindText(stmt, 7, variant)
        } else {
            sqlite3_bind_null(stmt, 7)
        }

        if let workspaceID = attempt.workspaceID {
            bindText(stmt, 8, workspaceID.uuidString)
        } else {
            sqlite3_bind_null(stmt, 8)
        }

        sqlite3_bind_int(stmt, 9, Int32(attempt.generation))

        if let leaseOwner = attempt.leaseOwner {
            bindText(stmt, 10, leaseOwner)
        } else {
            sqlite3_bind_null(stmt, 10)
        }

        if let leaseToken = attempt.leaseToken {
            bindText(stmt, 11, leaseToken)
        } else {
            sqlite3_bind_null(stmt, 11)
        }

        if let leaseExpiry = attempt.leaseExpiry {
            sqlite3_bind_double(stmt, 12, leaseExpiry.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 12)
        }

        sqlite3_bind_double(stmt, 13, attempt.startedAt.timeIntervalSince1970)

        if let ended = attempt.endedAt {
            sqlite3_bind_double(stmt, 14, ended.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 14)
        }

        bindText(stmt, 15, attempt.outcome.rawValue)

        if let toolCallCount = attempt.toolCallCount {
            sqlite3_bind_int(stmt, 16, Int32(toolCallCount))
        } else {
            sqlite3_bind_null(stmt, 16)
        }

        if let duration = attempt.durationSeconds {
            sqlite3_bind_int(stmt, 17, Int32(duration))
        } else {
            sqlite3_bind_null(stmt, 17)
        }

        try stepDone(stmt)
    }

    private func loadTask(id: UUID) throws -> CodingTask? {
        let sql = """
            SELECT
                id, project_id, title, objective, priority, status, stage,
                block_reason, previous_stage, version, budget, current_attempt_id,
                created_at, updated_at
            FROM tasks WHERE id = ?;
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, &stmt)
        bindText(stmt, 1, id.uuidString)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return try parseTask(from: stmt!)
        }
        return nil
    }

    private func loadTasks(projectID: UUID) throws -> [CodingTask] {
        let sql = """
            SELECT
                id, project_id, title, objective, priority, status, stage,
                block_reason, previous_stage, version, budget, current_attempt_id,
                created_at, updated_at
            FROM tasks WHERE project_id = ? ORDER BY priority DESC, created_at ASC;
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, &stmt)
        bindText(stmt, 1, projectID.uuidString)

        var tasks: [CodingTask] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let task = try parseTask(from: stmt!)
            tasks.append(task)
        }
        return tasks
    }

    private func parseTask(from stmt: OpaquePointer) throws -> CodingTask {
        let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0)))!
        let projectID = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 1)))!
        let title = String(cString: sqlite3_column_text(stmt, 2))
        let objective = String(cString: sqlite3_column_text(stmt, 3))
        let priority = Int(sqlite3_column_int(stmt, 4))
        let status = TaskStatus(rawValue: String(cString: sqlite3_column_text(stmt, 5)))!
        let stage = TaskStage(rawValue: String(cString: sqlite3_column_text(stmt, 6)))!

        var blockReason: TaskBlockReason?
        if let text = sqlite3_column_text(stmt, 7) {
            let str = String(cString: text)
            blockReason = try? JSONDecoder().decode(TaskBlockReason.self, from: Data(str.utf8))
        }

        var prevStage: TaskStage?
        if let text = sqlite3_column_text(stmt, 8) {
            prevStage = TaskStage(rawValue: String(cString: text))
        }

        let version = Int(sqlite3_column_int(stmt, 9))
        let budgetStr = String(cString: sqlite3_column_text(stmt, 10))
        let budget = (try? JSONDecoder().decode(ExecutionBudget.self, from: Data(budgetStr.utf8))) ?? ExecutionBudget()

        var currentAttemptID: UUID?
        if let text = sqlite3_column_text(stmt, 11) {
            currentAttemptID = UUID(uuidString: String(cString: text))
        }

        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13))

        let criteria = try loadCriteria(for: id)

        return CodingTask(
            id: id,
            projectID: projectID,
            title: title,
            objective: objective,
            priority: priority,
            status: status,
            stage: stage,
            blockReason: blockReason,
            previousStageBeforeBlock: prevStage,
            version: version,
            criteria: criteria,
            budget: budget,
            currentAttemptID: currentAttemptID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func loadCriteria(for taskID: UUID) throws -> [CodingAcceptanceCriterion] {
        let sql = "SELECT id, task_id, description, is_completed, evidence_id FROM criteria WHERE task_id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, &stmt)
        bindText(stmt, 1, taskID.uuidString)

        var criteria: [CodingAcceptanceCriterion] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0)))!
            let tid = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 1)))!
            let desc = String(cString: sqlite3_column_text(stmt, 2))
            let isComp = sqlite3_column_int(stmt, 3) == 1
            var evid: UUID?
            if let text = sqlite3_column_text(stmt, 4) {
                evid = UUID(uuidString: String(cString: text))
            }
            criteria.append(
                CodingAcceptanceCriterion(
                    id: id,
                    taskID: tid,
                    description: desc,
                    isCompleted: isComp,
                    evidenceID: evid
                ))
        }
        return criteria
    }

    private func loadDependencies(projectID: UUID) throws -> [TaskDependency] {
        let sql = "SELECT project_id, prerequisite_task_id, dependent_task_id FROM task_dependencies WHERE project_id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, &stmt)
        bindText(stmt, 1, projectID.uuidString)

        var deps: [TaskDependency] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let pid = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0)))!
            let prereq = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 1)))!
            let dep = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 2)))!
            deps.append(TaskDependency(projectID: pid, prerequisiteTaskID: prereq, dependentTaskID: dep))
        }
        return deps
    }

    private func loadActiveAttempt(for taskID: UUID) throws -> TaskAttempt? {
        let sql = """
            SELECT
                id, task_id, attempt_sequence, role, provider_id, model_id,
                variant_snapshot, workspace_id, generation, lease_owner,
                lease_token, lease_expiry, started_at, ended_at, outcome,
                tool_call_count, duration_seconds
            FROM task_attempts
            WHERE task_id = ? AND ended_at IS NULL AND outcome = 'inProgress';
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, &stmt)
        bindText(stmt, 1, taskID.uuidString)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return parseAttempt(from: stmt!)
        }
        return nil
    }

    private func loadActiveAttempts(projectID: UUID) throws -> [TaskAttempt] {
        let sql = """
            SELECT
                a.id, a.task_id, a.attempt_sequence, a.role, a.provider_id, a.model_id,
                a.variant_snapshot, a.workspace_id, a.generation, a.lease_owner,
                a.lease_token, a.lease_expiry, a.started_at, a.ended_at, a.outcome,
                a.tool_call_count, a.duration_seconds
            FROM task_attempts a
            JOIN tasks t ON t.id = a.task_id
            WHERE t.project_id = ? AND a.ended_at IS NULL AND a.outcome = 'inProgress';
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, &stmt)
        bindText(stmt, 1, projectID.uuidString)

        var attempts: [TaskAttempt] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let attempt = parseAttempt(from: stmt!) {
                attempts.append(attempt)
            }
        }
        return attempts
    }

    private func parseAttempt(from stmt: OpaquePointer) -> TaskAttempt? {
        guard let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))),
            let taskID = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 1))),
            let role = AgentRole(rawValue: String(cString: sqlite3_column_text(stmt, 3)))
        else {
            return nil
        }
        let seq = Int(sqlite3_column_int(stmt, 2))
        let providerID = String(cString: sqlite3_column_text(stmt, 4))
        let modelID = String(cString: sqlite3_column_text(stmt, 5))

        var variant: String?
        if let text = sqlite3_column_text(stmt, 6) {
            variant = String(cString: text)
        }

        var workspaceID: UUID?
        if let text = sqlite3_column_text(stmt, 7) {
            workspaceID = UUID(uuidString: String(cString: text))
        }

        let generation = Int(sqlite3_column_int(stmt, 8))

        var leaseOwner: String?
        if let text = sqlite3_column_text(stmt, 9) {
            leaseOwner = String(cString: text)
        }

        var leaseToken: String?
        if let text = sqlite3_column_text(stmt, 10) {
            leaseToken = String(cString: text)
        }

        var leaseExpiry: Date?
        if sqlite3_column_type(stmt, 11) != SQLITE_NULL {
            leaseExpiry = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))
        }

        let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12))

        var endedAt: Date?
        if sqlite3_column_type(stmt, 13) != SQLITE_NULL {
            endedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13))
        }

        let outcomeStr = String(cString: sqlite3_column_text(stmt, 14))
        let outcome = AttemptOutcome(rawValue: outcomeStr) ?? .inProgress

        var toolCallCount: Int?
        if sqlite3_column_type(stmt, 15) != SQLITE_NULL {
            toolCallCount = Int(sqlite3_column_int(stmt, 15))
        }

        var duration: Int?
        if sqlite3_column_type(stmt, 16) != SQLITE_NULL {
            duration = Int(sqlite3_column_int(stmt, 16))
        }

        return TaskAttempt(
            id: id,
            taskID: taskID,
            attemptSequence: seq,
            role: role,
            providerID: providerID,
            modelID: modelID,
            variantSnapshot: variant,
            workspaceID: workspaceID,
            generation: generation,
            leaseOwner: leaseOwner,
            leaseToken: leaseToken,
            leaseExpiry: leaseExpiry,
            startedAt: startedAt,
            endedAt: endedAt,
            outcome: outcome,
            toolCallCount: toolCallCount,
            durationSeconds: duration
        )
    }

    private func isAttemptActive(attemptID: UUID, taskID: UUID) throws -> Bool {
        let sql = "SELECT outcome, ended_at FROM task_attempts WHERE id = ? AND task_id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, &stmt)
        bindText(stmt, 1, attemptID.uuidString)
        bindText(stmt, 2, taskID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        let outcome = String(cString: sqlite3_column_text(stmt, 0))
        let isEnded = sqlite3_column_type(stmt, 1) != SQLITE_NULL
        return !isEnded && outcome == AttemptOutcome.inProgress.rawValue
    }

    /// Returns true when an expired lease may accept the requester because ownership is reconciled.
    ///
    /// A terminal attempt provably stopped writing, so any task may reclaim its lease after expiry.
    /// A lease whose attempt row is missing (or unreadable) is an unknown owner: only the task
    /// recorded on the lease may re-adopt it. An active attempt keeps the conflict.
    private func canReclaimExpiredLease(
        heldByAttemptID: UUID?,
        heldByTaskID: UUID,
        requesterTaskID: UUID
    ) throws -> Bool {
        guard let heldByAttemptID else {
            return requesterTaskID == heldByTaskID
        }
        let sql = "SELECT outcome FROM task_attempts WHERE id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, &stmt)
        bindText(stmt, 1, heldByAttemptID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else {
            return requesterTaskID == heldByTaskID
        }
        guard let outcome = AttemptOutcome(rawValue: String(cString: text)) else {
            return false
        }
        return outcome != .inProgress
    }

    private func maxAttemptGeneration(for taskID: UUID) throws -> Int {
        let sql = "SELECT COALESCE(MAX(generation), 0) FROM task_attempts WHERE task_id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, &stmt)
        bindText(stmt, 1, taskID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func prepare(_ sql: String, _ stmt: inout OpaquePointer?) throws {
        guard let db else { throw TaskRepositoryError.readOnly("Store is closed") }
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            if msg.contains("FOREIGN KEY") {
                throw TaskRepositoryError.foreignKeyViolation(msg)
            }
            throw TaskRepositoryError.underlying(msg)
        }
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) {
        sqlite3_bind_text(stmt, index, (text as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func stepDone(_ stmt: OpaquePointer?) throws {
        guard let db else { throw TaskRepositoryError.readOnly("Store is closed") }
        let result = sqlite3_step(stmt)
        if result != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            if (result & 0xFF) == SQLITE_CONSTRAINT || msg.contains("FOREIGN KEY") {
                throw TaskRepositoryError.foreignKeyViolation(msg)
            }
            throw TaskRepositoryError.underlying(msg)
        }
    }
}
