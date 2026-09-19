import Foundation
import XCTest

@testable import AgenticSidebar

final class ToolApprovalRoutingRegressionTests: XCTestCase {
    func testMutatingToolsReachTheAppApprovalPolicy() {
        let rules = Dictionary(
            uniqueKeysWithValues: ToolApprovalPolicy.routedPermissionRules.map { ($0.key, $0.value) }
        )
        for tool in ["edit", "write", "patch", "multiedit"] {
            XCTAssertEqual(rules[tool], .string("ask"), "A backend allow never emits a permission request for \(tool)")
        }
    }

    func testAskPreservesInFolderEditsButDoesNotApproveUnknownOrExternalPaths() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        for tool in ["edit", "write", "patch", "multiedit"] {
            XCTAssertEqual(
                ToolApprovalPolicy.ask.automaticReply(for: tool, patterns: ["Notes.txt"], baseURL: base),
                .once,
                "Existing in-folder edit behavior must survive routing"
            )
            XCTAssertNil(ToolApprovalPolicy.ask.automaticReply(for: tool, patterns: [], baseURL: base))
            XCTAssertNil(ToolApprovalPolicy.ask.automaticReply(for: tool, patterns: ["/etc/passwd"], baseURL: base))
            XCTAssertNil(ToolApprovalPolicy.approveSafe.automaticReply(for: tool, patterns: [], baseURL: base))
        }
    }
}
