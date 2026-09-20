import Foundation

/// Executables the resolver is allowed to place in a trusted recipe.
///
/// The installed formatter version is part of the toolchain, not of the project, so a
/// version mismatch can be reported instead of silently substituting another tool.
struct VerificationToolchain: Sendable, Equatable {
    let swiftExecutable: URL
    let swiftFormatExecutable: URL?
    let installedSwiftFormatVersion: String?

    /// Detects the toolchain of the current host without interpreting a shell.
    static func detected() -> VerificationToolchain {
        let swiftCandidates = ["/usr/bin/swift", "/opt/homebrew/bin/swift"]
        let swiftExecutable =
            swiftCandidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: "/usr/bin/swift")
        let formatter = URL(fileURLWithPath: "/opt/homebrew/bin/swift-format")
        let installedVersion =
            FileManager.default.isExecutableFile(atPath: formatter.path)
            ? VerificationToolProbe.version(of: formatter)
            : nil
        return VerificationToolchain(
            swiftExecutable: swiftExecutable,
            swiftFormatExecutable: FileManager.default.isExecutableFile(atPath: formatter.path) ? formatter : nil,
            installedSwiftFormatVersion: installedVersion
        )
    }
}

/// Bounded probe for a tool's reported version.
private enum VerificationToolProbe {
    static func version(of executable: URL) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
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

/// Resolves a trusted, versioned verification recipe for a repository.
///
/// Only known project metadata produces commands. `Package.swift` marks a SwiftPM project;
/// the executable product name comes from that file and the formatter pin comes from the
/// repository's CI metadata. A formatter whose installed version does not match the pin is
/// recorded as skipped, never substituted. A project without a recognized marker is refused,
/// and a caller-supplied recipe may only run after explicit approval.
struct VerificationResolver: Sendable {
    static let recipeVersion = 1
    private static let buildTimeout: TimeInterval = 900
    private static let testTimeout: TimeInterval = 900
    private static let formatTimeout: TimeInterval = 300

    let toolchain: VerificationToolchain

    func resolve(repository: URL) async throws -> VerificationRecipe {
        let repositoryURL = repository.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repositoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VerificationResolverError.unrecognizedProject(path: repositoryURL.path, reason: "not a directory")
        }
        let packageURL = repositoryURL.appendingPathComponent("Package.swift", isDirectory: false)
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw VerificationResolverError.unrecognizedProject(
                path: repositoryURL.path,
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
                path: repositoryURL.path,
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
                arguments: ["test"],
                relativeWorkingDirectory: ".",
                timeoutSeconds: Self.testTimeout,
                required: true
            ),
        ]
        var skippedSteps: [VerificationStepSkip] = []
        var trustedSource = "Package.swift(product=\(product))"

        if let pin = try formatterPin(in: repositoryURL) {
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
    private static func relativePathEscapesWorkspace(_ path: String, workspace: URL) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("/") else { return true }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("..") else { return true }
        let resolved = workspace.appendingPathComponent(trimmed.isEmpty ? "." : trimmed).standardizedFileURL.path
        let root = workspace.standardizedFileURL.path
        return resolved != root && !resolved.hasPrefix(root + "/")
    }

    /// First `.executable(name: "...")` product declaration, in file order.
    private static func firstExecutableProduct(in source: String) -> String? {
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
