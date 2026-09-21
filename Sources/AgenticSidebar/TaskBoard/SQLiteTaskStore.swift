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

    /// Eşzamanlı kapatma: çağıran iş parçacığını kuyruk boşalana kadar tutar.
    ///
    /// `deinit` bu yolu kullanır; kuyrukta kısa txn işleri koştuğu için tutma
    /// sınırlıdır, kilitlenme yapmaz (kuyruk işleri `self`'i tutmaz, o yüzden
    /// `deinit` kuyruk üstünde koşamaz). Yine de yanlışlıkla kuyruk üstünden
    /// çağrı `dispatchPrecondition` ile gürültülü patlar (sessiz deadlock
    /// yerine). Eşzamansız bağlamda `close()` kullanılır, bu değil.
    public func closeSync() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {
            closeAssumingOnQueue()
        }
    }

    public func close() async {
        // `closeSync` buradan çağrılmaz: kuyruk üstünde koşan blok
        // `notOnQueue` önkoşuluna takılırdı. Kuyruğa eşzamansız verilir,
        // çağıran askıda bekler, iş parçacığı tutulmaz.
        await withCheckedContinuation { continuation in
            queue.async {
                self.closeAssumingOnQueue()
                continuation.resume()
            }
        }
    }

    /// Kuyruk üstünde varsayar; çağıran `queue.sync/async` içinden çağırmalıdır.
    private func closeAssumingOnQueue() {
        guard !isClosed, let db = self.db else { return }
        sqlite3_close(db)
        self.db = nil
        self.isClosed = true
    }

    public func currentSchemaVersionSync() -> Int {
        queue.sync {
            guard let db else { return 0 }
            return TaskStoreMigrations.getSchemaVersion(of: db)
        }
    }

    // MARK: - CodingTaskRepository

    public func saveProject(_ project: CodingProject) async throws {
        try queue.sync {
            try checkOpen()
            try executeTransaction {
                let refsData = try JSONEncoder().encode(project.protectedRefs)
                let refsString = String(data: refsData, encoding: .utf8) ?? "[]"
                let sql = """
                    INSERT INTO projects (id, name, repository_path, git_identity, protected_refs, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        repository_path = excluded.repository_path,
                        git_identity = excluded.git_identity,
                        protected_refs = excluded.protected_refs;
                    """
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                try prepare(sql, &stmt)
                bindText(stmt, 1, project.id.uuidString)
                bindText(stmt, 2, project.name)
                bindText(stmt, 3, project.repositoryPath)
                bindText(stmt, 4, project.gitIdentity)
                bindText(stmt, 5, refsString)
                sqlite3_bind_double(stmt, 6, project.createdAt.timeIntervalSince1970)
                try stepDone(stmt)
            }
        }
    }

    public func loadProject(id: UUID) async throws -> CodingProject? {
        try queue.sync {
            try checkOpen()
            return try loadProjectRow(id: id)
        }
    }

    public func listProjects() async throws -> [CodingProject] {
        try queue.sync {
            try checkOpen()
            let sql = "SELECT id, name, repository_path, git_identity, protected_refs, created_at FROM projects ORDER BY created_at ASC;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql, &stmt)
            var projects: [CodingProject] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let stmt else {
                    throw TaskRepositoryError.storeCorrupt("Project row is unreadable: missing statement")
                }
                if let project = try parseProject(from: stmt) {
                    projects.append(project)
                }
            }
            return projects
        }
    }

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

    public func updateTaskDetails(
        taskID: UUID,
        expectedVersion: Int,
        title: String,
        objective: String,
        priority: Int
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
                task.title = title
                task.objective = objective
                task.priority = priority
                task.version += 1
                task.updatedAt = Date()
                try updateTask(task)
                return task
            }
        }
    }

    public func deleteTask(taskID: UUID) async throws {
        try queue.sync {
            try checkOpen()
            try executeTransaction {
                guard try loadTask(id: taskID) != nil else {
                    throw TaskRepositoryError.taskNotFound(taskID)
                }
                // Önkoşul kenarı RESTRICT ile korunur; silinen göreve dokunan
                // tüm kenarlar önce kaldırılır, çocuk satırlar CASCADE ile gider.
                try deleteDependencies(involving: taskID)
                let sql = "DELETE FROM tasks WHERE id = ?;"
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                try prepare(sql, &stmt)
                bindText(stmt, 1, taskID.uuidString)
                try stepDone(stmt)
            }
        }
    }

    public func renameProject(id: UUID, name: String) async throws -> CodingProject {
        try queue.sync {
            try checkOpen()
            return try executeTransaction {
                guard try loadProjectRow(id: id) != nil else {
                    throw TaskRepositoryError.storeCorrupt("Project not found: \(id)")
                }
                let sql = "UPDATE projects SET name = ? WHERE id = ?;"
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                try prepare(sql, &stmt)
                bindText(stmt, 1, name)
                bindText(stmt, 2, id.uuidString)
                try stepDone(stmt)
                guard let renamed = try loadProjectRow(id: id) else {
                    throw TaskRepositoryError.storeCorrupt("Project not found: \(id)")
                }
                return renamed
            }
        }
    }

    public func deleteProject(id: UUID) async throws {
        try queue.sync {
            try checkOpen()
            try executeTransaction {
                guard try loadProjectRow(id: id) != nil else {
                    throw TaskRepositoryError.storeCorrupt("Project not found: \(id)")
                }
                for task in try loadTasks(projectID: id) {
                    try deleteDependencies(involving: task.id)
                    let deleteTaskSQL = "DELETE FROM tasks WHERE id = ?;"
                    var taskStmt: OpaquePointer?
                    defer { sqlite3_finalize(taskStmt) }
                    try prepare(deleteTaskSQL, &taskStmt)
                    bindText(taskStmt, 1, task.id.uuidString)
                    try stepDone(taskStmt)
                }
                let sql = "DELETE FROM projects WHERE id = ?;"
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                try prepare(sql, &stmt)
                bindText(stmt, 1, id.uuidString)
                try stepDone(stmt)
            }
        }
    }

    public func addDependency(_ dependency: TaskDependency) async throws {
        try queue.sync {
            try checkOpen()
            try executeTransaction {
                let tasks = try [dependency.prerequisiteTaskID, dependency.dependentTaskID].compactMap { try loadTask(id: $0) }
                // Preserve SQLite's foreign-key error when a task is missing.
                if tasks.count == 2 {
                    let existing = try loadDependencies(projectID: dependency.projectID)
                    _ = try TaskDependencyGraph.add(dependency, to: existing, tasks: tasks)
                }

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
                // The acceptance transition is the only place a human accept approval is
                // validated; persisting it in the same transaction makes the approval and
                // the task state commit or roll back together, so no rejected transition
                // can leave an orphan approval that authorizes later work.
                if case .accept = action, let approval = context.humanApproval {
                    try insertApprovalIfAbsent(approval)
                }
                return updated
            }
        }
    }

    public func setCriterionCompletion(
        taskID: UUID,
        criterionID: UUID,
        isCompleted: Bool,
        expectedVersion: Int
    ) async throws -> CodingTask {
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
                guard let index = task.criteria.firstIndex(where: { $0.id == criterionID }) else {
                    throw TaskRepositoryError.underlying(
                        "criterion \(criterionID.uuidString) not found for task \(taskID.uuidString)"
                    )
                }

                let sql = "UPDATE criteria SET is_completed = ? WHERE id = ? AND task_id = ?;"
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                try prepare(sql, &stmt)
                sqlite3_bind_int(stmt, 1, isCompleted ? 1 : 0)
                bindText(stmt, 2, criterionID.uuidString)
                bindText(stmt, 3, taskID.uuidString)
                try stepDone(stmt)
                guard sqlite3_changes(db) == 1 else {
                    throw TaskRepositoryError.underlying(
                        "criterion \(criterionID.uuidString) update affected \(sqlite3_changes(db)) rows"
                    )
                }

                task.criteria[index].isCompleted = isCompleted
                task.version += 1
                task.updatedAt = Date()
                try updateTask(task)
                return task
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
                    INSERT INTO verification_evidence (
                        id, task_id, attempt_id, recipe_name, step_name, status, passed,
                        exit_code, timed_out, details_redacted, workspace_fingerprint, blocked_by, recorded_at,
                        recipe_version
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                try prepare(sql, &stmt)
                bindText(stmt, 1, evidence.id.uuidString)
                if let taskID = evidence.taskID {
                    bindText(stmt, 2, taskID.uuidString)
                } else {
                    sqlite3_bind_null(stmt, 2)
                }
                if let attemptID = evidence.attemptID {
                    bindText(stmt, 3, attemptID.uuidString)
                } else {
                    sqlite3_bind_null(stmt, 3)
                }
                bindText(stmt, 4, evidence.recipeName)
                if let stepName = evidence.stepName {
                    bindText(stmt, 5, stepName)
                } else {
                    sqlite3_bind_null(stmt, 5)
                }
                bindText(stmt, 6, evidence.status.rawValue)
                sqlite3_bind_int(stmt, 7, evidence.passed ? 1 : 0)
                if let exitCode = evidence.exitCode {
                    sqlite3_bind_int(stmt, 8, exitCode)
                } else {
                    sqlite3_bind_null(stmt, 8)
                }
                sqlite3_bind_int(stmt, 9, evidence.timedOut ? 1 : 0)
                bindText(stmt, 10, evidence.detailsRedacted)
                if let fingerprint = evidence.workspaceFingerprint {
                    bindText(stmt, 11, fingerprint)
                } else {
                    sqlite3_bind_null(stmt, 11)
                }
                if let blockedBy = evidence.blockedBy {
                    bindText(stmt, 12, blockedBy)
                } else {
                    sqlite3_bind_null(stmt, 12)
                }
                sqlite3_bind_double(stmt, 13, evidence.recordedAt.timeIntervalSince1970)
                if let recipeVersion = evidence.recipeVersion {
                    sqlite3_bind_int(stmt, 14, Int32(recipeVersion))
                } else {
                    sqlite3_bind_null(stmt, 14)
                }
                try stepDone(stmt)
            }
        }
    }

    /// Loads one evidence entry by identity; nil when no such entry exists.
    public func evidence(id: UUID) async throws -> VerificationEvidence? {
        try queue.sync {
            try checkOpen()
            let sql = """
                SELECT
                    id, task_id, attempt_id, recipe_name, step_name, status, exit_code,
                    timed_out, details_redacted, workspace_fingerprint, blocked_by, recorded_at,
                    recipe_version
                FROM verification_evidence
                WHERE id = ?;
                """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql, &stmt)
            bindText(stmt, 1, id.uuidString)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return loadEvidence(stmt: stmt)
        }
    }

    /// Persists one review finding. A row that claims a dismissal without a human actor and
    /// reason is stored as-is; consumers must treat such a row as open.
    public func recordFinding(_ finding: ReviewFinding) async throws {
        try queue.sync {
            try checkOpen()
            try executeTransaction {
                let sql = """
                    INSERT INTO review_findings (
                        id, task_id, attempt_id, severity, summary, status,
                        dismissal_actor, dismissal_reason, dismissed_at, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                try prepare(sql, &stmt)
                bindText(stmt, 1, finding.id.uuidString)
                bindText(stmt, 2, finding.taskID.uuidString)
                if let attemptID = finding.attemptID {
                    bindText(stmt, 3, attemptID.uuidString)
                } else {
                    sqlite3_bind_null(stmt, 3)
                }
                bindText(stmt, 4, finding.severity.rawValue)
                bindText(stmt, 5, finding.summary)
                bindText(stmt, 6, finding.status.rawValue)
                bindOptionalText(stmt, 7, finding.dismissalActor)
                bindOptionalText(stmt, 8, finding.dismissalReason)
                if let dismissedAt = finding.dismissedAt {
                    sqlite3_bind_double(stmt, 9, dismissedAt.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(stmt, 9)
                }
                sqlite3_bind_double(stmt, 10, finding.createdAt.timeIntervalSince1970)
                try stepDone(stmt)
            }
        }
    }

    /// Loads every finding for a task, oldest first.
    public func findings(taskID: UUID) async throws -> [ReviewFinding] {
        try queue.sync {
            try checkOpen()
            return try loadFindings(taskID: taskID)
        }
    }

    /// Applies an explicit human dismissal, refusing to record one without actor and reason.
    ///
    /// An already validly dismissed finding is refused instead of overwritten; a persisted row
    /// whose dismissal lacks a human record counts as open, so it may be dismissed properly.
    public func dismissFinding(
        findingID: UUID,
        actor: String,
        reason: String,
        at date: Date
    ) async throws -> ReviewFinding {
        try queue.sync {
            try checkOpen()
            return try executeTransaction {
                guard let finding = try loadFinding(id: findingID) else {
                    throw TaskRepositoryError.findingNotFound(findingID)
                }
                guard finding.isOpen else {
                    throw TaskRepositoryError.findingAlreadyDismissed(findingID: findingID)
                }
                let dismissed = try finding.dismissed(by: actor, reason: reason, at: date)
                let sql = """
                    UPDATE review_findings SET
                        status = ?, dismissal_actor = ?, dismissal_reason = ?, dismissed_at = ?
                    WHERE id = ?;
                    """
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                try prepare(sql, &stmt)
                bindText(stmt, 1, dismissed.status.rawValue)
                bindOptionalText(stmt, 2, dismissed.dismissalActor)
                bindOptionalText(stmt, 3, dismissed.dismissalReason)
                sqlite3_bind_double(stmt, 4, date.timeIntervalSince1970)
                bindText(stmt, 5, findingID.uuidString)
                try stepDone(stmt)
                return dismissed
            }
        }
    }

    /// Persists one scoped approval record, refusing one without a human actor.
    public func recordApproval(_ approval: TaskApproval) async throws {
        try queue.sync {
            try checkOpen()
            let actor = approval.actor.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !actor.isEmpty else {
                throw TaskRepositoryError.invalidApprovalActor(approvalID: approval.id)
            }
            try executeTransaction {
                try insertApproval(approval)
            }
        }
    }

    /// Inserts an approval row inside the caller's transaction unless its identity is already
    /// recorded, so an approval that already authorized this exact content is never duplicated.
    ///
    /// The human-actor invariant is enforced here as well as in `recordApproval`: an accept
    /// transition must not be able to persist an approval that names no human.
    private func insertApprovalIfAbsent(_ approval: TaskApproval) throws {
        let actor = approval.actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !actor.isEmpty else {
            throw TaskRepositoryError.invalidApprovalActor(approvalID: approval.id)
        }
        let existsSql = "SELECT 1 FROM task_approvals WHERE id = ? LIMIT 1;"
        var existsStmt: OpaquePointer?
        defer { sqlite3_finalize(existsStmt) }
        try prepare(existsSql, &existsStmt)
        bindText(existsStmt, 1, approval.id.uuidString)
        if sqlite3_step(existsStmt) == SQLITE_ROW {
            return
        }
        try insertApproval(approval)
    }

    private func insertApproval(_ approval: TaskApproval) throws {
        let sql = """
            INSERT INTO task_approvals (id, task_id, attempt_id, fingerprint, actor, timestamp, action)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, &stmt)
        bindText(stmt, 1, approval.id.uuidString)
        bindText(stmt, 2, approval.taskID.uuidString)
        bindText(stmt, 3, approval.attemptID.uuidString)
        bindText(stmt, 4, approval.fingerprint)
        bindText(stmt, 5, approval.actor)
        sqlite3_bind_double(stmt, 6, approval.timestamp.timeIntervalSince1970)
        bindText(stmt, 7, approval.action.rawValue)
        try stepDone(stmt)
    }

    /// Loads every approval for a task, oldest first.
    public func approvals(taskID: UUID) async throws -> [TaskApproval] {
        try queue.sync {
            try checkOpen()
            return try loadApprovals(taskID: taskID)
        }
    }

    private func loadEvidence(stmt: OpaquePointer?) -> VerificationEvidence? {
        guard let idText = optionalText(stmt, 0), let id = UUID(uuidString: idText) else { return nil }
        guard let recipeName = optionalText(stmt, 3) else { return nil }
        guard let statusText = optionalText(stmt, 5), let status = VerificationEvidenceStatus(rawValue: statusText) else {
            return nil
        }
        guard let details = optionalText(stmt, 8) else { return nil }
        let exitCode: Int32? = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_int(stmt, 6)
        let recipeVersion: Int? =
            sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 12))
        return VerificationEvidence(
            id: id,
            taskID: optionalText(stmt, 1).flatMap(UUID.init(uuidString:)),
            attemptID: optionalText(stmt, 2).flatMap(UUID.init(uuidString:)),
            recipeName: recipeName,
            stepName: optionalText(stmt, 4),
            status: status,
            exitCode: exitCode,
            timedOut: sqlite3_column_int(stmt, 7) != 0,
            detailsRedacted: details,
            workspaceFingerprint: optionalText(stmt, 9),
            blockedBy: optionalText(stmt, 10),
            recordedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11)),
            recipeVersion: recipeVersion
        )
    }

    private func optionalText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: text)
    }

    private func loadFinding(id: UUID) throws -> ReviewFinding? {
        let sql = """
            SELECT id, task_id, attempt_id, severity, summary, status,
                   dismissal_actor, dismissal_reason, dismissed_at, created_at
            FROM review_findings
            WHERE id = ?;
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, &stmt)
        bindText(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return try parseFinding(from: stmt!)
    }

    private func loadFindings(taskID: UUID) throws -> [ReviewFinding] {
        let sql = """
            SELECT id, task_id, attempt_id, severity, summary, status,
                   dismissal_actor, dismissal_reason, dismissed_at, created_at
            FROM review_findings
            WHERE task_id = ?
            ORDER BY created_at ASC, id ASC;
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, &stmt)
        bindText(stmt, 1, taskID.uuidString)
        var findings: [ReviewFinding] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            findings.append(try parseFinding(from: stmt!))
        }
        return findings
    }

    private func parseFinding(from stmt: OpaquePointer) throws -> ReviewFinding {
        guard let idText = optionalText(stmt, 0), let id = UUID(uuidString: idText),
            let taskIDText = optionalText(stmt, 1), let taskID = UUID(uuidString: taskIDText)
        else {
            throw TaskRepositoryError.storeCorrupt("Review finding row has an invalid identity")
        }
        let attemptID = optionalText(stmt, 2).flatMap(UUID.init(uuidString:))
        guard let severityText = optionalText(stmt, 3), let severity = ReviewFindingSeverity(rawValue: severityText) else {
            throw TaskRepositoryError.storeCorrupt("Review finding \(id) has an invalid severity")
        }
        guard let summary = optionalText(stmt, 4) else {
            throw TaskRepositoryError.storeCorrupt("Review finding \(id) has no summary")
        }
        guard let statusText = optionalText(stmt, 5), let status = ReviewFindingStatus(rawValue: statusText) else {
            throw TaskRepositoryError.storeCorrupt("Review finding \(id) has an invalid status")
        }
        let dismissedAt: Date? =
            sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
        return ReviewFinding(
            id: id,
            taskID: taskID,
            attemptID: attemptID,
            severity: severity,
            summary: summary,
            status: status,
            dismissalActor: optionalText(stmt, 6),
            dismissalReason: optionalText(stmt, 7),
            dismissedAt: dismissedAt,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
        )
    }

    private func loadApprovals(taskID: UUID) throws -> [TaskApproval] {
        let sql = """
            SELECT id, task_id, attempt_id, fingerprint, actor, timestamp, action
            FROM task_approvals
            WHERE task_id = ?
            ORDER BY timestamp ASC, id ASC;
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, &stmt)
        bindText(stmt, 1, taskID.uuidString)
        var approvals: [TaskApproval] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = optionalText(stmt, 0), let id = UUID(uuidString: idText),
                let storedTaskIDText = optionalText(stmt, 1), let storedTaskID = UUID(uuidString: storedTaskIDText),
                let attemptIDText = optionalText(stmt, 2), let attemptID = UUID(uuidString: attemptIDText),
                let fingerprint = optionalText(stmt, 3),
                let actor = optionalText(stmt, 4),
                let actionText = optionalText(stmt, 6), let action = ApprovalAction(rawValue: actionText)
            else {
                throw TaskRepositoryError.storeCorrupt("Approval row for task \(taskID) is unreadable")
            }
            approvals.append(
                TaskApproval(
                    id: id,
                    taskID: storedTaskID,
                    attemptID: attemptID,
                    fingerprint: fingerprint,
                    actor: actor,
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                    action: action
                )
            )
        }
        return approvals
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ text: String?) {
        if let text {
            bindText(stmt, index, text)
        } else {
            sqlite3_bind_null(stmt, index)
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

    /// Göreve dokunan tüm bağımlılık kenarlarını kaldırır; çağıran işlem
    /// içinden çağırmalıdır. Önkoşul kenarı RESTRICT ile korunduğu için
    /// görev satırı silinmeden önce kenarların gitmesi şarttır.
    private func deleteDependencies(involving taskID: UUID) throws {
        let sql = "DELETE FROM task_dependencies WHERE prerequisite_task_id = ? OR dependent_task_id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, &stmt)
        bindText(stmt, 1, taskID.uuidString)
        bindText(stmt, 2, taskID.uuidString)
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

    /// Tek proje satırını okur; kimliği bozuk satırda storeCorrupt fırlatır.
    private func loadProjectRow(id: UUID) throws -> CodingProject? {
        let sql = "SELECT id, name, repository_path, git_identity, protected_refs, created_at FROM projects WHERE id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, &stmt)
        bindText(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let stmt else {
            throw TaskRepositoryError.storeCorrupt("Project row is unreadable: missing statement")
        }
        return try parseProject(from: stmt)
    }

    /// Proje satırını ayrıştırır; eksik kimlikte nil döner ki eski satırlar atlanabilsin.
    private func parseProject(from stmt: OpaquePointer) throws -> CodingProject? {
        guard let idText = optionalText(stmt, 0), let id = UUID(uuidString: idText) else {
            throw TaskRepositoryError.storeCorrupt("Project row has an invalid identity")
        }
        guard let name = optionalText(stmt, 1),
            let repositoryPath = optionalText(stmt, 2),
            let gitIdentity = optionalText(stmt, 3)
        else {
            return nil
        }
        let refsText = optionalText(stmt, 4) ?? "[]"
        let protectedRefs = (try? JSONDecoder().decode([String].self, from: Data(refsText.utf8))) ?? []
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
        return CodingProject(
            id: id,
            name: name,
            repositoryPath: repositoryPath,
            gitIdentity: gitIdentity,
            protectedRefs: protectedRefs,
            createdAt: createdAt
        )
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
            guard let stmt else {
                throw TaskRepositoryError.storeCorrupt("Task row is unreadable: missing statement")
            }
            return try parseTask(from: stmt)
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
            guard let stmt else {
                throw TaskRepositoryError.storeCorrupt("Task row is unreadable: missing statement")
            }
            let task = try parseTask(from: stmt)
            tasks.append(task)
        }
        return tasks
    }

    private func parseTask(from stmt: OpaquePointer) throws -> CodingTask {
        // Bozuk satırda çökmek yerine storeCorrupt fırlat
        guard let idText = optionalText(stmt, 0), let id = UUID(uuidString: idText),
            let projectIDText = optionalText(stmt, 1), let projectID = UUID(uuidString: projectIDText)
        else {
            throw TaskRepositoryError.storeCorrupt("Task row has an invalid identity")
        }
        guard let title = optionalText(stmt, 2) else {
            throw TaskRepositoryError.storeCorrupt("Task \(id) has no title")
        }
        guard let objective = optionalText(stmt, 3) else {
            throw TaskRepositoryError.storeCorrupt("Task \(id) has no objective")
        }
        let priority = Int(sqlite3_column_int(stmt, 4))
        guard let statusText = optionalText(stmt, 5), let status = TaskStatus(rawValue: statusText) else {
            throw TaskRepositoryError.storeCorrupt("Task \(id) has an invalid status")
        }
        guard let stageText = optionalText(stmt, 6), let stage = TaskStage(rawValue: stageText) else {
            throw TaskRepositoryError.storeCorrupt("Task \(id) has an invalid stage")
        }

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
        guard let budgetStr = optionalText(stmt, 10) else {
            throw TaskRepositoryError.storeCorrupt("Task \(id) has no budget")
        }
        let budget = (try? JSONDecoder().decode(ExecutionBudget.self, from: Data(budgetStr.utf8))) ?? ExecutionBudget()

        let currentAttemptID: UUID? = optionalText(stmt, 11).flatMap(UUID.init(uuidString:))

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
            guard let stmt else {
                throw TaskRepositoryError.storeCorrupt("Criterion row is unreadable: missing statement")
            }
            // Bozuk satırda çökmek yerine storeCorrupt fırlat
            guard let idText = optionalText(stmt, 0), let id = UUID(uuidString: idText),
                let tidText = optionalText(stmt, 1), let tid = UUID(uuidString: tidText)
            else {
                throw TaskRepositoryError.storeCorrupt("Criterion row has an invalid identity")
            }
            guard let desc = optionalText(stmt, 2) else {
                throw TaskRepositoryError.storeCorrupt("Criterion \(id) has no description")
            }
            let isComp = sqlite3_column_int(stmt, 3) == 1
            let evid: UUID? = optionalText(stmt, 4).flatMap(UUID.init(uuidString:))
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
            guard let stmt else {
                throw TaskRepositoryError.storeCorrupt("Dependency row is unreadable: missing statement")
            }
            // Bozuk satırda çökmek yerine storeCorrupt fırlat
            guard let pidText = optionalText(stmt, 0), let pid = UUID(uuidString: pidText),
                let prereqText = optionalText(stmt, 1), let prereq = UUID(uuidString: prereqText),
                let depText = optionalText(stmt, 2), let dep = UUID(uuidString: depText)
            else {
                throw TaskRepositoryError.storeCorrupt("Dependency row has an invalid identity")
            }
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
            guard let stmt else { return nil }
            return parseAttempt(from: stmt)
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
            guard let stmt else { break }
            if let attempt = parseAttempt(from: stmt) {
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
            if msg.contains("UNIQUE constraint") {
                throw TaskRepositoryError.duplicateRecord(msg)
            }
            if (result & 0xFF) == SQLITE_CONSTRAINT || msg.contains("FOREIGN KEY") {
                throw TaskRepositoryError.foreignKeyViolation(msg)
            }
            throw TaskRepositoryError.underlying(msg)
        }
    }
}
