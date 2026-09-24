import AppKit
import XCTest

@testable import AgenticSidebar

/// Artımlı yazımın (`apply`) taze kurulumla aynı yerleşimi üretmesi.
/// Tek bir akış flush'u birden fazla bloğu birden tamamlar; dikişteki
/// paragraf aralığı kaybolursa satır 10 pt kısa ölçülür ve kuyruğu kırpılır.
@MainActor
final class SelectableMarkdownTextIncrementalTests: XCTestCase {
    func testAppendingMultipleBlocksKeepsOldLastSpacing() {
        let typography = MarkdownRunTypography.default
        let width: CGFloat = 724
        let previous = Self.paragraphs(count: 7)
        let next = Self.paragraphs(count: 13)

        let live = SelectableMarkdownTextView.makeTextView()
        let coordinator = SelectableMarkdownTextView.Coordinator()
        SelectableMarkdownTextView.apply(
            blocks: previous, typography: typography, to: live, coordinator: coordinator
        )
        SelectableMarkdownTextView.apply(
            blocks: next, typography: typography, to: live, coordinator: coordinator
        )

        let fresh = SelectableMarkdownTextView.makeTextView()
        let freshCoordinator = SelectableMarkdownTextView.Coordinator()
        SelectableMarkdownTextView.apply(
            blocks: next, typography: typography, to: fresh, coordinator: freshCoordinator
        )

        XCTAssertEqual(live.string, fresh.string)
        XCTAssertEqual(
            Self.spacings(of: live), Self.spacings(of: fresh),
            "Eski son blok son statüsünü kaybedince yeniden dizilmeli"
        )
        XCTAssertEqual(
            Self.height(of: live, width: width), Self.height(of: fresh, width: width),
            accuracy: 0.5
        )
    }

    func testSingleBlockAppendStaysIncremental() {
        let typography = MarkdownRunTypography.default
        let width: CGFloat = 724
        let previous = Self.paragraphs(count: 7)
        let next = Self.paragraphs(count: 8)

        let live = SelectableMarkdownTextView.makeTextView()
        let coordinator = SelectableMarkdownTextView.Coordinator()
        SelectableMarkdownTextView.apply(
            blocks: previous, typography: typography, to: live, coordinator: coordinator
        )
        SelectableMarkdownTextView.apply(
            blocks: next, typography: typography, to: live, coordinator: coordinator
        )

        // Tek blok ekleme baştan yazım değil kuyruk değişimidir.
        XCTAssertGreaterThan(coordinator.lastEdit.location, 0)
        XCTAssertEqual(coordinator.incrementalEdits, 1)

        let fresh = SelectableMarkdownTextView.makeTextView()
        let freshCoordinator = SelectableMarkdownTextView.Coordinator()
        SelectableMarkdownTextView.apply(
            blocks: next, typography: typography, to: fresh, coordinator: freshCoordinator
        )
        XCTAssertEqual(live.string, fresh.string)
        XCTAssertEqual(
            Self.height(of: live, width: width), Self.height(of: fresh, width: width),
            accuracy: 0.5
        )
    }

    private static func paragraphs(count: Int) -> [MarkdownBlock] {
        (0..<count).map { index in
            .paragraph(
                id: "p-\(index)",
                content: "Paragraf \(index): akış sırasında büyüyen koşunun dikiş aralığını denetler."
            )
        }
    }

    private static func spacings(of textView: NSTextView) -> [CGFloat] {
        guard let storage = textView.textStorage else { return [] }
        var out: [CGFloat] = []
        storage.enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, _, _ in
            out.append((value as? NSParagraphStyle)?.paragraphSpacing ?? -1)
        }
        return out
    }

    private static func height(of textView: NSTextView, width: CGFloat) -> CGFloat {
        guard
            let container = textView.textContainer,
            let layout = textView.layoutManager
        else {
            return -1
        }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        var frame = textView.frame
        frame.size.width = width
        textView.frame = frame
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }
}
