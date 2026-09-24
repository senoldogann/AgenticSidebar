import AppKit
import SwiftUI

/// The typography a run of markdown prose is laid out with.
///
/// Passed in rather than read from the environment so the attributed string can
/// be built — and compared — outside a view body.
struct MarkdownRunTypography: Equatable {
    let fontFamily: AppFontFamily
    let pointSize: CGFloat
    let lineSpacing: CGFloat

    static let `default` = MarkdownRunTypography(
        fontFamily: .system,
        pointSize: AppFontSize.regular.pointSize,
        lineSpacing: AppLineSpacing.normal.spacing
    )

    var baseFont: NSFont {
        Self.font(family: fontFamily, size: pointSize)
    }

    /// Inline `code` spans: monospaced, a touch smaller than the body so the
    /// line height stays the body's.
    var codeFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: max(10, pointSize - 1.5), weight: .regular)
    }

    var numberFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: max(11, pointSize - 1), weight: .semibold)
    }

    func headingFont(level: Int) -> NSFont {
        switch level {
        case 1:
            Self.font(family: fontFamily, size: pointSize + 4, bold: true)
        case 2:
            Self.font(family: fontFamily, size: pointSize + 2, bold: true)
        case 3:
            Self.font(family: fontFamily, size: pointSize + 0.5, bold: true)
        default:
            Self.font(family: fontFamily, size: max(11, pointSize - 0.5), bold: true)
        }
    }

    func applying(bold: Bool, italic: Bool, to font: NSFont) -> NSFont {
        var result = font
        let manager = NSFontManager.shared
        if bold {
            result = manager.convert(result, toHaveTrait: .boldFontMask)
        }
        if italic {
            result = manager.convert(result, toHaveTrait: .italicFontMask)
        }
        return result
    }

    static func font(
        family: AppFontFamily,
        size: CGFloat,
        bold: Bool = false
    ) -> NSFont {
        let weight: NSFont.Weight = bold ? .bold : .regular
        let system = NSFont.systemFont(ofSize: size, weight: weight)

        guard family != .system else {
            return system
        }

        let design: NSFontDescriptor.SystemDesign =
            switch family {
            case .system: .default
            case .rounded: .rounded
            case .serif: .serif
            case .monospaced: .monospaced
            }

        guard let descriptor = system.fontDescriptor.withDesign(design) else {
            return system
        }

        return NSFont(descriptor: descriptor, size: size) ?? system
    }
}

