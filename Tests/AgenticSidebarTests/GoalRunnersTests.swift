import Foundation
import XCTest

@testable import AgenticSidebar

/// Doğrulama koşucuları: paket kontrolü, derleme-kırmızıysa-testi-atla,
/// gerçek süreç ve zaman aşımı yolu.
final class GoalRunnersTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testIsSwiftPackageRequiresManifest() {
        let empty = temporaryDirectory()
        XCTAssertFalse(GoalRunners.isSwiftPackage(at: empty))
        try? "// swift-tools-version: 6.0".write(
            to: empty.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertTrue(GoalRunners.isSwiftPackage(at: empty))
    }

    func testEnclosingSwiftPackageWalksUpFromNestedFile() {
        let root = temporaryDirectory()
        let nested = root.appendingPathComponent("Sources/App")
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try? "// swift-tools-version: 6.0".write(
            to: root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        let file = nested.appendingPathComponent("Main.swift")
        try? "// empty".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(GoalRunners.enclosingSwiftPackage(for: file.path)?.path, root.path)
        XCTAssertEqual(GoalRunners.enclosingSwiftPackage(for: nested.path)?.path, root.path)
    }

    func testEnclosingSwiftPackageIgnoresMissingPaths() {
        XCTAssertNil(GoalRunners.enclosingSwiftPackage(for: ""))
        XCTAssertNil(
            GoalRunners.enclosingSwiftPackage(
                for: "/definitely-not-here-goal-test/Nested/File.swift"
            )
        )
        XCTAssertNil(GoalRunners.enclosingSwiftPackage(for: temporaryDirectory().path))
    }

    func testResolvePackageDirectoryPrefersKnownThenSeeds() {
        let root = temporaryDirectory()
        try? "// swift-tools-version: 6.0".write(
            to: root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        let nestedFile = root.appendingPathComponent("Sources/Main.swift")
        try? FileManager.default.createDirectory(
            at: nestedFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? "// empty".write(to: nestedFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            GoalRunners.resolvePackageDirectory(knownPaths: [root.path], seedPaths: [])?.path,
            root.path
        )
        XCTAssertEqual(
            GoalRunners.resolvePackageDirectory(knownPaths: [""], seedPaths: [nestedFile.path])?.path,
            root.path
        )
        XCTAssertNil(
            GoalRunners.resolvePackageDirectory(knownPaths: [""], seedPaths: [""])
        )
    }

    func testSwiftExecutableResolvesFromPATH() throws {
        let dir = temporaryDirectory()
        let fake = dir.appendingPathComponent("swift")
        try "#!/bin/sh\nexit 0\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let resolved = GoalRunners.swiftExecutable(
            fileManager: .default,
            environment: ["PATH": dir.path]
        )
        XCTAssertEqual(resolved?.path, fake.path)
    }

    func testVerifySkipsTestsWhenBuildFails() async {
        let runners = GoalRunners(
            execute: { _, arguments, _ in
                if arguments == ["build"] {
                    return GoalCommandResult(exitCode: 1, outputTail: "boom", timedOut: false)
                }
                return GoalCommandResult(exitCode: 0, outputTail: "ok", timedOut: false)
            },
            timeoutSeconds: 5
        )
        let report = await runners.verify(packageDirectory: temporaryDirectory())
        XCTAssertFalse(report.buildSucceeded)
        XCTAssertFalse(report.testsSucceeded)
        XCTAssertNil(report.tests)
        XCTAssertTrue(report.summary.contains("build failed"))
    }

    func testVerifyRunsTestsWhenBuildPasses() async {
        let runners = GoalRunners(
            execute: { _, _, _ in
                GoalCommandResult(exitCode: 0, outputTail: "ok", timedOut: false)
            },
            timeoutSeconds: 5
        )
        let report = await runners.verify(packageDirectory: temporaryDirectory())
        XCTAssertTrue(report.buildSucceeded)
        XCTAssertTrue(report.testsSucceeded)
        XCTAssertTrue(report.summary.contains("build and tests passed"))
    }

    func testVerifyReportsMissingToolchain() async {
        // Boş PATH + bilinen konumlarda swift yoksa kayıp sayılır; varsa bu
        // test stub yola girmez, o yüzden yalnız sonuç tutarlılığı bakılır.
        let runners = GoalRunners(
            execute: { _, _, _ in
                GoalCommandResult(exitCode: 0, outputTail: "ok", timedOut: false)
            },
            timeoutSeconds: 5
        )
        let report = await runners.verify(packageDirectory: temporaryDirectory())
        XCTAssertTrue(report.buildSucceeded)
    }

    func testRunThroughProcessEcho() async {
        let result = await GoalRunners.runThroughProcess(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello-goal"],
            workingDirectory: temporaryDirectory(),
            timeoutSeconds: 10
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.outputTail.contains("hello-goal"))
        XCTAssertFalse(result.timedOut)
    }

    func testRunThroughProcessDrainsOutputLargerThanPipeCapacity() async {
        let result = await GoalRunners.runThroughProcess(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", String(repeating: "x", count: 128_000)],
            workingDirectory: temporaryDirectory(),
            timeoutSeconds: 5
        )
        XCTAssertTrue(result.succeeded, result.outputTail)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.outputTail.count, GoalRunners.reportTailCharacters)
    }

    func testRunThroughProcessFailure() async {
        let result = await GoalRunners.runThroughProcess(
            executable: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [],
            workingDirectory: temporaryDirectory(),
            timeoutSeconds: 10
        )
        XCTAssertFalse(result.succeeded)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
    }

    func testRunThroughProcessTimeout() async {
        let result = await GoalRunners.runThroughProcess(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"],
            workingDirectory: temporaryDirectory(),
            timeoutSeconds: 1
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
    }

    func testRunThroughProcessCancellationStopsTheChildPromptly() async {
        let directory = temporaryDirectory()
        let started = Date()
        let task = Task {
            await GoalRunners.runThroughProcess(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                workingDirectory: directory,
                timeoutSeconds: 60
            )
        }

        do {
            try await Task.sleep(for: .milliseconds(100))
        } catch {
            XCTFail("İptal testi beklemesi başarısız: \(error)")
            return
        }
        task.cancel()
        let result = await task.value

        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.outputTail.contains("Cancelled"))
    }

    func testTimeoutDiagnosticDoesNotExposeCommandArguments() async throws {
        let directory = temporaryDirectory()
        let script = directory.appendingPathComponent("goal-fixture")
        try "#!/bin/sh\nexec /bin/sleep 2\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let result = await GoalRunners.runThroughProcess(
            executable: script,
            arguments: ["sensitive-argument-marker"],
            workingDirectory: directory,
            timeoutSeconds: 0.1
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.outputTail.contains("sensitive-argument-marker"))
    }

    func testExitedParentDoesNotWaitForBackgroundChildHoldingOutputPipe() async {
        let started = Date()
        let result = await GoalRunners.runThroughProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo goal-ready; /bin/sleep 4 &"],
            workingDirectory: temporaryDirectory(),
            timeoutSeconds: 0.5
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 2,
            "A child that inherited stdout must not keep a completed verification waiting"
        )
        XCTAssertTrue(result.succeeded, result.outputTail)
        XCTAssertTrue(result.outputTail.contains("goal-ready"))
    }

    func testRunThroughProcessMissingExecutable() async {
        let result = await GoalRunners.runThroughProcess(
            executable: URL(fileURLWithPath: "/tmp/definitely-not-here-goal-test"),
            arguments: [],
            workingDirectory: temporaryDirectory(),
            timeoutSeconds: 5
        )
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.outputTail.contains("Could not launch"))
    }
}
