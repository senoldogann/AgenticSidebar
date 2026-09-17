import Foundation
import XCTest
@testable import AgenticSidebar

final class PastedTextAttachmentTests: XCTestCase {
    func testShortPastesStayInline() {
        XCTAssertFalse(PastedTextAttachment.shouldSpillToFile("Hello"))
        XCTAssertFalse(
            PastedTextAttachment.shouldSpillToFile(
                String(repeating: "a", count: PastedTextAttachment.thresholdCharacters)
            ),
            "exactly at the threshold still fits the field"
        )
    }

    func testLongPastesSpillToAFile() {
        XCTAssertTrue(
            PastedTextAttachment.shouldSpillToFile(
                String(repeating: "a", count: PastedTextAttachment.thresholdCharacters + 1)
            )
        )
    }

    func testMultilinePasteSpillsToAFileEvenWhenCharacterCountIsLow() {
        let lines = (1...25).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertLessThan(lines.count, PastedTextAttachment.thresholdCharacters)
        XCTAssertTrue(PastedTextAttachment.shouldSpillToFile(lines))
    }

    func testFileNameIsMarkdownAndUnique() {
        let first = PastedTextAttachment.fileName(date: Date(), uniquifier: "aaaaaa")
        let second = PastedTextAttachment.fileName(date: Date(), uniquifier: "bbbbbb")

        XCTAssertTrue(first.hasPrefix("pasted-text-"))
        XCTAssertTrue(first.hasSuffix(".md"))
        XCTAssertNotEqual(first, second)
    }

    func testSpillWritesTheTextAndPrunesOldSpills() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let url = try PastedTextAttachment.spill(
            String(repeating: "x", count: 2_500),
            uniquifier: "first1",
            fileManager: .default,
            baseURL: base
        )
        XCTAssertEqual(url.pathExtension, "md")
        XCTAssertEqual(url.lastPathComponent, "readme.md")
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8).count,
            2_500,
            "the file holds the whole paste, not a preview"
        )

        // One over the cap prunes exactly the oldest spill.
        for index in 0..<(PastedTextAttachment.maximumStoredFiles + 1) {
            _ = try PastedTextAttachment.spill(
                "spill \(index)",
                uniquifier: String(format: "u%05d", index),
                fileManager: .default,
                baseURL: base
            )
        }

        let folder = PastedTextAttachment.directory(baseURL: base)
        let kept = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        XCTAssertEqual(kept.count, PastedTextAttachment.maximumStoredFiles)
    }

    func testSpillWithoutAStorageLocationThrows() {
        XCTAssertThrowsError(
            try PastedTextAttachment.spill("text", fileManager: .default, baseURL: nil)
        ) { error in
            XCTAssertEqual(error as? PastedTextAttachmentError, .noStorageLocation)
        }
    }
}
