import Foundation
import XCTest

@testable import AgenticSidebar

final class ToolApprovalSymlinkRegressionTests: XCTestCase {
    func testDanglingSymlinkToNewOutsideFileRequiresApproval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let base = root.appendingPathComponent("workspace", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missing = outside.appendingPathComponent("new.txt")
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("link.txt"), withDestinationURL: missing
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertTrue(
            ToolApprovalPolicy.reachesOutsideWorkingDirectory(["link.txt"], baseURL: base)
        )
        XCTAssertNil(
            ToolApprovalPolicy.approveSafe.automaticReply(
                for: "write", patterns: ["link.txt"], baseURL: base
            )
        )
    }

    func testNewFileBelowEscapingDirectorySymlinkRequiresApproval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let base = root.appendingPathComponent("workspace", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("link"),
            withDestinationURL: outside
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.txt").path))
        XCTAssertTrue(
            ToolApprovalPolicy.reachesOutsideWorkingDirectory(["link/new.txt"], baseURL: base)
        )
        XCTAssertNil(
            ToolApprovalPolicy.approveSafe.automaticReply(
                for: "write", patterns: ["link/new.txt"], baseURL: base
            )
        )
    }
}
