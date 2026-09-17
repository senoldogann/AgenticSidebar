import SwiftUI

struct AgentActivityTimelineView: View {
    @Environment(\.colorScheme) private var colorScheme

    let group: AgentTurnActivityGroup
    let isTurnActive: Bool
    let isSessionBusy: Bool
    /// Bitmiş bir alt ajanın raporunu sağ panelde açmak için; verilmezse düğme
    /// çizilmez.
    let onOpenReport: ((AgentActivity) -> Void)?
    let onOpenReview: ((TurnFileChangesSummary, FileChangeItem?) -> Void)?

    @State private var explicitlyExpandedIDs: Set<String> = []
    @State private var explicitlyCollapsedIDs: Set<String> = []
    @State private var userManuallyCollapsed: Bool = false
    @State private var workingDotCount: Int = 1

    init(
        group: AgentTurnActivityGroup,
        isTurnActive: Bool,
        isSessionBusy: Bool,
        onOpenReport: ((AgentActivity) -> Void)?,
        onOpenReview: ((TurnFileChangesSummary, FileChangeItem?) -> Void)?
    ) {
        self.group = group
        self.isTurnActive = isTurnActive
        self.isSessionBusy = isSessionBusy
        self.onOpenReport = onOpenReport
        self.onOpenReview = onOpenReview
    }

