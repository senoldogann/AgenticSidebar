import AppKit
import Foundation

/// ANSI SGR (renk/biçim) dizilerini `NSAttributedString` koşularına çevirir.
///
/// Kapsam bilerek dardır: SGR (`ESC[ … m`) dışındaki tüm kaçışlar
/// (`LocalTerminalService.plainText` ile aynı desen) atılır. İmleç hareketi,
/// alternatif ekran gibi tam-uçbirim davranışları yoktur — `vim`/`top` gibi
/// uygulamalar hâlâ desteklenmez. Buna karşılık `ls --color`, `git diff`,
/// renkli istemler ve hata çıktıları gerçek Terminal'deki gibi görünür.
///
/// Ayrıştırıcı saf ve durumludur: `var` bir örnek parça parça beslenir, çünkü
/// SGR durumu veri sınırlarını aşar (bir parça kırmızı açar, kapanış sonraki
/// parçada gelir).
struct AnsiStyleParser: Sendable {
    /// Uçbirim yüzeyiyle aynı yazıtipi; her çağrıda yeni örnek döner.
    static func baseFont() -> NSFont {
        .monospacedSystemFont(ofSize: 11.5, weight: .regular)
    }

    private struct Style: Equatable {
        var foreground: NSColor?
        var background: NSColor?
        var isBold = false
        var isFaint = false
        var isItalic = false
        var isUnderline = false
        var isStrikethrough = false
    }

    private var style = Style()

    mutating func append(_ text: String, to result: NSMutableAttributedString) {
        guard let tokens = Self.tokens(in: text) else {
            result.append(NSAttributedString(string: text, attributes: attributes()))
            return
        }
        var cursor = text.startIndex
        for token in tokens {
            if cursor < token.range.lowerBound {
                result.append(
                    NSAttributedString(
                        string: String(text[cursor..<token.range.lowerBound]),
                        attributes: attributes()
                    ))
            }
            if token.isSGR {
                applySGR(token.parameters)
            }
            cursor = token.range.upperBound
        }
        if cursor < text.endIndex {
            result.append(
                NSAttributedString(
                    string: String(text[cursor...]),
                    attributes: attributes()
                ))
        }
    }

    /// Tek parçalık kolaylık: durum taşınmaz.
    nonisolated static func styled(_ text: String) -> NSAttributedString {
        var parser = AnsiStyleParser()
        let result = NSMutableAttributedString()
        parser.append(text, to: result)
        return result
    }

    /// Metnin sonundaki yarım kaçışı ayırır.
    ///
    /// Parça sınırında bölünmüş `ESC[31` gibi bir dizi, bekletilmeden
    /// ayrıştırılsa düz metin olarak sızardı. Dönen `pending` sonraki parçanın
    /// başına eklenir; `complete` hemen işlenir.
    nonisolated static func splitTrailingPartialEscape(_ text: String) -> (complete: String, pending: String) {
        guard let escIndex = text.lastIndex(where: { $0.unicodeScalars.first?.value == 0x1B }) else {
            return (text, "")
        }
        let tailScalars = Array(text[escIndex...].unicodeScalars.map(\.value))
        // ESC tek başına ya da ESC "[" + parametre önekinden ibaretse yarımdır.
        // "[" dışında bir karakter gelmişse dizi tamam sayılır (örn. ESC]).
        let isPartial: Bool = {
            guard tailScalars.first == 0x1B else {
                return false
            }
            let rest = Array(tailScalars.dropFirst())
            guard let second = rest.first else {
                return true
            }
            guard second == 0x5B else {
                return false
            }
            return rest.dropFirst().allSatisfy {
                (0x30...0x3A).contains($0) || $0 == 0x3B || $0 == 0x3F
            }
        }()
        if isPartial {
            return (String(text[..<escIndex]), String(text[escIndex...]))
        }
        return (text, "")
    }

