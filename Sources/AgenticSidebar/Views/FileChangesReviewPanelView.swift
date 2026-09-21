import AppKit
import SwiftUI

/// Right-side slide-in panel displaying the list of changed files and interactive diffs.
struct FileChangesReviewPanelView: View {
    @Environment(\.paneWidth) private var paneWidth

    let summary: TurnFileChangesSummary
    let initialSelectedFile: FileChangeItem?
    let preset: AppThemePreset
    let isDark: Bool
    let onDismiss: () -> Void

    @State private var selectedFileID: UUID?
    @State private var copyConfirmation = CopyConfirmation()
    @State private var viewMode: ReviewViewMode = .diff
    @State private var diskFileContent: String?
    @State private var isLoadingDiskContent = false

    private enum ReviewViewMode: String, CaseIterable, Identifiable {
        case diff = "Diff"
        case fullFile = "Full File"

        var id: String { rawValue }
    }

    init(
        summary: TurnFileChangesSummary,
        initialSelectedFile: FileChangeItem?,
        preset: AppThemePreset,
        isDark: Bool,
        onDismiss: @escaping () -> Void
    ) {
        self.summary = summary
        self.initialSelectedFile = initialSelectedFile
        self.preset = preset
        self.isDark = isDark
        self.onDismiss = onDismiss
        _selectedFileID = State(initialValue: initialSelectedFile?.id)
    }

