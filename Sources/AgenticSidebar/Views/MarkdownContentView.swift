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
    /// A `solution` fence: an exam answer's full derivation, rendered as a
    /// document card with a single copy action instead of as chat prose.
    case solution(id: String, content: String)
    /// A math formula or LaTeX block (`$$...$$` or ```math fence).
    case math(id: String, formula: String)

    var id: String {
        switch self {
        case .paragraph(let id, _): id
        case .heading(let id, _, _): id
        case .code(let id, _, _): id
        case .bulletItem(let id, _): id
        case .numberedItem(let id, _, _): id
        case .blockquote(let id, _): id
        case .divider(let id): id
        case .table(let id, _, _, _): id
        case .chart(let id, _): id
        case .plan(let id, _): id
        case .solution(let id, _): id
        case .math(let id, _): id
        }
    }
}

struct MarkdownContentView: View {
    let markdown: String
    let allowsPlanDocuments: Bool
    let isStreaming: Bool

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

    init(
        markdown: String,
        allowsPlanDocuments: Bool,
        isStreaming: Bool
    ) {
        self.markdown = markdown
        self.allowsPlanDocuments = allowsPlanDocuments
        self.isStreaming = isStreaming
    }

    init(
        markdown: String,
        allowsPlanDocuments: Bool
    ) {
        self.init(
            markdown: markdown,
            allowsPlanDocuments: allowsPlanDocuments,
            isStreaming: false
        )
    }

    init(markdown: String) {
        self.init(
            markdown: markdown,
            allowsPlanDocuments: true,
            isStreaming: false
        )
    }

