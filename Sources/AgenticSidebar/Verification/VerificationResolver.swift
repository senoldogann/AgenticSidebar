import Foundation

/// Executables the resolver is allowed to place in a trusted recipe.
///
/// The installed formatter version is part of the toolchain, not of the project, so a
/// version mismatch can be reported instead of silently substituting another tool.
/// Language runtimes (`node`, `python3`, `go`, `cargo`) are optional: a recipe
/// only names the runtime its project kind needs, and a missing runtime refuses
/// resolution instead of substituting another command.
struct VerificationToolchain: Sendable, Equatable {
    let swiftExecutable: URL
    let swiftFormatExecutable: URL?
    let installedSwiftFormatVersion: String?
    let nodeExecutable: URL?
    let npmExecutable: URL?
    let pythonExecutable: URL?
    let pytestExecutable: URL?
    let goExecutable: URL?
    let cargoExecutable: URL?

    init(
        swiftExecutable: URL,
        swiftFormatExecutable: URL? = nil,
        installedSwiftFormatVersion: String? = nil,
        nodeExecutable: URL? = nil,
        npmExecutable: URL? = nil,
        pythonExecutable: URL? = nil,
        pytestExecutable: URL? = nil,
        goExecutable: URL? = nil,
        cargoExecutable: URL? = nil
    ) {
        self.swiftExecutable = swiftExecutable
        self.swiftFormatExecutable = swiftFormatExecutable
        self.installedSwiftFormatVersion = installedSwiftFormatVersion
        self.nodeExecutable = nodeExecutable
        self.npmExecutable = npmExecutable
        self.pythonExecutable = pythonExecutable
        self.pytestExecutable = pytestExecutable
        self.goExecutable = goExecutable
        self.cargoExecutable = cargoExecutable
    }

    /// Detects the toolchain of the current host without interpreting a shell.
    ///
    /// Sabit adaylar önce denenir (deterministik sıra), bulunamazsa `PATH`
    /// taranır: Nix, swiftenv ya da Homebrew'suz bir makinede sabit
    /// `/opt/homebrew` yolu tek başına kördür.
    static func detected() -> VerificationToolchain {
        let swiftCandidates = [
            "/usr/bin/swift",
            "/opt/homebrew/bin/swift",
            "/usr/local/bin/swift",
            "/opt/local/bin/swift",
        ]
        let swiftExecutable =
            swiftCandidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
            ?? executableInPath("swift").map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: "/usr/bin/swift")
        let homebrewFormatter = URL(fileURLWithPath: "/opt/homebrew/bin/swift-format")
        let formatterPath =
            FileManager.default.isExecutableFile(atPath: homebrewFormatter.path)
            ? homebrewFormatter.path
            : executableInPath("swift-format")
        let formatter = formatterPath.map { URL(fileURLWithPath: $0) }
        let installedVersion =
            formatter
            .flatMap {
                FileManager.default.isExecutableFile(atPath: $0.path)
                    ? VerificationToolProbe.version(
                        of: $0,
                        timeout: VerificationToolProbe.probeTimeout,
                        drainGrace: VerificationToolProbe.probeDrainGrace
                    )
                    : nil
            }
        return VerificationToolchain(
            swiftExecutable: swiftExecutable,
            swiftFormatExecutable: formatter,
            installedSwiftFormatVersion: installedVersion,
            nodeExecutable: firstExecutable(candidates: ["/opt/homebrew/bin/node", "/usr/local/bin/node"], name: "node"),
            npmExecutable: firstExecutable(candidates: ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"], name: "npm"),
            pythonExecutable: firstExecutable(
                candidates: ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"],
                name: "python3"
            ),
            pytestExecutable: executableInPath("pytest").map { URL(fileURLWithPath: $0) },
            goExecutable: firstExecutable(
                candidates: ["/opt/homebrew/bin/go", "/usr/local/go/bin/go", "/usr/local/bin/go"],
                name: "go"
            ),
            cargoExecutable: firstExecutable(
                candidates: [
                    "\(NSHomeDirectory())/.cargo/bin/cargo",
                    "/opt/homebrew/bin/cargo",
                    "/usr/local/bin/cargo",
                ],
                name: "cargo"
            )
        )
    }

