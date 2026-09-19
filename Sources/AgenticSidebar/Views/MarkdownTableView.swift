import SwiftUI

enum MarkdownTableCellAlignment: Equatable, Sendable {
    case leading
    case center
    case trailing

    var frameAlignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// Table detection and parsing for the markdown block parser.
///
/// A table is a `|`-separated header row immediately followed by a delimiter
/// row (`|---|---|`); everything that keeps looking like a table row after that
/// becomes a body row. Cells are padded or trimmed to the header width so every
/// row renders in the same column layout.
enum MarkdownTables {
    struct ParsedTable: Equatable {
        let headers: [String]
        let alignments: [MarkdownTableCellAlignment]
        let rows: [[String]]
        let nextIndex: Int
    }

    static func isTableStart(in lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count else {
            return false
        }

        let headerLine = lines[index].trimmingCharacters(in: .whitespaces)
        guard headerLine.contains("|") else {
            return false
        }

        let delimiterLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard delimiterLine.contains("|"), isDelimiterRow(delimiterLine) else {
            return false
        }

        let headerCells = splitRow(headerLine)
        return headerCells.count >= 2 && headerCells.count == splitRow(delimiterLine).count
    }

    static func parse(in lines: [String], startingAt startIndex: Int) -> ParsedTable? {
        guard isTableStart(in: lines, at: startIndex) else {
            return nil
        }

        let headers = splitRow(lines[startIndex])
        let alignments = splitRow(lines[startIndex + 1]).map(alignment(forDelimiterCell:))

        var rows: [[String]] = []
        var index = startIndex + 2

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

            guard !trimmed.isEmpty, trimmed.contains("|"), !isDelimiterRow(trimmed) else {
                break
            }

            rows.append(normalized(cells: splitRow(trimmed), columnCount: headers.count))
            index += 1
        }

        return ParsedTable(
            headers: headers,
            alignments: alignments,
            rows: rows,
            nextIndex: index
        )
    }

    static func splitRow(_ line: String) -> [String] {
        var content = line.trimmingCharacters(in: .whitespaces)

        if content.hasPrefix("|") {
            content.removeFirst()
        }
        if content.hasSuffix("|") {
            content.removeLast()
        }

        var cells: [String] = []
        var currentCell = ""
        var isEscaping = false

        for character in content {
            if isEscaping {
                currentCell.append(character)
                isEscaping = false
                continue
            }

            switch character {
            case "\\":
                isEscaping = true
            case "|":
                cells.append(currentCell.trimmingCharacters(in: .whitespaces))
                currentCell = ""
            default:
                currentCell.append(character)
            }
        }
        if isEscaping {
            currentCell.append("\\")
        }

        cells.append(currentCell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func isDelimiterRow(_ line: String) -> Bool {
        let cells = splitRow(line)

        guard !cells.isEmpty else {
            return false
        }

        return cells.allSatisfy { cell in
            var core = cell

            if core.hasPrefix(":") {
                core.removeFirst()
            }
            if core.hasSuffix(":") {
                core.removeLast()
            }

            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }

    private static func alignment(forDelimiterCell cell: String) -> MarkdownTableCellAlignment {
        if cell.hasPrefix(":") && cell.hasSuffix(":") {
            return .center
        }

        return cell.hasSuffix(":") ? .trailing : .leading
    }

    private static func normalized(cells: [String], columnCount: Int) -> [String] {
        if cells.count == columnCount {
            return cells
        }

        if cells.count > columnCount {
            return Array(cells.prefix(columnCount))
        }

        return cells + Array(repeating: "", count: columnCount - cells.count)
    }
}

/// Renders a parsed table with equal-width columns that stay inside the message
/// column, theme-tinted header, and hairline grid lines.
struct MarkdownTableView: View {
    let headers: [String]
    let alignments: [MarkdownTableCellAlignment]
    let rows: [[String]]
    let fontSize: CGFloat
    let design: Font.Design
    let isDark: Bool
    let preset: AppThemePreset

    var body: some View {
        VStack(spacing: 0) {
            rowView(cells: headers, isHeader: true, isStriped: false)

            ForEach(rows.indices, id: \.self) { index in
                Rectangle()
                    .fill(borderColor)
                    .frame(height: 1)

                rowView(
                    cells: rows[index],
                    isHeader: false,
                    isStriped: !index.isMultiple(of: 2)
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private var borderColor: Color {
        (isDark ? preset.borderSubtleDark : preset.borderSubtleLight).opacity(0.9)
    }

    private func rowView(cells: [String], isHeader: Bool, isStriped: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(headers.indices, id: \.self) { column in
                if column > 0 {
                    Rectangle()
                        .fill(borderColor)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }

                cellView(
                    text: cells.indices.contains(column) ? cells[column] : "",
                    column: column,
                    isHeader: isHeader
                )
            }
        }
        .background(rowBackground(isHeader: isHeader, isStriped: isStriped))
    }

    private func cellView(text: String, column: Int, isHeader: Bool) -> some View {
        let alignment = alignments.indices.contains(column) ? alignments[column] : .leading

        return Text(MarkdownInlineText.attributed(from: text))
            .font(
                .system(
                    size: fontSize,
                    weight: isHeader ? .semibold : .regular,
                    design: design
                )
            )
            .foregroundStyle(.primary)
            .multilineTextAlignment(alignment.textAlignment)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minWidth: 72, maxWidth: 260, alignment: alignment.frameAlignment)
    }

    private func rowBackground(isHeader: Bool, isStriped: Bool) -> Color {
        if isHeader {
            return (preset.accentGradient.first ?? .accentColor)
                .opacity(isDark ? 0.16 : 0.12)
        }

        return isStriped ? Color.primary.opacity(isDark ? 0.045 : 0.03) : Color.clear
    }
}
