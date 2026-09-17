import Darwin
import Foundation

// MARK: - Steps

/// The two one-time commands the app is allowed to run for computer use.
///
/// Fixed on purpose: the folder is the only variable, so nothing the user can
/// type reaches a shell. `npm` is resolved through `PATH` like the terminal
/// would, and the process runs with the same trimmed environment the OpenCode
/// server gets.
enum ComputerUseSetupStep: String, CaseIterable, Equatable, Identifiable, Sendable {
    case buildCLI
    case installHelper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .buildCLI:
            "Build the CLI"
        case .installHelper:
            "Install the signed helper"
        }
    }

    /// The whole thing a terminal would need, for the copy button.
    var command: String {
        (["npm"] + arguments).joined(separator: " ")
    }

    /// The npm arguments. `build` and `setup:computer:macos` are package.json
    /// scripts in the chatgpt-system checkout, and nothing else is runnable from
    /// this enum.
    var arguments: [String] {
        switch self {
        case .buildCLI:
            ["run", "build"]
        case .installHelper:
            ["run", "setup:computer:macos"]
        }
    }

    /// What the button is for, shown before the user commits to it.
    var detail: String {
        switch self {
        case .buildCLI:
            "Compiles `dist/cli.js`, the file the MCP server runs. Needed after a fresh clone or after pulling changes."
        case .installHelper:
            "Builds the native runtime and installs it as `~/.chatgpt-system/ChatGPTSystemComputerRuntime.app`, which is the app macOS grants permissions to. Takes a few minutes."
        }
    }

    var isSlow: Bool {
        switch self {
        case .buildCLI:
            false
        case .installHelper:
            true
        }
    }

    /// How long `run` waits before killing the process. `npm` hanging forever
    /// used to leave the reader task and `waitUntilExit` blocked with no way
    /// out except the cancel button.
    var timeout: Duration {
        switch self {
        case .buildCLI:
            .seconds(120)
        case .installHelper:
            .seconds(600)
        }
    }
}

/// The result of one setup command.
struct ComputerUseSetupOutcome: Equatable, Sendable {
    var step: ComputerUseSetupStep
    var exitCode: Int32
    var didLaunch: Bool
    var didCancel: Bool

    var didSucceed: Bool {
        didLaunch && !didCancel && exitCode == 0
    }
}

/// Runs a setup step. Injected so the state machine can be tested without npm.
protocol ComputerUseSetupRunning: Sendable {
    func run(
        step: ComputerUseSetupStep,
        in directoryURL: URL,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> ComputerUseSetupOutcome

    /// Stops the running step, if any.
    func cancel()
}

/// Spawns `npm` for a setup step and streams its output.
///
/// `/usr/bin/env` resolves `npm` from `PATH`, so Homebrew and `nvm` installs
/// both work without the app guessing a path — and no shell is involved.
final class SystemComputerUseSetupRunner: ComputerUseSetupRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var currentProcess: Process?

    func run(
        step: ComputerUseSetupStep,
        in directoryURL: URL,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> ComputerUseSetupOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["npm"] + step.arguments
        process.currentDirectoryURL = directoryURL
        process.environment = FoundationOpenCodeProcessLauncher.childEnvironment(overrides: [:])
        // npm must never wait for input; the app has no terminal to answer with.
        process.standardInput = FileHandle.nullDevice

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            return ComputerUseSetupOutcome(
                step: step,
                exitCode: 127,
                didLaunch: false,
                didCancel: false
            )
        }

        lock.withLock {
            currentProcess = process
        }

        let timedOut = LockedFlag()
        let outcome = await withTaskGroup(
            of: ComputerUseSetupOutcome?.self,
            returning: ComputerUseSetupOutcome.self
        ) { group in
            group.addTask {
                let reader = Task.detached(priority: .utility) { () -> Int in
                    var lines = 0
                    do {
                        for try await line in output.fileHandleForReading.bytes.lines {
                            lines += 1
                            onLine(String(line))
                        }
                    } catch {
                        // A stream that ends badly still ends; the exit status below is
                        // what the user is told to act on.
                    }
                    return lines
                }
                _ = await reader.value

                process.waitUntilExit()
                let status = process.terminationStatus
                let reason = process.terminationReason

                if timedOut.value {
                    return ComputerUseSetupOutcome(
                        step: step,
                        exitCode: 124,
                        didLaunch: true,
                        didCancel: false
                    )
                }
                // SIGTERM, and only SIGTERM, is this app's own cancel button.
                let didCancel = reason == .uncaughtSignal && status == SIGTERM

                return ComputerUseSetupOutcome(
                    step: step,
                    exitCode: didCancel ? 0 : status,
                    didLaunch: true,
                    didCancel: didCancel
                )
            }
            group.addTask {
                try? await Task.sleep(for: step.timeout)
                return nil
            }

            for await result in group {
                if let finished = result {
                    group.cancelAll()
                    return finished
                }
                // The sleeper won: the command hung. SIGTERM it; the waiter
                // above maps the death to a 124 timeout (not a user cancel).
                timedOut.value = true
                process.terminate()
            }
            timedOut.value = true
            process.terminate()
            return ComputerUseSetupOutcome(
                step: step,
                exitCode: 124,
                didLaunch: true,
                didCancel: false
            )
        }

        lock.withLock {
            currentProcess = nil
        }
        if outcome.exitCode == 124, !outcome.didCancel {
            onLine("Timed out after \(step.timeoutDescription); the process was stopped.")
        }
        return outcome
    }

    func cancel() {
        lock.withLock {
            currentProcess?.terminate()
        }
    }
}

/// A boolean shared between the waiter and the timeout sleeper.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

private extension ComputerUseSetupStep {
    /// Short human text for the timeout notice line.
    var timeoutDescription: String {
        switch self {
        case .buildCLI:
            "120s"
        case .installHelper:
            "600s"
        }
    }
}
