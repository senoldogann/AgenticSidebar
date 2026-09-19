import Darwin
import Foundation

/// Tek komutun sonucu: çıkış kodu, budanmış çıktı ve zaman aşımı bayrağı.
/// `timedOut` varken `exitCode` güvenilmezdir (sonlandırılan sürecindir).
struct GoalCommandResult: Equatable, Sendable {
    let exitCode: Int32
    let outputTail: String
    let timedOut: Bool

    init(exitCode: Int32, outputTail: String, timedOut: Bool) {
        self.exitCode = exitCode
        self.outputTail = outputTail
        self.timedOut = timedOut
    }

    var succeeded: Bool {
        !timedOut && exitCode == 0
    }
}

/// Komut çalıştırıcı: çalıştırılabilir, argümanlar, çalışma dizini.
/// Enjekte edilir; üretim `Process` kullanır, testler sahte döndürür.
typealias GoalCommandExecutor = @Sendable (_ executable: URL, _ arguments: [String], _ workingDirectory: URL) async -> GoalCommandResult

/// Bitiş kapılarının gerçek doğrulaması: `swift build` + `swift test`
/// hedef projenin dizininde koşar. Komutlar sabittir (kullanıcı girdisi
/// komuta gömülmez), kabuk yoktur, o yüzden enjeksiyon yüzeyi yoktur;
/// tek girdi çalışma dizinidir ve o da `Package.swift` barındırma şartıyla
/// doğrulanır.
struct GoalRunners: Sendable {
    /// Ham çıktıda tutulan üst sınır; derleme günlüğü diski şişirmez.
    static let maximumOutputBytes = 200_000
    /// Rapora taşınan kuyruk: başarısızlığın sebebi genelde sondadır.
    static let reportTailCharacters = 4_000

    let execute: GoalCommandExecutor
    let timeoutSeconds: TimeInterval

    init(execute: @escaping GoalCommandExecutor, timeoutSeconds: TimeInterval) {
        self.execute = execute
        self.timeoutSeconds = timeoutSeconds
    }

