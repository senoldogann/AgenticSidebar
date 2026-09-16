import AppKit
import SwiftUI

enum MarkdownBlock: Identifiable, Equatable {
    case paragraph(id: String, content: String)
    case heading(id: String, level: Int, text: String)
    case code(id: String, language: String, code: String)
    case bulletItem(id: String, text: String)
    case numberedItem(id: String, number: String, text: String)
    case blockquote(id: String, text: String)
    case divider(id: String)
    case table(
        id: String,
        headers: [String],
        alignments: [MarkdownTableCellAlignment],
        rows: [[String]]
    )
    case chart(id: String, spec: MarkdownChartSpec)
    /// A `plan` fence: the assistant's proposal, rendered as a document instead
    /// of as chat prose.
    case plan(id: String, content: String)

    var id: String {
        switch self {
        case let .paragraph(id, _): id
        case let .heading(id, _, _): id
        case let .code(id, _, _): id
        case let .bulletItem(id, _): id
        case let .numberedItem(id, _, _): id
        case let .blockquote(id, _): id
        case let .divider(id): id
        case let .table(id, _, _, _): id
        case let .chart(id, _): id
        case let .plan(id, _): id
        }
    }
}

struct MarkdownContentView: View {
    let markdown: String

    /// Plan documents are only recognised in a message body, never inside the
    /// body of a plan itself: a nested fence stays an ordinary code block, so the
    /// renderer cannot recurse.
    let allowsPlanDocuments: Bool

    @Environment(SettingsStore.self) private var settingsStore: SettingsStore?
    @Environment(\.colorScheme) private var systemColorScheme

    /// Ayrıştırma bu önbellekte hafızalanır.
    ///
    /// Önceki hâlde sonuç `init` içinde üretilip `@State`'e yazılıyordu; SwiftUI
    /// var olan state'i koruduğu için bu pahalı sonuç her yeniden çizimde
    /// (akışta 40 ms'de bir, hem de transkriptteki her mesaj için) hesaplanıp
    /// atılıyor, metin değiştiğinde `onChange` bir kez daha ayrıştırıyordu.
    /// Önbellek görünüm kimliğine bağlıdır: küresel durum yok, ilk karede boş
    /// içerik yok, metin değişmedikçe yeniden ayrıştırma yok.
    @State private var cache = MarkdownParseCache()

    init(markdown: String, allowsPlanDocuments: Bool = true) {
        self.markdown = markdown
        self.allowsPlanDocuments = allowsPlanDocuments
    }

    private var blocks: [MarkdownBlock] {
        cache.blocks(
            for: markdown,
            allowsPlanDocuments: allowsPlanDocuments
        )
    }

    private var fontFamily: AppFontFamily {
        settingsStore?.fontFamily ?? .system
    }

    private var fontSize: AppFontSize {
        settingsStore?.fontSize ?? .regular
    }

    private var codeFontSize: CodeFontSize {
        settingsStore?.codeFontSize ?? .standard
    }

    private var codeWordWrap: Bool {
        settingsStore?.codeWordWrap ?? false
    }

    private var lineSpacing: AppLineSpacing {
        settingsStore?.lineSpacing ?? .normal
    }

    private var isDarkMode: Bool {
        settingsStore?.isDark(systemColorScheme: systemColorScheme)
            ?? (systemColorScheme == .dark)
    }

