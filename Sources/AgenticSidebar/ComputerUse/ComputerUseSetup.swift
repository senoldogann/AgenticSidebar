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

    /// Karta iletilen satır tavanı: `swift build` gibi adımlar çok konuşkandır;
    /// kart zaten son 120 satırı tutar, buradaki tavan ana iş parçacığı selini
    /// keser. Süreç akmaya devam eder, yalnızca iletim durur.
    static let maximumForwardedLines = 2_000
    /// Tek satır tavanı (bayt): anormal uzun bir satır kartı şişirmesin.
    static let maximumLineBytes = 8_000

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
                // Ayrık değil grup çocuğu: dış iptal buraya ulaşır, boru
                // kapanınca (`terminate`/`kill` sonrası EOF) okuyucu biter.
                let reader = Task(priority: .utility) { () -> Int in
                    var lines = 0
                    var forwarded = 0
                    do {
                        for try await line in output.fileHandleForReading.bytes.lines {
                            lines += 1
                            // Tavan aşıldıysa akıtmaya devam et (çocuk tıkanmasın),
                            // karta yazma; sonunda tek satırlık kesme notu düşülür.
                            guard forwarded < Self.maximumForwardedLines else {
                                continue
                            }
                            forwarded += 1
                            onLine(Self.cappedLine(String(line)))
                        }
                    } catch {
                        // A stream that ends badly still ends; the exit status below is
                        // what the user is told to act on.
                    }
                    if lines > forwarded {
                        onLine("… output truncated (\(lines - forwarded) further lines not shown)")
                    }
                    return lines
                }
                _ = await reader.value

                // Havuz iş parçacığını tutmamak için bekleme ayrı iş parçacığında.
                let exitStatus: (Int32, Process.TerminationReason) = await withCheckedContinuation { continuation in
                    Thread.detachNewThread {
                        process.waitUntilExit()
                        continuation.resume(returning: (process.terminationStatus, process.terminationReason))
                    }
                }
                let status = exitStatus.0
                let reason = exitStatus.1

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
                // SIGTERM'i yoksayan sürece kısa süre tanınır, sonra SIGKILL:
                // yoksa `waitUntilExit` sonsuza dek bloklanır.
                timedOut.value = true
                process.terminate()
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
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
        let process = lock.withLock {
            currentProcess
        }
        process?.terminate()
        // SIGTERM'i yoksayan süreci ölüme terk etme: kısa süre sonra SIGKILL.
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(5))
            if let process, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    /// Uzun satırı bayt tavanında kırpar; `utf8.count` (karakter sayımının
    /// aksine) sabit zamanlıdır ve karakter sayısından küçük olamaz, yani eşik
    /// ön elemesi için yeterlidir. Kesme karakter sınırında yapılır.
    static func cappedLine(_ line: String) -> String {
        guard line.utf8.count > maximumLineBytes else {
            return line
        }
        return String(line.prefix(maximumLineBytes)) + "…"
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

extension ComputerUseSetupStep {
    /// Short human text for the timeout notice line.
    fileprivate var timeoutDescription: String {
        switch self {
        case .buildCLI:
            "120s"
        case .installHelper:
            "600s"
        }
    }
}
