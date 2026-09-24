import Foundation
import XCTest

@testable import AgenticSidebar

final class BrowserCookieImportTests: XCTestCase {
    // MARK: - Safari binarycookies

    func testSafariParserReadsACookie() throws {
        let expiry = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let data = Self.makeBinaryCookies(
            domain: "example.com",
            name: "session",
            value: "abc123",
            path: "/app",
            isSecure: true,
            expiry: expiry.timeIntervalSinceReferenceDate
        )

        let cookies = try SafariCookieParser.parse(data: data)

        XCTAssertEqual(cookies.count, 1)
        let cookie = try XCTUnwrap(cookies.first)
        XCTAssertEqual(cookie.domain, "example.com")
        XCTAssertEqual(cookie.name, "session")
        XCTAssertEqual(cookie.value, "abc123")
        XCTAssertEqual(cookie.path, "/app")
        XCTAssertTrue(cookie.isSecure)
        let expiresAt = try XCTUnwrap(cookie.expiresAt)
        XCTAssertEqual(expiresAt.timeIntervalSinceReferenceDate, expiry.timeIntervalSinceReferenceDate, accuracy: 0.001)
    }

    func testSafariParserRejectsBadMagic() {
        XCTAssertThrowsError(try SafariCookieParser.parse(data: Data([0, 1, 2, 3, 4, 5, 6, 7])))
    }

    func testSafariExpiryZeroMeansSession() {
        XCTAssertNil(SafariCookieImporter.expiryDate(macEpochSeconds: 0))
        XCTAssertNotNil(SafariCookieImporter.expiryDate(macEpochSeconds: 1))
    }

    // MARK: - Chrome dönemi

    func testChromeExpiryConversion() throws {
        // 2024-01-01 00:00 UTC: (1704067200 + 11644473600) * 1_000_000.
        let micros: Int64 = 13_348_540_800_000_000
        let date = try XCTUnwrap(
            ChromeCookieImporter.expiryDate(webKitMicroseconds: micros, isSession: false)
        )

        XCTAssertEqual(date.timeIntervalSince1970, 1_704_067_200, accuracy: 1)
    }

    func testChromeSessionOrEmptyExpiryIsNil() {
        XCTAssertNil(ChromeCookieImporter.expiryDate(webKitMicroseconds: 13_348_435_200_000_000, isSession: true))
        XCTAssertNil(ChromeCookieImporter.expiryDate(webKitMicroseconds: 0, isSession: false))
    }

    // MARK: - Özet metni

    func testSummaryTextWithNothingFound() {
        let summary = BrowserProfileImporter.Summary(
            imported: 0,
            skippedEncrypted: 0,
            chromeNote: nil,
            safariNote: nil
        )

        XCTAssertEqual(summary.displayText, "No browser cookies were found to import")
    }

    func testSummaryTextWithImportsAndSkips() {
        let summary = BrowserProfileImporter.Summary(
            imported: 4310,
            skippedEncrypted: 3,
            chromeNote: nil,
            safariNote: nil
        )

        XCTAssertTrue(summary.displayText.contains("4310"))
        XCTAssertTrue(summary.displayText.contains("3"))
    }

    // MARK: - Sentetik binarycookies kurucusu

    private static func makeBinaryCookies(
        domain: String,
        name: String,
        value: String,
        path: String,
        isSecure: Bool,
        expiry: Double
    ) -> Data {
        var record = Data()
        func append32(_ value: UInt32) {
            record.append(UInt8(value & 0xFF))
            record.append(UInt8((value >> 8) & 0xFF))
            record.append(UInt8((value >> 16) & 0xFF))
            record.append(UInt8((value >> 24) & 0xFF))
        }
        func appendDouble(_ value: Double) {
            append32(UInt32(value.bitPattern & 0xFFFF_FFFF))
            append32(UInt32(value.bitPattern >> 32))
        }
        func appendString(_ text: String) -> Int {
            let offset = record.count
            record.append(contentsOf: text.utf8)
            record.append(0)
            return offset
        }

        // Başlık (56 bayt) önce yer tutar, dizeler sonra yazılır.
        let headerSize = 56
        record.append(contentsOf: [UInt8](repeating: 0, count: headerSize))
        let urlOffset = appendString(domain) - 0
        let nameOffset = appendString(name)
        let pathOffset = appendString(path)
        let valueOffset = appendString(value)

        func patch32(at offset: Int, value: Int) {
            record[offset] = UInt8(value & 0xFF)
            record[offset + 1] = UInt8((value >> 8) & 0xFF)
            record[offset + 2] = UInt8((value >> 16) & 0xFF)
            record[offset + 3] = UInt8((value >> 24) & 0xFF)
        }
        patch32(at: 0, value: record.count)
        patch32(at: 8, value: isSecure ? 0x1 : 0x0)
        patch32(at: 16, value: urlOffset)
        patch32(at: 20, value: nameOffset)
        patch32(at: 24, value: pathOffset)
        patch32(at: 28, value: valueOffset)

        var cookie = record
        func patchDouble(into data: inout Data, at offset: Int, value: Double) {
            let bits = value.bitPattern
            data[offset] = UInt8(bits & 0xFF)
            data[offset + 1] = UInt8((bits >> 8) & 0xFF)
            data[offset + 2] = UInt8((bits >> 16) & 0xFF)
            data[offset + 3] = UInt8((bits >> 24) & 0xFF)
            data[offset + 4] = UInt8((bits >> 32) & 0xFF)
            data[offset + 5] = UInt8((bits >> 40) & 0xFF)
            data[offset + 6] = UInt8((bits >> 48) & 0xFF)
            data[offset + 7] = UInt8((bits >> 56) & 0xFF)
        }
        patchDouble(into: &cookie, at: 40, value: expiry)
        patchDouble(into: &cookie, at: 48, value: expiry)

        var file = Data("cook".utf8)
        func appendBigEndian32(_ value: UInt32) {
            file.append(UInt8((value >> 24) & 0xFF))
            file.append(UInt8((value >> 16) & 0xFF))
            file.append(UInt8((value >> 8) & 0xFF))
            file.append(UInt8(value & 0xFF))
        }
        appendBigEndian32(1)
        let pageSize = UInt32(8 + cookie.count)
        appendBigEndian32(pageSize)
        // Sayfa: çerez sayısı (LE) + ofset (LE) + kayıt.
        file.append(contentsOf: [1, 0, 0, 0, 8, 0, 0, 0])
        file.append(cookie)
        return file
    }
}
