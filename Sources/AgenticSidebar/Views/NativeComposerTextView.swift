import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class NativeComposerTextView: NSTextView {
    var submissionAvailability = ComposerSubmissionAvailability.unavailable
    var onSubmit: (() -> Void)?
    /// A long paste becomes a file attachment instead of draft text. Return
    /// `true` when the paste was handled so nothing is inserted; `false` falls
    /// back to the platform paste and the text lands inline.
    var onSpillLargePaste: ((String) -> Bool)?
    /// A pasted image becomes a file attachment the same way a dropped one
    /// does. Arguments are the raw bytes and the source type identifier;
    /// return `true` when the image was attached, `false` to fall through.
    var onPasteImage: ((Data, String) -> Bool)?
    /// Escape önce öneri panelini kapatır; kapatacak bir panel yoksa `false`
    /// döner ve tuş sistemin varsayılanına bırakılır.
    var onCancelSuggestions: (() -> Bool)?

    override func paste(_ sender: Any?) {
        guard !pasteImageIfNeeded() else {
            return
        }
        guard !spillLargePasteIfNeeded() else {
            return
        }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        guard !spillLargePasteIfNeeded() else {
            return
        }
        super.pasteAsPlainText(sender)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if let handler = onSpillLargePaste,
            let text = pboard.string(forType: .string),
            PastedTextAttachment.shouldSpillToFile(text)
        {
            if handler(text) {
                return true
            }
        }
        return super.readSelection(from: pboard, type: type)
    }

    /// Panodaki metin dosya eşiğini aşarsa işleyiciye verir.
    ///
    /// Kısa yapıştırmalar her zamanki yoldan gider: her Cmd+V'de pano okumak
    /// yerine önce uzunluk bakılır, eşik altı metin dokunulmadan geçer.
    private func spillLargePasteIfNeeded() -> Bool {
        guard
            let handler = onSpillLargePaste,
            let text = NSPasteboard.general.string(forType: .string),
            PastedTextAttachment.shouldSpillToFile(text)
        else {
            return false
        }

        return handler(text)
    }

    /// Panodaki görüntü dosya eki olur (ekran görüntüsü Cmd+V'si).
    ///
    /// Metin kopyası bu türleri taşımadığı için resim önce bakılır: metin
    /// eşiğiyle çakışmaz. Düz metin yapıştırma (`pasteAsPlainText`) bilerek
    /// buraya uğramaz — açık niyet metinse resim eklenmemelidir.
    private func pasteImageIfNeeded() -> Bool {
        guard let handler = onPasteImage else {
            return false
        }
        let board = NSPasteboard.general
        if let data = board.data(forType: .tiff), !data.isEmpty {
            return handler(data, UTType.tiff.identifier)
        }
        if let data = board.data(forType: .png), !data.isEmpty {
            return handler(data, UTType.png.identifier)
        }
        return false
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            let handled = !hasMarkedText() && onCancelSuggestions?() == true
            if handled {
                return
            }
            super.keyDown(with: event)
            return
        }

        guard event.keyCode == 36 || event.keyCode == 76 else {
            super.keyDown(with: event)
            return
        }
        guard !hasMarkedText() else {
            super.keyDown(with: event)
            return
        }

        let modifiers = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        let action = ComposerSubmissionPolicy.action(
            for: returnGesture(modifiers: modifiers),
            availability: submissionAvailability
        )

        switch action {
        case .submit:
            // Without a submit handler, Return falls back to the platform default
            // rather than terminating the application.
            guard let onSubmit else {
                super.keyDown(with: event)
                return
            }
            onSubmit()
        case .insertNewline:
            insertNewline(nil)
        case .suppress:
            return
        case .systemDefault:
            super.keyDown(with: event)
        }
    }

    private func returnGesture(
        modifiers: NSEvent.ModifierFlags
    ) -> ComposerReturnGesture {
        if modifiers.contains(.shift) {
            return .shifted
        }

        let semanticModifiers: NSEvent.ModifierFlags = [
            .command,
            .control,
            .option,
        ]
        if modifiers.intersection(semanticModifiers).isEmpty {
            return .plain
        }

        return .modified
    }
}

struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String

    let submissionAvailability: ComposerSubmissionAvailability
    let onSubmit: @MainActor () -> Void
    /// Öneri paneli açıkken Escape'in onu kapatıp kapatmadığını bildirir.
    let onCancelSuggestions: @MainActor () -> Bool
    /// Eşik üstü yapıştırma dosya eki olur; `true` ekler, `false` satıra yazar.
    let onSpillLargePaste: @MainActor (String) -> Bool
    /// Panoya kopyalanmış görüntü dosya eki olur; `true` ekler, `false` düşer.
    let onPasteImage: @MainActor (Data, String) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    /// Modeldeki metin görünüme yazılsın mı?
    ///
    /// İşaretli metin (giriş yönteminin bitmemiş hecesi) varken yazılmaz:
    /// temsilci o metni modele taşımaz, bu yüzden modeldeki eski metin
    /// görünümdeki yeni heceyi ezmemeli. Arka plandaki sohbetler akarken
    /// gövde saniyede defalarca tazelenir; koruma yoksa bitmemiş girdi her
    /// tazede silinir ve başka sohbette yazıyormuş gibi görünür.
    static func shouldApplyModelText(
        hasMarkedText: Bool,
        viewString: String,
        modelText: String
    ) -> Bool {
        guard !hasMarkedText else {
            return false
        }
        return viewString != modelText
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NativeComposerTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Ask AgenticSidebar")
        textView.setAccessibilityHelp(
            "Press Return to send. Press Shift-Return for a new line."
        )

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        updateConfiguration(textView)
        return scrollView
    }

    func updateNSView(
        _ scrollView: NSScrollView,
        context: Context
    ) {
        guard let textView = textView(in: scrollView) else {
            return
        }
        updateConfiguration(textView)

        guard
            Self.shouldApplyModelText(
                hasMarkedText: textView.hasMarkedText(),
                viewString: textView.string,
                modelText: text
            )
        else {
            return
        }

        let selectedRange = textView.selectedRange()
        textView.string = text
        let maximumLocation = (text as NSString).length
        textView.setSelectedRange(
            NSRange(
                location: min(selectedRange.location, maximumLocation),
                length: 0
            )
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView scrollView: NSScrollView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let textView = textView(in: scrollView) else {
            return nil
        }

        // Only a bounded prefix is laid out. The editor is capped at a few lines,
        // so measuring more of a pasted document changed nothing except the cost:
        // text layout of the whole draft ran on every keystroke and every state
        // change, which is what made a large paste feel stuck.
        let prefix = ComposerDraftMetrics.measuredPrefix(of: textView.string)
        let measuredText = prefix.isEmpty ? " " : prefix
        let font =
            textView.font
            ?? NSFont.systemFont(
                ofSize: NSFont.systemFontSize
            )
        let measuredBounds = (measuredText as NSString).boundingRect(
            with: NSSize(
                width: width,
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let contentHeight = ceil(
            measuredBounds.height
                + (textView.textContainerInset.height * 2)
        )

        return CGSize(
            width: width,
            height: min(max(contentHeight, 22), ComposerDraftMetrics.maximumMeasuredHeight)
        )
    }

    private func updateConfiguration(_ textView: NativeComposerTextView) {
        textView.submissionAvailability = submissionAvailability
        textView.onSubmit = onSubmit
        textView.onCancelSuggestions = onCancelSuggestions
        textView.onSpillLargePaste = onSpillLargePaste
        textView.onPasteImage = onPasteImage
    }

    private func textView(in scrollView: NSScrollView) -> NativeComposerTextView? {
        scrollView.documentView as? NativeComposerTextView
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }

            // Marked text is an input method's in-progress composition; writing it
            // out would fight the candidate window.
            guard !textView.hasMarkedText() else {
                return
            }

            text.wrappedValue = textView.string
        }
    }
}