    private var blocks: [MarkdownBlock] {
        cache.blocks(
            for: markdown,
            allowsPlanDocuments: allowsPlanDocuments,
            isStreaming: isStreaming
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
            ForEach(rows) { row in
                switch row {
                case .text(let id, let blocks):
                    SelectableMarkdownTextView(blocks: blocks, typography: runTypography)
                        .id(id)

                case .block(let block):
                    renderBlock(block)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A run of prose, or a block that has to be its own view.
    ///
    /// Consecutive prose is grouped so one drag can select a whole answer; a code
    /// block or a table ends the run because it brings its own view and its own
    /// affordances.
    private enum MarkdownRow: Identifiable {
        case text(id: String, blocks: [MarkdownBlock])
        case block(MarkdownBlock)

        var id: String {
            switch self {
            case .text(let id, _): "run-\(id)"
            case .block(let block): block.id
            }
        }
    }

    private var runTypography: MarkdownRunTypography {
        MarkdownRunTypography(
            fontFamily: fontFamily,
            pointSize: fontSize.pointSize,
            lineSpacing: lineSpacing.spacing
        )
    }

    private var rows: [MarkdownRow] {
        var rows: [MarkdownRow] = []
        var run: [MarkdownBlock] = []

        func flushRun() {
            guard let first = run.first else {
                return
            }
            rows.append(.text(id: first.id, blocks: run))
            run = []
        }

        for block in blocks {
            guard MarkdownTextRunBuilder.isTextual(block) else {
                flushRun()
                rows.append(.block(block))
                continue
            }

            run.append(block)
        }

        flushRun()
        return rows
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(_, let content):
            Text(MarkdownInlineText.attributed(from: content))
                .font(.system(size: fontSize.pointSize, weight: .regular, design: fontFamily.fontDesign))
                .lineSpacing(lineSpacing.spacing)
                .foregroundStyle(.primary)

        case .heading(_, let level, let text):
            headingView(level: level, text: text)

        case .code(_, let language, let code):
            CodeBlockView(
                language: language,
                code: code,
                fontSize: codeFontSize.pointSize,
                wordWrap: codeWordWrap,
                preset: themePreset,
                previewIsDark: isDarkMode
            )

        case .bulletItem(_, let text):
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

        case .numberedItem(_, let number, let text):
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

        case .blockquote(_, let text):
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

        case .table(_, let headers, let alignments, let rows):
            MarkdownTableView(
                headers: headers,
                alignments: alignments,
                rows: rows,
                fontSize: fontSize.pointSize,
                design: fontFamily.fontDesign,
                isDark: isDarkMode,
                preset: themePreset
            )

        case .chart(_, let spec):
            MarkdownChartView(
                spec: spec,
                isDark: isDarkMode,
                preset: themePreset,
                fontSize: fontSize.pointSize
            )

        case .plan(_, let content):
            PlanDocumentView(markdown: content)

        case .solution(_, let content):
            SolutionDocumentView(markdown: content)

        case .math(_, let formula):
            MathBlockView(
                formula: formula,
                fontSize: fontSize.pointSize,
                isDark: isDarkMode
            )
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
    let preset: AppThemePreset
    let previewIsDark: Bool

    @Environment(\.colorScheme) private var colorScheme

    @State private var confirmation = CopyConfirmation()
    @State private var showingPreview: Bool = false

    private var isDark: Bool { colorScheme == .dark }

    /// Yalnızca güvenli önizlenebilir dillerde buton çıkar; diğerleri salt kod kalır.
    private var previewSource: PreviewArtifactBuilder.Source? {
        switch language.lowercased() {
        case "html":
            return .html(code)
        case "svg":
            return .svg(code)
        case "mermaid":
            return .mermaid(code)
        default:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "Code" : language.lowercased())
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if previewSource != nil {
                    Button {
                        showingPreview = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "eye")
                                .font(.system(size: 10, weight: .medium))
                            Text("Preview")
                                .font(.caption2.weight(.medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .interactiveHoverPill(cornerRadius: 6)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .foregroundStyle(.secondary)
                    .help("Yalıtılmış önizlemeyi aç")
                }

                Button {
                    confirmation.copy(code)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: confirmation.isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                        Text(confirmation.isCopied ? "Copied" : "Copy")
                            .font(.caption2.weight(.medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .interactiveHoverPill(cornerRadius: 6)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .foregroundStyle(confirmation.isCopied ? .green : .secondary)
                .help("Copy code to clipboard")
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
        .sheet(isPresented: $showingPreview) {
            if let source = previewSource {
                LivePreviewPanelView(
                    title: language.lowercased(),
                    html: PreviewArtifactBuilder.document(for: source),
                    preset: preset,
                    isDark: previewIsDark,
                    onDismiss: { showingPreview = false }
                )
                .frame(minWidth: 560, minHeight: 420)
            }
        }
    }
}

private struct MathBlockView: View {
    let formula: String
    let fontSize: CGFloat
    let isDark: Bool

    @State private var confirmation = CopyConfirmation()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "function")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Formula")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    confirmation.copy(MathFormulaDisplay.copyText(raw: formula))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: confirmation.isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                        Text(confirmation.isCopied ? "Copied" : "Copy")
                            .font(.caption2.weight(.medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .interactiveHoverPill(cornerRadius: 6)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .foregroundStyle(confirmation.isCopied ? .green : .secondary)
                .help("Copy formula to clipboard")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.03))

            Divider()
                .opacity(0.25)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(MathFormulaDisplay.displayText(raw: formula))
                    .font(.system(size: max(14, fontSize + 1.5), weight: .regular, design: .serif))
                    .lineSpacing(4)
                    .foregroundStyle(isDark ? Color(white: 0.92) : Color(white: 0.12))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            isDark
                ? Color(red: 0.09, green: 0.10, blue: 0.14)
                : Color(red: 0.95, green: 0.95, blue: 0.97),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(.vertical, 3)
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

    func blocks(
        for markdown: String,
        allowsPlanDocuments: Bool,
        isStreaming: Bool
    ) -> [MarkdownBlock] {
        if source == markdown, self.allowsPlanDocuments == allowsPlanDocuments {
            return parsed
        }

        // A second chance before parsing: check shared store only if NOT streaming.
        if !isStreaming,
            let shared = MarkdownParseStore.shared.blocks(
                for: markdown,
                allowsPlanDocuments: allowsPlanDocuments
            )
        {
            source = markdown
            self.allowsPlanDocuments = allowsPlanDocuments
            parsed = shared
            return shared
        }

        let blocks = parseMarkdownBlocks(
            from: markdown,
            allowsPlanDocuments: allowsPlanDocuments
        )

        // Do not thrash the shared store with rapid intermediate streaming fragments!
        if !isStreaming {
            MarkdownParseStore.shared.store(
                blocks,
                for: markdown,
                allowsPlanDocuments: allowsPlanDocuments
            )
        }

        source = markdown
        self.allowsPlanDocuments = allowsPlanDocuments
        parsed = blocks
        return blocks
    }

    func blocks(
        for markdown: String,
        allowsPlanDocuments: Bool
    ) -> [MarkdownBlock] {
        blocks(
            for: markdown,
            allowsPlanDocuments: allowsPlanDocuments,
            isStreaming: false
        )
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
            || (totalCharacters > Self.maximumTotalCharacters && recency.count > 1)
        {
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
    /// Kapanmamış `$$` bloğunun yutabileceği en fazla satır; üstünde açılış
    /// satırı düz metindir, mesajın geri kalanı kurtulur.
    let maximumMathBlockLines = 40
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
                isPlanFenceLanguage(language)
            {
                blocks.append(.plan(id: "plan-\(blockCounter)", content: fenceContent))
            } else if allowsPlanDocuments,
                isSolutionFenceLanguage(language)
            {
                blocks.append(.solution(id: "solution-\(blockCounter)", content: fenceContent))
            } else if let chartSpec = chartSpec(fromFenceLanguage: language, content: fenceContent) {
                blocks.append(.chart(id: "chart-\(blockCounter)", spec: chartSpec))
            } else if isMathFenceLanguage(language) {
                blocks.append(.math(id: "math-\(blockCounter)", formula: fenceContent))
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

        if trimmed.hasPrefix("$$") {
            if trimmed.count >= 4 && trimmed.dropFirst(2).contains("$$") {
                blockCounter += 1
                blocks.append(.math(id: "math-\(blockCounter)", formula: trimmed))
                index += 1
                continue
            }

            let mathStart = index
            index += 1
            var mathLines: [String] = [trimmed]
            var closed = false
            // Kapanmamış `$$` mesajın geri kalanını yutmasın: makul bir
            // pencerede kapanış yoksa açılış satırı düz metindir, tüketilen
            // satırlar geri sarılıp normal akışta ayrıştırılır.
            while index < lines.count, mathLines.count <= maximumMathBlockLines {
                let mLine = lines[index]
                mathLines.append(mLine)
                index += 1
                if mLine.trimmingCharacters(in: .whitespaces).hasSuffix("$$") {
                    closed = true
                    break
                }
            }
            blockCounter += 1
            if closed {
                blocks.append(.math(id: "math-\(blockCounter)", formula: mathLines.joined(separator: "\n")))
            } else {
                index = mathStart + 1
                blocks.append(.paragraph(id: "para-\(blockCounter)", content: trimmed))
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

            if nextTrimmed.isEmpty || nextTrimmed.hasPrefix("```") || nextTrimmed.hasPrefix("$$") || nextTrimmed.hasPrefix("#")
                || nextTrimmed.hasPrefix("> ") || nextTrimmed.hasPrefix("- ") || nextTrimmed.hasPrefix("* ") || nextTrimmed.hasPrefix("+ ")
                || parseNumberedList(line: nextTrimmed) != nil || nextTrimmed == "---" || nextTrimmed == "***" || nextTrimmed == "___"
                || MarkdownTables.isTableStart(in: lines, at: index)
            {
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

/// `plan` ile aynı kural: ilk token `solution` ise dildir, arkası
/// parametredir (örn. ` ```solution full`).
func isSolutionFenceLanguage(_ language: String) -> Bool {
    let tokens = language.lowercased().split(separator: " ").map(String.init)
    return tokens.first == AgentMode.solutionFenceLanguage
}

/// `plan`/`chart` ile aynı kural: ilk token `math`/`latex` ise dildir,
/// arkası parametredir (örn. ` ```math display`).
func isMathFenceLanguage(_ language: String) -> Bool {
    let tokens = language.lowercased().split(separator: " ").map(String.init)
    return tokens.first == "math" || tokens.first == "latex"
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

    // Bilinmeyen tür sessizce çubuğa düşmez: üstteki kural gereği
    // bozuk grafik kod bloğu kalır, model yazım hatası maskelenmez.
    let defaultKind: MarkdownChartSpec.Kind
    if tokens.count > 1 {
        guard let kind = MarkdownChartSpec.Kind(rawValue: tokens[1]) else {
            return nil
        }
        defaultKind = kind
    } else {
        defaultKind = .bar
    }

    return MarkdownCharts.parseSpec(from: content, defaultKind: defaultKind)
}

private func parseNumberedList(line: String) -> (number: String, text: String)? {
    guard let dotIndex = line.firstIndex(of: ".") else {
        return nil
    }

    let prefix = String(line[..<dotIndex])

    // Ordered lists stay short in practice; the bound keeps prose that happens to
    // open with a four-digit number ("2026. yılında ...") in the paragraph path.
    guard prefix.count <= 3, prefix.allSatisfy(\.isNumber), Int(prefix) != nil else {
        return nil
    }

    let remainderIndex = line.index(after: dotIndex)
    let remainder = String(line[remainderIndex...]).trimmingCharacters(in: .whitespaces)
    return (number: "\(prefix).", text: remainder)
}
