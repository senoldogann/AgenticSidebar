import CryptoKit
import Foundation

/// Cooperative cancellation shared between the runner actor and its off-actor process
/// executor: `cancel()` may run while a step is waiting for its process to exit.
///
/// One flag belongs to exactly one run and is never shared between runs, so cancelling
/// one run can neither cancel another nor poison a future run.
private final class VerificationCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.withLock { cancelled = true }
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }
}

/// Stable identity of exactly one verification run.
struct VerificationRunID: Sendable, Hashable {
    let rawValue: UUID
}

/// Typed refusals raised before a run may start or continue.
enum VerificationRunnerError: LocalizedError, Equatable, Sendable {
    /// A second run was requested while another run is in flight.
    case runAlreadyInFlight(activeRunID: VerificationRunID)
    /// The same run identity is already executing; a run may execute exactly once.
    case runAlreadyExecuting(runID: VerificationRunID)
    /// The runner does not understand the recipe version and must never guess at it.
    case unsupportedRecipeVersion(recipe: String, version: Int, supported: Int)
    /// The run identity does not match any in-flight run.
    case unknownRun(runID: VerificationRunID)

    var errorDescription: String? {
        switch self {
        case .runAlreadyInFlight(let activeRunID):
            return "VERIFICATION_RUN_IN_FLIGHT: run \(activeRunID.rawValue.uuidString) is already in flight"
        case .runAlreadyExecuting(let runID):
            return "VERIFICATION_RUN_ALREADY_EXECUTING: run \(runID.rawValue.uuidString) is already executing"
        case .unsupportedRecipeVersion(let recipe, let version, let supported):
            return
                "VERIFICATION_UNSUPPORTED_RECIPE_VERSION: recipe \(recipe) version \(version) is not understood (supported: \(supported))"
        case .unknownRun(let runID):
            return "VERIFICATION_UNKNOWN_RUN: no run \(runID.rawValue.uuidString) is in flight"
        }
    }
}

/// Outcome of one bounded process invocation.
private struct VerificationStepOutcome: Sendable {
    let exitCode: Int32?
    let timedOut: Bool
    let cancelled: Bool
    let launchFailure: String?
    let standardOutput: String
    let standardError: String
    let outputWasTruncated: Bool
}