    private var themePreset: AppThemePreset {
        settingsStore?.currentThemePreset
            ?? AppThemes.preset(for: ThemeIdentifier.nebula.rawValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                renderBlock(block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .paragraph(_, content):
            Text(MarkdownInlineText.attributed(from: content))
                .font(.system(size: fontSize.pointSize, weight: .regular, design: fontFamily.fontDesign))
                .lineSpacing(lineSpacing.spacing)
                .foregroundStyle(.primary)

        case let .heading(_, level, text):
            headingView(level: level, text: text)

        case let .code(_, language, code):
            CodeBlockView(
                language: language,
                code: code,
                fontSize: codeFontSize.pointSize,
                wordWrap: codeWordWrap
            )

        case let .bulletItem(_, text):
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .font(.system(size: fontSize.pointSize, weight: .bold, design: fontFamily.fontDesign))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, alignment: .center)

                Text(MarkdownInlineText.attributed(from: text))
                    .font(.system(size: fontSize.pointSize, weight: .regular, design: fontFamily.fontDesign))
                    .lineSpacing(lineSpacing.spacing)
                    .foregroundStyle(.primary)
            }
            .padding(.leading, 4)

        case let .numberedItem(_, number, text):
            HStack(alignment: .top, spacing: 8) {
                Text(number)
                    .font(.system(size: max(11, fontSize.pointSize - 1.0), weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 16, alignment: .trailing)

                Text(MarkdownInlineText.attributed(from: text))
                    .font(.system(size: fontSize.pointSize, weight: .regular, design: fontFamily.fontDesign))
                    .lineSpacing(lineSpacing.spacing)
                    .foregroundStyle(.primary)
            }
            .padding(.leading, 4)

        case let .blockquote(_, text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: 3)

                Text(MarkdownInlineText.attributed(from: text))
                    .font(.system(size: max(11, fontSize.pointSize - 0.5), weight: .regular, design: fontFamily.fontDesign))
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineSpacing(lineSpacing.spacing)
            }
            .padding(.vertical, 2)
            .padding(.leading, 4)

        case .divider:
            Divider()
                .opacity(0.5)
                .padding(.vertical, 4)

        case let .table(_, headers, alignments, rows):
            MarkdownTableView(
                headers: headers,
                alignments: alignments,
                rows: rows,
                fontSize: fontSize.pointSize,
                design: fontFamily.fontDesign,
                isDark: isDarkMode,
                preset: themePreset
            )

        case let .chart(_, spec):
            MarkdownChartView(
                spec: spec,
                isDark: isDarkMode,
                preset: themePreset,
                fontSize: fontSize.pointSize
            )

        case let .plan(_, content):
            PlanDocumentView(markdown: content)
        }
    }

    @ViewBuilder
    private func headingView(level: Int, text: String) -> some View {
        let baseSize = fontSize.pointSize
        switch level {
        case 1:
            Text(MarkdownInlineText.attributed(from: text))
                .font(.system(size: baseSize + 4.0, weight: .bold, design: fontFamily.fontDesign))
                .foregroundStyle(.primary)
                .padding(.top, 4)
        case 2:
            Text(MarkdownInlineText.attributed(from: text))
                .font(.system(size: baseSize + 2.0, weight: .bold, design: fontFamily.fontDesign))
                .foregroundStyle(.primary)
                .padding(.top, 3)
        case 3:
            Text(MarkdownInlineText.attributed(from: text))
                .font(.system(size: baseSize + 0.5, weight: .semibold, design: fontFamily.fontDesign))
                .foregroundStyle(.primary)
                .padding(.top, 2)
        default:
            Text(MarkdownInlineText.attributed(from: text))
                .font(.system(size: max(11, baseSize - 0.5), weight: .semibold, design: fontFamily.fontDesign))
                .foregroundStyle(.secondary)
        }
    }
}

private struct CodeBlockView: View {
    let language: String
    let code: String
    let fontSize: CGFloat
    let wordWrap: Bool

    @Environment(\.colorScheme) private var colorScheme

    @State private var isCopied: Bool = false

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "Code" : language.lowercased())
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    copyToClipboard()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                        Text(isCopied ? "Copied" : "Copy")
                            .font(.caption2.weight(.medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .interactiveHoverPill(cornerRadius: 6)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .foregroundStyle(isCopied ? .green : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.04))

            Divider()
                .opacity(0.3)

            if wordWrap {
                Text(code)
                    .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                    .lineSpacing(3)
                    .foregroundStyle(isDark ? Color(white: 0.88) : Color(white: 0.12))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(code)
                        .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                        .lineSpacing(3)
                        .foregroundStyle(isDark ? Color(white: 0.88) : Color(white: 0.12))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(
            isDark
                ? Color(red: 0.09, green: 0.10, blue: 0.13)
                : Color(red: 0.94, green: 0.94, blue: 0.96),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)

        isCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            isCopied = false
        }
    }
}

/// Tek bir mesajın ayrıştırma sonucunu tutan önbellek.
///
/// `@State` içinde yaşar, yani görünüm kimliği başına bir tanedir ve yalnızca
/// ana iş parçacığında kullanılır. Kaynak metin değişmedikçe aynı blok listesi
/// döner; değiştiğinde bir kez yeniden ayrıştırılır.
@MainActor
final class MarkdownParseCache {
    private var source: String?
    private var allowsPlanDocuments: Bool?
    private var parsed: [MarkdownBlock] = []

