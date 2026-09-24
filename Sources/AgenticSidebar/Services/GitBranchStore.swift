import Foundation
import Observation

// MARK: - Komut koşucusu

/// Tek bir `git` yoklamasının sonucu (`Workspace/GitCommandRunner` üstünden).
struct GitProbeResult: Equatable, Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    var didSucceed: Bool {
        exitCode == 0
    }

    /// `git` hata metninden kullanıcıya gösterilecek satır: ilk boş olmayan
    /// satır, yoksa çıkış kodu.
    var failureMessage: String {
        let line =
            standardError
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return line?.trimmingCharacters(in: .whitespaces) ?? "git exited with status \(exitCode)"
    }
}

/// `git` çalıştırır. Enjekte edilebilir: depo süreç başlatmadan test
/// edilebilsin.
protocol GitBranchCommandRunning: Sendable {
    func runGit(arguments: [String], directory: String, timeout: TimeInterval) async -> GitProbeResult
}

/// Gerçek koşucu: mevcut `Workspace/GitCommandRunner` üstünden, arka kuyrukta
/// koşar (o tür eşzamanlıdır). Zaman aşımı ve boru sınırları o türden gelir.
struct SystemGitBranchRunner: GitBranchCommandRunning {
    func runGit(arguments: [String], directory: String, timeout: TimeInterval) async -> GitProbeResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let runner = GitCommandRunner(
                    executableDirectory: URL(fileURLWithPath: "/usr/bin"),
                    maxOutputBytes: 256 * 1024
                )
                do {
                    let result = try runner.run(
                        executable: "git",
                        arguments: arguments,
                        directory: URL(fileURLWithPath: directory),
                        timeout: timeout
                    )
                    continuation.resume(
                        returning: GitProbeResult(
                            exitCode: result.exitCode,
                            standardOutput: result.standardOutput,
                            standardError: result.standardError
                        )
                    )
                } catch {
                    let message =
                        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    continuation.resume(
                        returning: GitProbeResult(
                            exitCode: 127,
                            standardOutput: "",
                            standardError: message
                        )
                    )
                }
            }
        }
    }
}

// MARK: - Saf ayrıştırıcı

