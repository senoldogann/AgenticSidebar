import Foundation
import XCTest
@testable import AgenticSidebar

/// The prompt shape is not guesswork: OpenCode 1.18.31 accepts file parts as
/// `{type, mime, filename, url}` and its own CLI inlines attachments as `data:`
/// URLs, so these tests pin that contract down.
final class OpenCodePromptPartTests: XCTestCase {
    func testReadableImagesBecomeInlineFileParts() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageURL = directory.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]).write(to: imageURL)

        let parts = OpenCodePromptBuilder.parts(
            for: ChatMessage(
                role: .user,
                text: "What is broken here?",
                attachmentPaths: [imageURL.path]
            ),
            speedMode: .normal
        )

        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts.first, .text("What is broken here?"))
        XCTAssertEqual(
            parts.last,
            .file(
                mime: "image/png",
                filename: "shot.png",
                url: "data:image/png;base64,\(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]).base64EncodedString())"
            )
        )
    }

    func testFilePartEncodesTheVerifiedWireShape() throws {
        let part = OpenCodePromptPart.file(
            mime: "image/png",
            filename: "shot.png",
            url: "data:image/png;base64,AAAA"
        )

        let data = try JSONEncoder().encode(part)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )

        XCTAssertEqual(object, [
            "type": "file",
            "mime": "image/png",
            "filename": "shot.png",
            "url": "data:image/png;base64,AAAA"
        ])
    }

    func testPlainTextMessagesStayASingleTextPart() throws {
        let parts = OpenCodePromptBuilder.parts(
            for: ChatMessage(role: .user, text: "Just a question"),
            speedMode: .normal
        )

        XCTAssertEqual(parts, [.text("Just a question")])
    }

    func testFastModeLeadsThePromptWithTheSpeedInstruction() throws {
        let fastParts = OpenCodePromptBuilder.parts(
            for: ChatMessage(role: .user, text: "Explain the failure"),
            speedMode: .fast
        )

        guard case let .text(fastText) = try XCTUnwrap(fastParts.first) else {
            return XCTFail("Expected a text part")
        }
        XCTAssertTrue(fastText.hasPrefix("FAST MODE:"))
        XCTAssertTrue(fastText.hasSuffix("Explain the failure"))

        let normalParts = OpenCodePromptBuilder.parts(
            for: ChatMessage(role: .user, text: "Explain the failure"),
            speedMode: .normal
        )
        XCTAssertEqual(normalParts, [.text("Explain the failure")])
    }

    func testUnsupportedOrMissingFilesAreReferencedByPathInsteadOfDropped() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let archiveURL = directory.appendingPathComponent("bundle.zip")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: archiveURL)

        let parts = OpenCodePromptBuilder.parts(
            for: ChatMessage(
                role: .user,
                text: "See attached",
                attachmentPaths: [archiveURL.path, directory.appendingPathComponent("missing.png").path]
            ),
            speedMode: .normal
        )

        XCTAssertEqual(parts.count, 1)
        guard case let .text(text) = try XCTUnwrap(parts.first) else {
            return XCTFail("Expected a text part")
        }
        XCTAssertTrue(text.contains("See attached"))
        XCTAssertTrue(text.contains("bundle.zip"))
        XCTAssertTrue(text.contains("missing.png"))
    }

    func testOversizedFilesAreReferencedByPathInsteadOfInlined() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageURL = directory.appendingPathComponent("big.png")
        try Data(repeating: 1, count: 32).write(to: imageURL)

        XCTAssertNil(
            OpenCodePromptBuilder.inlinePart(
                forPath: imageURL.path,
                maximumInlineBytes: 8
            )
        )

        let parts = OpenCodePromptBuilder.parts(
            for: ChatMessage(
                role: .user,
                text: "look",
                attachmentPaths: [imageURL.path]
            ),
            speedMode: .normal,
            maximumInlineBytes: 8
        )

        XCTAssertEqual(parts.count, 1, "An oversized file is not inlined")
    }

    func testEmptyFilesAreSkipped() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let emptyURL = directory.appendingPathComponent("empty.png")
        try Data().write(to: emptyURL)

        XCTAssertNil(OpenCodePromptBuilder.inlinePart(forPath: emptyURL.path))
    }

    func testMimeTypeOnlyInlinesMediaTheBackendCanForward() {
        XCTAssertEqual(OpenCodePromptBuilder.inlineMIMEType(forPath: "/tmp/a.png"), "image/png")
        XCTAssertEqual(OpenCodePromptBuilder.inlineMIMEType(forPath: "/tmp/a.txt"), "text/plain")
        XCTAssertEqual(OpenCodePromptBuilder.inlineMIMEType(forPath: "/tmp/a.pdf"), "application/pdf")
        XCTAssertNil(OpenCodePromptBuilder.inlineMIMEType(forPath: "/tmp/a.zip"))
        XCTAssertNil(OpenCodePromptBuilder.inlineMIMEType(forPath: "/tmp/a.unknownextension"))
        XCTAssertNil(OpenCodePromptBuilder.inlineMIMEType(forPath: "/tmp/noextension"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-part-tests-\(UUID().uuidString)")

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        return directory
    }
}