/// Turns a run of markdown blocks into one attributed string.
///
/// The run exists for selection. SwiftUI gives every `Text` its own text view and
/// a drag cannot cross that boundary, so a reply that was one view per paragraph
/// could only ever be selected a paragraph at a time — the reason dragging down
/// an answer stopped at the first blank line. One AppKit text view per run is
/// what makes selecting a whole reply in a single gesture work.
enum MarkdownTextRunBuilder {
    /// The blocks that can live in the shared text view.
    /// Code, tables, charts, plan documents and solutions keep their own views:
    /// they carry their own affordances (a copy button, a chart, an approval
    /// bar) and end the run — a run never spans them.
    static func isTextual(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .paragraph, .heading, .bulletItem, .numberedItem, .blockquote:
            true
        case .code, .divider, .table, .chart, .plan, .solution, .math:
            false
        }
    }

    /// A cheap identity for the run, so a redraw that did not change the text does
    /// not rebuild and re-lay out the whole thing.
    static func token(
        blocks: [MarkdownBlock],
        typography: MarkdownRunTypography
    ) -> String {
        let content = blocks.map { block in
            switch block {
            case .paragraph(_, let content): "p:\(content)"
            case .heading(_, let level, let text): "h\(level):\(text)"
            case .bulletItem(_, let text): "*:\(text)"
            case .numberedItem(_, let number, let text): "\(number).:\(text)"
            case .blockquote(_, let text): ">\(text)"
            case .code(let id, _, _): "code:\(id)"
            case .divider(let id): "divider:\(id)"
            case .table(let id, _, _, _): "table:\(id)"
            case .chart(let id, _): "chart:\(id)"
            case .plan(let id, _): "plan:\(id)"
            case .solution(let id, _): "solution:\(id)"
            case .math(let id, _): "math:\(id)"
            }
        }

        return [
            typography.fontFamily.rawValue,
            "\(typography.pointSize)",
            "\(typography.lineSpacing)",
        ].joined(separator: "-") + "|" + content.joined(separator: "\n")
    }

    static func attributedString(
        blocks: [MarkdownBlock],
        typography: MarkdownRunTypography
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        for (offset, block) in blocks.enumerated() {
            result.append(
                piece(
                    for: block,
                    isFirst: offset == 0,
                    isLast: offset == blocks.count - 1,
                    typography: typography
                )
            )
        }

        return result
    }

    /// One block's contribution to the run, its separator included.
    ///
    /// A run is updated block by block while an answer streams, and only the
    /// blocks that changed are re-typeset. That is why the pieces are exposed: the
    /// text view can replace the tail of what it already holds instead of
    /// rebuilding — and re-laying out — the whole answer on every flush.
    static func piece(
        for block: MarkdownBlock,
        isFirst: Bool,
        isLast: Bool,
        typography: MarkdownRunTypography
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        if !isFirst {
            result.append(NSAttributedString(string: "\n"))
        }

        // The gap *between* blocks is the paragraph spacing, and the gap to
        // whatever follows the run is the enclosing stack's spacing — so the
        // last paragraph must not add one of its own.
        result.append(paragraph(for: block, typography: typography, isLast: isLast))

        return result
    }

    private static func paragraph(
        for block: MarkdownBlock,
        typography: MarkdownRunTypography,
        isLast: Bool
    ) -> NSAttributedString {
        switch block {
        case .paragraph(_, let content):
            return inline(
                content,
                typography: typography,
                style: paragraphStyle(typography: typography, isLast: isLast)
            )

        case .heading(_, let level, let text):
            return inline(
                text,
                typography: typography,
                font: typography.headingFont(level: level),
                style: paragraphStyle(
                    typography: typography,
                    spaceBefore: headingSpaceBefore(level: level),
                    isLast: isLast
                )
            )

        case .bulletItem(_, let text):
            let style = paragraphStyle(typography: typography, indent: 20, isLast: isLast)
            let bullet = NSMutableAttributedString(
                string: "•\t",
                attributes: [
                    .font: typography.applying(bold: true, italic: false, to: typography.baseFont),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: style,
                ]
            )
            bullet.append(
                inline(text, typography: typography, style: style)
            )
            return bullet

        case .numberedItem(_, let number, let text):
            let style = paragraphStyle(typography: typography, indent: 20, isLast: isLast)
            let prefix = NSMutableAttributedString(
                string: "\(number)\t",
                attributes: [
                    .font: typography.numberFont,
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: style,
                ]
            )
            prefix.append(
                inline(text, typography: typography, style: style)
            )
            return prefix

        case .blockquote(_, let text):
            return inline(
                text,
                typography: typography,
                color: .secondaryLabelColor,
                italic: true,
                style: paragraphStyle(typography: typography, indent: 12, isLast: isLast)
            )

        case .code, .divider, .table, .chart, .plan, .solution, .math:
            // Not textual: `isTextual` keeps these out of a run, and an empty
            // paragraph is the safe answer if one ever arrives.
            return NSAttributedString()
        }
    }

    private static func headingSpaceBefore(level: Int) -> CGFloat {
        switch level {
        case 1: 4
        case 2: 3
        case 3: 2
        default: 0
        }
    }

    private static func paragraphStyle(
        typography: MarkdownRunTypography,
        indent: CGFloat = 0,
        spaceBefore: CGFloat = 0,
        isLast: Bool
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = typography.lineSpacing
        style.paragraphSpacing = isLast ? 0 : 10
        style.paragraphSpacingBefore = spaceBefore
        style.headIndent = indent
        style.firstLineHeadIndent = 0

        if indent > 0 {
            // The bullet or number sits at the margin and the text starts at the
            // indent, which is what makes a wrapped list line line up under the
            // first one instead of under the bullet.
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        }

        return style
    }

    /// Inline markdown as AppKit attributes.
    ///
    /// `InlinePresentationIntent` means nothing to AppKit — a converted
    /// attributed string would lose every bold, italic and code span — so the
    /// emphasis is read off the runs and turned into fonts here.
    private static func inline(
        _ markdown: String,
        typography: MarkdownRunTypography,
        font: NSFont? = nil,
        color: NSColor = .labelColor,
        italic: Bool = false,
        style: NSParagraphStyle
    ) -> NSMutableAttributedString {
        let source = MarkdownInlineText.attributed(from: markdown)
        let result = NSMutableAttributedString()

        for run in source.runs {
            let text = String(source[run.range].characters)
            guard !text.isEmpty else {
                continue
            }

            var runFont = font ?? typography.baseFont
            var runColor = color
            var background: NSColor?
            var link: NSURL?

            if let intent = run.inlinePresentationIntent, !intent.contains(.code) {
                runFont = typography.applying(
                    bold: intent.contains(.stronglyEmphasized),
                    italic: intent.contains(.emphasized),
                    to: runFont
                )
            } else if run.inlinePresentationIntent?.contains(.code) == true {
                runFont = typography.codeFont
                background = .quaternaryLabelColor
            }

            if italic {
                runFont = typography.applying(bold: false, italic: true, to: runFont)
            }

            if let destination = run.link {
                link = destination as NSURL
                runColor = .linkColor
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: runFont,
                .foregroundColor: runColor,
                .paragraphStyle: style,
            ]

            if let background {
                attributes[.backgroundColor] = background
            }

            if let link {
                attributes[.link] = link
            }

            result.append(NSAttributedString(string: text, attributes: attributes))
        }

        return result
    }
}

