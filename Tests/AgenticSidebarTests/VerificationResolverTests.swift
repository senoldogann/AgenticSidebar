import Foundation
import XCTest

@testable import AgenticSidebar

/// Trusted recipe resolution tests.
///
/// A recipe may only be derived from known project metadata: the presence of
/// `Package.swift` plus the repository's CI pin. Anything else is refused with a
/// typed error, and any caller-supplied (non-standard) recipe needs explicit
/// approval before it is accepted.
final class VerificationResolverTests: XCTestCase {

    // MARK: - Fixtures

    private struct Fixture {
        let root: URL
        let repositoryURL: URL
        let swiftExecutable: URL
        let swiftFormatExecutable: URL
    }

    /// The repository's real product declaration, reduced to the fields the resolver reads.
    private let repositoryPackageSwift = """
        // swift-tools-version: 6.2

        import PackageDescription

        let package = Package(
            name: "AgenticSidebar",
            products: [
                .executable(
                    name: "AgenticSidebar",
                    targets: ["AgenticSidebar"]
                )
            ]
        )
        """

    /// The repository's real formatter pin, reduced to the field the resolver reads.
    private let repositoryCI = """
        name: CI

        jobs:
          format:
            runs-on: macos-26
            env:
              SWIFT_FORMAT_VERSION: "604.0.0"
        """

    private func makeFixture(
        name: String,
        packageSwift: String?,
        ciYAML: String?
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentic-verification-resolver-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        let repositoryURL = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let swiftExecutable = try makeExecutable(named: "fake-swift", in: root)
        let swiftFormatExecutable = try makeExecutable(named: "fake-swift-format", in: root)

        if let packageSwift {
            try Data(packageSwift.utf8).write(to: repositoryURL.appendingPathComponent("Package.swift"))
        }
        if let ciYAML {
            let workflows = repositoryURL.appendingPathComponent(".github/workflows", isDirectory: true)
            try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
            try Data(ciYAML.utf8).write(to: workflows.appendingPathComponent("ci.yml"))
        }
        return Fixture(
            root: root,
            repositoryURL: repositoryURL,
            swiftExecutable: swiftExecutable,
            swiftFormatExecutable: swiftFormatExecutable
        )
    }