    /// SGR dizisiyse (`ESC[` … `m`) parametrelerini döner; `ESC[m` boş
    /// parametreyle sıfırlamadır. SGR değilse `nil` döner (dizi çöpe gider).
    ///
    /// Kaynakta görünmez bayt olmasın diye sayısal karşılaştırma yapılır:
    /// ESC (0x1B) + "[" ile açılır, "m" (0x6D) ile kapanır, en az 3 karakter.
    nonisolated static func sgrParameters(in sequence: String) -> [Int]? {
        let scalars = Array(sequence.unicodeScalars)
        guard scalars.count >= 3,
            scalars[0].value == 0x1B,
            scalars[1].value == 0x5B,
            scalars.last?.value == 0x6D
        else {
            return nil
        }
        let body = sequence.dropFirst(2).dropLast()
        return body.split(whereSeparator: { $0 == ";" || $0 == ":" })
            .compactMap { Int($0) }
    }

    /// Kaçış dizisini metin eklemeden tüketir: SGR ise biçimi günceller,
    /// diğer kaçışlar çöpe gider.
    ///
    /// `LocalTerminalService` parçayı önce ANSI dizilerine böler; araya giren
    /// satır-düzenleme baytları (`\r`, `\b`) tamponlarda çözülürken SGR durumu
    /// burada tek elden ilerler, parça sınırlarını aşar.
    mutating func consumeEscapeSequence(_ sequence: String) {
        guard let parameters = Self.sgrParameters(in: sequence) else {
            return
        }
        applySGR(parameters)
    }

    // MARK: - SGR

    private mutating func applySGR(_ parameters: [Int]) {
        if parameters.isEmpty {
            style = Style()
            return
        }
        var index = 0
        while index < parameters.count {
            let code = parameters[index]
            switch code {
            case 0:
                style = Style()
            case 1:
                style.isBold = true
            case 2:
                style.isFaint = true
            case 3:
                style.isItalic = true
            case 4:
                style.isUnderline = true
            case 9:
                style.isStrikethrough = true
            case 22:
                style.isBold = false
                style.isFaint = false
            case 23:
                style.isItalic = false
            case 24:
                style.isUnderline = false
            case 29:
                style.isStrikethrough = false
            case 30...37:
                style.foreground = Self.standardColor(code - 30)
            case 39:
                style.foreground = nil
            case 40...47:
                style.background = Self.standardColor(code - 40)
            case 49:
                style.background = nil
            case 90...97:
                style.foreground = Self.brightColor(code - 90)
            case 100...107:
                style.background = Self.brightColor(code - 100)
            case 38, 48:
                index = applyExtendedColor(kind: code, parameters: parameters, index: index)
            default:
                break
            }
            index += 1
        }
    }

    /// `38/48;5;n` (256 renk) ve `38/48;2;r;g;b` (gerçek renk) öneklerini yer;
    /// dizin ilerletilir, böylece tüketilen sayılar renk kodu sanılmaz.
    private mutating func applyExtendedColor(kind: Int, parameters: [Int], index: Int) -> Int {
        guard index + 1 < parameters.count else {
            return index
        }
        var resolved: NSColor?
        var next = index
        if parameters[index + 1] == 5, index + 2 < parameters.count,
            let color = Self.palette256(parameters[index + 2])
        {
            resolved = color
            next = index + 2
        } else if parameters[index + 1] == 2, index + 4 < parameters.count {
            let red = parameters[index + 2]
            let green = parameters[index + 3]
            let blue = parameters[index + 4]
            guard (0...255).contains(red), (0...255).contains(green), (0...255).contains(blue) else {
                return index
            }
            resolved = NSColor(
                calibratedRed: CGFloat(red) / 255,
                green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255,
                alpha: 1
            )
            next = index + 4
        } else {
            return index
        }
        guard let color = resolved else {
            return index
        }
        if kind == 38 {
            style.foreground = color
        } else {
            style.background = color
        }
        return next
    }

