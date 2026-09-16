import Foundation
import XCTest
@testable import AgenticSidebar

final class ComputerUseConfigurationTests: XCTestCase {
    func testExpandResolvesHomeShorthand() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        XCTAssertEqual(
            ComputerUseConfiguration.expand(rootPath: "~/code/chatgpt-system", homeDirectoryURL: home),
            "/Users/tester/code/chatgpt-system"
        )
        XCTAssertEqual(
            ComputerUseConfiguration.expand(rootPath: "~", homeDirectoryURL: home),
            "/Users/tester"
        )
        XCTAssertEqual(
            ComputerUseConfiguration.expand(rootPath: "/opt/chatgpt-system", homeDirectoryURL: home),
            "/opt/chatgpt-system"
        )
        XCTAssertEqual(
            ComputerUseConfiguration.expand(rootPath: "   ", homeDirectoryURL: home),
            ""
        )
    }

    func testResolveFailsWhenTheCLIIsMissing() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = ComputerUseConfiguration.resolve(
            rootPath: root.path,
            workingDirectoryURL: root,
            environment: ["PATH": "/nonexistent"],
            fileManager: .default
        )

        guard case .failure(let error) = result else {
            return XCTFail("Expected a missing CLI failure")
        }
        XCTAssertEqual(error, .cliMissing(path: root.appendingPathComponent("dist/cli.js").path))
    }

    func testNodeLocatorReturnsNilWhenNothingIsExecutable() {
        XCTAssertNil(
            ComputerUseConfiguration.locateNode(
                environment: ["PATH": "/nonexistent/bin"],
                fileManager: .default,
                candidatePaths: []
            )
        )
    }

    func testResolveFindsNodeOnTheSearchPath() throws {
        let root = try makeTemporaryDirectory()
        let nodeDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: nodeDirectory)
        }
        try makeCLI(at: root)
        try makeExecutable(named: "node", in: nodeDirectory)

        let result = ComputerUseConfiguration.resolve(
            rootPath: root.path,
            workingDirectoryURL: root,
            environment: ["PATH": nodeDirectory.path],
            fileManager: .default
        )

        switch result {
        case .success(let configuration):
            XCTAssertEqual(configuration.projectRootURL.path, root.path)
            XCTAssertEqual(
                configuration.cliURL.path,
                root.appendingPathComponent("dist/cli.js").path
            )
            XCTAssertTrue(configuration.nodeExecutableURL.path.hasSuffix("/node"))
        case .failure(let error):
            XCTFail("Expected success, got \(error)")
        }
    }

    func testDecisionIsDisabledWithoutOptInAndInvalidWithABadPath() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            ComputerUseConfiguration.decision(
                enabled: false,
                rootPath: root.path,
                workingDirectoryURL: root,
                environment: ["PATH": "/nonexistent"],
                fileManager: .default
            ),
            .disabled
        )

        guard case .invalid(let message) = ComputerUseConfiguration.decision(
            enabled: true,
            rootPath: root.path,
            workingDirectoryURL: root,
            environment: ["PATH": "/nonexistent"],
            fileManager: .default
        ) else {
            return XCTFail("Expected an invalid decision")
        }
        XCTAssertTrue(message.contains("dist/cli.js"))
    }

    func testMCPServerConfigRunsTheCLIOverStdioWithComputerUseOnly() throws {
        let root = try makeTemporaryDirectory()
        let nodeDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: nodeDirectory)
        }
        try makeCLI(at: root)
        try makeExecutable(named: "node", in: nodeDirectory)

        let configuration = try ComputerUseConfiguration.resolve(
            rootPath: root.path,
            workingDirectoryURL: root,
            environment: ["PATH": nodeDirectory.path],
            fileManager: .default
        ).get()

        let serverConfig = configuration.mcpServerConfig()

        XCTAssertEqual(serverConfig.type, "local")
        XCTAssertTrue(serverConfig.enabled)
        XCTAssertEqual(serverConfig.environment, nil)
        XCTAssertEqual(serverConfig.command[0], configuration.nodeExecutableURL.path)
        XCTAssertEqual(serverConfig.command[1], configuration.cliURL.path)
        XCTAssertEqual(
            Array(serverConfig.command.dropFirst(2)),
            [
                "stdio",
                "--root", root.path,
                "--personal-admin",
                "--enable-computer-use"
            ]
        )
        XCTAssertFalse(serverConfig.command.contains("--enable-full-host-js"))
        XCTAssertFalse(serverConfig.command.contains("--enable-owner-runtime"))
    }

    func testHelperBundlePathIsUserLevelAndConfigurationIndependent() {
        let helper = ComputerUseConfiguration.helperBundleURL(
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )
        XCTAssertEqual(
            helper.path,
            "/Users/tester/.chatgpt-system/ChatGPTSystemComputerRuntime.app"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func makeCLI(at root: URL) throws {
        let directory = root.appendingPathComponent("dist", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("// cli".utf8).write(to: directory.appendingPathComponent("cli.js"))
    }

    private func makeExecutable(named name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}
