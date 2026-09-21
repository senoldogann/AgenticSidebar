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

/// Bitiş kapılarının gerçek doğrulaması: hedef projenin dizininde koşar.
/// SwiftPM'de `swift build` + `swift test`, Xcode projesinde `xcodebuild`
/// build + test. Komutlar sabittir (kullanıcı girdisi komuta gömülmez),
/// kabuk yoktur, o yüzden enjeksiyon yüzeyi yoktur; tek girdi çalışma
/// dizinidir ve o da proje işareti (`Package.swift` ya da Xcode projesi)
/// şartıyla doğrulanır. Şema adı projenin kendi listesinden gelir
/// (`xcodebuild -list -json`), `Package.swift` ürün adı gibi güvenilir
/// projen metadata'sıdır.
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

    /// Üretim koşucusu: çalıştırılabilir sabit çözümleyicilerden gelir
    /// (`swift` ya da `xcodebuild`); `verify` bunlardan başkasını istemez.
    /// Kullanıcı girdisi komuta gömülmez (sabit-komut politikası).
    static func live(timeoutSeconds: TimeInterval = 600) -> GoalRunners {
        GoalRunners(
            execute: { executable, arguments, workingDirectory in
                await runThroughProcess(
                    executable: executable,
                    arguments: arguments,
                    workingDirectory: workingDirectory,
                    timeoutSeconds: timeoutSeconds
                )
            },
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Desteklenen proje türü: SwiftPM ya da Xcode. Doğrulama komutları türe
    /// göre seçilir; ikisi de yoksa dizin kapıdan reddedilir.
    enum GoalProjectKind: Equatable, Sendable {
        case swiftPM
        case xcode(XcodeProjectRef)
    }

    /// Xcode proje başvurusu: dizindeki `*.xcodeproj` ya da `*.xcworkspace`.
    /// Yalnız en üst düzey aranır; iç içe örnekler belirsiz olurdu.
    struct XcodeProjectRef: Equatable, Sendable {
        let url: URL
        let isWorkspace: Bool
        /// `xcodebuild` bayrağı: `-project` ya da `-workspace`.
        var flag: String {
            isWorkspace ? "-workspace" : "-project"
        }
    }

    /// Dizin Swift paketi mi: `swift build`/`swift test` ancak o zaman anlamlı.
    /// Yanlış dizinde tur harcamamak için kapıdan önce bakılır.
    static func isSwiftPackage(at directory: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: directory.appendingPathComponent("Package.swift").path)
    }

    /// Dizindeki Xcode projesi: önce `*.xcodeproj`, yoksa `*.xcworkspace`.
    /// Birden çok adayda alfabetik ilk kazanır (belirleyicidir). Dönen yol
    /// çağıranın verdiği dizin biçimini korur (`/var` ↔ `/private/var`
    /// çözünmesi karşılaştırmaları bozardı).
    static func xcodeProject(at directory: URL, fileManager: FileManager = .default) -> XcodeProjectRef? {
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }
        func firstChild(withExtension ext: String) -> URL? {
            contents
                .filter { $0.pathExtension == ext && isDirectory($0, fileManager: fileManager) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .first
                .map { directory.appendingPathComponent($0.lastPathComponent, isDirectory: true) }
        }
        if let project = firstChild(withExtension: "xcodeproj") {
            return XcodeProjectRef(url: project, isWorkspace: false)
        }
        if let workspace = firstChild(withExtension: "xcworkspace") {
            return XcodeProjectRef(url: workspace, isWorkspace: true)
        }
        return nil
    }

    /// Dizin desteklenen proje mi: önce SwiftPM, sonra Xcode.
    static func supportedProject(at directory: URL, fileManager: FileManager = .default) -> GoalProjectKind? {
        if isSwiftPackage(at: directory, fileManager: fileManager) {
            return .swiftPM
        }
        if let xcode = xcodeProject(at: directory, fileManager: fileManager) {
            return .xcode(xcode)
        }
        return nil
    }

    /// Seçilen klasörün kullanılabilir hâli: kendisi projeseyse kendisi,
    /// değilse tek bir alt dizini projeseyse o alt dizin (klasik "bir üstü
    /// seçme" hatası sessizce düzelir). Birden çok adayda `nil` döner —
    /// tahmin yürütülmez, kullanıcı seçer.
    static func usableProjectDirectory(at directory: URL, fileManager: FileManager = .default) -> URL? {
        if supportedProject(at: directory, fileManager: fileManager) != nil {
            return directory
        }
        guard
            let children = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }
        let candidates =
            children
            .filter {
                isDirectory($0, fileManager: fileManager)
                    && supportedProject(at: $0, fileManager: fileManager) != nil
            }
            .map { directory.appendingPathComponent($0.lastPathComponent, isDirectory: true) }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
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
        enclosingDirectory(for: path, fileManager: fileManager) {
            isSwiftPackage(at: $0, fileManager: fileManager)
        }
    }

    /// Dosya ya da dizin yolunu kapsayan en yakın Xcode proje dizini.
    static func enclosingXcodeProject(for path: String, fileManager: FileManager = .default) -> URL? {
        enclosingDirectory(for: path, fileManager: fileManager) {
            xcodeProject(at: $0, fileManager: fileManager) != nil
        }
    }

    /// Yukarı yürümenin ortak gövdesi: dosya ise dizininden başlar, eşleşen
    /// ilk atayı döndürür.
    private static func enclosingDirectory(
        for path: String,
        fileManager: FileManager,
        match: (URL) -> Bool
    ) -> URL? {
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
            if match(current) {
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
    /// tercih; SwiftPM öncelikli, sonra Xcode), sonra oturumdaki dosya
    /// sinyallerinden türetilen dizin (aynı öncelik). `nil` = hiçbir aday
    /// desteklenen proje değildir; çağıran yedeğe düşer.
    static func resolvePackageDirectory(
        knownPaths: [String],
        seedPaths: [String],
        fileManager: FileManager = .default
    ) -> URL? {
        func knownDirectory(match: (URL) -> Bool) -> URL? {
            for path in knownPaths {
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    continue
                }
                let url = URL(fileURLWithPath: trimmed)
                if match(url) {
                    return url
                }
            }
            return nil
        }
        if let swift = knownDirectory(match: { isSwiftPackage(at: $0, fileManager: fileManager) }) {
            return swift
        }
        if let xcode = knownDirectory(match: { xcodeProject(at: $0, fileManager: fileManager) != nil }) {
            return xcode
        }
        for seed in seedPaths {
            if let found = enclosingSwiftPackage(for: seed, fileManager: fileManager) {
                return found
            }
        }
        for seed in seedPaths {
            if let found = enclosingXcodeProject(for: seed, fileManager: fileManager) {
                return found
            }
        }
        return nil
    }

    /// Tam kapı: önce derleme, yeşilse testler. Derleme kırmızıysa testler
    /// koşulmaz (`tests == nil`); rapor bunu "atlandı" diye yazar.
    /// Komutlar proje türüne göre seçilir (SwiftPM ya da Xcode).
    func verify(packageDirectory: URL) async -> GoalVerificationReport {
        switch Self.supportedProject(at: packageDirectory) {
        case .swiftPM:
            return await verifySwiftPM(packageDirectory: packageDirectory)
        case .xcode(let project):
            return await verifyXcode(project: project, packageDirectory: packageDirectory)
        case nil:
            return GoalVerificationReport(
                build: GoalCommandResult(
                    exitCode: -1,
                    outputTail: "Not a SwiftPM package or Xcode project directory.",
                    timedOut: false
                ),
                tests: nil
            )
        }
    }

    /// SwiftPM kapısı: `swift build`, yeşilse `swift test`.
    private func verifySwiftPM(packageDirectory: URL) async -> GoalVerificationReport {
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

    /// Xcode kapısı: şema projenin kendi listesinden çözülür
    /// (`xcodebuild -list -json`, salt okunur keşif), sonra aynı şemayla
    /// build + test. Derleme kırmızıysa testler koşulmaz.
    private func verifyXcode(project: XcodeProjectRef, packageDirectory: URL) async -> GoalVerificationReport {
        func refusal(_ text: String) -> GoalVerificationReport {
            GoalVerificationReport(
                build: GoalCommandResult(exitCode: -1, outputTail: text, timedOut: false),
                tests: nil
            )
        }
        guard let xcodebuild = Self.xcodebuildExecutable() else {
            return refusal("Xcode command line tools not found; install Xcode and retry.")
        }
        let projectFlag = [project.flag, project.url.lastPathComponent]
        let list = await execute(xcodebuild, projectFlag + ["-list", "-json"], packageDirectory)
        guard !Task.isCancelled else {
            return GoalVerificationReport(build: list, tests: nil)
        }
        guard list.succeeded else {
            return refusal("Could not list Xcode schemes: \(list.outputTail)")
        }
        let schemes = Self.xcodeSchemes(fromListJSON: Data(list.outputTail.utf8))
        let projectName = project.url.deletingPathExtension().lastPathComponent
        guard let scheme = Self.preferredXcodeScheme(from: schemes, projectName: projectName) else {
            return refusal("No Xcode schemes found in \(project.url.lastPathComponent).")
        }
        let schemeFlag = projectFlag + ["-scheme", scheme]
        let build = await execute(
            xcodebuild,
            schemeFlag + ["-destination", "generic/platform=macOS", "build"],
            packageDirectory
        )
        guard !Task.isCancelled else {
            return GoalVerificationReport(build: build, tests: nil)
        }
        guard build.succeeded else {
            return GoalVerificationReport(build: build, tests: nil)
        }
        let tests = await execute(
            xcodebuild,
            schemeFlag + ["-destination", "platform=macOS", "test"],
            packageDirectory
        )
        return GoalVerificationReport(build: build, tests: tests)
    }

    /// `xcodebuild -list -json` çıktısındaki şemalar. Saf fonksiyondur.
    nonisolated static func xcodeSchemes(fromListJSON data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        for container in ["project", "workspace"] {
            if let dict = root[container] as? [String: Any],
                let schemes = dict["schemes"] as? [String]
            {
                return schemes
            }
        }
        return []
    }

    /// Şema seçimi: proje adıyla birebir eşleşen kazanır, yoksa alfabetik
    /// ilk. Belirleyicidir; hangi şemanın koşacağı komut satırından bellidir.
    nonisolated static func preferredXcodeScheme(from schemes: [String], projectName: String) -> String? {
        if schemes.contains(projectName) {
            return projectName
        }
        return schemes.sorted().first
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

    /// `xcodebuild` konumu: `swift` ile aynı kural (ortam kazanır, bilinen
    /// kurulum yedektir). Bulunamazsa `nil`, çağıran "araç zinciri yok" yazar.
    static func xcodebuildExecutable(
        fileManager: FileManager = .default, environment: [String: String] = ProcessInfo.processInfo.environment
    )
        -> URL?
    {
        var candidates: [String] = []
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { String($0) + "/xcodebuild" })
        }
        candidates.append("/usr/bin/xcodebuild")
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