    func blocks(for markdown: String, allowsPlanDocuments: Bool) -> [MarkdownBlock] {
        if source == markdown, self.allowsPlanDocuments == allowsPlanDocuments {
            return parsed
        }

        // A second chance before parsing: the same text is commonly rendered by a
        // *new* view instance after the user switches conversations and comes
        // back, which loses this per-view cache but not the shared one.
        if let shared = MarkdownParseStore.shared.blocks(
            for: markdown,
            allowsPlanDocuments: allowsPlanDocuments
        ) {
            source = markdown
            self.allowsPlanDocuments = allowsPlanDocuments
            parsed = shared
            return shared
        }

        let blocks = parseMarkdownBlocks(
            from: markdown,
            allowsPlanDocuments: allowsPlanDocuments
        )
        MarkdownParseStore.shared.store(
            blocks,
            for: markdown,
            allowsPlanDocuments: allowsPlanDocuments
        )
        source = markdown
        self.allowsPlanDocuments = allowsPlanDocuments
        parsed = blocks
        return blocks
    }
}

/// A bounded, shared parse cache.
///
/// The per-view cache above survives re-renders but not a conversation switch:
/// the transcript rows are new view instances, so every visible message was
/// re-parsed on every switch and every scroll back. This store closes that gap
/// and is bounded in both entries and characters, because retaining parsed code
/// blocks of a long conversation forever would trade a stall for a leak.
@MainActor
final class MarkdownParseStore {
    static let shared = MarkdownParseStore()

    static let maximumEntries = 256
    static let maximumTotalCharacters = 1_000_000

    private struct Key: Hashable {
        let text: String
        let allowsPlanDocuments: Bool
    }

    private var entries: [Key: [MarkdownBlock]] = [:]
    /// Least recently used first.
    private var recency: [Key] = []
    private var totalCharacters = 0

    private(set) var hits = 0
    private(set) var misses = 0

    func blocks(for text: String, allowsPlanDocuments: Bool) -> [MarkdownBlock]? {
        let key = Key(text: text, allowsPlanDocuments: allowsPlanDocuments)

        guard let blocks = entries[key] else {
            misses += 1
            return nil
        }

        hits += 1
        touch(key)
        return blocks
    }

    func store(
        _ blocks: [MarkdownBlock],
        for text: String,
        allowsPlanDocuments: Bool
    ) {
        let key = Key(text: text, allowsPlanDocuments: allowsPlanDocuments)
        guard entries[key] == nil else {
            return
        }

        entries[key] = blocks
        recency.append(key)
        totalCharacters += text.count

        while recency.count > Self.maximumEntries
            || (totalCharacters > Self.maximumTotalCharacters && recency.count > 1) {
            let oldest = recency.removeFirst()
            totalCharacters -= oldest.text.count
            entries[oldest] = nil
        }
    }

    /// Used by the tests to start from a known state.
    func reset() {
        entries.removeAll()
        recency.removeAll()
        totalCharacters = 0
        hits = 0
        misses = 0
    }

    private func touch(_ key: Key) {
        if let index = recency.firstIndex(of: key) {
            recency.remove(at: index)
        }
        recency.append(key)
    }
}

