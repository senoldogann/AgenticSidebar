import Charts
import SwiftUI

struct MarkdownChartPoint: Equatable, Sendable {
    let label: String
    let value: Double
}

struct MarkdownChartSpec: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case bar
        case line
        case area
        case pie
    }

    let kind: Kind
    let title: String?
    let points: [MarkdownChartPoint]
}

/// Parses the body of a ` ```chart ` fence.
///
/// Accepted lines:
/// - `type: bar|line|area|pie` and `title: ...` configure the chart
/// - `labels: Q1, Q2, Q3` with `values: 10, 20, 30` supply the data
/// - `Q1 = 10`, `Q1: 10` or `Q1, 10` add a single point
///
/// A fence without a recognizable series renders as a plain code block, so a
/// malformed chart never swallows its content.
enum MarkdownCharts {
    static func parseSpec(
        from content: String,
        defaultKind: MarkdownChartSpec.Kind
    ) -> MarkdownChartSpec? {
        var kind = defaultKind
        var title: String?
        var labels: [String] = []
        var values: [Double] = []
        var points: [MarkdownChartPoint] = []

        for rawLine in content.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                continue
            }

            guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "=" }) else {
                if let point = point(fromCommaSeparated: line) {
                    points.append(point)
                }
                continue
            }

            let rawKey = String(line[..<separator])
                .trimmingCharacters(in: .whitespaces)
            let key = rawKey.lowercased()
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)

            switch key {
            case "type", "kind":
                if let parsedKind = MarkdownChartSpec.Kind(rawValue: value.lowercased()) {
                    kind = parsedKind
                }
            case "title", "name":
                title = value.isEmpty ? nil : value
            case "labels", "x":
                labels = splitList(value)
            case "values", "y":
                values = splitList(value).compactMap(number(from:))
            default:
                if let number = number(from: value) {
                    points.append(MarkdownChartPoint(label: rawKey, value: number))
                }
            }
        }

        if points.isEmpty, !labels.isEmpty {
            points = zip(labels, values).map {
                MarkdownChartPoint(label: $0, value: $1)
            }
        }

        guard !points.isEmpty else {
            return nil
        }

        return MarkdownChartSpec(kind: kind, title: title, points: points)
    }

    private static func splitList(_ value: String) -> [String] {
        value
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func point(fromCommaSeparated line: String) -> MarkdownChartPoint? {
        let parts =
            line
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard parts.count >= 2, let value = number(from: parts[1]) else {
            return nil
        }

        return MarkdownChartPoint(label: parts[0], value: value)
    }

    private static func number(from value: String) -> Double? {
        let sanitized =
            value
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: " ", with: "")

        return Double(sanitized)
    }
}

/// Swift Charts rendering for a parsed ` ```chart ` fence.
struct MarkdownChartView: View {
    let spec: MarkdownChartSpec
    let isDark: Bool
    let preset: AppThemePreset
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = spec.title {
                Text(title)
                    .font(.system(size: fontSize + 0.5, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            Chart {
                ForEach(Array(spec.points.enumerated()), id: \.offset) { _, point in
                    marks(for: point)
                }
            }
            .chartLegend(spec.kind == .pie ? .visible : .hidden)
            .frame(height: 220)
        }
        .padding(14)
        .background(
            (isDark ? preset.surfaceDark : preset.surfaceLight)
                .opacity(isDark ? 0.6 : 0.85),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    (isDark ? preset.borderSubtleDark : preset.borderSubtleLight).opacity(0.9),
                    lineWidth: 1
                )
        )
    }

    private var accentColor: Color {
        preset.accentGradient.first ?? .accentColor
    }

    @ChartContentBuilder
    private func marks(for point: MarkdownChartPoint) -> some ChartContent {
        switch spec.kind {
        case .bar:
            BarMark(
                x: .value("Label", point.label),
                y: .value("Value", point.value)
            )
            .foregroundStyle(accentColor)
            .cornerRadius(4)

        case .line:
            LineMark(
                x: .value("Label", point.label),
                y: .value("Value", point.value)
            )
            .foregroundStyle(accentColor)
            .interpolationMethod(.catmullRom)

            PointMark(
                x: .value("Label", point.label),
                y: .value("Value", point.value)
            )
            .foregroundStyle(accentColor)

        case .area:
            AreaMark(
                x: .value("Label", point.label),
                y: .value("Value", point.value)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [accentColor.opacity(0.45), accentColor.opacity(0.05)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("Label", point.label),
                y: .value("Value", point.value)
            )
            .foregroundStyle(accentColor)
            .interpolationMethod(.catmullRom)

        case .pie:
            SectorMark(
                angle: .value("Value", point.value),
                innerRadius: .ratio(0.55),
                angularInset: 1.5
            )
            .foregroundStyle(by: .value("Label", point.label))
            .cornerRadius(4)
        }
    }
}