    /// İlk çalıştırılabilir sabit adayı, yoksa `PATH` taraması; kabuk yok.
    private static func firstExecutable(candidates: [String], name: String) -> URL? {
        if let fixed = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: fixed)
        }
        return executableInPath(name).map { URL(fileURLWithPath: $0) }
    }

    /// `PATH` içindeki ilk çalıştırılabilir eşleşmenin tam yolu; kabuk yok,
    /// yalnızca dizin taraması. `detected()` içindeki sabit adaylar
    /// tutmazsa taşınabilirlik ağıdır.
    static func executableInPath(_ name: String) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
        for directory in directories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

/// Deadline-bounded probe for a tool's reported version.
///
/// The probe never waits unbounded on the tool or on its pipe: `--version` output is
/// drained with a bounded grace, a tool that outlives `timeout` is terminated (SIGTERM,
/// then SIGKILL to its process group after the grace), the direct child is always reaped,
/// and a descendant that inherited stdout and outlived the child is killed with its
/// process group. A probe that cannot produce a complete version inside those bounds
/// returns nil, which the resolver records as a mismatch rather than a guess.
enum VerificationToolProbe {
    static let probeTimeout: TimeInterval = 5
    static let probeDrainGrace: TimeInterval = 2
    static let maxVersionBytes = 64 * 1024

    static func version(of executable: URL, timeout: TimeInterval, drainGrace: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let readHandle = pipe.fileHandleForReading
        let collector = BoundedOutputCollector(limit: maxVersionBytes)
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            collector.drain(readHandle)
            drainGroup.leave()
        }

        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSemaphore.signal() }
        do {
            try process.run()
        } catch {
            try? readHandle.close()
            _ = drainGroup.wait(timeout: .now() + drainGrace)
            return nil
        }

        let childLeadsProcessGroup = getpgid(process.processIdentifier) == process.processIdentifier
        let exitedBeforeDeadline = exitSemaphore.wait(timeout: .now() + timeout) == .success
        if !exitedBeforeDeadline {
            terminate(process, exitSemaphore: exitSemaphore, grace: drainGrace)
        }
        let drainFinished = drainGroup.wait(timeout: .now() + drainGrace) == .success
        if !drainFinished {
            // The child is gone but something still holds the write end of the pipe;
            // close our end and kill the recorded process group so the drain cannot
            // stall and no descendant is left behind.
            try? readHandle.close()
            killGroup(process, childLeadsProcessGroup: childLeadsProcessGroup)
            _ = drainGroup.wait(timeout: .now() + drainGrace)
        }
        // Reap the direct child on every path, including the terminate branch.
        process.waitUntilExit()
        // A read that only completed after killing a pipe holder is not a complete read.
        guard exitedBeforeDeadline, drainFinished else { return nil }

        let data = collector.snapshot().data
        let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    /// Terminates an overrunning tool, escalating to SIGKILL after the grace period.
    ///
    /// Foundation launches the child as its own process-group leader. SIGTERM reaches the
    /// direct child only; the escalation reaches the whole group, which is what stops a
    /// descendant that inherited the stdout pipe.
    private static func terminate(_ process: Process, exitSemaphore: DispatchSemaphore, grace: TimeInterval) {
        if process.isRunning {
            process.terminate()
        }
        if exitSemaphore.wait(timeout: .now() + grace) == .timedOut, process.isRunning {
            let pid = process.processIdentifier
            if getpgid(pid) == pid {
                killpg(pid, SIGKILL)
            } else {
                kill(pid, SIGKILL)
            }
            _ = exitSemaphore.wait(timeout: .now() + grace)
        }
    }

    /// Kills the process group of a child that already exited but left a descendant holding the pipe.
    private static func killGroup(_ process: Process, childLeadsProcessGroup: Bool) {
        guard childLeadsProcessGroup else { return }
        let pid = process.processIdentifier
        guard pid > 0, killpg(pid, 0) == 0 else { return }
        killpg(pid, SIGKILL)
    }
}

