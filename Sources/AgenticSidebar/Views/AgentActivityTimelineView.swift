import SwiftUI

struct AgentActivityTimelineView: View {
    @Environment(\.colorScheme) private var colorScheme

    let group: AgentTurnActivityGroup
    let isTurnActive: Bool

    @State private var expandedActivityIDs: Set<String>
    @State private var userManuallyCollapsed: Bool = false
    @State private var workingDotCount: Int = 1

    init(
        group: AgentTurnActivityGroup,
        isTurnActive: Bool
    ) {
        self.group = group
        self.isTurnActive = isTurnActive
        let isRunning = isTurnActive || group.activities.contains { $0.phase == .running }
        if isRunning, let thinking = group.activities.first(where: { $0.kind == .thinking }) {
            self._expandedActivityIDs = State(initialValue: [thinking.id.rawValue])
        } else {
            self._expandedActivityIDs = State(initialValue: [])
        }
    }

    private var isTurnRunning: Bool {
        isTurnActive || group.activities.contains { $0.phase == .running }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let thinking = group.activities.first(where: { $0.kind == .thinking }) {
                let children = group.activities.filter { $0.id != thinking.id }
                thinkingParentRow(thinking: thinking, children: children)
            } else {
                ForEach(group.activities) { activity in
                    activityRow(activity, isNested: false)
                }
            }

            if isTurnRunning {
                HStack(spacing: 6) {
                    Text(workingText)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                        .sunshineShimmer(isActive: true)

                    Spacer()
                }
                .padding(.leading, 4)
                .padding(.top, 2)
                .task {
                    while !Task.isCancelled && isTurnRunning {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        workingDotCount = (workingDotCount % 3) + 1
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if isTurnRunning && !userManuallyCollapsed {
                if let thinking = group.activities.first(where: { $0.kind == .thinking }) {
                    if !expandedActivityIDs.contains(thinking.id.rawValue) {
                        expandedActivityIDs.insert(thinking.id.rawValue)
                    }
                }
            }
        }
        .onChange(of: isTurnRunning) { oldValue, newValue in
            if newValue && !oldValue {
                userManuallyCollapsed = false
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    if let thinking = group.activities.first(where: { $0.kind == .thinking }) {
                        _ = expandedActivityIDs.insert(thinking.id.rawValue)
                    }
                }
            } else if !newValue && oldValue {
                userManuallyCollapsed = false
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    if let thinking = group.activities.first(where: { $0.kind == .thinking }) {
                        _ = expandedActivityIDs.remove(thinking.id.rawValue)
                    }
                }
            }
        }
        .onChange(of: group.activities) { _, newActivities in
            if isTurnRunning && !userManuallyCollapsed {
                if let thinking = newActivities.first(where: { $0.kind == .thinking }) {
                    if !expandedActivityIDs.contains(thinking.id.rawValue) {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            _ = expandedActivityIDs.insert(thinking.id.rawValue)
                        }
                    }
                }
            }
        }
    }

    private var workingText: String {
        "Working" + String(repeating: ".", count: workingDotCount)
    }


    @ViewBuilder
    private func thinkingParentRow(
        thinking: AgentActivity,
        children: [AgentActivity]
    ) -> some View {
        let isExpanded = expandedActivityIDs.contains(thinking.id.rawValue)
        let isRunning = thinking.phase == .running

        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    if isExpanded {
                        expandedActivityIDs.remove(thinking.id.rawValue)
                        if isTurnRunning {
                            userManuallyCollapsed = true
                        }
                    } else {
                        expandedActivityIDs.insert(thinking.id.rawValue)
                        if isTurnRunning {
                            userManuallyCollapsed = false
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    activityIcon(for: thinking)

                    rowLabel(for: thinking)

                    Spacer(minLength: 8)

                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 12, height: 12)
                    } else if thinking.phase == .failed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let detail = thinking.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12, design: .default))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 12)
                            .padding(.vertical, 2)
                    }

                    ForEach(children) { child in
                        activityRow(child, isNested: true)
                    }
                }
                .padding(.leading, 16)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1.5)
                        .padding(.leading, 10)
                        .padding(.vertical, 2)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func activityRow(_ activity: AgentActivity, isNested: Bool) -> some View {
        let isExpanded = expandedActivityIDs.contains(activity.id.rawValue)
        let isRunning = activity.phase == .running

        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    if isExpanded {
                        expandedActivityIDs.remove(activity.id.rawValue)
                    } else {
                        expandedActivityIDs.insert(activity.id.rawValue)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    // Action Icon
                    activityIcon(for: activity)

                    // Title & Description
                    rowLabel(for: activity)

                    Spacer(minLength: 8)

                    // Running progress or completion chevron
                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 12, height: 12)
                    } else if activity.phase == .failed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            // Inline Expanded Content (Terminal Box or File Detail)
            if isExpanded {
                expandedContent(for: activity)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func activityIcon(for activity: AgentActivity) -> some View {
        switch activity.kind {
        case .command:
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        case .read:
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        case .edit, .update:
            Image(systemName: "pencil")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        case .delete:
            Image(systemName: "trash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        case .webSearch:
            Image(systemName: "globe")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        case .thinking:
            Image(systemName: "brain")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        case .tool:
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        }
    }

    @ViewBuilder
    private func rowLabel(for activity: AgentActivity) -> some View {
        if activity.kind == .thinking {
            thinkingRowLabel(thinking: activity)
        } else if let title = activity.title, !title.isEmpty {
            parseTitleText(title)
                .sunshineShimmer(isActive: activity.phase == .running)
        } else {
            let presentation = AgentActivityPresentation(kind: activity.kind)
            let fallbackTitle = activity.phase == .running ? presentation.runningStatusName : presentation.title
            HStack(spacing: 5) {
                Text(fallbackTitle)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)

                if let detail = activity.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .sunshineShimmer(isActive: activity.phase == .running)
        }
    }

    @ViewBuilder
    private func thinkingRowLabel(thinking: AgentActivity) -> some View {
        let hasRunningChildren = group.activities.contains { $0.id != thinking.id && $0.phase == .running }

        if thinking.phase == .running || hasRunningChildren {
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                Text(
                    thinkingText(
                        thinking: thinking,
                        hasRunningChildren: hasRunningChildren,
                        at: context.date
                    )
                )
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .sunshineShimmer(isActive: true)
            }
        } else {
            Text(
                thinkingText(
                    thinking: thinking,
                    hasRunningChildren: false,
                    at: Date()
                )
            )
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.secondary)
        }
    }

    /// Ölçüm görünümün dışında, saf bir fonksiyonda durur.
    private func thinkingText(
        thinking: AgentActivity,
        hasRunningChildren: Bool,
        at date: Date
    ) -> String {
        ThinkingDurationPresentation.text(
            startedAt: thinking.startedAt,
            completedAt: thinking.completedAt,
            isRunning: thinking.phase == .running,
            hasRunningChildren: hasRunningChildren,
            now: date
        )
    }

    @ViewBuilder
    private func parseTitleText(_ title: String) -> some View {
        let parts = title.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            let verb = parts[0]
            let target = parts[1]

            HStack(spacing: 5) {
                Text(verb)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)

                Text(target)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            Text(title)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func expandedContent(for activity: AgentActivity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // A file change reads as a diff first: the `+`/`-` lines are the
            // point of the activity, and the tool's raw result adds little.
            if let diff = activity.diff, !diff.isEmpty {
                diffCard(diff: diff, path: activity.detail)
            }

            if activity.kind == .command {
                resultCard(
                    header: activity.detail,
                    headerSymbol: "terminal",
                    body: activity.output
                )
            } else if let output = activity.output, !output.isEmpty {
                // For reads and writes the tool's result *is* the file content,
                // so the card is labelled with the path it came from.
                resultCard(
                    header: activity.detail,
                    headerSymbol: "doc.text",
                    body: output
                )
            } else if activity.diff == nil, let detail = activity.detail, !detail.isEmpty {
                HStack(spacing: 6) {
                    Text(detail)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 24)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// The console-style surface shared by command output and file results.
    @ViewBuilder
    private func resultCard(
        header: String?,
        headerSymbol: String,
        body: String?
    ) -> some View {
        let isDark = colorScheme == .dark
        let text = body ?? ""

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: headerSymbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(isDark ? Color(white: 0.55) : Color(white: 0.45))

                Text(header ?? "command")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(isDark ? Color(white: 0.82) : Color(white: 0.22))
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(.bottom, text.isEmpty ? 0 : 2)

            if !text.isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(isDark ? Color(white: 0.68) : Color(white: 0.38))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isDark
                ? Color.black.opacity(0.55)
                : Color.black.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isDark
                        ? Color.white.opacity(0.12)
                        : Color.black.opacity(0.10),
                    lineWidth: 1
                )
        )
        .padding(.leading, 24)
        .padding(.trailing, 8)
    }

    /// The `+`/`-` preview of a file change, line by line, the way a diff is read
    /// everywhere else.
    @ViewBuilder
    private func diffCard(diff: String, path: String?) -> some View {
        let isDark = colorScheme == .dark
        let lines = diff.components(separatedBy: "\n")
        let addedCount = lines.filter { $0.hasPrefix("+ ") }.count
        let removedCount = lines.filter { $0.hasPrefix("- ") }.count

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "plusminus")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(isDark ? Color(white: 0.55) : Color(white: 0.45))

                if let path, !path.isEmpty {
                    Text(path)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(isDark ? Color(white: 0.82) : Color(white: 0.22))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 6)

                Text("+\(addedCount)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.green)

                Text("−\(removedCount)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.red)
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(diffLineForeground(line, isDark: isDark))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 0.5)
                            .background(diffLineBackground(line, isDark: isDark))
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isDark
                ? Color.black.opacity(0.55)
                : Color.black.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isDark
                        ? Color.white.opacity(0.12)
                        : Color.black.opacity(0.10),
                    lineWidth: 1
                )
        )
        .padding(.leading, 24)
        .padding(.trailing, 8)
    }

    private func diffLineForeground(_ line: String, isDark: Bool) -> Color {
        if line.hasPrefix("+ ") {
            return isDark ? Color(red: 0.48, green: 0.88, blue: 0.55) : Color(red: 0.05, green: 0.42, blue: 0.14)
        }
        if line.hasPrefix("- ") {
            return isDark ? Color(red: 0.98, green: 0.55, blue: 0.55) : Color(red: 0.60, green: 0.08, blue: 0.10)
        }
        if line.hasPrefix("…") {
            return .secondary
        }

        return isDark ? Color(white: 0.62) : Color(white: 0.40)
    }

    private func diffLineBackground(_ line: String, isDark: Bool) -> Color {
        if line.hasPrefix("+ ") {
            return Color.green.opacity(isDark ? 0.14 : 0.12)
        }
        if line.hasPrefix("- ") {
            return Color.red.opacity(isDark ? 0.14 : 0.10)
        }

        return .clear
    }
}

private struct SunshineShimmerModifier: ViewModifier {
    let isActive: Bool
    @State private var startPhase: CGFloat = -1.5

    init(isActive: Bool) {
        self.isActive = isActive
    }

    func body(content: Content) -> some View {
        if isActive {
            content
                .overlay(
                    GeometryReader { proxy in
                        let width = max(proxy.size.width, 100)
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: Color(red: 1.0, green: 0.85, blue: 0.45).opacity(0.18), location: 0.35),
                                .init(color: Color(red: 1.0, green: 0.98, blue: 0.85).opacity(0.70), location: 0.50),
                                .init(color: Color(red: 1.0, green: 0.85, blue: 0.45).opacity(0.18), location: 0.65),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: max(80, width * 0.45))
                        .offset(x: startPhase * (width + 120))
                        .blendMode(.plusLighter)
                    }
                    .mask(content)
                )
                .onAppear {
                    withAnimation(
                        .linear(duration: 3.6)
                        .repeatForever(autoreverses: false)
                    ) {
                        startPhase = 1.5
                    }
                }
        } else {
            content
        }
    }
}

extension View {
    fileprivate func sunshineShimmer(isActive: Bool) -> some View {
        modifier(SunshineShimmerModifier(isActive: isActive))
    }
}
