import SwiftUI

/// Inline summary card shown in the transcript when a turn modified or created files.
struct FileChangesSummaryCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let summary: TurnFileChangesSummary
    @Binding var isExpanded: Bool
    let onOpenReview: (TurnFileChangesSummary, FileChangeItem?) -> Void

    init(
        summary: TurnFileChangesSummary,
        isExpanded: Binding<Bool>,
        onOpenReview: @escaping (TurnFileChangesSummary, FileChangeItem?) -> Void
    ) {
        self.summary = summary
        self._isExpanded = isExpanded
        self.onOpenReview = onOpenReview
    }

    private var isDark: Bool {
        colorScheme == .dark
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                Divider()
                    .opacity(0.25)
                    .padding(.top, 6)
                    .padding(.bottom, 6)

                VStack(spacing: 3) {
                    ForEach(summary.files) { file in
                        fileRow(file)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            isDark
                ? Color(white: 0.12).opacity(0.85)
                : Color(white: 0.95).opacity(0.9),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(isDark ? Color.white.opacity(0.75) : Color.primary.opacity(0.65))

                    Text("\(summary.fileCount) \(summary.fileCount == 1 ? "file" : "files") changed")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)

                    HStack(spacing: 4) {
                        Text("+\(summary.totalAdditions)")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.green)

                        Text("-\(summary.totalDeletions)")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.red)
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(isDark ? Color.white.opacity(0.7) : Color.secondary)
                        .padding(.leading, 2)

                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .interactiveHoverPill(cornerRadius: 6)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(isExpanded ? "Collapse file list" : "Expand file list")
            .accessibilityLabel(isExpanded ? "Collapse file list" : "Expand file list")

            Button {
                onOpenReview(summary, nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 10.5, weight: .medium))

                    Text("Review")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .interactiveHoverPill(cornerRadius: 6)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Open changes in review panel")
            .accessibilityLabel("Review changes")
        }
    }

    private func fileRow(_ file: FileChangeItem) -> some View {
        Button {
            onOpenReview(summary, file)
        } label: {
            HStack(spacing: 7) {
                fileIcon(for: file.fileExtension)
                    .frame(width: 15, height: 15)

                Text(file.fileName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(file.directoryPath)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 6)

                HStack(spacing: 4) {
                    Text("+\(file.additions)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.green)

                    Text("-\(file.deletions)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.red)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3.5)
            .contentShape(Rectangle())
            .interactiveHoverPill(cornerRadius: 5)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Inspect \(file.fileName)")
    }

    @ViewBuilder
    private func fileIcon(for ext: String) -> some View {
        switch ext {
        case "swift":
            Image(systemName: "swift")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.orange)
        case "json":
            Image(systemName: "curlybraces")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.yellow)
        case "md", "markdown", "txt":
            Image(systemName: "doc.text")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.blue)
        case "sh", "bash", "zsh":
            Image(systemName: "terminal")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.green)
        case "js", "ts", "jsx", "tsx":
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.yellow)
        default:
            Image(systemName: "doc.text")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }
}