    /// Üretim koşucusu: hangi çalıştırılabilir istenirse istensin çözümlenmiş
    /// `swift` koşar (sabit-komut politikası: kullanıcı girdisi komuta gömülmez).
    static func live(timeoutSeconds: TimeInterval = 600) -> GoalRunners {
        GoalRunners(
            execute: { _, arguments, workingDirectory in
                await runThroughProcess(
                    executable: swiftExecutable() ?? URL(fileURLWithPath: "/usr/bin/swift"),
                    arguments: arguments,
                    workingDirectory: workingDirectory,
                    timeoutSeconds: timeoutSeconds
                )
            },
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Dizin Swift paketi mi: `swift build`/`swift test` ancak o zaman anlamlı.
    /// Yanlış dizinde tur harcamamak için kapıdan önce bakılır.
    static func isSwiftPackage(at directory: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: directory.appendingPathComponent("Package.swift").path)
    }

    /// Yukarı yürümenin üst sınırı: derin monorepo içleri için yeterlidir,
    /// dosya sistemini köke kadar süpürmez.
    private static let maximumEnclosingLevels = 12

    /// Dosya ya da dizin yolunu kapsayan en yakın Swift paket dizini.
    ///
    /// Oturum zaten projenin dosyalarına dokunmuştur (ekler, okunan/yazılan
    /// yollar, diff kartları); bu yolların atalarından `Package.swift`
    /// barındıran ilk dizin, kullanıcıya klasör sormadan hedef dizindir.
    /// Var olmayan yollar sessizce atlanır. Yalnız yerel disk okunur.
    static func enclosingSwiftPackage(for path: String, fileManager: FileManager = .default) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: trimmed, isDirectory: &isDirectory) else {
            return nil
        }
        var current = URL(fileURLWithPath: trimmed, isDirectory: isDirectory.boolValue)
        if !isDirectory.boolValue {
            current = current.deletingLastPathComponent()
        }
        for _ in 0..<Self.maximumEnclosingLevels {
            if isSwiftPackage(at: current, fileManager: fileManager) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else {
                return nil
            }
            current = parent
        }
        return nil
    }

    /// Hedef dizin seçimi: önce bilinen dizinler (önceki koşu, kayıtlı
    /// tercih), sonra oturumdaki dosya sinyallerinden türetilen paket
    /// dizini. `nil` = hiçbir aday paket değildir; çağıran yedeğe düşer.
    static func resolvePackageDirectory(
        knownPaths: [String],
        seedPaths: [String],
        fileManager: FileManager = .default
    ) -> URL? {
        for path in knownPaths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            let url = URL(fileURLWithPath: trimmed)
            if isSwiftPackage(at: url, fileManager: fileManager) {
                return url
            }
        }
        for seed in seedPaths {
            if let found = enclosingSwiftPackage(for: seed, fileManager: fileManager) {
                return found
            }
        }
        return nil
    }

    /// Tam kapı: önce derleme, yeşilse testler. Derleme kırmızıysa testler
    /// koşulmaz (`tests == nil`); rapor bunu "atlandı" diye yazar.
    func verify(packageDirectory: URL) async -> GoalVerificationReport {
        guard let swift = Self.swiftExecutable() else {
            let missing = GoalCommandResult(
                exitCode: -1,
                outputTail: "Swift toolchain not found; install Xcode command line tools and retry.",
                timedOut: false
            )
            return GoalVerificationReport(build: missing, tests: nil)
        }
        let build = await execute(swift, ["build"], packageDirectory)
        guard !Task.isCancelled else {
            return GoalVerificationReport(build: build, tests: nil)
        }
        guard build.succeeded else {
            return GoalVerificationReport(build: build, tests: nil)
        }
        let tests = await execute(swift, ["test"], packageDirectory)
        return GoalVerificationReport(build: build, tests: tests)
    }

    /// `swift` konumu: kullanıcının ortamı kazanır (sürüm yöneticisi ve
    /// `xcode-select` şimleri), bilinen kurulumlar yedektir. Bulunamazsa `nil`
    /// döner, çağıran bunu "araç zinciri yok" diye raporlar.
    static func swiftExecutable(fileManager: FileManager = .default, environment: [String: String] = ProcessInfo.processInfo.environment)
        -> URL?
    {
        var candidates: [String] = []
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { String($0) + "/swift" })
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/swift",
            "/usr/local/bin/swift",
            "/usr/bin/swift",
        ])
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    // MARK: - Process

    /// Ham süreç çalıştırma: `verify` dışından da çağrılabilir ki zaman aşımı
    /// yolu gerçek süreçle test edilebilsin (`/bin/sleep` + kısa baraj).
    static func runThroughProcess(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        timeoutSeconds: TimeInterval
    ) async -> GoalCommandResult {
        let box = GoalProcessBox()
        let runnerExecutable = executable
        let work = Task.detached(priority: .utility) { () -> GoalCommandResult in
            let process = Process()
            process.executableURL = runnerExecutable
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                await box.set(process)
            } catch {
                await box.didFailToStart()
                return GoalCommandResult(
                    exitCode: -1,
                    outputTail: "Could not launch \(runnerExecutable.lastPathComponent): \(error.localizedDescription)",
                    timedOut: false
                )
            }
            // Drain while the child writes: waiting first deadlocks once the
            // kernel pipe fills. Retain only the last bounded portion.
            let reader = pipe.fileHandleForReading
            let drain = Task.detached(priority: .utility) { () -> Data in
                var tail = Data()
                // A background descendant may inherit stdout after the direct
                // child exits. Poll instead of waiting indefinitely for EOF.
                let descriptor = reader.fileDescriptor
                var buffer = [UInt8](repeating: 0, count: 8192)
                var parentExitedAt: Date?
                while true {
                    if await box.hasExited() {
                        if parentExitedAt == nil {
                            parentExitedAt = Date()
                        }
                        if let exitedAt = parentExitedAt,
                            Date().timeIntervalSince(exitedAt) >= 0.25
                        {
                            break
                        }
                    }
                    var event = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                    let ready = Darwin.poll(&event, 1, 50)
                    if ready < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    if ready == 0 {
                        if parentExitedAt != nil { break }
                        continue
                    }
                    guard event.revents & Int16(POLLIN | POLLHUP) != 0 else { break }
                    let readCount = buffer.withUnsafeMutableBytes {
                        Darwin.read(descriptor, $0.baseAddress, $0.count)
                    }
                    guard readCount > 0 else { break }
                    tail.append(contentsOf: buffer.prefix(readCount))
                    if tail.count > maximumOutputBytes {
                        tail.removeFirst(tail.count - maximumOutputBytes)
                    }
                }
                reader.closeFile()
                return tail
            }
            pipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            let capped = await drain.value
            await box.set(nil)
            let text = String(decoding: capped, as: UTF8.self)
            return GoalCommandResult(
                exitCode: process.terminationStatus,
                outputTail: String(text.suffix(reportTailCharacters)),
                timedOut: false
            )
        }
        let winner = await pollForExit(box: box, until: Date().addingTimeInterval(timeoutSeconds))
        if winner {
            return await work.value
        }
        let wasCancelled = Task.isCancelled
        await box.terminate()
        let exitedAfterTerminate = await pollForExit(box: box, until: Date().addingTimeInterval(2))
        if exitedAfterTerminate {
            _ = await work.value
        } else {
            await box.kill()
            _ = await work.value
        }
        return GoalCommandResult(
            exitCode: -1,
            outputTail:
                wasCancelled
                ? "Cancelled: \(runnerExecutable.lastPathComponent) (arguments omitted)"
                : "Timed out after \(Int(timeoutSeconds))s: \(runnerExecutable.lastPathComponent) (arguments omitted)",
            timedOut: !wasCancelled
        )
    }

    /// Kutu yoklaması: görev grubundan çıkarken kalan çocuğu beklemek
    /// (`cancelAll` sonrası `work.value` yine biteni bekler) zaman aşımını
    /// etkisiz bırakırdı. Yoklama biteni beklemez, yalnızca bakar.
    private static func pollForExit(box: GoalProcessBox, until deadline: Date) async -> Bool {
        while !Task.isCancelled, Date() < deadline {
            if await box.hasExited() {
                return true
            }
            do {
                try await Task.sleep(for: .seconds(0.1))
            } catch {
                return false
            }
        }
        guard !Task.isCancelled else {
            return false
        }
        return await box.hasExited()
    }
}