/// Secret redaction and clipping for recorded verification output.
enum VerificationOutputRedactor {
    /// Masks credential-shaped values before any output is persisted.
    ///
    /// Scheme-aware rules run first: a `Basic` or `Bearer` token is masked as a whole
    /// before the key/value rule sees the line, and the key/value rule refuses to swallow
    /// a scheme word itself, so `Authorization: Bearer <token>` and
    /// `{"authorization": "Basic <token>"}` can never leave the token unmasked behind a
    /// redacted scheme. The key/value rule tolerates quotes around the key and the value
    /// so JSON bodies (`{"token": "…"}`, `{"api_key": "…"}`) are masked as well.
    static func redact(_ text: String) -> String {
        let patterns: [(pattern: String, template: String)] = [
            (#"(?i)((?:basic|bearer)\s+)[A-Za-z0-9._~+/=-]{4,}"#, "$1<redacted>"),
            (
                #"(?i)("?(?:api[_-]?key|access[_-]?token|auth[_-]?token|token|secret|password|passwd|authorization)"?\s*[:=]\s*["']?)(?!["']?(?:basic|bearer)\b)\S+"#,
                "$1<redacted>"
            ),
            (#"AKIA[0-9A-Z]{16}"#, "<redacted>"),
            (#"gh[pousr]_[A-Za-z0-9]{20,}"#, "<redacted>"),
        ]
        var result = text
        for entry in patterns {
            guard let regex = try? NSRegularExpression(pattern: entry.pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: entry.template)
        }
        return result
    }

    /// Bounds the recorded text and marks the cut so a reader never mistakes it for the whole output.
    static func clip(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n[clipped]"
    }
}

/// Runs a trusted verification recipe against one workspace.
///
/// Concurrency: at most one run is in flight per runner. `beginRun` registers a run and
/// returns its identity; a second concurrent registration is refused with
/// `VerificationRunnerError.runAlreadyInFlight` instead of being queued, so two
/// verifications on one workspace can never interleave steps or corrupt each other's
/// fingerprint checks. A registered identity executes exactly once: a concurrent second
/// `run` for the same identity is refused with `VerificationRunnerError.runAlreadyExecuting`.
/// Cancellation is scoped to a single run identity (`cancel(runID:)`): it never touches
/// another run, it releases an identity that never started, and it is never a sticky flag
/// that poisons future runs.
///
/// Execution is ordered and argv-only: there is no shell anywhere in this type. Every
/// step gets a wall-clock deadline and a bounded, redacted output budget. A required
/// step that fails prevents its dependents, which are recorded as skipped with the
/// blocker name. Each evidence entry carries the workspace fingerprint observed before
/// the step; when that fingerprint changes between steps the runner stops without a
/// pass. After the final step the fingerprint is recomputed and compared: when it
/// drifted, the last passed step is recorded as failed, because the tested revision is
/// no longer the revision under test.
actor VerificationRunner {
    private static let pollInterval: TimeInterval = 0.05
    private static let fingerprintTimeout: TimeInterval = 10
    /// Adım başı süreler ne olursa olsun tek koşunun üst sınırı: takılan bir
    /// süreç zinciri koşuyu süresiz uzatamaz. Aşımda kalan adımlar `skipped`
    /// yazılır (`blockedBy=runDeadlineExceeded`).
    private static let maximumRunDuration: TimeInterval = 600
    /// Chunk size used while streaming an untracked file through SHA-256.
    private static let untrackedFileChunkBytes = 1_048_576

    private let maxOutputBytes: Int
    private let maxDetailsCharacters: Int
    private let terminationGrace: TimeInterval
    private let drainGrace: TimeInterval
    private let gitRunner: GitCommandRunner

    private var activeRun: ActiveRun?

    private struct ActiveRun {
        let id: VerificationRunID
        let recipe: VerificationRecipe
        let workspace: URL
        let cancellation: VerificationCancellationFlag
        var isExecuting: Bool
    }

    init(
        maxOutputBytes: Int,
        maxDetailsCharacters: Int,
        terminationGrace: TimeInterval,
        drainGrace: TimeInterval,
        gitExecutableDirectory: URL
    ) {
        self.maxOutputBytes = maxOutputBytes
        self.maxDetailsCharacters = maxDetailsCharacters
        self.terminationGrace = terminationGrace
        self.drainGrace = drainGrace
        self.gitRunner = GitCommandRunner(executableDirectory: gitExecutableDirectory, maxOutputBytes: maxOutputBytes)
    }

    /// Registers one run and returns its identity.
    ///
    /// A second registration while a run is in flight is refused with
    /// `.runAlreadyInFlight`; the runner deliberately rejects rather than queues, so the
    /// caller learns immediately that its second request was not started. An unknown
    /// recipe version is refused here, before anything can run or be recorded as passed.
    func beginRun(recipe: VerificationRecipe, workspace: URL) throws -> VerificationRunID {
        if let activeRun {
            throw VerificationRunnerError.runAlreadyInFlight(activeRunID: activeRun.id)
        }
        guard (1...VerificationRecipe.currentVersion).contains(recipe.version) else {
            throw VerificationRunnerError.unsupportedRecipeVersion(
                recipe: recipe.name,
                version: recipe.version,
                supported: VerificationRecipe.currentVersion
            )
        }
        let runID = VerificationRunID(rawValue: UUID())
        activeRun = ActiveRun(
            id: runID,
            recipe: recipe,
            workspace: workspace,
            cancellation: VerificationCancellationFlag(),
            isExecuting: false
        )
        return runID
    }

    /// Executes a registered run to completion and deregisters it.
    ///
    /// The registration is marked executing in the same actor-isolated stretch that
    /// checks it, before the first `await`, so a concurrent second `run` of the same
    /// identity is refused with `.runAlreadyExecuting` instead of executing the recipe
    /// twice. A refused call never returns evidence and never touches the active run.
    func run(_ runID: VerificationRunID) async throws -> [VerificationEvidence] {
        guard let activeRun, activeRun.id == runID else {
            throw VerificationRunnerError.unknownRun(runID: runID)
        }
        guard !activeRun.isExecuting else {
            throw VerificationRunnerError.runAlreadyExecuting(runID: runID)
        }
        self.activeRun?.isExecuting = true
        defer {
            if self.activeRun?.id == runID {
                self.activeRun = nil
            }
        }
        return await execute(
            recipe: activeRun.recipe,
            workspace: activeRun.workspace,
            cancellation: activeRun.cancellation
        )
    }

    /// Registers and executes one verification; a concurrent second run is refused.
    func verify(recipe: VerificationRecipe, workspace: URL) async throws -> [VerificationEvidence] {
        let runID = try beginRun(recipe: recipe, workspace: workspace)
        return try await run(runID)
    }

    /// Requests cancellation of exactly one run.
    ///
    /// An executing run gets its flag set and is deregistered when `run` returns. A run
    /// that was registered but never started is deregistered here, so a token that will
    /// never execute cannot occupy the single-flight slot forever. A run that already
    /// finished, or an identity this runner never minted, is a no-op: cancellation can
    /// never leak into another run.
    func cancel(runID: VerificationRunID) {
        guard let activeRun, activeRun.id == runID else { return }
        guard activeRun.isExecuting else {
            self.activeRun = nil
            return
        }
        activeRun.cancellation.cancel()
    }

    private func execute(
        recipe: VerificationRecipe,
        workspace: URL,
        cancellation: VerificationCancellationFlag
    ) async -> [VerificationEvidence] {
        let workspaceURL = workspace.standardizedFileURL.resolvingSymlinksInPath()
        var entries: [VerificationEvidence] = []

        guard let initialFingerprint = workspaceFingerprint(of: workspaceURL) else {
            for step in recipe.steps {
                entries.append(
                    makeEvidence(
                        recipe: recipe,
                        stepName: step.name,
                        status: .failed,
                        exitCode: nil,
                        timedOut: false,
                        details: renderedDetails(
                            step: step,
                            status: .failed,
                            exitCode: nil,
                            timedOut: false,
                            cancelled: false,
                            truncated: false,
                            launchFailure: nil,
                            reason: "workspace fingerprint unavailable; no revision can be verified",
                            standardOutput: "",
                            standardError: ""
                        ),
                        fingerprint: nil,
                        blockedBy: nil
                    )
                )
            }
            appendRecipeSkips(recipe: recipe, entries: &entries, blockedBy: nil)
            return entries
        }

        var recordedFingerprint = initialFingerprint
        var blocker: String?
        var lastExecutedIndex: Int?
        let runDeadline = Date().addingTimeInterval(Self.maximumRunDuration)

        for step in recipe.steps {
            if cancellation.isCancelled, blocker == nil {
                blocker = "cancellation"
            }
            // Üst süre denetimi: iptal gibi yapışkan değil, yalnızca bu koşunun
            // kalan adımlarını atlatır.
            if blocker == nil, Date() >= runDeadline {
                blocker = "runDeadlineExceeded"
            }
            if let blocker {
                entries.append(
                    makeEvidence(
                        recipe: recipe,
                        stepName: step.name,
                        status: .skipped,
                        exitCode: nil,
                        timedOut: false,
                        details: "step=\(step.name) status=skipped blockedBy=\(blocker)",
                        fingerprint: recordedFingerprint,
                        blockedBy: blocker
                    )
                )
                continue
            }
            guard let workingDirectory = resolveWorkingDirectory(step.relativeWorkingDirectory, in: workspaceURL) else {
                entries.append(
                    makeEvidence(
                        recipe: recipe,
                        stepName: step.name,
                        status: .failed,
                        exitCode: nil,
                        timedOut: false,
                        details: renderedDetails(
                            step: step,
                            status: .failed,
                            exitCode: nil,
                            timedOut: false,
                            cancelled: false,
                            truncated: false,
                            launchFailure: nil,
                            reason: "working directory \(step.relativeWorkingDirectory) escapes the workspace",
                            standardOutput: "",
                            standardError: ""
                        ),
                        fingerprint: recordedFingerprint,
                        blockedBy: nil
                    )
                )
                if step.required {
                    blocker = step.name
                }
                continue
            }
            guard let currentFingerprint = workspaceFingerprint(of: workspaceURL) else {
                entries.append(
                    makeEvidence(
                        recipe: recipe,
                        stepName: step.name,
                        status: .failed,
                        exitCode: nil,
                        timedOut: false,
                        details: renderedDetails(
                            step: step,
                            status: .failed,
                            exitCode: nil,
                            timedOut: false,
                            cancelled: false,
                            truncated: false,
                            launchFailure: nil,
                            reason: "workspace fingerprint unavailable; no revision can be verified",
                            standardOutput: "",
                            standardError: ""
                        ),
                        fingerprint: nil,
                        blockedBy: nil
                    )
                )
                if step.required {
                    blocker = step.name
                }
                continue
            }
            if currentFingerprint != recordedFingerprint {
                entries.append(
                    makeEvidence(
                        recipe: recipe,
                        stepName: step.name,
                        status: .skipped,
                        exitCode: nil,
                        timedOut: false,
                        details:
                            "step=\(step.name) status=skipped blockedBy=workspaceFingerprint workspace fingerprint changed between steps (\(recordedFingerprint) -> \(currentFingerprint))",
                        fingerprint: currentFingerprint,
                        blockedBy: "workspaceFingerprint"
                    )
                )
                blocker = "workspaceFingerprint"
                continue
            }

            let outcome = await runStep(step, workingDirectory: workingDirectory, cancellation: cancellation)
            let status: VerificationEvidenceStatus =
                (outcome.launchFailure == nil && outcome.exitCode == 0 && !outcome.timedOut && !outcome.cancelled)
                ? .passed : .failed
            entries.append(
                makeEvidence(
                    recipe: recipe,
                    stepName: step.name,
                    status: status,
                    exitCode: outcome.exitCode,
                    timedOut: outcome.timedOut,
                    details: renderedDetails(
                        step: step,
                        status: status,
                        exitCode: outcome.exitCode,
                        timedOut: outcome.timedOut,
                        cancelled: outcome.cancelled,
                        truncated: outcome.outputWasTruncated,
                        launchFailure: outcome.launchFailure,
                        reason: nil,
                        standardOutput: outcome.standardOutput,
                        standardError: outcome.standardError
                    ),
                    fingerprint: currentFingerprint,
                    blockedBy: nil
                )
            )
            recordedFingerprint = currentFingerprint
            lastExecutedIndex = entries.count - 1
            if status != .passed, step.required {
                blocker = outcome.cancelled ? "cancellation" : step.name
            }
        }

        applyPostFinalFingerprintCheck(
            workspaceURL: workspaceURL,
            recordedFingerprint: recordedFingerprint,
            lastExecutedIndex: lastExecutedIndex,
            entries: &entries
        )

        appendRecipeSkips(recipe: recipe, entries: &entries, blockedBy: blocker)
        return entries
    }

    /// Recomputes the fingerprint after the final step. A revision that changed while the
    /// last step was running (or after it) must not leave a PASS behind: the last passed
    /// entry is rewritten as failed with the drift recorded, and an unreadable final
    /// fingerprint fails the same way.
    private func applyPostFinalFingerprintCheck(
        workspaceURL: URL,
        recordedFingerprint: String,
        lastExecutedIndex: Int?,
        entries: inout [VerificationEvidence]
    ) {
        guard let lastExecutedIndex else { return }
        let previous = entries[lastExecutedIndex]
        guard previous.status == .passed else { return }
        guard let finalFingerprint = workspaceFingerprint(of: workspaceURL) else {
            entries[lastExecutedIndex] = rewritten(
                previous,
                status: .failed,
                details: previous.detailsRedacted
                    + "\nfinal workspace fingerprint unavailable after the last step; the tested revision cannot be confirmed"
            )
            return
        }
        guard finalFingerprint != recordedFingerprint else { return }
        entries[lastExecutedIndex] = rewritten(
            previous,
            status: .failed,
            details: previous.detailsRedacted
                + "\nfinal workspace fingerprint changed after the last step: \(recordedFingerprint) -> \(finalFingerprint)"
        )
    }

    // MARK: - Evidence assembly

    private func appendRecipeSkips(
        recipe: VerificationRecipe,
        entries: inout [VerificationEvidence],
        blockedBy: String?
    ) {
        for skip in recipe.skippedSteps {
            entries.append(
                makeEvidence(
                    recipe: recipe,
                    stepName: skip.name,
                    status: .skipped,
                    exitCode: nil,
                    timedOut: false,
                    details: "step=\(skip.name) status=skipped reason=\(skip.reason)",
                    fingerprint: nil,
                    blockedBy: blockedBy
                )
            )
        }
    }

    private func makeEvidence(
        recipe: VerificationRecipe,
        stepName: String,
        status: VerificationEvidenceStatus,
        exitCode: Int32?,
        timedOut: Bool,
        details: String,
        fingerprint: String?,
        blockedBy: String?
    ) -> VerificationEvidence {
        VerificationEvidence(
            recipeName: recipe.name,
            stepName: stepName,
            status: status,
            exitCode: exitCode,
            timedOut: timedOut,
            detailsRedacted: details,
            workspaceFingerprint: fingerprint,
            blockedBy: blockedBy,
            recipeVersion: recipe.version
        )
    }

    private func rewritten(
        _ evidence: VerificationEvidence,
        status: VerificationEvidenceStatus,
        details: String
    ) -> VerificationEvidence {
        VerificationEvidence(
            id: evidence.id,
            taskID: evidence.taskID,
            attemptID: evidence.attemptID,
            recipeName: evidence.recipeName,
            stepName: evidence.stepName,
            status: status,
            exitCode: evidence.exitCode,
            timedOut: evidence.timedOut,
            detailsRedacted: VerificationOutputRedactor.clip(details, limit: maxDetailsCharacters),
            workspaceFingerprint: evidence.workspaceFingerprint,
            blockedBy: evidence.blockedBy,
            recordedAt: evidence.recordedAt,
            recipeVersion: evidence.recipeVersion
        )
    }

    private func renderedDetails(
        step: VerificationStep,
        status: VerificationEvidenceStatus,
        exitCode: Int32?,
        timedOut: Bool,
        cancelled: Bool,
        truncated: Bool,
        launchFailure: String?,
        reason: String?,
        standardOutput: String,
        standardError: String
    ) -> String {
        var text =
            "step=\(step.name) executable=\(step.executable) status=\(status.rawValue) exit=\(exitCode.map(String.init) ?? "none") timedOut=\(timedOut) cancelled=\(cancelled) truncated=\(truncated)"
        if let reason {
            text += "\n\(reason)"
        }
        if let launchFailure {
            text += "\nunavailable: \(launchFailure)"
        }
        if !standardOutput.isEmpty {
            text += "\nstdout:\n\(standardOutput)"
        }
        if !standardError.isEmpty {
            text += "\nstderr:\n\(standardError)"
        }
        return VerificationOutputRedactor.clip(
            VerificationOutputRedactor.redact(text),
            limit: maxDetailsCharacters
        )
    }

    // MARK: - Workspace revision

    /// Complete revision of the workspace under test, or nil when it cannot be trusted.
    ///
    /// The SHA-256 payload is:
    /// 1. `git rev-parse HEAD`.
    /// 2. `git status --porcelain=v1 -z --untracked-files=all`: staged, modified, deleted,
    ///    renamed, conflicted and untracked non-ignored paths. Ignored files never appear,
    ///    so ignored build artifacts do not change the fingerprint.
    /// 3. `git diff HEAD --no-ext-diff --binary` for the tracked working-tree change.
    /// 4. For every untracked non-ignored file: its path plus `sha256=<digest>;bytes=<size>`
    ///    over the file's full byte stream, read in bounded chunks. Changing any byte of an
    ///    untracked file, including its tail, therefore changes the fingerprint.
    ///
    /// When a git invocation is refused, exits nonzero or reports clipped output, or when
    /// an untracked file listed by status cannot be read end to end — an open failure, a
    /// read error mid-stream, or a size that changed while reading — the fingerprint is
    /// unavailable: a truncated or partial revision must fail closed instead of hashing
    /// partial state.
    private func workspaceFingerprint(of workspace: URL) -> String? {
        guard FileManager.default.fileExists(atPath: workspace.path) else { return nil }
        guard let head = runGit(["rev-parse", "HEAD"], in: workspace),
            head.exitCode == 0, !head.outputWasTruncated
        else { return nil }
        guard let status = runGit(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: workspace),
            status.exitCode == 0, !status.outputWasTruncated
        else { return nil }
        guard let diff = runGit(["diff", "HEAD", "--no-ext-diff", "--binary"], in: workspace),
            diff.exitCode == 0, !diff.outputWasTruncated
        else { return nil }

        let untrackedPaths = Self.untrackedPaths(fromPorcelainZ: status.standardOutput)
        var untrackedDigests: [String] = []
        untrackedDigests.reserveCapacity(untrackedPaths.count)
        for path in untrackedPaths {
            guard let digest = untrackedFileDigest(in: workspace, relativePath: path) else { return nil }
            untrackedDigests.append("\(path)=\(digest)")
        }

        let payload = """
            head=\(head.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            status=\(status.standardOutput)
            diff=\(diff.standardOutput)
            untracked=\(untrackedDigests.joined(separator: "\n"))
            """
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Paths of untracked non-ignored entries in `git status --porcelain=v1 -z` output.
    ///
    /// Rename and copy records carry a second NUL-terminated source path; those records
    /// are consumed without ever being treated as untracked.
    private static func untrackedPaths(fromPorcelainZ output: String) -> [String] {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true)
        var paths: [String] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            var consumed = 1
            if record.count > 3 {
                let first = record[record.startIndex]
                let second = record[record.index(after: record.startIndex)]
                if first == "R" || first == "C" || second == "R" || second == "C" {
                    consumed = 2
                } else if first == "?" && second == "?" {
                    paths.append(String(record.dropFirst(3)))
                }
            }
            index += consumed
        }
        return paths
    }

    /// `sha256` of an untracked file's full byte stream, plus its total size.
    ///
    /// The file is streamed in bounded chunks, so an arbitrarily large untracked file
    /// neither loads into memory nor hides a tail change behind a prefix digest. A read
    /// error, a short read or a size that changed while reading makes the digest nil,
    /// and an unavailable digest makes the whole fingerprint nil: the runner fails closed
    /// instead of verifying a revision it cannot confirm.
    private func untrackedFileDigest(in workspace: URL, relativePath: String) -> String? {
        let fileURL = workspace.appendingPathComponent(relativePath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = (attributes[.size] as? NSNumber)?.int64Value
        else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        var readBytes: Int64 = 0
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: Self.untrackedFileChunkBytes)
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            readBytes += Int64(chunk.count)
        }
        guard readBytes == size else { return nil }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "sha256=\(digest);bytes=\(size)"
    }

    private func runGit(_ arguments: [String], in directory: URL) -> GitCommandResult? {
        try? gitRunner.run(
            executable: "git",
            arguments: arguments,
            directory: directory,
            timeout: Self.fingerprintTimeout
        )
    }

    private func resolveWorkingDirectory(_ relativePath: String, in workspace: URL) -> URL? {
        // Kaçış denetimi çözümleyiciyle paylaşılır ve sembolik bağ çözer:
        // çalışma alanı içindeki bir bağ (`sub/evil` → `/etc`) öneki
        // tutturur ama diske dışarıyı yazardı.
        guard !WorkspacePathContainment.relativePath(relativePath, escapesWorkspace: workspace) else {
            return nil
        }
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = workspace.appendingPathComponent(trimmed.isEmpty ? "." : trimmed)
            .resolvingSymlinksInPath().standardized
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return resolved
    }

    // MARK: - Bounded process execution

    private func runStep(
        _ step: VerificationStep,
        workingDirectory: URL,
        cancellation: VerificationCancellationFlag
    ) async -> VerificationStepOutcome {
        let maxOutputBytes = self.maxOutputBytes
        let terminationGrace = self.terminationGrace
        let drainGrace = self.drainGrace
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = Self.executeProcess(
                    step: step,
                    workingDirectory: workingDirectory,
                    maxOutputBytes: maxOutputBytes,
                    terminationGrace: terminationGrace,
                    drainGrace: drainGrace,
                    cancellation: cancellation
                )
                continuation.resume(returning: outcome)
            }
        }
    }

    private static func executeProcess(
        step: VerificationStep,
        workingDirectory: URL,
        maxOutputBytes: Int,
        terminationGrace: TimeInterval,
        drainGrace: TimeInterval,
        cancellation: VerificationCancellationFlag
    ) -> VerificationStepOutcome {
        guard step.executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: step.executable) else {
            return VerificationStepOutcome(
                exitCode: nil,
                timedOut: false,
                cancelled: false,
                launchFailure: "executable unavailable at \(step.executable)",
                standardOutput: "",
                standardError: "",
                outputWasTruncated: false
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: step.executable)
        process.arguments = step.arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutCollector = BoundedOutputCollector(limit: maxOutputBytes)
        let stderrCollector = BoundedOutputCollector(limit: maxOutputBytes)
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutCollector.drain(stdoutHandle)
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrCollector.drain(stderrHandle)
            drainGroup.leave()
        }

        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSemaphore.signal() }

        do {
            try process.run()
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            if drainGroup.wait(timeout: .now() + drainGrace) == .timedOut {
                try? stdoutHandle.close()
                try? stderrHandle.close()
            }
            return VerificationStepOutcome(
                exitCode: nil,
                timedOut: false,
                cancelled: false,
                launchFailure: "launch failed: \(error)",
                standardOutput: "",
                standardError: "",
                outputWasTruncated: false
            )
        }

        let childLeadsProcessGroup = getpgid(process.processIdentifier) == process.processIdentifier
        var timedOut = false
        var cancelled = false
        let deadline = Date().addingTimeInterval(step.timeoutSeconds)

        while true {
            if exitSemaphore.wait(timeout: .now() + Self.pollInterval) == .success {
                break
            }
            if cancellation.isCancelled {
                cancelled = true
                terminate(process, exitSemaphore: exitSemaphore, terminationGrace: terminationGrace)
                break
            }
            if Date() >= deadline {
                timedOut = true
                terminate(process, exitSemaphore: exitSemaphore, terminationGrace: terminationGrace)
                break
            }
        }

        process.waitUntilExit()
        if drainGroup.wait(timeout: .now() + drainGrace) == .timedOut {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            killPipeHoldingDescendants(process, childLeadsProcessGroup: childLeadsProcessGroup)
        }

        let stdout = stdoutCollector.snapshot()
        let stderr = stderrCollector.snapshot()
        return VerificationStepOutcome(
            exitCode: process.terminationStatus,
            timedOut: timedOut,
            cancelled: cancelled,
            launchFailure: nil,
            standardOutput: String(decoding: stdout.data, as: UTF8.self),
            standardError: String(decoding: stderr.data, as: UTF8.self),
            outputWasTruncated: stdout.wasTruncated || stderr.wasTruncated
        )
    }

    private static func terminate(
        _ process: Process,
        exitSemaphore: DispatchSemaphore,
        terminationGrace: TimeInterval
    ) {
        if process.isRunning {
            process.terminate()
        }
        if exitSemaphore.wait(timeout: .now() + terminationGrace) == .timedOut, process.isRunning {
            let pid = process.processIdentifier
            if getpgid(pid) == pid {
                killpg(pid, SIGKILL)
            } else {
                kill(pid, SIGKILL)
            }
            _ = exitSemaphore.wait(timeout: .now() + terminationGrace)
        }
    }

    /// Kills the group of a child that already exited but left a pipe-holding descendant.
    private static func killPipeHoldingDescendants(_ process: Process, childLeadsProcessGroup: Bool) {
        guard childLeadsProcessGroup else { return }
        let pid = process.processIdentifier
        guard pid > 0, killpg(pid, 0) == 0 else { return }
        killpg(pid, SIGKILL)
    }
}
