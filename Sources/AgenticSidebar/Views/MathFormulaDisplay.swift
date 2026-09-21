import Foundation

/// Ham LaTeX formülünü okunabilir düz metne çevirir.
///
/// Görünüm katmanı gerçek bir TeX motoru kullanmaz; bu yüzden `\frac{1}{2}`
/// gibi kaynak olduğu gibi gösterilemez. Bu dönüştürücü kopyalanan LaTeX
/// kaynağını bozmadan yalnızca ekrandaki metni sadeleştirir.
enum MathFormulaDisplay {
    /// Ekranda gösterilecek sade metni üretir.
    static func displayText(raw: String) -> String {
        let cleaned: String = stripDelimiters(text: raw)
        let withoutTextCommands: String = replaceTextCommands(text: cleaned)
        let withoutFractions: String = replaceFractions(text: withoutTextCommands)
        let withoutRoots: String = replaceRoots(text: withoutFractions)
        let withoutCommands: String = replaceCommands(text: withoutRoots)
        let withoutSuperscripts: String = replaceSuperscripts(text: withoutCommands)
        let withoutSubscripts: String = replaceSubscripts(text: withoutSuperscripts)
        let withoutEscapes: String = replaceEscapes(text: withoutSubscripts)
        return tidy(text: withoutEscapes)
    }

    /// Kopyalama için ham LaTeX kaynağını sadeleştirir.
    static func copyText(raw: String) -> String {
        return stripDelimiters(text: raw)
    }

