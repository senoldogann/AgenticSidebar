import Foundation

/// Result of one fixed-argv process invocation.
struct GitCommandResult: Sendable, Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
    /// True when either stream exceeded the runner's byte budget and was clipped.
    let outputWasTruncated: Bool
}

/// Failures raised by the process runner itself, before or during launch.
enum GitCommandRunnerError: LocalizedError, Equatable, Sendable {
    case invalidExecutableName(String)
    case executableNotFound(String)
    case launchFailed(executable: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidExecutableName(let name):
            return "Process runner refused executable name \(name): a plain tool name is required"
        case .executableNotFound(let name):
            return "Process runner could not find executable \(name)"
        case .launchFailed(let executable, let reason):
            return "Process runner could not launch \(executable): \(reason)"
        }
    }
}

/// Runs a fixed executable with a fixed argv array inside a working directory.
///
/// There is no shell anywhere in this type: `executable` must be a plain tool name
/// that resolves under `executableDirectory`, and every argument stays a separate
/// `Process` argument. No caller string is ever interpreted by a shell, and output
/// is captured with a hard byte budget so a noisy command cannot exhaust memory.
///
/// Every invocation carries a wall-clock deadline (`defaultTimeout` unless the caller
/// overrides it). A process that overruns is terminated (SIGTERM, then SIGKILL after a
/// short grace period), its pipes are drained, and the call throws the typed
/// `WorkspaceGuardError.gitTimedOut` so a hung tool can never block the workspace actor
/// forever.
final class GitCommandRunner: Sendable {
    static let defaultTimeout: TimeInterval = 30
    private static let terminationGrace: TimeInterval = 2

    let executableDirectory: URL
    let maxOutputBytes: Int

    fileprivate static let readChunkBytes = 64 * 1024

    init(executableDirectory: URL, maxOutputBytes: Int) {
        self.executableDirectory = executableDirectory
        self.maxOutputBytes = maxOutputBytes
    }

    func run(
        executable: String,
        arguments: [String],
        directory: URL,
        timeout: TimeInterval = GitCommandRunner.defaultTimeout
    ) throws -> GitCommandResult {
        guard Self.isValidExecutableName(executable) else {
            throw GitCommandRunnerError.invalidExecutableName(executable)
        }
        let executableURL = executableDirectory.appendingPathComponent(executable, isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw GitCommandRunnerError.executableNotFound(executable)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // Optional index locks would otherwise let read-only probes rewrite the
        // source repository's index while a test asserts byte-identical state.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutCollector = BoundedOutputCollector(limit: maxOutputBytes)
        let stderrCollector = BoundedOutputCollector(limit: maxOutputBytes)
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        // Draining both pipes concurrently is what keeps a chatty child from
        // filling a pipe buffer while the parent waits for exit.
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
            drainGroup.wait()
            throw GitCommandRunnerError.launchFailed(executable: executable, reason: "\(error)")
        }

        if exitSemaphore.wait(timeout: .now() + timeout) == .timedOut {
            terminateProcess(process, exitSemaphore: exitSemaphore)
            drainGroup.wait()
            process.waitUntilExit()
            throw WorkspaceGuardError.gitTimedOut(executable: executable, arguments: arguments, timeout: timeout)
        }

        drainGroup.wait()
        process.waitUntilExit()

        let stdout = stdoutCollector.snapshot()
        let stderr = stderrCollector.snapshot()
        return GitCommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: stdout.data, as: UTF8.self),
            standardError: String(decoding: stderr.data, as: UTF8.self),
            outputWasTruncated: stdout.wasTruncated || stderr.wasTruncated
        )
    }

    /// Terminates an overrunning process, escalating to SIGKILL after a grace period.
    private func terminateProcess(_ process: Process, exitSemaphore: DispatchSemaphore) {
        if process.isRunning {
            process.terminate()
        }
        if exitSemaphore.wait(timeout: .now() + Self.terminationGrace) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = exitSemaphore.wait(timeout: .now() + Self.terminationGrace)
        }
    }

    private static func isValidExecutableName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
    }
}

/// Thread-safe, byte-bounded pipe drain.
private final class BoundedOutputCollector: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var wasTruncated = false

    init(limit: Int) {
        self.limit = limit
    }

    /// Reads until EOF, discarding bytes beyond the budget but never stalling the pipe.
    func drain(_ handle: FileHandle) {
        while true {
            do {
                guard let chunk = try handle.read(upToCount: GitCommandRunner.readChunkBytes), !chunk.isEmpty else {
                    return
                }
                consume(chunk)
            } catch {
                return
            }
        }
    }

    func snapshot() -> (data: Data, wasTruncated: Bool) {
        lock.withLock { (data, wasTruncated) }
    }

    private func consume(_ chunk: Data) {
        lock.withLock {
            let remaining = limit - data.count
            if remaining <= 0 {
                wasTruncated = true
                return
            }
            if chunk.count > remaining {
                data.append(chunk.prefix(remaining))
                wasTruncated = true
            } else {
                data.append(chunk)
            }
        }
    }
}
