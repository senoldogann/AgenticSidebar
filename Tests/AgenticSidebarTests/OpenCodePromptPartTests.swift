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
        guard case .text(let text) = try XCTUnwrap(parts.first) else {
            return XCTFail("Expected a text part")
        }
        XCTAssertTrue(
            text.contains("What is broken here?"),
            "The user message stays in the text part"
        )
        XCTAssertTrue(
            text.contains(imageURL.path),
            "An inlined image keeps its on-disk path so the agent can open the file itself"
        )
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

        XCTAssertEqual(
            object,
            [
                "type": "file",
                "mime": "image/png",
                "filename": "shot.png",
                "url": "data:image/png;base64,AAAA",
            ])
    }

    func testPlainTextMessagesStayASingleTextPart() throws {
        let parts = OpenCodePromptBuilder.parts(
            for: ChatMessage(role: .user, text: "Just a question"),
            speedMode: .normal
        )

        XCTAssertEqual(parts, [.text("<user_turn>\nJust a question\n</user_turn>")])
    }

    func testFastModeLeadsThePromptWithTheSpeedInstruction() throws {
        let fastParts = OpenCodePromptBuilder.parts(
            for: ChatMessage(role: .user, text: "Explain the failure"),
            speedMode: .fast
        )

        guard case .text(let fastText) = try XCTUnwrap(fastParts.first) else {
            return XCTFail("Expected a text part")
        }
        XCTAssertTrue(fastText.hasPrefix("FAST MODE:"))
        XCTAssertTrue(fastText.contains("Explain the failure"))
        XCTAssertTrue(fastText.hasSuffix("</user_turn>"))

        let normalParts = OpenCodePromptBuilder.parts(
            for: ChatMessage(role: .user, text: "Explain the failure"),
            speedMode: .normal
        )
        XCTAssertEqual(normalParts, [.text("<user_turn>\nExplain the failure\n</user_turn>")])
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
        guard case .text(let text) = try XCTUnwrap(parts.first) else {
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
        XCTAssertEqual(OpenCodePromptBuilder.inlineMIMEType(forPath: "/tmp/a.pdf"), "application/pdf")
        XCTAssertNil(
            OpenCodePromptBuilder.inlineMIMEType(forPath: "/tmp/a.txt"),
            "A text file part is rejected by the model layer; text is quoted into the prompt instead"
        )
        XCTAssertNil(OpenCodePromptBuilder.inlineMIMEType(forPath: "/tmp/a.md"))
        XCTAssertNil(OpenCodePromptBuilder.inlineMIMEType(forPath: "/tmp/a.zip"))
        XCTAssertNil(OpenCodePromptBuilder.inlineMIMEType(forPath: "/tmp/a.unknownextension"))
        XCTAssertNil(OpenCodePromptBuilder.inlineMIMEType(forPath: "/tmp/noextension"))
    }

    /// The regression this guards: a pasted document was attached as
    /// `{"type":"file","mime":"text/markdown"}`, the provider refused the turn with
    /// `'media type: text/markdown' functionality not supported.`, and because the
    /// rejected part stayed in the backend session every later turn of that
    /// conversation failed too — including ones with no attachment.
    func testTextAttachmentsAreQuotedIntoThePromptRatherThanSentAsFileParts() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let documentURL = directory.appendingPathComponent("readme.md")
        try Data("# Plan\n\nStep one.".utf8).write(to: documentURL)

        let parts = OpenCodePromptBuilder.parts(
            for: ChatMessage(
                role: .user,
                text: "Summarise this",
                attachmentPaths: [documentURL.path]
            ),
            speedMode: .normal
        )

        XCTAssertEqual(parts.count, 1, "A text attachment adds no file part")
        guard case .text(let text) = try XCTUnwrap(parts.first) else {
            return XCTFail("Expected a text part")
        }

        XCTAssertTrue(text.contains("Summarise this"))
        XCTAssertTrue(text.contains("readme.md"))
        XCTAssertTrue(text.contains("Step one."), "The document travels as prompt text")
        XCTAssertFalse(
            parts.contains { part in
                if case .file = part { return true }
                return false
            }
        )
    }

    func testTextTooLongToQuoteIsReferencedByPathInstead() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let documentURL = directory.appendingPathComponent("huge.txt")
        try Data(String(repeating: "a", count: 64).utf8).write(to: documentURL)

        XCTAssertNil(
            OpenCodePromptBuilder.quotedDocument(
                forPath: documentURL.path,
                maximumCharacters: 8
            )
        )

        XCTAssertNotNil(
            OpenCodePromptBuilder.quotedDocument(
                forPath: documentURL.path,
                maximumCharacters: 128
            )
        )
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
