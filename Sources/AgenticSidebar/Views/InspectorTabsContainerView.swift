import SwiftUI

/// Container presenting multiple tabs in the right inspector panel with a top tab bar.
struct InspectorTabsContainerView: View {
    let tabs: [InspectorTab]
    let selectedTabID: String
    let preset: AppThemePreset
    let isDark: Bool
    let isExpanded: Bool
    /// Terminal sekmelerinin kabukları burada yaşar; sekme değişiminde kabuk
    /// kapanmaz, sekme kapanınca kapatılır.
    let terminalCenter: TerminalServiceCenter
    let onSelectTab: (String) -> Void
    let onCloseTab: (String) -> Void
    let onToggleExpand: () -> Void
    let onCloseAll: () -> Void

    private var activeTab: InspectorTab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.last
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            Divider()
                .opacity(0.4)

            if let activeTab {
                content(for: activeTab)
                    .id(activeTab.id)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            (isDark ? preset.surfaceDark : preset.surfaceLight).opacity(0.96)
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill((isDark ? preset.borderSubtleDark : preset.borderSubtleLight).opacity(0.6))
                .frame(width: 1)
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs) { tab in
                        tabItem(tab)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }

            Spacer(minLength: 0)

            Divider()
                .frame(height: 16)
                .opacity(0.3)
                .padding(.horizontal, 4)

            Button {
                onToggleExpand()
            } label: {
                Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .interactiveHoverCircle()
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(isExpanded ? "Restore side panel width" : "Expand to full width")

            Button {
                onCloseAll()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .interactiveHoverCircle()
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Close inspector panel")
            .padding(.trailing, 8)
        }
        .frame(height: 36)
        .background(
            (isDark ? Color.black.opacity(0.2) : Color.black.opacity(0.03))
        )
    }

    private func tabItem(_ tab: InspectorTab) -> some View {
        let isSelected = tab.id == selectedTabID
        let label = InspectorTab.displayLabel(for: tab, among: tabs)

        return HStack(spacing: 6) {
            Button {
                onSelectTab(tab.id)
            } label: {
                HStack(spacing: 5) {
                    tabIcon(name: tab.iconName, colorName: tab.iconColorName)
                        .frame(width: 13, height: 13)

                    Text(label)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(tab.title)

            Button {
                onCloseTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(isSelected ? Color.secondary : Color.secondary.opacity(0.6))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Close \(label) (\(tab.title))")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(
            isSelected
                ? (isDark ? preset.surfaceDark : preset.surfaceLight)
                : (isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.04)),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    isSelected
                        ? (isDark ? preset.borderSubtleDark : preset.borderSubtleLight).opacity(0.8)
                        : Color.clear,
                    lineWidth: 1
                )
        )
    }

    @ViewBuilder
    private func tabIcon(name: String, colorName: String) -> some View {
        let icon = Image(systemName: name)
            .font(.system(size: 10.5, weight: .semibold))

        switch colorName {
        case "orange":
            icon.foregroundStyle(.orange)
        case "yellow":
            icon.foregroundStyle(.yellow)
        case "blue":
            icon.foregroundStyle(.blue)
        case "green":
            icon.foregroundStyle(.green)
        case "purple":
            icon.foregroundStyle(.purple)
        case "red":
            icon.foregroundStyle(.red)
        case "accent":
            icon.foregroundStyle(preset.accentGradient.first ?? .accentColor)
        default:
            icon.foregroundStyle(.secondary)
        }
    }

    // MARK: - Active Content

    @ViewBuilder
    private func content(for tab: InspectorTab) -> some View {
        switch tab.kind {
        case .file(let url):
            FileInspectorPanelView(
                url: url,
                preset: preset,
                isDark: isDark,
                onDismiss: {
                    onCloseTab(tab.id)
                }
            )

        case .subagentReport(_, let title, let report):
            SubagentReportPanelView(
                title: title,
                report: report,
                preset: preset,
                isDark: isDark,
                onDismiss: {
                    onCloseTab(tab.id)
                }
            )

        case .changesReview(_, let summary, let initialFile):
            FileChangesReviewPanelView(
                summary: summary,
                initialSelectedFile: initialFile,
                preset: preset,
                isDark: isDark,
                onDismiss: {
                    onCloseTab(tab.id)
                }
            )
            .id("review:\(summary.id.uuidString):\(initialFile?.id.uuidString ?? "all")")

        case .terminal(let id, let workingDirectory):
            TerminalHostView(
                center: terminalCenter,
                tabID: id,
                workingDirectoryPath: workingDirectory,
                preset: preset,
                isDark: isDark,
                onDismiss: {
                    onCloseTab(tab.id)
                }
            )
        }
    }
}