    /// Baş ve sondaki `$$`, `$` sarmalayıcıları temizler.
    static func stripDelimiters(text: String) -> String {
        var result: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("$$") && result.hasSuffix("$$") && result.count >= 4 {
            result = String(result.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if result.hasPrefix("$") && result.hasSuffix("$") && result.count >= 2 {
            result = String(result.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    /// `\text{...}`, `\mathrm{...}` gibi kutuları iç metne indirger.
    static func replaceTextCommands(text: String) -> String {
        var result: String = text
        let wrappers: [String] = ["\\text", "\\mathrm", "\\mathbf", "\\mathit", "\\mathbb", "\\mathcal", "\\operatorname"]
        for wrapper: String in wrappers {
            result = replaceBraceCommand(text: result, command: wrapper)
        }
        return result
    }

    /// `\frac{a}{b}` yapısını `a/b` biçimine çevirir.
    static func replaceFractions(text: String) -> String {
        var result: String = text
        let commands: [String] = ["\\dfrac", "\\tfrac", "\\cfrac", "\\frac"]
        var guardCount: Int = 0
        while containsAnyCommand(text: result, commands: commands) && guardCount < 50 {
            guardCount += 1
            guard let replaced: String = replaceFirstFraction(text: result, commands: commands) else {
                break
            }
            result = replaced
        }
        return result
    }

    /// `\sqrt{x}` yapısını `√(x)` biçimine çevirir.
    static func replaceRoots(text: String) -> String {
        var result: String = text
        var guardCount: Int = 0
        while result.contains("\\sqrt") && guardCount < 50 {
            guardCount += 1
            guard let replaced: String = replaceFirstRoot(text: result) else {
                break
            }
            result = replaced
        }
        return result
    }

    /// Sık kullanılan LaTeX komutlarını Unicode karşılığına çevirir.
    static func replaceCommands(text: String) -> String {
        var result: String = text
        let mapping: [(String, String)] = [
            ("\\times", "×"),
            ("\\cdot", "·"),
            ("\\div", "÷"),
            ("\\pm", "±"),
            ("\\mp", "∓"),
            ("\\leq", "≤"),
            ("\\geq", "≥"),
            ("\\neq", "≠"),
            ("\\approx", "≈"),
            ("\\equiv", "≡"),
            ("\\infty", "∞"),
            ("\\sum", "∑"),
            ("\\int", "∫"),
            ("\\partial", "∂"),
            ("\\nabla", "∇"),
            ("\\in", "∈"),
            ("\\notin", "∉"),
            ("\\subset", "⊂"),
            ("\\cup", "∪"),
            ("\\cap", "∩"),
            ("\\rightarrow", "→"),
            ("\\leftarrow", "←"),
            ("\\Rightarrow", "⇒"),
            ("\\Leftrightarrow", "⇔"),
            ("\\ldots", "…"),
            ("\\cdots", "⋯"),
            ("\\circ", "∘"),
            ("\\alpha", "α"),
            ("\\beta", "β"),
            ("\\gamma", "γ"),
            ("\\delta", "δ"),
            ("\\theta", "θ"),
            ("\\lambda", "λ"),
            ("\\mu", "μ"),
            ("\\sigma", "σ"),
            ("\\pi", "π"),
            ("\\left", ""),
            ("\\right", ""),
            ("\\quad", " "),
            ("\\qquad", " "),
            ("\\,", " "),
            ("\\;", " "),
            ("\\:", " "),
            ("\\!", ""),
            ("\\>", " "),
            ("\\sin", "sin"),
            ("\\cos", "cos"),
            ("\\tan", "tan"),
            ("\\log", "log"),
            ("\\ln", "ln"),
            ("\\exp", "exp"),
            ("\\min", "min"),
            ("\\max", "max"),
        ]
        for pair: (String, String) in mapping {
            result = result.replacingOccurrences(of: pair.0, with: pair.1)
        }
        result = replaceUnknownCommands(text: result)
        return result
    }

    /// `^{...}` ve `^x` üst simgelerini Unicode biçime çevirir.
    static func replaceSuperscripts(text: String) -> String {
        var result: String = ""
        var index: String.Index = text.startIndex
        while index < text.endIndex {
            let character: Character = text[index]
            if character == "^" {
                let next: String.Index = text.index(after: index)
                if next < text.endIndex && text[next] == "{" {
                    guard let brace: BraceContent = extractBraceContent(text: text, openIndex: next) else {
                        result.append(character)
                        index = next
                        continue
                    }
                    result.append(superscriptOrFallback(content: brace.content))
                    index = brace.nextIndex
                    continue
                }
                if next < text.endIndex {
                    let single: String = String(text[next])
                    if let mapped: String = superscriptMap()[single] {
                        result.append(mapped)
                        index = text.index(after: next)
                        continue
                    }
                }
                result.append(character)
                index = next
                continue
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }

    /// `_{...}` ve `_x` alt simgelerini Unicode biçime çevirir.
    static func replaceSubscripts(text: String) -> String {
        var result: String = ""
        var index: String.Index = text.startIndex
        while index < text.endIndex {
            let character: Character = text[index]
            if character == "_" {
                let next: String.Index = text.index(after: index)
                if next < text.endIndex && text[next] == "{" {
                    guard let brace: BraceContent = extractBraceContent(text: text, openIndex: next) else {
                        result.append(character)
                        index = next
                        continue
                    }
                    result.append(subscriptOrFallback(content: brace.content))
                    index = brace.nextIndex
                    continue
                }
                if next < text.endIndex {
                    let single: String = String(text[next])
                    if let mapped: String = subscriptMap()[single] {
                        result.append(mapped)
                        index = text.index(after: next)
                        continue
                    }
                }
                result.append(character)
                index = next
                continue
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }

    /// `\{`, `\}`, `\%` gibi kaçışları düz karaktere çevirir.
    static func replaceEscapes(text: String) -> String {
        var result: String = text
        let mapping: [(String, String)] = [
            ("\\{", "{"),
            ("\\}", "}"),
            ("\\%", "%"),
            ("\\$", "$"),
            ("\\&", "&"),
            ("\\#", "#"),
            ("\\_", "_"),
            ("\\\\", "\n"),
        ]
        for pair: (String, String) in mapping {
            result = result.replacingOccurrences(of: pair.0, with: pair.1)
        }
        return result
    }

    /// Fazla boşlukları temizler.
    static func tidy(text: String) -> String {
        let lines: [String] = text.components(separatedBy: "\n")
        let trimmedLines: [String] = lines.map { line in
            collapseSpaces(text: line.trimmingCharacters(in: .whitespaces))
        }
        let nonEmpty: [String] = trimmedLines.filter { line in
            line.isEmpty == false
        }
        return nonEmpty.joined(separator: "\n")
    }
}

/// Süslü parantez içeriğini taşıyan küçük değer türü.
private struct BraceContent {
    let content: String
    let nextIndex: String.Index
}

/// `{" anahtarından dengeli kapanışı bulur.
private func extractBraceContent(text: String, openIndex: String.Index) -> BraceContent? {
    guard openIndex < text.endIndex && text[openIndex] == "{" else {
        return nil
    }
    var depth: Int = 0
    var index: String.Index = openIndex
    var contentStart: String.Index? = nil
    while index < text.endIndex {
        let character: Character = text[index]
        if character == "{" {
            depth += 1
            if depth == 1 {
                contentStart = text.index(after: index)
            }
        }
        if character == "}" {
            depth -= 1
            if depth == 0 {
                guard let start: String.Index = contentStart else {
                    return nil
                }
                let content: String = String(text[start..<index])
                let next: String.Index = text.index(after: index)
                return BraceContent(content: content, nextIndex: next)
            }
        }
        index = text.index(after: index)
    }
    return nil
}

/// Tek komutluk süslü parantez sarmalını iç metne indirger.
private func replaceBraceCommand(text: String, command: String) -> String {
    var result: String = text
    var guardCount: Int = 0
    while let range: Range<String.Index> = result.range(of: command), guardCount < 50 {
        guardCount += 1
        let afterCommand: String.Index = range.upperBound
        guard afterCommand < result.endIndex && result[afterCommand] == "{" else {
            break
        }
        guard let brace: BraceContent = extractBraceContent(text: result, openIndex: afterCommand) else {
            break
        }
        result.replaceSubrange(range.lowerBound..<brace.nextIndex, with: brace.content)
    }
    return result
}

/// Metinde listelenen komutlardan biri geçiyor mu bakar.
private func containsAnyCommand(text: String, commands: [String]) -> Bool {
    for command: String in commands {
        if text.contains(command) {
            return true
        }
    }
    return false
}

/// İlk kesir komutunu `(pay)/(payda)` biçimine çevirir.
private func replaceFirstFraction(text: String, commands: [String]) -> String? {
    var earliestRange: Range<String.Index>? = nil
    for command: String in commands {
        if let range: Range<String.Index> = text.range(of: command) {
            if let earliest = earliestRange {
                if range.lowerBound < earliest.lowerBound {
                    earliestRange = range
                }
            } else {
                earliestRange = range
            }
        }
    }
    guard let commandRange: Range<String.Index> = earliestRange else {
        return nil
    }
    var cursor: String.Index = commandRange.upperBound
    guard cursor < text.endIndex && text[cursor] == "{" else {
        return nil
    }
    guard let numerator: BraceContent = extractBraceContent(text: text, openIndex: cursor) else {
        return nil
    }
    cursor = numerator.nextIndex
    guard cursor < text.endIndex && text[cursor] == "{" else {
        return nil
    }
    guard let denominator: BraceContent = extractBraceContent(text: text, openIndex: cursor) else {
        return nil
    }
    let top: String = wrapForFraction(content: numerator.content)
    let bottom: String = wrapForFraction(content: denominator.content)
    var result: String = text
    result.replaceSubrange(commandRange.lowerBound..<denominator.nextIndex, with: top + "/" + bottom)
    return result
}

/// İlk kök komutunu `√(...)` biçimine çevirir.
private func replaceFirstRoot(text: String) -> String? {
    guard let range: Range<String.Index> = text.range(of: "\\sqrt") else {
        return nil
    }
    var cursor: String.Index = range.upperBound
    // `\\sqrt[n]{x}` biçimindeki dereceyi sade üs olarak başa alır.
    var degreePrefix: String = ""
    if cursor < text.endIndex && text[cursor] == "[" {
        if let close: String.Index = text[cursor...].firstIndex(of: "]") {
            let degree: String = String(text[text.index(after: cursor)..<close])
            let compact: String = degree.trimmingCharacters(in: .whitespacesAndNewlines)
            if compact.isEmpty == false {
                degreePrefix = compact + "√"
            }
            cursor = text.index(after: close)
        }
    }
    guard cursor < text.endIndex && text[cursor] == "{" else {
        return nil
    }
    guard let inner: BraceContent = extractBraceContent(text: text, openIndex: cursor) else {
        return nil
    }
    let body: String = wrapForRoot(content: inner.content)
    let replacement: String = degreePrefix.isEmpty ? "√" + body : degreePrefix + body
    var result: String = text
    result.replaceSubrange(range.lowerBound..<inner.nextIndex, with: replacement)
    return result
}

/// Bilinmeyen `\komut` kalıntılarının ters bölüsünü atar.
private func replaceUnknownCommands(text: String) -> String {
    var result: String = ""
    var index: String.Index = text.startIndex
    while index < text.endIndex {
        let character: Character = text[index]
        if character != "\\" {
            result.append(character)
            index = text.index(after: index)
            continue
        }
        let next: String.Index = text.index(after: index)
        if next >= text.endIndex {
            break
        }
        let nextCharacter: Character = text[next]
        if nextCharacter.isLetter {
            // `\sin` gibi komutlarda ters bölüyü atıp adı korur.
            var end: String.Index = next
            while end < text.endIndex && text[end].isLetter {
                end = text.index(after: end)
            }
            result.append(contentsOf: text[next..<end])
            index = end
            continue
        }
        result.append(character)
        result.append(nextCharacter)
        index = text.index(after: next)
    }
    return result
}

/// Kesir pay/paydası parantez ister mi karar verir.
private func wrapForFraction(content: String) -> String {
    let trimmed: String = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return "?"
    }
    if trimmed.hasPrefix("(") && trimmed.hasSuffix(")") {
        return trimmed
    }
    let plain: Bool =
        trimmed.allSatisfy { character in
            character.isNumber || character.isLetter
        } && trimmed.contains(" ") == false
    if plain {
        return trimmed
    }
    return "(" + trimmed + ")"
}

/// Kök içini tek simgede yalın, uzunsa parantezli yazar.
private func wrapForRoot(content: String) -> String {
    let trimmed: String = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count <= 1 {
        return trimmed
    }
    if trimmed.hasPrefix("(") && trimmed.hasSuffix(")") {
        return trimmed
    }
    return "(" + trimmed + ")"
}

/// İçerik üst simgeye birebir çevrilebilirse çevirir, yoksa `^(...)` yazar.
private func superscriptOrFallback(content: String) -> String {
    let map: [String: String] = superscriptMap()
    var converted: String = ""
    for character: Character in content {
        let key: String = String(character)
        guard let mapped: String = map[key] else {
            return "^(" + content + ")"
        }
        converted.append(mapped)
    }
    return converted.isEmpty ? "" : converted
}

/// İçerik alt simgeye birebir çevrilebilirse çevirir, yoksa `_(...)` yazar.
private func subscriptOrFallback(content: String) -> String {
    let map: [String: String] = subscriptMap()
    var converted: String = ""
    for character: Character in content {
        let key: String = String(character)
        guard let mapped: String = map[key] else {
            return "_(" + content + ")"
        }
        converted.append(mapped)
    }
    return converted.isEmpty ? "" : converted
}

/// Üst simge karakter tablosu.
private func superscriptMap() -> [String: String] {
    return [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "n": "ⁿ", "i": "ⁱ",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ",
        "f": "ᶠ", "g": "ᵍ", "h": "ʰ", "j": "ʲ", "k": "ᵏ",
        "l": "ˡ", "m": "ᵐ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ",
        "s": "ˢ", "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ",
        "x": "ˣ", "y": "ʸ", "z": "ᶻ",
    ]
}

/// Alt simge karakter tablosu.
private func subscriptMap() -> [String: String] {
    return [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ",
        "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ",
        "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ",
        "v": "ᵥ", "x": "ₓ",
    ]
}

/// Ardışık boşlukları teke indirir.
private func collapseSpaces(text: String) -> String {
    var result: String = ""
    var previousWasSpace: Bool = false
    for character: Character in text {
        if character == " " || character == "\t" {
            if previousWasSpace {
                continue
            }
            previousWasSpace = true
            result.append(" ")
            continue
        }
        previousWasSpace = false
        result.append(character)
    }
    return result
}