    private var selectedFile: FileChangeItem? {
        if let selectedFileID {
            return summary.files.first { $0.id == selectedFileID }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .opacity(0.35)

            if let selected = selectedFile {
                fileDiffView(for: selected)
            } else {
                fileListView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            (isDark ? preset.surfaceDark : preset.surfaceLight).opacity(0.97)
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill((isDark ? preset.borderSubtleDark : preset.borderSubtleLight).opacity(0.6))
                .frame(width: 1)
        }
        .onChange(of: initialSelectedFile) { _, newFile in
            if let newFile {
                selectedFileID = newFile.id
                viewMode = .diff
                diskFileContent = nil
            }
        }
    }

    // MARK: - Header

    /// Dar panelde başlık taşardı: 135'lik dilim seçici + 3 düğme + geri/başlık
    /// aynı satıra sığmaz, yazılar simgelerin üstüne binerdi. Daraltmada
    /// seçici küçülür, ikincil düğme (Finder) kalkar, dolgular incelir.
    private var isCompactHeader: Bool {
        PaneResponsive.isCompact(width: paneWidth)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let selected = selectedFile {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedFileID = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        if !isCompactHeader {
                            Text("All files")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .interactiveHoverPill(cornerRadius: 6)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Back to all changed files")

                Divider()
                    .frame(height: 14)
                    .opacity(0.4)

                fileIcon(for: selected.fileExtension)
                    .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(selected.fileName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    HStack(spacing: 4) {
                        Text("+\(selected.additions)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.green)

                        Text("-\(selected.deletions)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                }
            } else {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(preset.accentGradient.first ?? .accentColor)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 1.5) {
                    Text("Changed Files")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    HStack(spacing: 5) {
                        Text("\(summary.fileCount) \(summary.fileCount == 1 ? "file" : "files")")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)

                        Text("+\(summary.totalAdditions)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.green)

                        Text("-\(summary.totalDeletions)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                if let selected = selectedFile {
                    Picker("", selection: $viewMode) {
                        ForEach(ReviewViewMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(isCompactHeader ? .mini : .small)
                    .frame(maxWidth: isCompactHeader ? 118 : 135)
                    .onChange(of: viewMode) { _, newMode in
                        if newMode == .fullFile {
                            loadDiskContent(for: selected.path)
                        }
                    }

                    Button {
                        copyFileDetails(selected)
                    } label: {
                        Image(systemName: copyConfirmation.isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(copyConfirmation.isCopied ? .green : .secondary)
                            .frame(width: 24, height: 24)
                            .interactiveHoverCircle()
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Copy diff or path")

                    // Daraltmada kalkar: kopyala + kapat yeter, satır nefes alır.
                    if !isCompactHeader {
                        Button {
                            revealInFinder(path: selected.path)
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .interactiveHoverCircle()
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .help("Reveal in Finder")
                    }
                } else {
                    Button {
                        copyAllPaths()
                    } label: {
                        Image(systemName: copyConfirmation.isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(copyConfirmation.isCopied ? .green : .secondary)
                            .frame(width: 24, height: 24)
                            .interactiveHoverCircle()
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Copy all file paths")
                }

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .interactiveHoverCircle()
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Close review panel")
                .accessibilityLabel("Close review")
            }
        }
        .padding(.horizontal, isCompactHeader ? 10 : 14)
        .padding(.vertical, 10)
    }

    // MARK: - File List (Screenshot 2)

    private var fileListView: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(summary.files) { file in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedFileID = file.id
                            viewMode = .diff
                            diskFileContent = nil
                        }
                    } label: {
                        HStack(spacing: 8) {
                            fileIcon(for: file.fileExtension)
                                .frame(width: 16, height: 16)

                            Text(file.fileName)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Text(file.directoryPath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 6)

                            HStack(spacing: 4) {
                                Text("+\(file.additions)")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.green)

                                Text("-\(file.deletions)")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.red)
                            }

                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.secondary.opacity(0.7))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .interactiveHoverPill(cornerRadius: 6)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("View diff for \(file.fileName)")
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Diff & Content View

    @ViewBuilder
    private func fileDiffView(for file: FileChangeItem) -> some View {
        if viewMode == .diff {
            if let diff = file.diff, !diff.isEmpty {
                diffLinesView(diff: diff)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)

                    Text("No inline diff recorded for this change.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)

                    Button("View Full File") {
                        viewMode = .fullFile
                        loadDiskContent(for: file.path)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("View the full file from disk")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            }
        } else {
            fullFileContentView(for: file)
        }
    }

    private func diffLinesView(diff: String) -> some View {
        let lines = diff.components(separatedBy: "\n")

        return GeometryReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary.opacity(0.55))
                                .frame(width: 34, alignment: .trailing)
                                .userSelectable(false)

                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(diffForeground(line))
                                .fixedSize(horizontal: true, vertical: false)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                        .frame(minWidth: max(proxy.size.width, 0), alignment: .leading)
                        .background(diffBackground(line))
                    }
                }
                .frame(minWidth: max(proxy.size.width, 0), alignment: .leading)
                .padding(.vertical, 8)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func fullFileContentView(for file: FileChangeItem) -> some View {
        if isLoadingDiskContent {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading file content...")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let content = diskFileContent {
            let lines = content.components(separatedBy: "\n")
            GeometryReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary.opacity(0.55))
                                    .frame(width: 36, alignment: .trailing)
                                    .userSelectable(false)

                                Text(line.isEmpty ? " " : line)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: true, vertical: false)

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 1.5)
                            .frame(minWidth: max(proxy.size.width, 0), alignment: .leading)
                        }
                    }
                    .frame(minWidth: max(proxy.size.width, 0), alignment: .leading)
                    .padding(.vertical, 8)
                }
            }
            .textSelection(.enabled)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundStyle(.orange)

                Text("File is not present on disk or could not be decoded.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        }
    }

    // MARK: - Diff Styling

    private func diffForeground(_ line: String) -> Color {
        if line.hasPrefix("+ ") || line.hasPrefix("+") {
            return isDark ? Color(red: 0.55, green: 0.95, blue: 0.65) : Color(red: 0.10, green: 0.60, blue: 0.20)
        }
        if line.hasPrefix("- ") || line.hasPrefix("-") {
            return isDark ? Color(red: 0.95, green: 0.55, blue: 0.55) : Color(red: 0.75, green: 0.15, blue: 0.15)
        }
        return .primary
    }

    private func diffBackground(_ line: String) -> Color {
        if line.hasPrefix("+ ") || line.hasPrefix("+") {
            return Color.green.opacity(isDark ? 0.16 : 0.10)
        }
        if line.hasPrefix("- ") || line.hasPrefix("-") {
            return Color.red.opacity(isDark ? 0.16 : 0.10)
        }
        return .clear
    }

    // MARK: - Actions

    private func copyFileDetails(_ file: FileChangeItem) {
        copyConfirmation.copy(file.diff ?? file.path)
    }

    private func copyAllPaths() {
        copyConfirmation.copy(summary.files.map(\.path).joined(separator: "\n"))
    }

    private func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func loadDiskContent(for path: String) {
        guard diskFileContent == nil else {
            return
        }
        isLoadingDiskContent = true
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                    let str = String(data: data, encoding: .utf8)
                else {
                    return nil
                }
                return str
            }.value

            await MainActor.run {
                self.diskFileContent = loaded
                self.isLoadingDiskContent = false
            }
        }
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

extension View {
    @ViewBuilder
    fileprivate func userSelectable(_ selectable: Bool) -> some View {
        if #available(macOS 14.0, *) {
            // Unselectable line numbers
            self
        } else {
            self
        }
    }
}