    private func attributes() -> [NSAttributedString.Key: Any] {
        var traits = NSFontTraitMask()
        if style.isBold {
            traits.insert(.boldFontMask)
        }
        if style.isItalic {
            traits.insert(.italicFontMask)
        }
        var resolvedAttributes: [NSAttributedString.Key: Any] = [
            .font: traits.isEmpty
                ? Self.baseFont()
                : NSFontManager.shared.convert(Self.baseFont(), toHaveTrait: traits),
            .foregroundColor: style.foreground
                ?? (style.isFaint ? NSColor.labelColor.withAlphaComponent(0.55) : NSColor.labelColor),
        ]
        if let background = style.background {
            resolvedAttributes[.backgroundColor] = background
        }
        if style.isUnderline {
            resolvedAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.isStrikethrough {
            resolvedAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return resolvedAttributes
    }

    // MARK: - Jetonlar

    private struct Token {
        let range: Range<String.Index>
        let isSGR: Bool
        let parameters: [Int]
    }

    /// `plainText` ile aynı kaçış deseni: SGR olanlar biçime, kalanı çöpe.
    nonisolated static let escapePatternSource =
        "\u{1B}\\[[0-9;:?]*[A-Za-z]|\u{1B}\\][^\u{07}]*\u{07}|\u{1B}[()][0-9A-B]|\u{1B}[=>M78]|\u{0F}"

    /// Derlenmiş desen: `tokens` sıcak yolda çağrılır, her seferinde
    /// derlemek parça başına gereksiz çalışmadır. Desen sabittir, geçersiz
    /// olursa `tokens` eskisi gibi `nil` döner.
    private static let cachedEscapeRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: escapePatternSource
    )

    private static func tokens(in text: String) -> [Token]? {
        guard let pattern = cachedEscapeRegex else {
            return nil
        }
        let fullRange = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: fullRange).compactMap { match in
            guard let range = Range(match.range, in: text) else {
                return nil
            }
            let sequence = String(text[range])
            guard let parameters = Self.sgrParameters(in: sequence) else {
                return Token(range: range, isSGR: false, parameters: [])
            }
            return Token(range: range, isSGR: true, parameters: parameters)
        }
    }

    // MARK: - Palet (xterm)

    private static func standardColor(_ index: Int) -> NSColor {
        let palette: [(CGFloat, CGFloat, CGFloat)] = [
            (0, 0, 0), (0.804, 0, 0), (0, 0.804, 0), (0.804, 0.804, 0),
            (0, 0, 0.804), (0.804, 0, 0.804), (0, 0.804, 0.804), (0.898, 0.898, 0.898),
        ]
        guard palette.indices.contains(index) else {
            return NSColor(calibratedWhite: 0.5, alpha: 1)
        }
        let rgb = palette[index]
        return NSColor(calibratedRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }

    private static func brightColor(_ index: Int) -> NSColor {
        let palette: [(CGFloat, CGFloat, CGFloat)] = [
            (0.498, 0.498, 0.498), (1, 0, 0), (0, 1, 0), (1, 1, 0),
            (0.36, 0.36, 1), (1, 0, 1), (0, 1, 1), (1, 1, 1),
        ]
        guard palette.indices.contains(index) else {
            return NSColor(calibratedWhite: 0.5, alpha: 1)
        }
        let rgb = palette[index]
        return NSColor(calibratedRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }

    private static func palette256(_ index: Int) -> NSColor? {
        guard (0...255).contains(index) else {
            return nil
        }
        if index < 8 {
            return standardColor(index)
        }
        if index < 16 {
            return brightColor(index - 8)
        }
        if index < 232 {
            let levels: [CGFloat] = [0, 0.373, 0.529, 0.686, 0.843, 1]
            let offset = index - 16
            return NSColor(
                calibratedRed: levels[(offset / 36) % 6],
                green: levels[(offset / 6) % 6],
                blue: levels[offset % 6],
                alpha: 1
            )
        }
        let gray = CGFloat(8 + 10 * (index - 232)) / 255
        return NSColor(calibratedRed: gray, green: gray, blue: gray, alpha: 1)
    }
}
