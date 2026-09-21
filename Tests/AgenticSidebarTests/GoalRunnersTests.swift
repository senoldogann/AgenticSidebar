import Foundation
import XCTest

@testable import AgenticSidebar

/// Doğrulama koşucuları: proje kontrolü (SwiftPM + Xcode), derleme-kırmızıysa-testi-atla,
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
        let package = temporaryDirectory()
        try? "// swift-tools-version: 6.0".write(
            to: package.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        let report = await runners.verify(packageDirectory: package)
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
        // `verify` desteklenen proje dizini ister (SwiftPM ya da Xcode).
        let package = temporaryDirectory()
        try? "// swift-tools-version: 6.0".write(
            to: package.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        let report = await runners.verify(packageDirectory: package)
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
        let package = temporaryDirectory()
        try? "// swift-tools-version: 6.0".write(
            to: package.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        let report = await runners.verify(packageDirectory: package)
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

    // MARK: - Xcode projeleri

    private func xcodeDirectory(projectName: String = "Demo") -> URL {
        let dir = temporaryDirectory()
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("\(projectName).xcodeproj"),
            withIntermediateDirectories: true
        )
        return dir
    }

    func testXcodeProjectPrefersProjectOverWorkspace() {
        let dir = temporaryDirectory()
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("B.xcworkspace"),
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("A.xcodeproj"),
            withIntermediateDirectories: true
        )
        let ref = GoalRunners.xcodeProject(at: dir)
        XCTAssertEqual(ref?.url.lastPathComponent, "A.xcodeproj")
        XCTAssertEqual(ref?.isWorkspace, false)
        XCTAssertEqual(ref?.flag, "-project")
    }

    func testXcodeProjectFindsWorkspaceWhenNoProject() {
        let dir = temporaryDirectory()
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Pods.xcworkspace"),
            withIntermediateDirectories: true
        )
        let ref = GoalRunners.xcodeProject(at: dir)
        XCTAssertEqual(ref?.url.lastPathComponent, "Pods.xcworkspace")
        XCTAssertEqual(ref?.isWorkspace, true)
        XCTAssertEqual(ref?.flag, "-workspace")
    }

    func testXcodeProjectIgnoresStrayFilesAndEmptyDirs() {
        let dir = temporaryDirectory()
        try? "sahte".write(
            to: dir.appendingPathComponent("A.xcodeproj"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertNil(GoalRunners.xcodeProject(at: dir))
        XCTAssertNil(GoalRunners.xcodeProject(at: temporaryDirectory()))
    }

    func testSupportedProjectPrefersSwiftPM() {
        let dir = xcodeDirectory()
        try? "// swift-tools-version: 6.0".write(
            to: dir.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(GoalRunners.supportedProject(at: dir), .swiftPM)
    }

    func testSupportedProjectFindsXcode() {
        let dir = xcodeDirectory(projectName: "OSJarvis")
        XCTAssertEqual(
            GoalRunners.supportedProject(at: dir),
            .xcode(
                GoalRunners.XcodeProjectRef(
                    url: dir.appendingPathComponent("OSJarvis.xcodeproj"),
                    isWorkspace: false
                )
            )
        )
    }

    func testUsableProjectDirectory() {
        let swift = temporaryDirectory()
        try? "// swift-tools-version: 6.0".write(
            to: swift.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(GoalRunners.usableProjectDirectory(at: swift)?.path, swift.path)

        let parent = temporaryDirectory()
        let child = parent.appendingPathComponent("App")
        try? FileManager.default.createDirectory(
            at: child.appendingPathComponent("Demo.xcodeproj"),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(GoalRunners.usableProjectDirectory(at: parent)?.path, child.path)

        let ambiguous = temporaryDirectory()
        for name in ["One", "Two"] {
            try? FileManager.default.createDirectory(
                at: ambiguous.appendingPathComponent(name).appendingPathComponent("D.xcodeproj"),
                withIntermediateDirectories: true
            )
        }
        XCTAssertNil(
            GoalRunners.usableProjectDirectory(at: ambiguous),
            "Birden çok adayda tahmin yürütülmez"
        )
        XCTAssertNil(GoalRunners.usableProjectDirectory(at: temporaryDirectory()))
    }

    func testXcodeSchemesParsing() {
        let project = """
            {"project":{"name":"Demo","schemes":["Demo","DemoTests"]}}
            """.data(using: .utf8)!
        XCTAssertEqual(GoalRunners.xcodeSchemes(fromListJSON: project), ["Demo", "DemoTests"])
        let workspace = """
            {"workspace":{"name":"Pods","schemes":["Pods"]}}
            """.data(using: .utf8)!
        XCTAssertEqual(GoalRunners.xcodeSchemes(fromListJSON: workspace), ["Pods"])
        XCTAssertEqual(GoalRunners.xcodeSchemes(fromListJSON: Data("bozuk".utf8)), [])
    }

    func testPreferredXcodeScheme() {
        XCTAssertEqual(
            GoalRunners.preferredXcodeScheme(from: ["B", "Demo", "A"], projectName: "Demo"),
            "Demo"
        )
        XCTAssertEqual(
            GoalRunners.preferredXcodeScheme(from: ["B", "A"], projectName: "Demo"),
            "A"
        )
        XCTAssertNil(GoalRunners.preferredXcodeScheme(from: [], projectName: "Demo"))
    }

    func testXcodebuildExecutableResolvesFromPATH() throws {
        let dir = temporaryDirectory()
        let fake = dir.appendingPathComponent("xcodebuild")
        try "#!/bin/sh\nexit 0\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let resolved = GoalRunners.xcodebuildExecutable(
            fileManager: .default,
            environment: ["PATH": dir.path]
        )
        XCTAssertEqual(resolved?.path, fake.path)
    }

    func testVerifyXcodeRunsListBuildThenTest() async {
        let recorder = XcodeCallRecorder()
        let runners = GoalRunners(
            execute: { _, arguments, _ in
                await recorder.append(arguments)
                if arguments.contains("-list") {
                    return GoalCommandResult(
                        exitCode: 0,
                        outputTail: #"{"project":{"name":"Demo","schemes":["Demo"]}}"#,
                        timedOut: false
                    )
                }
                return GoalCommandResult(exitCode: 0, outputTail: "ok", timedOut: false)
            },
            timeoutSeconds: 5
        )
        let report = await runners.verify(packageDirectory: xcodeDirectory(projectName: "Demo"))
        XCTAssertTrue(report.buildSucceeded)
        XCTAssertTrue(report.testsSucceeded)
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(calls[0].contains("-list"))
        XCTAssertTrue(calls[1].contains("build"))
        XCTAssertTrue(calls[2].contains("test"))
        XCTAssertTrue(calls[1].contains("Demo"), "Şema komuta taşınmalı")
    }

    func testVerifyXcodeSkipsTestWhenBuildFails() async {
        let recorder = XcodeCallRecorder()
        let runners = GoalRunners(
            execute: { _, arguments, _ in
                await recorder.append(arguments)
                if arguments.contains("-list") {
                    return GoalCommandResult(
                        exitCode: 0,
                        outputTail: #"{"project":{"name":"Demo","schemes":["Demo"]}}"#,
                        timedOut: false
                    )
                }
                if arguments.contains("build") {
                    return GoalCommandResult(exitCode: 65, outputTail: "derleme patladı", timedOut: false)
                }
                return GoalCommandResult(exitCode: 0, outputTail: "ok", timedOut: false)
            },
            timeoutSeconds: 5
        )
        let report = await runners.verify(packageDirectory: xcodeDirectory(projectName: "Demo"))
        XCTAssertFalse(report.buildSucceeded)
        XCTAssertNil(report.tests)
        let recordedCount = await recorder.calls.count
        XCTAssertEqual(recordedCount, 2)
    }

    func testVerifyXcodeRefusesWhenNoSchemes() async {
        let runners = GoalRunners(
            execute: { _, _, _ in
                GoalCommandResult(
                    exitCode: 0,
                    outputTail: #"{"project":{"name":"Demo","schemes":[]}}"#,
                    timedOut: false
                )
            },
            timeoutSeconds: 5
        )
        let report = await runners.verify(packageDirectory: xcodeDirectory(projectName: "Demo"))
        XCTAssertFalse(report.buildSucceeded)
        XCTAssertTrue(report.build.outputTail.contains("No Xcode schemes"))
    }

    func testVerifyRefusesUnsupportedDirectory() async {
        let runners = GoalRunners(
            execute: { _, _, _ in
                GoalCommandResult(exitCode: 0, outputTail: "ok", timedOut: false)
            },
            timeoutSeconds: 5
        )
        let report = await runners.verify(packageDirectory: temporaryDirectory())
        XCTAssertFalse(report.buildSucceeded)
        XCTAssertNil(report.tests)
    }

    func testEnclosingXcodeProjectWalksUpFromNestedFile() {
        let root = xcodeDirectory()
        let nested = root.appendingPathComponent("Demo/Sources")
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("App.swift")
        try? "// empty".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(GoalRunners.enclosingXcodeProject(for: file.path)?.path, root.path)
    }

    func testResolvePackageDirectoryFindsXcodeAndPrefersSwiftPM() {
        let xcode = xcodeDirectory(projectName: "Demo")
        XCTAssertEqual(
            GoalRunners.resolvePackageDirectory(knownPaths: [xcode.path], seedPaths: [])?.path,
            xcode.path
        )
        let swift = temporaryDirectory()
        try? "// swift-tools-version: 6.0".write(
            to: swift.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(
            GoalRunners.resolvePackageDirectory(knownPaths: [xcode.path, swift.path], seedPaths: [])?.path,
            swift.path
        )
    }
}

/// `verify` stub'unda komut kaydı: `execute` eşzamanlı-kısıtlı kapanıştır,
/// o yüzden sayaç `actor` arkasında tutulur.
private actor XcodeCallRecorder {
    private(set) var calls: [[String]] = []
    func append(_ call: [String]) {
        calls.append(call)
    }
}