func parseMarkdownBlocks(
    from rawText: String,
    allowsPlanDocuments: Bool = true
) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    let lines = rawText.components(separatedBy: "\n")
    var index = 0
    var blockCounter = 0

    while index < lines.count {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("```") {
            let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            index += 1
            var codeLines: [String] = []

            while index < lines.count {
                let codeLine = lines[index]
                if codeLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    index += 1
                    break
                }
                codeLines.append(codeLine)
                index += 1
            }

            blockCounter += 1
            let fenceContent = codeLines.joined(separator: "\n")

            if allowsPlanDocuments,
               isPlanFenceLanguage(language) {
                blocks.append(.plan(id: "plan-\(blockCounter)", content: fenceContent))
            } else if let chartSpec = chartSpec(fromFenceLanguage: language, content: fenceContent) {
                blocks.append(.chart(id: "chart-\(blockCounter)", spec: chartSpec))
            } else {
                blocks.append(
                    .code(
                        id: "code-\(blockCounter)",
                        language: language,
                        code: fenceContent
                    )
                )
            }
            continue
        }

        if let table = MarkdownTables.parse(in: lines, startingAt: index) {
            blockCounter += 1
            blocks.append(
                .table(
                    id: "table-\(blockCounter)",
                    headers: table.headers,
                    alignments: table.alignments,
                    rows: table.rows
                )
            )
            index = table.nextIndex
            continue
        }

        if trimmed.hasPrefix("### ") {
            blockCounter += 1
            blocks.append(
                .heading(
                    id: "h3-\(blockCounter)",
                    level: 3,
                    text: String(trimmed.dropFirst(4))
                )
            )
            index += 1
            continue
        }

        if trimmed.hasPrefix("## ") {
            blockCounter += 1
            blocks.append(
                .heading(
                    id: "h2-\(blockCounter)",
                    level: 2,
                    text: String(trimmed.dropFirst(3))
                )
            )
            index += 1
            continue
        }

        if trimmed.hasPrefix("# ") {
            blockCounter += 1
            blocks.append(
                .heading(
                    id: "h1-\(blockCounter)",
                    level: 1,
                    text: String(trimmed.dropFirst(2))
                )
            )
            index += 1
            continue
        }

        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            blockCounter += 1
            blocks.append(.divider(id: "div-\(blockCounter)"))
            index += 1
            continue
        }

        if trimmed.hasPrefix("> ") {
            blockCounter += 1
            blocks.append(
                .blockquote(
                    id: "quote-\(blockCounter)",
                    text: String(trimmed.dropFirst(2))
                )
            )
            index += 1
            continue
        }

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            blockCounter += 1
            blocks.append(
                .bulletItem(
                    id: "bullet-\(blockCounter)",
                    text: String(trimmed.dropFirst(2))
                )
            )
            index += 1
            continue
        }

        if let match = parseNumberedList(line: trimmed) {
            blockCounter += 1
            blocks.append(
                .numberedItem(
                    id: "numbered-\(blockCounter)",
                    number: match.number,
                    text: match.text
                )
            )
            index += 1
            continue
        }

        if trimmed.isEmpty {
            index += 1
            continue
        }

        var paragraphLines: [String] = [line]
        index += 1

        while index < lines.count {
            let nextLine = lines[index]
            let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)

            if nextTrimmed.isEmpty ||
                nextTrimmed.hasPrefix("```") ||
                nextTrimmed.hasPrefix("#") ||
                nextTrimmed.hasPrefix("> ") ||
                nextTrimmed.hasPrefix("- ") ||
                nextTrimmed.hasPrefix("* ") ||
                nextTrimmed.hasPrefix("+ ") ||
                parseNumberedList(line: nextTrimmed) != nil ||
                nextTrimmed == "---" ||
                nextTrimmed == "***" ||
                nextTrimmed == "___" ||
                MarkdownTables.isTableStart(in: lines, at: index) {
                break
            }

            paragraphLines.append(nextLine)
            index += 1
        }

        blockCounter += 1
        blocks.append(
            .paragraph(
                id: "p-\(blockCounter)",
                content: paragraphLines.joined(separator: "\n")
            )
        )
    }

    return blocks
}

/// A `plan` fence is matched case-insensitively and may carry a trailing hint
/// (```plan full`), because the fence language is model-written text.
func isPlanFenceLanguage(_ language: String) -> Bool {
    let tokens = language.lowercased().split(separator: " ").map(String.init)
    return tokens.first == AgentMode.planFenceLanguage
}

/// Whether a reply holds a plan document the user can approve.
func containsPlanDocument(_ markdown: String) -> Bool {
    markdown.components(separatedBy: "\n").contains { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") else {
            return false
        }

        return isPlanFenceLanguage(String(trimmed.dropFirst(3)))
    }
}

/// A fenced block opens a chart only for the `chart` language (` ```chart `,
/// optionally followed by the chart type). Everything else — including a
/// malformed chart body — stays a code block.
private func chartSpec(
    fromFenceLanguage language: String,
    content: String
) -> MarkdownChartSpec? {
    let tokens = language.lowercased().split(separator: " ").map(String.init)

    guard tokens.first == "chart" else {
        return nil
    }

    let defaultKind = tokens.count > 1
        ? (MarkdownChartSpec.Kind(rawValue: tokens[1]) ?? .bar)
        : .bar

    return MarkdownCharts.parseSpec(from: content, defaultKind: defaultKind)
}

private func parseNumberedList(line: String) -> (number: String, text: String)? {
    guard let dotIndex = line.firstIndex(of: ".") else {
        return nil
    }

    let prefix = String(line[..<dotIndex])

    // Ordered lists stay short in practice; the bound keeps prose that happens to
    // open with a four-digit number ("2026. yılında ...") in the paragraph path.
    guard prefix.count <= 3, prefix.allSatisfy(\.isNumber), let _ = Int(prefix) else {
        return nil
    }

    let remainderIndex = line.index(after: dotIndex)
    let remainder = String(line[remainderIndex...]).trimmingCharacters(in: .whitespaces)
    return (number: "\(prefix).", text: remainder)
}
