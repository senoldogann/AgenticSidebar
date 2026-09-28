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

    func testLocalDevelopmentHostsGetPlainHTTP() {
        XCTAssertEqual(
            BrowserURLNormalizer.normalizedURL(from: "localhost:3000")?.absoluteString,
            "http://localhost:3000"
        )
        XCTAssertEqual(
            BrowserURLNormalizer.normalizedURL(from: "localhost")?.absoluteString,
            "http://localhost"
        )
        XCTAssertEqual(
            BrowserURLNormalizer.normalizedURL(from: "127.0.0.1:8080/app")?.absoluteString,
            "http://127.0.0.1:8080/app"
        )
        XCTAssertEqual(
            BrowserURLNormalizer.normalizedURL(from: "192.168.1.5:3000")?.absoluteString,
            "http://192.168.1.5:3000"
        )
        XCTAssertEqual(
            BrowserURLNormalizer.normalizedURL(from: "[::1]:5173")?.absoluteString,
            "http://[::1]:5173"
        )
    }

    func testPublicHostWithPortGetsHTTPS() {
        XCTAssertEqual(
            BrowserURLNormalizer.normalizedURL(from: "example.com:8443")?.absoluteString,
            "https://example.com:8443"
        )
        XCTAssertEqual(
            BrowserURLNormalizer.normalizedURL(from: "8.8.8.8")?.absoluteString,
            "https://8.8.8.8"
        )
    }

    func testAbsolutePathBecomesFileURL() {
        let url = BrowserURLNormalizer.normalizedURL(from: "/tmp/site/index.html")

        XCTAssertEqual(url?.isFileURL, true)
        XCTAssertEqual(url?.path, "/tmp/site/index.html")
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
