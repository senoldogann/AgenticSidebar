import AppKit
import SwiftUI

/// Sağ tarafta açılan alt ajan raporu okuyucusu.
///
/// Kart yalnız araç kullanımını gösterir; nihai rapor burada okunur. İçerik
/// markdown olarak çizilir ve seçilip kopyalanabilir.
struct SubagentReportPanelView: View {
    let title: String
    let report: String
    let preset: AppThemePreset
    let isDark: Bool
    let onDismiss: () -> Void

    @State private var copyConfirmation = CopyConfirmation()

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .opacity(0.4)

            ScrollView {
                MarkdownContentView(markdown: report, allowsPlanDocuments: false)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(minWidth: 340, idealWidth: 440, maxWidth: 640)
        .background(
            (isDark ? preset.surfaceDark : preset.surfaceLight).opacity(0.96)
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill((isDark ? preset.borderSubtleDark : preset.borderSubtleLight).opacity(0.6))
                .frame(width: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(preset.accentGradient.first ?? .accentColor)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text("Subagent report")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Button {
                    copyConfirmation.copy(report)
                } label: {
                    Image(systemName: copyConfirmation.isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(copyConfirmation.isCopied ? .green : .secondary)
                        .frame(width: 24, height: 24)
                        .interactiveHoverCircle()
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Copy report")
                .accessibilityLabel("Copy report")

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
                .help("Close report")
                .accessibilityLabel("Close report")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