    private func makeExecutable(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func toolchain(
        fixture: Fixture,
        swiftExecutable: URL? = nil,
        swiftFormatVersion: String? = "604.0.0"
    ) -> VerificationToolchain {
        VerificationToolchain(
            swiftExecutable: swiftExecutable ?? fixture.swiftExecutable,
            swiftFormatExecutable: fixture.swiftFormatExecutable,
            installedSwiftFormatVersion: swiftFormatVersion
        )
    }

    private func step(
        _ name: String,
        _ executable: String,
        _ arguments: [String],
        cwd: String = ".",
        required: Bool = true
    ) -> VerificationStep {
        VerificationStep(
            name: name,
            executable: executable,
            arguments: arguments,
            relativeWorkingDirectory: cwd,
            timeoutSeconds: 60,
            required: required
        )
    }

    private func assertResolverError(
        _ error: Error,
        _ check: (VerificationResolverError) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let resolverError = error as? VerificationResolverError else {
            XCTFail("expected a VerificationResolverError, got \(error)", file: file, line: line)
            return
        }
        XCTAssertTrue(check(resolverError), "unexpected resolver error: \(resolverError)", file: file, line: line)
    }

    // MARK: - Standard recipes

    func testResolverProducesThisRepositoriesExactSwiftPMRecipe() async throws {
        let fixture = try makeFixture(
            name: "swiftpm",
            packageSwift: repositoryPackageSwift,
            ciYAML: repositoryCI
        )
        let resolver = VerificationResolver(toolchain: toolchain(fixture: fixture))

        let recipe = try await resolver.resolve(repository: fixture.repositoryURL)

        XCTAssertEqual(recipe.name, "swiftpm:AgenticSidebar")
        XCTAssertEqual(recipe.version, VerificationResolver.recipeVersion)
        XCTAssertEqual(
            recipe.steps.map(\.name),
            ["build", "test", "format"],
            "the repository recipe must be build, test and the optional formatter step"
        )
        XCTAssertTrue(recipe.skippedSteps.isEmpty)

        let build = recipe.steps[0]
        XCTAssertEqual(build.executable, fixture.swiftExecutable.path)
        XCTAssertEqual(build.arguments, ["build", "--product", "AgenticSidebar", "-Xswiftc", "-warnings-as-errors"])
        XCTAssertEqual(build.relativeWorkingDirectory, ".")
        XCTAssertGreaterThan(build.timeoutSeconds, 0)
        XCTAssertTrue(build.required)

        let test = recipe.steps[1]
        XCTAssertEqual(test.executable, fixture.swiftExecutable.path)
        XCTAssertEqual(test.arguments, ["test"])
        XCTAssertEqual(test.relativeWorkingDirectory, ".")
        XCTAssertTrue(test.required)

        let format = recipe.steps[2]
        XCTAssertEqual(format.executable, fixture.swiftFormatExecutable.path)
        XCTAssertEqual(format.arguments, ["lint", "-r", "--strict", "Sources", "Tests"])
        XCTAssertEqual(format.relativeWorkingDirectory, ".")
        XCTAssertFalse(format.required, "the formatter gate is optional, never a silent substitution")
        XCTAssertTrue(recipe.trustedSource.contains("AgenticSidebar"))
        XCTAssertTrue(recipe.trustedSource.contains("604.0.0"))
    }

    func testResolverRecordsVersionMismatchedFormatterAsSkipped() async throws {
        let fixture = try makeFixture(
            name: "format-mismatch",
            packageSwift: repositoryPackageSwift,
            ciYAML: repositoryCI
        )
        let resolver = VerificationResolver(toolchain: toolchain(fixture: fixture, swiftFormatVersion: "603.0.0"))

        let recipe = try await resolver.resolve(repository: fixture.repositoryURL)

        XCTAssertEqual(recipe.steps.map(\.name), ["build", "test"])
        XCTAssertEqual(recipe.skippedSteps.map(\.name), ["format"])
        let reason = try XCTUnwrap(recipe.skippedSteps.first?.reason)
        XCTAssertTrue(reason.contains("604.0.0"), "skip reason must name the pinned version: \(reason)")
        XCTAssertTrue(reason.contains("603.0.0"), "skip reason must name the installed version: \(reason)")
    }

    func testResolverRecordsMissingFormatterAsSkipped() async throws {
        let fixture = try makeFixture(
            name: "format-missing",
            packageSwift: repositoryPackageSwift,
            ciYAML: repositoryCI
        )
        let resolver = VerificationResolver(
            toolchain: VerificationToolchain(
                swiftExecutable: fixture.swiftExecutable,
                swiftFormatExecutable: nil,
                installedSwiftFormatVersion: nil
            )
        )

        let recipe = try await resolver.resolve(repository: fixture.repositoryURL)

        XCTAssertEqual(recipe.steps.map(\.name), ["build", "test"])
        XCTAssertEqual(recipe.skippedSteps.map(\.name), ["format"])
        XCTAssertTrue(recipe.skippedSteps[0].reason.contains("not installed"))
    }

    func testResolverRefusesUnknownProjectWithoutExtensionInference() async throws {
        let fixture = try makeFixture(name: "unknown", packageSwift: nil, ciYAML: nil)
        // A script and Swift sources are not project metadata: the resolver must never
        // infer commands from a file extension or run a repository script.
        try Data("#!/bin/sh\nswift build\n".utf8).write(to: fixture.repositoryURL.appendingPathComponent("build.sh"))
        try Data("all:\n\tswift build\n".utf8).write(to: fixture.repositoryURL.appendingPathComponent("Makefile"))
        try Data("print(\"hello\")\n".utf8).write(to: fixture.repositoryURL.appendingPathComponent("main.swift"))
        let resolver = VerificationResolver(toolchain: toolchain(fixture: fixture))

        do {
            _ = try await resolver.resolve(repository: fixture.repositoryURL)
            XCTFail("an unknown project must not resolve to a recipe")
        } catch {
            assertResolverError(error) { error in
                if case .unrecognizedProject = error { return true }
                return false
            }
        }
    }

    func testResolverRefusesMissingRequiredTool() async throws {
        let fixture = try makeFixture(
            name: "missing-tool",
            packageSwift: repositoryPackageSwift,
            ciYAML: repositoryCI
        )
        let missing = fixture.root.appendingPathComponent("missing-swift", isDirectory: false)
        let resolver = VerificationResolver(toolchain: toolchain(fixture: fixture, swiftExecutable: missing))

        do {
            _ = try await resolver.resolve(repository: fixture.repositoryURL)
            XCTFail("a missing required tool must refuse resolution")
        } catch {
            assertResolverError(error) { error in
                if case .requiredToolUnavailable(let step, let executable) = error {
                    return step == "build" && executable == missing.path
                }
                return false
            }
        }
    }

    // MARK: - Non-standard recipes

    private func nonStandardRecipe(
        executable: String = "/usr/bin/true",
        cwd: String = ".",
        required: Bool = true
    ) -> VerificationRecipe {
        VerificationRecipe(
            name: "caller-override",
            version: 1,
            trustedSource: "caller",
            steps: [step("override", executable, [], cwd: cwd, required: required)],
            skippedSteps: []
        )
    }

    func testResolverRefusesUnapprovedNonStandardExecution() async throws {
        let fixture = try makeFixture(
            name: "unapproved",
            packageSwift: repositoryPackageSwift,
            ciYAML: repositoryCI
        )
        let resolver = VerificationResolver(toolchain: toolchain(fixture: fixture))
        let request = NonStandardVerificationRequest(recipe: nonStandardRecipe(), approvedBy: nil)

        do {
            _ = try await resolver.resolve(repository: fixture.repositoryURL, nonStandard: request)
            XCTFail("an unapproved non-standard recipe must be refused")
        } catch {
            assertResolverError(error) { error in
                if case .nonStandardExecutionRequiresApproval = error { return true }
                return false
            }
        }
    }

    func testResolverAcceptsApprovedNonStandardExecutionWithProvenance() async throws {
        let fixture = try makeFixture(
            name: "approved",
            packageSwift: repositoryPackageSwift,
            ciYAML: repositoryCI
        )
        let resolver = VerificationResolver(toolchain: toolchain(fixture: fixture))
        let request = NonStandardVerificationRequest(recipe: nonStandardRecipe(), approvedBy: "operator@example.com")

        let recipe = try await resolver.resolve(repository: fixture.repositoryURL, nonStandard: request)

        XCTAssertEqual(recipe.steps.count, 1)
        XCTAssertEqual(recipe.steps[0].executable, "/usr/bin/true")
        XCTAssertTrue(recipe.trustedSource.contains("operator@example.com"))
    }

    func testResolverRefusesInvalidNonStandardExecutable() async throws {
        let fixture = try makeFixture(
            name: "invalid-executable",
            packageSwift: repositoryPackageSwift,
            ciYAML: repositoryCI
        )
        let resolver = VerificationResolver(toolchain: toolchain(fixture: fixture))

        for executable in ["swift", "/usr/bin/definitely-missing-\(UUID().uuidString)"] {
            let request = NonStandardVerificationRequest(
                recipe: nonStandardRecipe(executable: executable),
                approvedBy: "operator@example.com"
            )
            do {
                _ = try await resolver.resolve(repository: fixture.repositoryURL, nonStandard: request)
                XCTFail("invalid executable \(executable) must be refused")
            } catch {
                assertResolverError(error) { error in
                    if case .invalidExecutable(let step, let refused, _) = error {
                        return step == "override" && refused == executable
                    }
                    return false
                }
            }
        }
    }

    func testResolverRefusesPathEscapeInNonStandardWorkingDirectory() async throws {
        let fixture = try makeFixture(
            name: "path-escape",
            packageSwift: repositoryPackageSwift,
            ciYAML: repositoryCI
        )
        let resolver = VerificationResolver(toolchain: toolchain(fixture: fixture))

        for cwd in ["../outside", "Sources/../../outside", "/tmp"] {
            let request = NonStandardVerificationRequest(
                recipe: nonStandardRecipe(cwd: cwd),
                approvedBy: "operator@example.com"
            )
            do {
                _ = try await resolver.resolve(repository: fixture.repositoryURL, nonStandard: request)
                XCTFail("working directory \(cwd) must be refused")
            } catch {
                assertResolverError(error) { error in
                    if case .pathEscape(let step, let refused) = error {
                        return step == "override" && refused == cwd
                    }
                    return false
                }
            }
        }
    }
}
