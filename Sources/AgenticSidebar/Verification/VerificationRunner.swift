import CryptoKit
import Foundation

/// Cooperative cancellation shared between the runner actor and its off-actor process
/// executor: `cancel()` may run while a step is waiting for its process to exit.
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
    static func redact(_ text: String) -> String {
        let patterns: [(pattern: String, template: String)] = [
            (#"(?i)((?:api[_-]?key|token|secret|password|passwd|authorization)\s*[:=]\s*)(\S+)"#, "$1<redacted>"),
            (#"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#, "$1<redacted>"),
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
/// Execution is ordered and argv-only: there is no shell anywhere in this type. Every
/// step gets a wall-clock deadline and a bounded, redacted output budget. A required
/// step that fails prevents its dependents, which are recorded as skipped with the
/// blocker name. Each evidence entry carries the workspace fingerprint observed before
/// the step; when that fingerprint changes between steps the runner stops without a
/// pass, because the tested revision is no longer the revision under test. Cancellation
/// is cooperative: `cancel()` terminates the running step and skips the rest.
actor VerificationRunner {
    private static let pollInterval: TimeInterval = 0.05
    private static let fingerprintTimeout: TimeInterval = 10

    private let maxOutputBytes: Int
    private let maxDetailsCharacters: Int
    private let terminationGrace: TimeInterval
    private let drainGrace: TimeInterval
    private let gitRunner: GitCommandRunner
    private let cancellation = VerificationCancellationFlag()

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

    /// Requests cancellation of the running verification; the next step is not started.
    func cancel() {
        cancellation.cancel()
    }

    var isCancelled: Bool {
        cancellation.isCancelled
    }

    func verify(recipe: VerificationRecipe, workspace: URL) async -> [VerificationEvidence] {
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

        for step in recipe.steps {
            if cancellation.isCancelled, blocker == nil {
                blocker = "cancellation"
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

            let outcome = await runStep(step, workingDirectory: workingDirectory)
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
            if status != .passed, step.required {
                blocker = outcome.cancelled ? "cancellation" : step.name
            }
        }

        appendRecipeSkips(recipe: recipe, entries: &entries, blockedBy: blocker)
        return entries
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
            blockedBy: blockedBy
        )
    }

    private func renderedDetails(
        step: VerificationStep,
        status: VerificationEvidenceStatus,
        exitCode: Int32?,
        timedOut: Bool,
        cancelled: Bool,
        launchFailure: String?,
        reason: String?,
        standardOutput: String,
        standardError: String
    ) -> String {
        var text =
            "step=\(step.name) executable=\(step.executable) status=\(status.rawValue) exit=\(exitCode.map(String.init) ?? "none") timedOut=\(timedOut) cancelled=\(cancelled)"
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

    /// Exact revision of the workspace under test: HEAD plus a digest of the tracked
    /// working-tree state and diff. Ignored build artifacts do not change it.
    private func workspaceFingerprint(of workspace: URL) -> String? {
        guard FileManager.default.fileExists(atPath: workspace.path) else { return nil }
        guard let head = runGit(["rev-parse", "HEAD"], in: workspace), head.exitCode == 0 else { return nil }
        guard let status = runGit(["status", "--porcelain=v1", "--untracked-files=all"], in: workspace), status.exitCode == 0
        else { return nil }
        guard let diff = runGit(["diff", "HEAD", "--no-ext-diff", "--binary"], in: workspace), diff.exitCode == 0 else {
            return nil
        }
        let payload = """
            head=\(head.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            status=\(status.standardOutput)
            diff=\(diff.standardOutput)
            """
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("/") else { return nil }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("..") else { return nil }
        let resolved = workspace.appendingPathComponent(trimmed.isEmpty ? "." : trimmed).standardizedFileURL
        let root = workspace.standardizedFileURL.path
        guard resolved.path == root || resolved.path.hasPrefix(root + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return resolved
    }

    // MARK: - Bounded process execution

    private func runStep(_ step: VerificationStep, workingDirectory: URL) async -> VerificationStepOutcome {
        let maxOutputBytes = self.maxOutputBytes
        let terminationGrace = self.terminationGrace
        let drainGrace = self.drainGrace
        let cancellation = self.cancellation
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
