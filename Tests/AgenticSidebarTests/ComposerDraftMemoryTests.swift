import Foundation
import XCTest

@testable import AgenticSidebar

@MainActor
final class ComposerDraftMemoryTests: XCTestCase {
    func testDraftsAreKeptPerSession() {
        let memory = ComposerDraftMemory()
        let first = UUID()
        let second = UUID()

        memory.drafts[first] = ComposerDraft(text: "hello", attachedURLs: [], selectedTags: [])
        memory.drafts[second] = ComposerDraft(text: "", attachedURLs: [], selectedTags: [])

        XCTAssertEqual(memory.drafts[first]?.text, "hello")
        XCTAssertEqual(memory.drafts[second]?.text, "")
    }

    func testDiscardDropsOnlyRemovedSessions() {
        let memory = ComposerDraftMemory()
        let live = UUID()
        let removed = UUID()

        memory.drafts[live] = ComposerDraft(text: "keep me", attachedURLs: [], selectedTags: [])
        memory.drafts[removed] = ComposerDraft(text: "drop me", attachedURLs: [], selectedTags: [])

        memory.discardSessions(notIn: [live])

        XCTAssertEqual(memory.drafts[live]?.text, "keep me")
        XCTAssertNil(
            memory.drafts[removed],
            "Silinen sohbetin taslağı tutulmamalı, yoksa başka sohbete sızar"
        )
    }

    /// Metin alanı oturuma bağlı kimlik taşır.
    ///
    /// `ComposerTextEditor` bir `NSViewRepresentable`: koordinatör
    /// oluşturulduğu andaki yazma bağlamayı tutar. Yan yana takasta aynı
    /// konumdaki alan başka oturumu gösterir ama koordinatör bayat kimlikle
    /// önceki oturumun taslağına yazardı — yazı diğer bölmede belirirdi.
    func testTextEditorIsIdentifiedBySession() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source =
            testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AgenticSidebar/Views/ComposerView.swift")
        let lines = try String(contentsOf: source, encoding: .utf8)
            .components(separatedBy: "\n")

        guard
            let editorIndex = lines.firstIndex(where: {
                $0.contains("ComposerTextEditor(")
            })
        else {
            XCTFail("ComposerTextEditor bulunamadı")
            return
        }

        let window = lines[editorIndex...].prefix(30).joined(separator: "\n")
        XCTAssertTrue(
            window.contains(".id(focusedSession.id)"),
            "Metin alanı oturum kimliğine bağlanmalı, yoksa takasta yazı yanlış taslağa gider"
        )
    }
}
