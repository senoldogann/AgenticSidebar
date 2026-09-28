import XCTest

@testable import AgenticSidebar

final class SSELineSplitterTests: XCTestCase {
    private func split(_ text: String) -> [String] {
        var splitter = SSELineSplitter()
        var lines: [String] = []
        for byte in Array(text.utf8) {
            if let line = splitter.feed(byte) {
                lines.append(line)
            }
        }
        if let line = splitter.finish() {
            lines.append(line)
        }
        return lines
    }

    func testUnicodeLineSeparatorsStayInsideTheLine() {
        let payload = "data: {\"delta\":\"a\u{2028}b\u{2029}c\u{85}d\"}\n\n"

        XCTAssertEqual(split(payload), ["data: {\"delta\":\"a\u{2028}b\u{2029}c\u{85}d\"}"])
    }

    func testCRLFAndBareCRAndLFAllEndLines() {
        XCTAssertEqual(
            split("data: 1\r\ndata: 2\rdata: 3\n\r\n: ping\ndata: 4"),
            ["data: 1", "data: 2", "data: 3", ": ping", "data: 4"]
        )
    }

    func testMultiByteCharactersSurvive() {
        XCTAssertEqual(split("data: çğüşöı 🚀\n"), ["data: çğüşöı 🚀"])
    }
}
