import Foundation
import XCTest

@testable import AgenticSidebar

final class BrowserURLNormalizerTests: XCTestCase {
    func testKnownSchemeIsKept() {
        XCTAssertEqual(
            BrowserURLNormalizer.normalizedURL(from: "https://example.com/docs?q=1")?.absoluteString,
            "https://example.com/docs?q=1"
        )
        XCTAssertEqual(
            BrowserURLNormalizer.normalizedURL(from: "about:blank")?.absoluteString,
            "about:blank"
        )
    }

    func testSchemelessHostGetsHTTPS() {
        XCTAssertEqual(
            BrowserURLNormalizer.normalizedURL(from: "example.com")?.absoluteString,
            "https://example.com"
        )
        XCTAssertEqual(
            BrowserURLNormalizer.normalizedURL(from: "docs.example.com/path")?.absoluteString,
            "https://docs.example.com/path"
        )
    }

    func testHostWithPortGetsHTTPS() {
        XCTAssertEqual(
            BrowserURLNormalizer.normalizedURL(from: "localhost:3000")?.absoluteString,
            "https://localhost:3000"
        )
    }

    func testPlainTextBecomesSearchQuery() {
        let url = BrowserURLNormalizer.normalizedURL(from: "swiftui navigation")

        XCTAssertEqual(url?.host, "www.google.com")
        XCTAssertEqual(url?.path, "/search")
        XCTAssertEqual(url?.query, "q=swiftui%20navigation")
    }

    func testWhitespaceIsTrimmedAndEmptyIsRefused() {
        XCTAssertEqual(
            BrowserURLNormalizer.normalizedURL(from: "  example.com  ")?.absoluteString,
            "https://example.com"
        )
        XCTAssertNil(BrowserURLNormalizer.normalizedURL(from: "   "))
    }
}
