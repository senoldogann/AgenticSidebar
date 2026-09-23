import Foundation
import XCTest

@testable import AgenticSidebar

final class ComputerUseFilesTests: XCTestCase {
    func testPermissionRulesKeepTheDenyFirstAskThenAllowOrder() {
        let rules = ComputerUseFiles.permissionRules

        XCTAssertEqual(
            rules.map(\.permission),
            [
                "chatgpt-system_*",
                "chatgpt-system_computer_*",
                "chatgpt-system_session_authority_*",
                "chatgpt-system_computer_health",
                "chatgpt-system_computer_run_js",
            ]
        )
        XCTAssertEqual(
            rules.map(\.action),
            ["deny", "ask", "ask", "allow", "deny"]
        )
    }

    func testConfigurationJSONWritesRulesInEvaluationOrder() {
        let json = ComputerUseFiles.configurationJSON(
            instructionsURL: URL(fileURLWithPath: "/tmp/instructions.md")
        )

        let denyRange = json.range(of: "\"chatgpt-system_*\": \"deny\"")
        let askRange = json.range(of: "\"chatgpt-system_computer_*\": \"ask\"")
        let authorityRange = json.range(of: "\"chatgpt-system_session_authority_*\": \"ask\"")
        let healthRange = json.range(of: "\"chatgpt-system_computer_health\": \"allow\"")
        let runJsRange = json.range(of: "\"chatgpt-system_computer_run_js\": \"deny\"")

        XCTAssertNotNil(denyRange)
        XCTAssertNotNil(askRange)
        XCTAssertNotNil(authorityRange)
        XCTAssertNotNil(healthRange)
        XCTAssertNotNil(runJsRange)

        // OpenCode "son eşleşen kural kazanır" uygular; sıra sözleşmenin parçası.
        if let denyRange, let askRange, let authorityRange, let healthRange, let runJsRange {
            XCTAssertLessThan(denyRange.lowerBound, askRange.lowerBound)
            XCTAssertLessThan(askRange.lowerBound, authorityRange.lowerBound)
            XCTAssertLessThan(authorityRange.lowerBound, healthRange.lowerBound)
            XCTAssertLessThan(healthRange.lowerBound, runJsRange.lowerBound)
        }
    }

    func testConfigurationJSONIsValidJSONAndPointsAtTheInstructionsFile() throws {
        let instructionsURL = URL(fileURLWithPath: "/Users/tester/notes/computer-use-instructions.md")
        let json = ComputerUseFiles.configurationJSON(instructionsURL: instructionsURL)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["$schema"] as? String, "https://opencode.ai/config.json")
        XCTAssertEqual(object["instructions"] as? [String], [instructionsURL.path])
        let permission = try XCTUnwrap(object["permission"] as? [String: String])
        // The app's own rules and the computer-use family rules share one file;
        // this asserts the family's five contributions.
        let familyRules = permission.filter { $0.key.hasPrefix("chatgpt-system_") }
        XCTAssertEqual(familyRules.count, 5)
    }

    func testWriteCreatesBothFilesInTheManagedDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = ComputerUseConfiguration(
            projectRootURL: directory.appendingPathComponent("chatgpt-system"),
            nodeExecutableURL: URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            workingDirectoryURL: directory
        )

        let configurationURL = try ComputerUseFiles.write(
            configuration: configuration,
            fileManager: .default
        )

        XCTAssertEqual(configurationURL.lastPathComponent, ComputerUseFiles.configurationFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configurationURL.path))

        let instructionsURL =
            directory
            .appendingPathComponent(ComputerUseFiles.instructionsFileName)
        let instructions = try String(contentsOf: instructionsURL, encoding: .utf8)
        XCTAssertTrue(instructions.contains("session_authority_start"))
        XCTAssertTrue(instructions.contains("computer_health"))
        XCTAssertTrue(instructions.contains("computer_observe"))
    }

    func testInstructionsDescribeTheApprovalAndLeaseContract() {
        let instructions = ComputerUseFiles.instructionsMarkdown()

        XCTAssertTrue(instructions.contains("Admin authority lease"))
        XCTAssertTrue(instructions.contains("Full access answers without a prompt"))
        XCTAssertTrue(instructions.contains("Ask and Approve for me may require user approval"))
        XCTAssertTrue(instructions.contains("--personal-admin") == false)
    }

    func testInstructionsUseTheSupportedComputerOpenAppTimeout() {
        let instructions = ComputerUseFiles.instructionsMarkdown()
        XCTAssertTrue(instructions.contains("`timeoutMs` up to 5000"))
        XCTAssertFalse(instructions.contains("`timeoutMs` up to 60000"))
    }

    func testInstructionsRequireAppSelectorAndDescribeRecovery() {
        let instructions = ComputerUseFiles.instructionsMarkdown()
        XCTAssertTrue(instructions.contains("REQUIRES `bundleIdentifier` or `name`"))
        XCTAssertTrue(instructions.contains("`target.by` is exactly one of"))
        XCTAssertTrue(instructions.contains("EITHER `x`/`y` OR `target`"))
        XCTAssertTrue(instructions.contains("`retryBudget` is allowed ONLY together with a semantic `target`"))
        XCTAssertTrue(instructions.contains("COMPUTER_PROTOCOL_INVALID"))
        XCTAssertTrue(instructions.contains("COMPUTER_USER_TAKEOVER"))
        XCTAssertTrue(instructions.contains("Hands off while anything runs"))
    }

    func testInstructionsDescribeUnavailableRecoveryWithoutBlindRetry() {
        let instructions = ComputerUseFiles.instructionsMarkdown()
        // Ekran görüntüsündeki döngü (observe -> UNAVAILABLE -> aynı observe)
        // yasaktır: önce tek bir health yoklaması, koşmuyorsa dur ve yönlendir.
        XCTAssertTrue(instructions.contains("COMPUTER_UNAVAILABLE"))
        XCTAssertTrue(instructions.contains("COMPUTER_DISABLED"))
        XCTAssertTrue(instructions.contains("do NOT retry the same observe/click in a loop"))
        XCTAssertTrue(instructions.contains("computer_health"))
    }
}