/// A run of markdown in a single selectable AppKit text view.
struct SelectableMarkdownTextView: NSViewRepresentable {
    let blocks: [MarkdownBlock]
    let typography: MarkdownRunTypography

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = Self.makeTextView()
        textView.delegate = context.coordinator
        Self.apply(
            blocks: blocks,
            typography: typography,
            to: textView,
            coordinator: context.coordinator
        )
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        Self.apply(
            blocks: blocks,
            typography: typography,
            to: textView,
            coordinator: context.coordinator
        )
    }

    /// Writes a run into the text view, re-typesetting only what changed.
    ///
    /// A streaming answer rewrites its *last* block several times a second. The
    /// whole run used to be rebuilt and laid out on every one of those flushes —
    /// measured here at 10–41 ms of attributed-string building plus 7–27 ms of
    /// layout for a 4–27k character answer, on the main thread, and it grows with
    /// the answer. At a 16–40 ms flush cadence that saturates the main thread, and
    /// the pinch is felt as a scroll that stutters and seems to be held by
    /// something else.
    ///
    /// Now the unchanged prefix keeps the text storage (and the layout) it already
    /// has: only the blocks from the first change onwards are replaced. Two side
    /// effects follow. A selection made in an earlier paragraph survives an answer
    /// that keeps growing below it, which `setAttributedString` used to throw away
    /// on every flush.
    static func apply(
        blocks: [MarkdownBlock],
        typography: MarkdownRunTypography,
        to textView: NSTextView,
        coordinator: Coordinator
    ) {
        let previousBlocks = coordinator.blocks
        let typographyChanged = coordinator.typography != typography

        guard typographyChanged || previousBlocks != blocks else {
            return
        }

        let startIndex =
            typographyChanged
            ? 0
            : Self.firstChangedBlockIndex(previous: previousBlocks, next: blocks)

        guard let storage = textView.textStorage else {
            return
        }

        let oldLength = storage.length
        let replacementStart = min(
            startIndex < coordinator.pieceOffsets.count
                ? coordinator.pieceOffsets[startIndex]
                : coordinator.writtenLength,
            oldLength
        )
        let replacedLength = oldLength - replacementStart

        let replacement = NSMutableAttributedString()
        var offsets = Array(coordinator.pieceOffsets.prefix(startIndex))

        for index in startIndex..<blocks.count {
            offsets.append(replacementStart + replacement.length)
            replacement.append(
                MarkdownTextRunBuilder.piece(
                    for: blocks[index],
                    isFirst: index == 0,
                    isLast: index == blocks.count - 1,
                    typography: typography
                )
            )
        }

        storage.beginEditing()
        storage.replaceCharacters(
            in: NSRange(location: replacementStart, length: replacedLength),
            with: replacement
        )
        storage.endEditing()

        coordinator.blocks = blocks
        coordinator.typography = typography
        coordinator.pieceOffsets = offsets
        coordinator.writtenLength = replacementStart + replacement.length
        coordinator.lastEdit = NSRange(location: replacementStart, length: replacedLength)
        // İçerik değişti: ölçüm önbelleği geçersiz.
        coordinator.measureGeneration &+= 1

        if startIndex == 0 {
            coordinator.fullRebuilds += 1
        } else {
            coordinator.incrementalEdits += 1
        }
    }

    /// The first block whose text differs, pulled back far enough to re-typeset the
    /// block that lost its "last" status.
    ///
    /// The final block carries no paragraph spacing and every earlier one does, so
    /// appending blocks also changes the one before them. The rebuild starts there.
    /// `min(index, next.count - 2)` alone only pulls back when the change is
    /// inside the last block; appending two or more blocks at once (a single
    /// streaming flush) leaves `index == previous.count` and the old last block
    /// keeps spacing 0, so the run measures 10 pt short per flush and its tail
    /// clips. Growing runs therefore always pull back to the old last block.
    private static func firstChangedBlockIndex(
        previous: [MarkdownBlock],
        next: [MarkdownBlock]
    ) -> Int {
        var index = 0
        while index < previous.count, index < next.count, previous[index] == next[index] {
            index += 1
        }

        var startIndex = max(0, min(index, next.count - 2))
        if next.count > previous.count, !previous.isEmpty {
            startIndex = min(startIndex, previous.count - 1)
        }
        return startIndex
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else {
            return nil
        }

        // Yerleşim aynı satırı kaydırma ve akış sırasında defalarca ölçer;
        // içerik ve genişlik değişmedikçe tam yerleşim tekrarlanmaz.
        let coordinator = context.coordinator
        if coordinator.lastMeasuredWidth == width,
            coordinator.lastMeasuredGeneration == coordinator.measureGeneration
        {
            return coordinator.lastMeasuredSize
        }

        let size = Self.measuredSize(of: nsView, width: width)
        coordinator.lastMeasuredWidth = width
        coordinator.lastMeasuredGeneration = coordinator.measureGeneration
        coordinator.lastMeasuredSize = size
        return size
    }

    /// A configured text view: not editable, not scrollable, transparent, and
    /// width-tracking, so it reads as part of the transcript rather than as a
    /// field.
    static func makeTextView() -> NSTextView {
        let textView = TranscriptTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.allowsUndo = false
        textView.isAutomaticLinkDetectionEnabled = false
        return textView
    }

    /// The size a run occupies at a given width.
    ///
    /// Static — and separate from the representable — because the height computed
    /// here is the height the run is *given*: under-report it and the answer is
    /// clipped. The measurement never touches the live view: `sizeThatFits` runs
    /// inside SwiftUI's layout pass, and widening the live text view (or its text
    /// container) from inside that pass asks AppKit for another constraint-update
    /// cycle while the window is already laying out. With a short answer that
    /// request is absorbed; with a long pasted answer plus an inspector opening
    /// beside it, every visible row re-measures at the new width in the same
    /// display cycle and the window aborts the layout loop (SIGABRT, bug 309).
    /// A detached measurer — never in a window, never in a hierarchy — lays out
    /// a copy of the same string instead, so the live view is only ever read.
    static func measuredSize(of textView: NSTextView, width: CGFloat) -> CGSize {
        guard width > 0 else {
            return CGSize(width: max(0, width), height: 0)
        }
        guard let storage = textView.textStorage, storage.length > 0 else {
            return CGSize(width: width, height: 0)
        }
        let measurer = Self.sharedMeasurer()
        // The measurer outlives the call, so a stale copy from an earlier row
        // must never be measured: the string comparison is a memcmp, not a
        // hash, and it only runs when a height is actually requested.
        if measurer.textStorage?.string != storage.string {
            measurer.textStorage?.setAttributedString(storage)
        }
        if let container = measurer.textContainer,
            container.containerSize.width != width
        {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        var frame = measurer.frame
        if frame.size.width != width {
            frame.size.width = width
            measurer.frame = frame
        }
        guard
            let container = measurer.textContainer,
            let layoutManager = measurer.layoutManager
        else {
            return CGSize(width: width, height: 0)
        }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return CGSize(width: width, height: ceil(used.height))
    }

    /// A text view that exists only to answer `measuredSize`.
    ///
    /// Main-thread only, like every other AppKit view here: `sizeThatFits` and
    /// the tests both run on the main thread. Same configuration as the live
    /// view (no padding, width-tracking container) so the height matches what
    /// the row is given.
    ///
    /// `nonisolated(unsafe)` because the holder is a non-Sendable AppKit view;
    /// the main-thread-only contract above is what makes sharing it sound.
    nonisolated(unsafe) private static var measurerStorage: NSTextView?
    private static func sharedMeasurer() -> NSTextView {
        if let measurerStorage {
            return measurerStorage
        }
        let measurer = makeTextView()
        measurerStorage = measurer
        return measurer
    }

    /// A text view that lets the transcript keep the scroll wheel.
    ///
    /// The run is not in a scroll view of its own, so a wheel event over the text
    /// would otherwise be swallowed by a view that has nothing to scroll — the
    /// chat would scroll everywhere except over the answer, which is where the
    /// pointer usually is.
    private final class TranscriptTextView: NSTextView {
        override func scrollWheel(with event: NSEvent) {
            nextResponder?.scrollWheel(with: event)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var blocks: [MarkdownBlock] = []
        var typography: MarkdownRunTypography?

        /// Where each block's piece starts in the text storage.
        var pieceOffsets: [Int] = []
        /// The length of the run as last written.
        var writtenLength = 0
        /// The range the last write replaced; `location > 0` means only the tail
        /// was touched. Used by the tests to prove the incremental path.
        fileprivate(set) var lastEdit = NSRange(location: 0, length: 0)
        fileprivate(set) var fullRebuilds = 0
        fileprivate(set) var incrementalEdits = 0
        /// Her yazımda artar; `sizeThatFits` aynı kuşak + genişlikte ölçümü
        /// atlar. Yazı tipi değişimi de `apply` yolundan geçtiği için ayrı
        /// anahtar gerekmez.
        var measureGeneration = 0
        var lastMeasuredGeneration = -1
        var lastMeasuredWidth: CGFloat = 0
        var lastMeasuredSize = CGSize.zero

        func textView(
            _ textView: NSTextView,
            clickedOnLink link: Any,
            at charIndex: Int
        ) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else {
                return false
            }
            // LLM üretimi metin keyfi bağlantı ekebilir: tek tıkla açılış
            // kimlik avına kapı aralar. http/https dahil her şema bilinçli
            // onay ister; kullanıcı konağı görerek karar verir.
            guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
                return false
            }
            let alert = NSAlert()
            alert.messageText = "Bağlantı açılsın mı?"
            alert.informativeText = url.absoluteString
            alert.addButton(withTitle: "Aç")
            alert.addButton(withTitle: "Vazgeç")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(url)
            }
            return true
        }
    }
}