/// `git branch`/`status` çıktılarını görünüme indirger.
///
/// Saf: süreç çalıştırmaz, dosya okumaz; bu yüzden testte doğrudan beslenir.
enum GitBranchListParser {
    /// `git branch --format=%(refname:short)` çıktısı → dal adları.
    static func branches(fromListOutput output: String) -> [String] {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// `git branch --show-current` çıktısı → dal adı; ayrık HEAD'te boştur.
    static func currentBranch(fromShowCurrentOutput output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `git status --porcelain=v1` çıktısı → değişen izlenen dosya sayısı.
    /// Boş satırlar sayılmaz.
    static func dirtyCount(fromStatusOutput output: String) -> Int {
        output
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }
}

// MARK: - Depo

/// Bestecinin bağlı olduğu klasördeki git dalları: liste, geçerli dal,
/// kirli sayaç ve güvenli dal değiştirme.
///
/// Kirli ağaçta `checkout` çalıştırılmaz: yarım iş kaybolmasın diye istek
/// hata ile reddedilir, kullanıcı önce işini toplar. `git`'in kendi reddi
/// (izlenmeyen dosya çakışması gibi) de aynen yüzeye taşınır.
@MainActor
@Observable
final class GitBranchStore {
    enum CheckoutError: LocalizedError, Equatable {
        case dirtyWorkingTree(count: Int)
        case gitFailed(message: String)

        var errorDescription: String? {
            switch self {
            case .dirtyWorkingTree(let count):
                return
                    "\(count) uncommitted change\(count == 1 ? "" : "s") — commit or stash first, then switch branches"
            case .gitFailed(let message):
                return message
            }
        }
    }

    /// `nil` = henüz bakılmadı (klasörsüz oturum dahil); `false` = git deposu değil.
    private(set) var isRepository: Bool?
    private(set) var currentBranch: String?
    /// Ayrık HEAD'te gösterilecek kısa SHA; dallı durumda `nil`.
    private(set) var detachedSHA: String?
    private(set) var branches: [String] = []
    private(set) var dirtyCount: Int = 0
    private(set) var isRefreshing = false
    private(set) var isSwitching = false
    private(set) var errorMessage: String?
    private(set) var directoryPath: String?

    @ObservationIgnored
    private let commandRunner: any GitBranchCommandRunning

    nonisolated static let commandTimeout: TimeInterval = 15

    init(commandRunner: any GitBranchCommandRunning = SystemGitBranchRunner()) {
        self.commandRunner = commandRunner
    }

    /// Bestecide gösterilecek ad: dal adı, ayrık HEAD'te kısa SHA.
    var displayName: String? {
        currentBranch ?? detachedSHA.map { "@\($0)" }
    }

    var hasDirtyChanges: Bool {
        dirtyCount > 0
    }

    /// Oturum/klasör değişiminde çağrılır: boş yolda sıfırlanır, aynı yolda
    /// tekrar taranmaz, yeni yolda tazelenir.
    func refreshIfNeeded(directoryPath: String?) {
        let trimmed = directoryPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            reset()
            return
        }
        guard self.directoryPath != trimmed else {
            return
        }
        Task { await refresh(directoryPath: trimmed) }
    }

    func forceRefresh() {
        guard let directoryPath else {
            return
        }
        Task { await refresh(directoryPath: directoryPath) }
    }

    /// Dala geçer; kirli ağaçta ya da `git` reddinde çalışmaz, neden
    /// `errorMessage` ile menüde gösterilir. Başarıda liste tazelenir.
    func checkout(branch: String) async {
        guard let directoryPath, !isSwitching else {
            return
        }
        guard branch != currentBranch else {
            return
        }
        if hasDirtyChanges {
            errorMessage = CheckoutError.dirtyWorkingTree(count: dirtyCount).errorDescription
            return
        }
        isSwitching = true
        defer { isSwitching = false }

        let result = await commandRunner.runGit(
            arguments: ["checkout", branch],
            directory: directoryPath,
            timeout: Self.commandTimeout
        )
        guard result.didSucceed else {
            let message = result.failureMessage
            errorMessage = message
            AppLog.agentSession.error(
                "Git checkout failed: \(message, privacy: .public)"
            )
            return
        }
        errorMessage = nil
        await refresh(directoryPath: directoryPath)
    }

    private func refresh(directoryPath: String) async {
        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        self.directoryPath = directoryPath
        let timeout = Self.commandTimeout

        let inside = await commandRunner.runGit(
            arguments: ["rev-parse", "--is-inside-work-tree"],
            directory: directoryPath,
            timeout: timeout
        )
        guard
            inside.didSucceed,
            inside.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        else {
            isRepository = false
            currentBranch = nil
            detachedSHA = nil
            branches = []
            dirtyCount = 0
            errorMessage = nil
            return
        }
        isRepository = true

        async let currentResult = commandRunner.runGit(
            arguments: ["branch", "--show-current"],
            directory: directoryPath,
            timeout: timeout
        )
        async let listResult = commandRunner.runGit(
            arguments: ["branch", "--format=%(refname:short)"],
            directory: directoryPath,
            timeout: timeout
        )
        async let statusResult = commandRunner.runGit(
            arguments: ["status", "--porcelain=v1", "--untracked-files=no"],
            directory: directoryPath,
            timeout: timeout
        )
        async let headResult = commandRunner.runGit(
            arguments: ["rev-parse", "--short", "HEAD"],
            directory: directoryPath,
            timeout: timeout
        )

        let (current, list, status, head) = await (currentResult, listResult, statusResult, headResult)

        currentBranch =
            current.didSucceed
            ? GitBranchListParser.currentBranch(fromShowCurrentOutput: current.standardOutput) : nil
        branches =
            list.didSucceed
            ? GitBranchListParser.branches(fromListOutput: list.standardOutput) : []
        dirtyCount =
            status.didSucceed
            ? GitBranchListParser.dirtyCount(fromStatusOutput: status.standardOutput) : 0
        if currentBranch == nil, head.didSucceed {
            let sha = head.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            detachedSHA = sha.isEmpty ? nil : sha
        } else {
            detachedSHA = nil
        }
        errorMessage = nil
    }

    private func reset() {
        isRepository = nil
        currentBranch = nil
        detachedSHA = nil
        branches = []
        dirtyCount = 0
        errorMessage = nil
        directoryPath = nil
    }
}