/// Guard-specific refusals raised before any verification command is trusted.
enum VerificationResolverError: LocalizedError, Equatable, Sendable {
    /// The repository has no recognized project marker; commands are never inferred from extensions.
    case unrecognizedProject(path: String, reason: String)
    /// A recognized metadata file could not be read.
    case metadataUnreadable(path: String, reason: String)
    /// A step's required tool is missing or is not executable.
    case requiredToolUnavailable(step: String, executable: String)
    /// A non-standard step names an executable that is not an existing absolute path.
    case invalidExecutable(step: String, executable: String, reason: String)
    /// A step's working directory would escape the workspace.
    case pathEscape(step: String, path: String)
    /// A caller-supplied recipe needs explicit approval before it may run.
    case nonStandardExecutionRequiresApproval(recipe: String)

    var errorDescription: String? {
        switch self {
        case .unrecognizedProject(let path, let reason):
            return "VERIFICATION_UNRECOGNIZED_PROJECT: \(path) is not a known project: \(reason)"
        case .metadataUnreadable(let path, let reason):
            return "VERIFICATION_METADATA_UNREADABLE: could not read \(path): \(reason)"
        case .requiredToolUnavailable(let step, let executable):
            return "VERIFICATION_TOOL_UNAVAILABLE: step \(step) requires executable \(executable)"
        case .invalidExecutable(let step, let executable, let reason):
            return "VERIFICATION_INVALID_EXECUTABLE: step \(step) executable \(executable) is refused: \(reason)"
        case .pathEscape(let step, let path):
            return "VERIFICATION_PATH_ESCAPE: step \(step) working directory \(path) escapes the workspace"
        case .nonStandardExecutionRequiresApproval(let recipe):
            return "VERIFICATION_APPROVAL_REQUIRED: non-standard recipe \(recipe) requires explicit approval"
        }
    }
}

/// Caller-supplied recipe outside the resolver's trusted catalog.
struct NonStandardVerificationRequest: Sendable, Equatable {
    let recipe: VerificationRecipe
    /// Non-empty actor identity that approved the override; nil or empty means unapproved.
    let approvedBy: String?
}

/// Marker-based project kind detection shared by registration, preflight
/// and recipe resolution.
///
/// Öncelik sırası deterministiktir: `Package.swift` (çalıştırılabilir ürünlü)
/// SwiftPM'dir; ardından `package.json` (Node), `pyproject.toml`/`setup.py`/
/// `setup.cfg`/`requirements.txt` (Python), `go.mod` (Go), `Cargo.toml`
/// (Rust) gelir. Hiçbir dil işareti yoksa ama `.git` varsa `generic` döner:
/// pano izler, koşturur ve inceler; otomatik doğrulama parmak izi ve insan
/// ölçütleriyle sınırlıdır. Ne dil işareti ne `.git` varsa `nil` döner ve
/// çağrı reddedilir; komutlar asla dosya uzantısından türetilmez, depo
/// betikleri asla çalıştırılmaz.
enum ProjectKindDetector: Sendable {
    /// Depo kökündeki dil işaretinden proje türü; tanınmazsa `nil`.
    static func detect(in repository: URL) -> ProjectKind? {
        let repositoryURL = repository.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repositoryURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return nil
        }
        if hasExecutableSwiftPMProduct(in: repositoryURL) {
            return .swiftpm
        }
        if fileExists("package.json", in: repositoryURL) {
            return .node
        }
        if fileExists("pyproject.toml", in: repositoryURL) || fileExists("setup.py", in: repositoryURL)
            || fileExists("setup.cfg", in: repositoryURL) || fileExists("requirements.txt", in: repositoryURL)
        {
            return .python
        }
        if fileExists("go.mod", in: repositoryURL) {
            return .go
        }
        if fileExists("Cargo.toml", in: repositoryURL) {
            return .rust
        }
        // `Package.swift` çalıştırılabilir ürünü yoksa SwiftPM sayılmaz ama
        // depo SwiftPM olabilir; tür yine de `swiftpm`dir ki çözümleme
        // tipik `unrecognizedProject` hatasını üretsin (sessiz `generic`
        // düşüş, eksik ürün bildirimini gizlerdi).
        if fileExists("Package.swift", in: repositoryURL) {
            return .swiftpm
        }
        if FileManager.default.fileExists(atPath: repositoryURL.appendingPathComponent(".git").path) {
            return .generic
        }
        return nil
    }

    /// Çalıştırılabilir ürün bildiren `Package.swift` var mı.
    static func hasExecutableSwiftPMProduct(in repository: URL) -> Bool {
        let packageURL = repository.appendingPathComponent("Package.swift", isDirectory: false)
        guard let packageSource = try? String(contentsOf: packageURL, encoding: .utf8) else {
            return false
        }
        return VerificationResolver.firstExecutableProduct(in: packageSource) != nil
    }

    private static func fileExists(_ name: String, in repository: URL) -> Bool {
        FileManager.default.fileExists(atPath: repository.appendingPathComponent(name, isDirectory: false).path)
    }
}