/// Doğrulama raporu: derleme sonucu + (derleme yeşilse) test sonucu.
struct GoalVerificationReport: Equatable, Sendable {
    let build: GoalCommandResult
    /// Derleme kırmızıysa koşulmaz, `nil` "atlandı" demektir.
    let tests: GoalCommandResult?

    init(build: GoalCommandResult, tests: GoalCommandResult?) {
        self.build = build
        self.tests = tests
    }

    var buildSucceeded: Bool {
        build.succeeded
    }

    var testsSucceeded: Bool {
        tests?.succeeded ?? false
    }

    /// Panele ve rapora tek satırlık özet.
    var summary: String {
        if build.timedOut {
            return "build timed out"
        }
        guard build.succeeded else {
            return "build failed (exit \(build.exitCode))"
        }
        guard let tests else {
            return "build passed; tests skipped"
        }
        if tests.timedOut {
            return "build passed; tests timed out"
        }
        return tests.succeeded ? "build and tests passed" : "build passed; tests failed (exit \(tests.exitCode))"
    }
}

/// Çalışan `Process`in tutacağı: zaman aşımında dışarıdan sonlandırma.
/// `Process` `Sendable` değildir; kutu `actor` olduğu için paylaşım güvenlidir.
private actor GoalProcessBox {
    private var process: Process?
    private var started = false
    private var requestedSignal: Int32?

    func set(_ process: Process?) {
        if process != nil {
            started = true
        }
        self.process = process
        if let process, let requestedSignal, process.isRunning {
            OpenCodeProcessTree.signalTree(
                rootedAt: process.processIdentifier,
                signal: requestedSignal,
                includeRoot: true
            )
        }
    }

    func didFailToStart() {
        started = true
        process = nil
    }

    /// Süreç bitti (ya da hiç başlayamadı) ve kutu bunu gördü.
    /// `started` bayrağı şarttır: süreç daha atanmadan `true` dönmek,
    /// zaman aşımı yoklamasını anında bitirirdi.
    func hasExited() -> Bool {
        guard started else {
            return false
        }
        return !(process?.isRunning ?? false)
    }

    func terminate() {
        requestedSignal = SIGTERM
        signalRunningProcess(SIGTERM)
    }

    /// Kibar sonlandırma yetmezse zorla öldürme (`SIGKILL`).
    func kill() {
        requestedSignal = SIGKILL
        signalRunningProcess(SIGKILL)
    }

    private func signalRunningProcess(_ signal: Int32) {
        guard let process, process.isRunning else {
            return
        }
        OpenCodeProcessTree.signalTree(
            rootedAt: process.processIdentifier,
            signal: signal,
            includeRoot: true
        )
    }
}
