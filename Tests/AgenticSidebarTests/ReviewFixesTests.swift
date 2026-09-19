import Foundation
import XCTest

@testable import AgenticSidebar

/// İnceleme düzeltmelerinin regresyon testleri.
final class ReviewFixesTests: XCTestCase {
    func testJSONValueKeepsNumbersAsNumbers() {
        let decoded = try! JSONSerialization.jsonObject(with: Data("{\"a\":1,\"b\":0}".utf8)) as! [String: Any]
        let value = JSONValue(any: decoded)
        guard case .object(let members) = value else {
            return XCTFail("object beklenir")
        }
        let map = Dictionary(uniqueKeysWithValues: members.map { ($0.key, $0.value) })
        XCTAssertEqual(map["a"], .int(1))
        XCTAssertEqual(map["b"], .int(0))
    }

    func testJSONValueKeepsBooleans() {
        let decoded = try! JSONSerialization.jsonObject(with: Data("{\"t\":true}".utf8)) as! [String: Any]
        let value = JSONValue(any: decoded)
        guard case .object(let members) = value else {
            return XCTFail("object beklenir")
        }
        XCTAssertEqual(members.first?.value, .bool(true))
    }

    func testFileSizeHandlesNSNumber() {
        let number = NSNumber(value: 1234)
        XCTAssertEqual(SessionArchiveStore.fileSize(from: number), 1234)
        XCTAssertEqual(SessionArchiveStore.fileSize(from: 56 as Int), 56)
        XCTAssertNil(SessionArchiveStore.fileSize(from: nil))
    }

    func testSplitCommandHandlesQuotes() {
        XCTAssertEqual(SettingsView.splitCommand("npx -y \"my pkg\""), ["npx", "-y", "my pkg"])
        XCTAssertEqual(SettingsView.splitCommand("  ls   -la "), ["ls", "-la"])
    }

    func testRemoteMCPRequiresHTTPS() {
        let http = MCPDefinition(transport: .remote, url: "http://example.com/mcp")
        XCTAssertFalse(http.isRunnable)
        let https = MCPDefinition(transport: .remote, url: "https://example.com/mcp")
        XCTAssertTrue(https.isRunnable)
        let loopback = MCPDefinition(transport: .remote, url: "http://127.0.0.1:9999/mcp")
        XCTAssertTrue(loopback.isRunnable)
    }

    func testElapsedTimeHandlesNonFinite() {
        XCTAssertEqual(ElapsedTimeFormatter.string(seconds: .nan), "0:00")
        XCTAssertEqual(ElapsedTimeFormatter.string(seconds: .infinity), "0:00")
    }

    func testAttachmentStoragePruneKeepsNewest() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        for index in 0..<5 {
            let url = base.appendingPathComponent("f\(index)")
            try Data("x".utf8).write(to: url)
            try? FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(1000 + index))],
                ofItemAtPath: url.path
            )
        }
        AttachmentStorage.prune(directory: base, keeping: 3)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertEqual(remaining.count, 3)
        XCTAssertTrue(remaining.contains("f4"))
    }
}