/// Resolves a trusted, versioned verification recipe for a repository.
///
/// Only known project metadata produces commands. `Package.swift` marks a
/// SwiftPM project; the executable product name comes from that file and the
/// formatter pin comes from the repository's CI metadata. `package.json`
/// marks Node (`npm run build --if-present` + `npm test`), Python markers
/// (`pyproject.toml`/`setup.py`/`setup.cfg`/`requirements.txt`) mark Python
/// (`compileall` + `pytest` ya da `unittest`), `go.mod` marks Go
/// (`go build` + `go test`), `Cargo.toml` marks Rust (`cargo build` +
/// `cargo test`). A Git repository without any language marker resolves to a
/// `generic` recipe whose single required `snapshot` step binds the workspace
/// fingerprint; human criteria then decide acceptance. A formatter whose
/// installed version does not match the pin is recorded as skipped, never
/// substituted. A directory with no recognized marker and no `.git` is
/// refused, and a caller-supplied recipe may only run after explicit approval.
struct VerificationResolver: Sendable {
    static let recipeVersion = VerificationRecipe.currentVersion
    private static let buildTimeout: TimeInterval = 900
    private static let testTimeout: TimeInterval = 900
    private static let formatTimeout: TimeInterval = 300

    let toolchain: VerificationToolchain

    /// Gönderim öncesi hafif ön kontrol: ajan koşmadan deponun güvenilir
    /// tarifeye çözülebileceğini söyler.
    ///
    /// `resolve` ile aynı tanıma bakar (tür algısı) ama araç zinciri
    /// yoklamaz ve reçete üretmez; dosya sistemi okuması dışında maliyeti
    /// yoktur. Arada dosya silinirse (TOCTOU) doğrulayıcının `catch` yolu
    /// yine tutarlı kanıt yazar, o yüzden burası yalnızca israfı önleyen
    /// hızlı kapıdır.
    static func isResolvable(repository: URL) -> Bool {
        resolveKind(repository: repository) != nil
            && (ProjectKindDetector.detect(in: repository) != .swiftpm
                || ProjectKindDetector.hasExecutableSwiftPMProduct(in: repository.standardizedFileURL))
    }

    /// Depo kökünün proje türü; tanınmazsa `nil` (ret gerekçesi üretir).
    static func resolveKind(repository: URL) -> ProjectKind? {
        ProjectKindDetector.detect(in: repository)
    }

