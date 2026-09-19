import AppKit
import SwiftUI

/// Tuş karşılığı: kabuğa bayt gönder, panodan yapıştır, AppKit'e bırak ya da yok say.
enum TerminalKeyAction: Equatable, Sendable {
    case send(Data)
    case paste
    case passThrough
    case ignore
}

/// `NSEvent`'ten kabuk baytına saf eşleme (test edilebilir, pencere gerekmez).
///
/// Çağıran `event.keyCode`, ayrışmış niteleyiciler ve `event.characters`
/// değerini verir. Yazdırılabilir tuşlar UTF-8 baytına, Tab/oklar/ESC
/// `xterm` dizilerine çevrilir; `zsh` satır düzenleyicisi gerisini üstlenir.
enum TerminalKeyEncoder {
    static func action(
        keyCode: UInt16,
        command: Bool,
        control: Bool,
        shift: Bool,
        characters: String?
    ) -> TerminalKeyAction {
        // Komut kısayolları AppKit'indir (kopyala, tümünü seç…); yalnız
        // yapıştırma kabuğa gider, yerel ekleme yapılmaz.
        if command, !control {
            if characters?.lowercased() == "v" {
                return .paste
            }
            return .passThrough
        }
        switch keyCode {
        case 36, 76:  // Return, keypad Enter
            return .send(Data("\n".utf8))
        case 48:  // Tab
            return shift ? .send(Data("\u{1B}[Z".utf8)) : .send(Data("\t".utf8))
        case 53:  // Escape
            return .send(Data([0x1B]))
        case 51:  // Delete (backspace)
            return .send(Data([0x7F]))
        case 117:  // Forward delete
            return .send(Data("\u{1B}[3~".utf8))
        case 123:  // Sol
            return .send(Data("\u{1B}[D".utf8))
        case 124:  // Sağ
            return .send(Data("\u{1B}[C".utf8))
        case 125:  // Aşağı
            return .send(Data("\u{1B}[B".utf8))
        case 126:  // Yukarı
            return .send(Data("\u{1B}[A".utf8))
        case 115:  // Home
            return .send(Data("\u{1B}[H".utf8))
        case 119:  // End
            return .send(Data("\u{1B}[F".utf8))
        case 116:  // PageUp
            return .send(Data("\u{1B}[5~".utf8))
        case 121:  // PageDown
            return .send(Data("\u{1B}[6~".utf8))
        default:
            break
        }
        // Cocoa, Ctrl+harfi genelde işlenmiş denetim karakterine çevirir
        // (Ctrl+C -> U+0003); çevrilmemiş tek ASCII harf de buradan yakalanır.
        if control,
            let text = characters,
            text.count == 1,
            let value = text.lowercased().unicodeScalars.first?.value,
            (0x61...0x7A).contains(value)
        {
            return .send(Data([UInt8(value - 96)]))
        }
        guard let characters, !characters.isEmpty else {
            return .ignore
        }
        let scalars = Array(characters.unicodeScalars)
        // Tek denetim karakteri (Ctrl dizileri, Opt+Backspace=^W) aynen iletilir.
        if scalars.count == 1, scalars[0].value < 0x20 {
            return .send(Data(characters.utf8))
        }
        // İşlev tuşları (U+F700-U+F8FF) ve özel tuşlar sessizce yok sayılır.
        let printable = scalars.allSatisfy {
            $0.value >= 0x20 && !(0xF700...0xF8FF).contains($0.value)
        }
        if printable {
            return .send(Data(characters.utf8))
        }
        return .ignore
    }
}

/// Tek yüzeyli uçbirim: çıktı salt-okunur akar, basılan her tuş kabuğa gider.
///
/// Kabuk bir pty ardında `zsh` çalıştırdığı için satır düzenleme kabuğun
/// işidir: Tab tamamlama, oklarla geçmiş, Ctrl+C kesme hep `zsh` üstlenir.
/// Yerel ekleme yapılmaz; kabuğun yankısı (echo) yazdıklarını gösterir.
final class TerminalEmulatorTextView: NSTextView {
    var sendHandler: (@Sendable (Data) -> Void)?
    /// Strong reference to the text storage when built locally, preventing deallocation by TextKit.
    private var retainedTextStorage: NSTextStorage?