    private var isTurnRunning: Bool {
        isSessionBusy || isTurnActive || group.activities.contains { $0.phase == .running }
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

            let fileSummary = TurnFileChangesSummary.from(group: group)
            if !isTurnRunning, !fileSummary.isEmpty, let onOpenReview {
                FileChangesSummaryCard(
                    summary: fileSummary,
                    isExpanded: Binding(
                        get: { !explicitlyCollapsedIDs.contains("files:\(group.id.uuidString)") },
                        set: { expanded in
                            let key = "files:\(group.id.uuidString)"
                            if expanded {
                                explicitlyCollapsedIDs.remove(key)
                            } else {
                                explicitlyCollapsedIDs.insert(key)
                            }
                        }
                    ),
                    onOpenReview: onOpenReview
                )
                .padding(.top, 2)
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
    }

    private func isActivityExpanded(_ activity: AgentActivity) -> Bool {
        let rawID = activity.id.rawValue
        if explicitlyCollapsedIDs.contains(rawID) {
            return false
        }
        if explicitlyExpandedIDs.contains(rawID) {
            return true
        }
        if activity.kind == .subagent && activity.phase == .running {
            return true
        }
        if activity.kind == .thinking && isTurnRunning && !userManuallyCollapsed {
            return true
        }
        return false
    }

    private func toggleActivityExpanded(_ activity: AgentActivity) {
        let rawID = activity.id.rawValue
        if isActivityExpanded(activity) {
            explicitlyExpandedIDs.remove(rawID)
            explicitlyCollapsedIDs.insert(rawID)
            if activity.kind == .thinking && isTurnRunning {
                userManuallyCollapsed = true
            }
        } else {
            explicitlyCollapsedIDs.remove(rawID)
            explicitlyExpandedIDs.insert(rawID)
            if activity.kind == .thinking && isTurnRunning {
                userManuallyCollapsed = false
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
        let isExpanded = isActivityExpanded(thinking)
        let isRunning = thinking.phase == .running

        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    toggleActivityExpanded(thinking)
                }
            } label: {
                HStack(spacing: 8) {
                    activityIcon(for: thinking)

                    rowLabel(for: thinking)

                    Spacer(minLength: 8)

                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(minWidth: 12, minHeight: 12)
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
                .interactiveHoverPill(cornerRadius: 6)
            }
            .buttonStyle(.plain)

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
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func activityRow(_ activity: AgentActivity, isNested: Bool) -> some View {
        let isExpanded = isActivityExpanded(activity)
        let isRunning = activity.phase == .running

        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    toggleActivityExpanded(activity)
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
                            .frame(minWidth: 12, minHeight: 12)
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
                .interactiveHoverPill(cornerRadius: 6)
            }
            .buttonStyle(.plain)

            // Inline Expanded Content (Terminal Box or File Detail)
            if isExpanded {
                expandedContent(for: activity)
                    .transition(.opacity)
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
        case .todo:
            Image(systemName: "checklist")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        case .subagent:
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        case .mcp:
            Image(systemName: "server.rack")
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
        case .question:
            Image(systemName: "questionmark.bubble.fill")
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
        let turnEndedAt = group.activities.compactMap(\.completedAt).max()

        if thinking.phase == .running || hasRunningChildren {
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                Text(
                    thinkingText(
                        thinking: thinking,
                        turnEndedAt: turnEndedAt,
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
                    turnEndedAt: turnEndedAt,
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
        turnEndedAt: Date?,
        hasRunningChildren: Bool,
        at date: Date
    ) -> String {
        ThinkingDurationPresentation.text(
            startedAt: thinking.startedAt,
            completedAt: thinking.completedAt,
            turnEndedAt: turnEndedAt,
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
            } else if activity.kind == .subagent {
                subagentExecutionCard(activity: activity)
            } else if activity.kind == .mcp {
                resultCard(
                    header: activity.detail ?? activity.title ?? "MCP Tool Call",
                    headerSymbol: "server.rack",
                    body: activity.output ?? (activity.phase == .running ? "Executing MCP tool..." : nil)
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

    /// Real-time rich execution card for subagents, showing live inner tool steps and statuses.
    @ViewBuilder
    private func subagentExecutionCard(activity: AgentActivity) -> some View {
        let isDark = colorScheme == .dark

        VStack(alignment: .leading, spacing: 8) {
            // Header bar
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(activity.title ?? activity.detail ?? "Subagent Execution")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if activity.phase == .running {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(minWidth: 10, minHeight: 10)
                        Text("Live")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.blue)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.blue.opacity(0.12))
                    )
                } else if activity.phase == .completed {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                        Text(Self.completionLabel(for: activity))
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.green.opacity(0.12))
                    )
                } else if activity.phase == .failed {
                    Text("Failed")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.red.opacity(0.12))
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            Divider()
                .opacity(0.3)

            // Body content
            subagentCardBody(activity: activity, isDark: isDark)
        }
        .background(
            isDark ? Color.black.opacity(0.55) : Color.black.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.10), lineWidth: 1)
        )
        .padding(.leading, 24)
        .padding(.trailing, 8)
    }

    /// Gövde: koşarken canlı araç satırları; bitince özet ve "Read report".
    ///
    /// Bitmiş bir alt ajanın `output`'u nihai rapordur ve kart onu gömmez — sağ
    /// panelde okunur. Kart yalnız araç kullanımını gösterir.
    @ViewBuilder
    private func subagentCardBody(activity: AgentActivity, isDark: Bool) -> some View {
        if activity.phase == .running || activity.phase == .cancelled {
            if let output = activity.output, !output.isEmpty {
                stepLines(output: output, isDark: isDark)
            } else {
                activityPlaceholder(activity: activity)
            }
        } else if activity.output?.isEmpty == false {
            HStack(spacing: 8) {
                Text(activity.detail ?? "Finished")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                reportButton(activity: activity)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        } else {
            activityPlaceholder(activity: activity)
        }
    }

    /// Raporu sağ panelde açar; eylem yoksa düğme çizilmez.
    @ViewBuilder
    private func reportButton(activity: AgentActivity) -> some View {
        if let onOpenReport {
            Button {
                onOpenReport(activity)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                    Text(activity.phase == .completed ? "Read report" : "Read output")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.blue.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Open in the side panel")
        }
    }

    private func stepLines(output: String, isDark: Bool) -> some View {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let displayLines = lines.count > 20 ? Array(lines.suffix(20)) : lines
        let omittedCount = lines.count - displayLines.count

        return VStack(alignment: .leading, spacing: 4) {
            if omittedCount > 0 {
                Text("… (\(omittedCount) earlier steps)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
            }
            ForEach(Array(displayLines.enumerated()), id: \.offset) { _, line in
                subagentStepLineView(line: line, isDark: isDark)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func activityPlaceholder(activity: AgentActivity) -> some View {
        HStack(spacing: 6) {
            if activity.phase == .running {
                ProgressView()
                    .controlSize(.mini)
                    .frame(minWidth: 12, minHeight: 12)
                Text("Subagent initializing and preparing tools…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("No output logged by subagent.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// "Completed · 3m 12s": bitiş rozeti geçen süreyi de söyler.
    private static func completionLabel(for activity: AgentActivity) -> String {
        guard let completedAt = activity.completedAt else {
            return "Completed"
        }

        let seconds = max(0, Int(completedAt.timeIntervalSince(activity.startedAt).rounded()))
        guard seconds >= 60 else {
            return "Completed · \(seconds)s"
        }

        return "Completed · \(seconds / 60)m \(seconds % 60)s"
    }

    @ViewBuilder
    private func subagentStepLineView(line: String, isDark: Bool) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("✓") {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.green)
                    .padding(.top, 2)
                Text(String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isDark ? Color(white: 0.88) : Color(white: 0.18))
            }
        } else if trimmed.hasPrefix("✗") {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.red)
                    .padding(.top, 2)
                Text(String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
            }
        } else if trimmed.hasPrefix("…") {
            HStack(alignment: .top, spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                    .frame(minWidth: 10, minHeight: 10)
                    .padding(.top, 2)
                Text(String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.blue)
            }
        } else if trimmed.hasPrefix("Subagent") {
            Text(trimmed)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
        } else {
            Text(trimmed)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isDark ? Color(white: 0.68) : Color(white: 0.38))
        }
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
    @State private var pulse: Bool = false

    init(isActive: Bool) {
        self.isActive = isActive
    }

    func body(content: Content) -> some View {
        if isActive {
            content
                .opacity(pulse ? 0.60 : 1.0)
                .animation(
                    .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                    value: pulse
                )
                .onAppear {
                    pulse = true
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