    func resolve(repository: URL) async throws -> VerificationRecipe {
        let repositoryURL = repository.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repositoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VerificationResolverError.unrecognizedProject(path: repositoryURL.path, reason: "not a directory")
        }
        guard let kind = ProjectKindDetector.detect(in: repositoryURL) else {
            throw VerificationResolverError.unrecognizedProject(
                path: repositoryURL.path,
                reason: "no recognized project marker (Package.swift, package.json, pyproject.toml, go.mod, Cargo.toml) and no .git"
            )
        }
        switch kind {
        case .swiftpm:
            return try resolveSwiftPM(repository: repositoryURL)
        case .node:
            return try resolveNode(repository: repositoryURL)
        case .python:
            return try resolvePython(repository: repositoryURL)
        case .go:
            return try resolveGo(repository: repositoryURL)
        case .rust:
            return try resolveRust(repository: repositoryURL)
        case .generic:
            return try resolveGeneric(repository: repositoryURL)
        }
    }

    /// SwiftPM tarifi: mevcut davranış birebir korunur (build + test
    /// zorunlu, format CI pini tutarsa isteğe bağlı).
    private func resolveSwiftPM(repository: URL) throws -> VerificationRecipe {
        let packageURL = repository.appendingPathComponent("Package.swift", isDirectory: false)
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw VerificationResolverError.unrecognizedProject(
                path: repository.path,
                reason: "no recognized project marker (Package.swift)"
            )
        }
        let packageSource: String
        do {
            packageSource = try String(contentsOf: packageURL, encoding: .utf8)
        } catch {
            throw VerificationResolverError.metadataUnreadable(path: packageURL.path, reason: "\(error)")
        }
        guard let product = Self.firstExecutableProduct(in: packageSource) else {
            throw VerificationResolverError.unrecognizedProject(
                path: repository.path,
                reason: "Package.swift declares no executable product"
            )
        }
        try requireExecutable(toolchain.swiftExecutable, step: "build")

        var steps: [VerificationStep] = [
            VerificationStep(
                name: "build",
                executable: toolchain.swiftExecutable.path,
                arguments: ["build", "--product", product, "-Xswiftc", "-warnings-as-errors"],
                relativeWorkingDirectory: ".",
                timeoutSeconds: Self.buildTimeout,
                required: true
            ),
            VerificationStep(
                name: "test",
                executable: toolchain.swiftExecutable.path,
                arguments: ["test", "-Xswiftc", "-warnings-as-errors"],
                relativeWorkingDirectory: ".",
                timeoutSeconds: Self.testTimeout,
                required: true
            ),
        ]
        var skippedSteps: [VerificationStepSkip] = []
        var trustedSource = "Package.swift(product=\(product))"

        if let pin = try formatterPin(in: repository) {
            trustedSource += ";.github/workflows/ci.yml(swift-format=\(pin))"
            if let formatExecutable = toolchain.swiftFormatExecutable,
                FileManager.default.isExecutableFile(atPath: formatExecutable.path)
            {
                if toolchain.installedSwiftFormatVersion == pin {
                    steps.append(
                        VerificationStep(
                            name: "format",
                            executable: formatExecutable.path,
                            arguments: ["lint", "-r", "--strict", "Sources", "Tests"],
                            relativeWorkingDirectory: ".",
                            timeoutSeconds: Self.formatTimeout,
                            required: false
                        )
                    )
                } else {
                    let installed = toolchain.installedSwiftFormatVersion ?? "unknown version"
                    skippedSteps.append(
                        VerificationStepSkip(
                            name: "format",
                            reason: "swift-format \(pin) required; installed \(installed)"
                        )
                    )
                }
            } else {
                skippedSteps.append(
                    VerificationStepSkip(
                        name: "format",
                        reason: "swift-format \(pin) required; formatter not installed"
                    )
                )
            }
        }

        return VerificationRecipe(
            name: "swiftpm:\(product)",
            version: Self.recipeVersion,
            trustedSource: trustedSource,
            steps: steps,
            skippedSteps: skippedSteps
        )
    }

    /// Node tarifi: `package.json` işaretinden çözülür.
    ///
    /// `build`, betik yoksa `npm`in kendi `--if-present` anlamıyla sıfır
    /// çıkar (araç anlamı, ikame değil); `test` bilerek `--if-present`
    /// taşımaz: betiksiz depoda `npm test` yüksek sesle düşer ve pano,
    /// geçiyormuş gibi yapmak yerine test betiği ister.
    private func resolveNode(repository: URL) throws -> VerificationRecipe {
        guard let npm = toolchain.npmExecutable else {
            throw VerificationResolverError.requiredToolUnavailable(step: "build", executable: "npm (not installed)")
        }
        try requireExecutable(npm, step: "build")
        return VerificationRecipe(
            name: "node:package.json",
            version: Self.recipeVersion,
            trustedSource: "package.json",
            steps: [
                VerificationStep(
                    name: "build",
                    executable: npm.path,
                    arguments: ["run", "build", "--if-present"],
                    relativeWorkingDirectory: ".",
                    timeoutSeconds: Self.buildTimeout,
                    required: true
                ),
                VerificationStep(
                    name: "test",
                    executable: npm.path,
                    arguments: ["test"],
                    relativeWorkingDirectory: ".",
                    timeoutSeconds: Self.testTimeout,
                    required: true
                ),
            ],
            skippedSteps: []
        )
    }

    /// Python tarifi: sözdizimi denetimi (`compileall`) + test koşusu.
    ///
    /// `pytest` kuruluysa o koşar, yoksa standart kütüphanedeki `unittest`
    /// kullanılır; ikisi de yoksa (python bile yoksa) çözümleme reddedilir,
    /// asla başka bir komut uydurulmaz.
    private func resolvePython(repository: URL) throws -> VerificationRecipe {
        guard let python = toolchain.pythonExecutable else {
            throw VerificationResolverError.requiredToolUnavailable(step: "build", executable: "python3 (not installed)")
        }
        try requireExecutable(python, step: "build")
        let testStep: VerificationStep
        if let pytest = toolchain.pytestExecutable, FileManager.default.isExecutableFile(atPath: pytest.path) {
            testStep = VerificationStep(
                name: "test",
                executable: pytest.path,
                arguments: ["-q"],
                relativeWorkingDirectory: ".",
                timeoutSeconds: Self.testTimeout,
                required: true
            )
        } else {
            testStep = VerificationStep(
                name: "test",
                executable: python.path,
                arguments: ["-m", "unittest", "discover"],
                relativeWorkingDirectory: ".",
                timeoutSeconds: Self.testTimeout,
                required: true
            )
        }
        return VerificationRecipe(
            name: "python:pyproject",
            version: Self.recipeVersion,
            trustedSource: "pyproject.toml/setup.py/setup.cfg/requirements.txt",
            steps: [
                VerificationStep(
                    name: "build",
                    executable: python.path,
                    arguments: ["-m", "compileall", "-q", "."],
                    relativeWorkingDirectory: ".",
                    timeoutSeconds: Self.buildTimeout,
                    required: true
                ),
                testStep,
            ],
            skippedSteps: []
        )
    }

    /// Go tarifi: `go.mod` işaretinden çözülür.
    private func resolveGo(repository: URL) throws -> VerificationRecipe {
        guard let go = toolchain.goExecutable else {
            throw VerificationResolverError.requiredToolUnavailable(step: "build", executable: "go (not installed)")
        }
        try requireExecutable(go, step: "build")
        return VerificationRecipe(
            name: "go:go.mod",
            version: Self.recipeVersion,
            trustedSource: "go.mod",
            steps: [
                VerificationStep(
                    name: "build",
                    executable: go.path,
                    arguments: ["build", "./..."],
                    relativeWorkingDirectory: ".",
                    timeoutSeconds: Self.buildTimeout,
                    required: true
                ),
                VerificationStep(
                    name: "test",
                    executable: go.path,
                    arguments: ["test", "./..."],
                    relativeWorkingDirectory: ".",
                    timeoutSeconds: Self.testTimeout,
                    required: true
                ),
            ],
            skippedSteps: []
        )
    }

    /// Rust tarifi: `Cargo.toml` işaretinden çözülür.
    private func resolveRust(repository: URL) throws -> VerificationRecipe {
        guard let cargo = toolchain.cargoExecutable else {
            throw VerificationResolverError.requiredToolUnavailable(step: "build", executable: "cargo (not installed)")
        }
        try requireExecutable(cargo, step: "build")
        return VerificationRecipe(
            name: "rust:Cargo.toml",
            version: Self.recipeVersion,
            trustedSource: "Cargo.toml",
            steps: [
                VerificationStep(
                    name: "build",
                    executable: cargo.path,
                    arguments: ["build"],
                    relativeWorkingDirectory: ".",
                    timeoutSeconds: Self.buildTimeout,
                    required: true
                ),
                VerificationStep(
                    name: "test",
                    executable: cargo.path,
                    arguments: ["test"],
                    relativeWorkingDirectory: ".",
                    timeoutSeconds: Self.testTimeout,
                    required: true
                ),
            ],
            skippedSteps: []
        )
    }

    /// Generic tarif: dil işareti yok, `.git` var.
    ///
    /// Tek zorunlu `snapshot` adımı hiçbir şeyi derlemez; koşucu her kanıta
    /// çalışma alanı parmak izini bağladığı için bu adım revizyonu kanıta
    /// mühürler. Kabul kararı insan ölçütlerine ve `accept` onayına kalır.
    /// `true` aracı yoksa tarif üretilemez: kanıtsız "geçti" uydurulmaz.
    private func resolveGeneric(repository: URL) throws -> VerificationRecipe {
        let truthy =
            ["/usr/bin/true", "/bin/true"].first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        guard let truthy else {
            throw VerificationResolverError.requiredToolUnavailable(step: "snapshot", executable: "/usr/bin/true")
        }
        return VerificationRecipe(
            name: "generic:git",
            version: Self.recipeVersion,
            trustedSource: "git(no language marker)",
            steps: [
                VerificationStep(
                    name: "snapshot",
                    executable: truthy.path,
                    arguments: [],
                    relativeWorkingDirectory: ".",
                    timeoutSeconds: 60,
                    required: true
                )
            ],
            skippedSteps: []
        )
    }

    /// Validates and accepts a caller-supplied recipe only after explicit approval.
    func resolve(repository: URL, nonStandard request: NonStandardVerificationRequest) async throws -> VerificationRecipe {
        let actor = request.approvedBy?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !actor.isEmpty else {
            throw VerificationResolverError.nonStandardExecutionRequiresApproval(recipe: request.recipe.name)
        }
        let repositoryURL = repository.standardizedFileURL
        for step in request.recipe.steps {
            try validate(step: step, repository: repositoryURL)
        }
        return VerificationRecipe(
            name: request.recipe.name,
            version: request.recipe.version,
            trustedSource: "non-standard approved by \(actor)",
            steps: request.recipe.steps,
            skippedSteps: request.recipe.skippedSteps
        )
    }

    private func requireExecutable(_ executable: URL, step: String) throws {
        guard executable.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw VerificationResolverError.requiredToolUnavailable(step: step, executable: executable.path)
        }
    }

    private func validate(step: VerificationStep, repository: URL) throws {
        guard step.executable.hasPrefix("/") else {
            throw VerificationResolverError.invalidExecutable(
                step: step.name,
                executable: step.executable,
                reason: "executable must be an absolute path"
            )
        }
        guard FileManager.default.isExecutableFile(atPath: step.executable) else {
            throw VerificationResolverError.invalidExecutable(
                step: step.name,
                executable: step.executable,
                reason: "executable does not exist or is not executable"
            )
        }
        guard Self.relativePathEscapesWorkspace(step.relativeWorkingDirectory, workspace: repository) == false else {
            throw VerificationResolverError.pathEscape(step: step.name, path: step.relativeWorkingDirectory)
        }
    }

    private func formatterPin(in repository: URL) throws -> String? {
        let ciURL = repository.appendingPathComponent(".github/workflows/ci.yml", isDirectory: false)
        guard FileManager.default.fileExists(atPath: ciURL.path) else { return nil }
        let source: String
        do {
            source = try String(contentsOf: ciURL, encoding: .utf8)
        } catch {
            throw VerificationResolverError.metadataUnreadable(path: ciURL.path, reason: "\(error)")
        }
        return Self.firstMatch(#"SWIFT_FORMAT_VERSION:\s*"([^"]+)""#, in: source)
    }

    /// True when a relative working directory is absolute or resolves outside the workspace.
    ///
    /// Denetim `WorkspacePathContainment` içindedir (çalıştırıcıyla paylaşılır
    /// ve sembolik bağ çözer); burası yalnız eski çağrı noktasını korur.
    private static func relativePathEscapesWorkspace(_ path: String, workspace: URL) -> Bool {
        WorkspacePathContainment.relativePath(path, escapesWorkspace: workspace)
    }

    /// First `.executable(name: "...")` product declaration, in file order.
    static func firstExecutableProduct(in source: String) -> String? {
        firstMatch(#"\.executable\(\s*name:\s*"([^"]+)""#, in: source)
    }

    private static func firstMatch(_ pattern: String, in source: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, options: [], range: range), match.numberOfRanges > 1,
            let captured = Range(match.range(at: 1), in: source)
        else {
            return nil
        }
        return String(source[captured])
    }
}