    /// `init(frame:textContainer:)` nil kapla kurulunca metin yığını eksik
    /// kalıyor (`textStorage` nil, `.string` yazımı bile sessizce düşüyor) ve
    /// yüzey kabuk çalışsa da boş görünüyordu. Kap yoksa kendi yığın kurulur.
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        if let container {
            super.init(frame: frameRect, textContainer: container)
        } else {
            let storage = NSTextStorage()
            let layout = NSLayoutManager()
            let fresh = NSTextContainer()
            storage.addLayoutManager(layout)
            layout.addTextContainer(fresh)
            super.init(frame: frameRect, textContainer: fresh)
            self.retainedTextStorage = storage
        }
        commonInit()
    }

    convenience init() {
        self.init(frame: .zero, textContainer: nil)
    }

    private func commonInit() {
        isEditable = false
        isSelectable = true
        isRichText = false
        importsGraphics = false
        usesFontPanel = false
        usesFindPanel = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        font = AnsiStyleParser.baseFont()
        textColor = .labelColor
        drawsBackground = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalEmulatorTextView yüklenemez")
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        let result = TerminalKeyEncoder.action(
            keyCode: event.keyCode,
            command: flags.contains(.command),
            control: flags.contains(.control),
            shift: flags.contains(.shift),
            characters: event.characters
        )
        switch result {
        case .send(let data):
            sendHandler?(data)
        case .paste:
            pasteFromClipboard()
        case .passThrough:
            super.keyDown(with: event)
        case .ignore:
            break
        }
    }

    override func paste(_ sender: Any?) {
        pasteFromClipboard()
    }

    override func pasteAsPlainText(_ sender: Any?) {
        pasteFromClipboard()
    }

    /// Girdi yönteminden (IME/emoji) gelen yazı da kabuğa gider.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        guard !text.isEmpty else {
            return
        }
        sendHandler?(Data(text.utf8))
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return
        }
        sendHandler?(Data(text.utf8))
    }
}

/// `LocalTerminalService` çıktısını AppKit metin yüzeyinde gösterir.
///
/// Çıktı artımlı eklenir (`clear`/budama sezilince tümü yenilenir); kullanıcı
/// dibe yapışıksa yeni çıktı dibi izler, yukarı kaydırdıysa izlemez.
/// Renkli gösterim `styledOutput` hattından gelir; düz `output` hattı testler
/// ve pano için korunur.
struct TerminalTTYView: NSViewRepresentable {
    var styledOutput: NSAttributedString
    var background: NSColor
    var foreground: NSColor
    var onSend: @Sendable (Data) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = background
        let textView = TerminalEmulatorTextView()
        textView.sendHandler = onSend
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textColor = foreground
        textView.insertionPointColor = foreground
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak coordinator = context.coordinator, weak scrollView] _ in
            Task { @MainActor in
                guard let coordinator, let clipView = scrollView?.contentView else {
                    return
                }
                let bottom = clipView.bounds.maxY
                let contentBottom = clipView.documentRect.maxY
                coordinator.isPinned = bottom >= contentBottom - 24
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? TerminalEmulatorTextView else {
            return
        }
        textView.sendHandler = onSend
        scrollView.backgroundColor = background
        textView.textColor = foreground
        textView.insertionPointColor = foreground
        context.coordinator.sync(styled: styledOutput, textView: textView)
        if !context.coordinator.didFocus {
            context.coordinator.didFocus = true
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else {
                    return
                }
                window.makeFirstResponder(textView)
            }
        }
    }

    func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.boundsObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.boundsObserver = nil
        }
        coordinator.textView = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var textView: TerminalEmulatorTextView?
        var displayed = NSAttributedString(string: "")
        var isPinned = true
        var didFocus = false
        var boundsObserver: NSObjectProtocol?

        /// Çıktıyı yüzeye işler: önek sürüyorsa yalnız eki ekler, temizlik ya
        /// da budamada (`clear`/budama sınırı) tümü yenilenir. Önek kararı
        /// düz metin üzerinden verilir; ek biçimli aralıktan alınır.
        func sync(styled: NSAttributedString, textView: TerminalEmulatorTextView) {
            if styled.length == displayed.length, styled.string == displayed.string {
                return
            }
            if styled.length >= displayed.length,
                (styled.string as NSString).hasPrefix(displayed.string),
                let storage = textView.textStorage
            {
                let extra = styled.attributedSubstring(
                    from: NSRange(location: displayed.length, length: styled.length - displayed.length)
                )
                if extra.length > 0 {
                    storage.append(extra)
                }
            } else if let storage = textView.textStorage {
                storage.setAttributedString(styled)
            } else {
                textView.string = styled.string
            }
            displayed = styled.copy() as? NSAttributedString ?? styled
            if isPinned {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }
}
