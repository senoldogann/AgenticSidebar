import SwiftUI

/// Yan soru (`/btw`) paneli: ana transkriptin dışında akan tek-atımlık yanıt.
///
/// Bestecinin üstünde demirler (onay çubuğu deseni): soru, akan markdown
/// cevap, önceki değişimler, Kopyala + Besteciye ekle + Kapat. Esc kapatır
/// (akan soruyu da iptal eder). Soru/cevap transkripte yazılmaz.
struct SideQuestionPanelView: View {
    @Bindable var service: SideQuestionService
    var onInsertToComposer: (String) -> Void
    var onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(SettingsStore.self) private var settingsStore
    /// Besteciyle aynı dış kenar boşluğu: panel kenarları giriş kutusuyla
    /// hizalı durur (besteci `composerOuterPadding` ile aynı yardımcıdan okur).
    @Environment(\.paneWidth) private var paneWidth
    @State private var copyConfirmation = CopyConfirmation()

    private static let answerMaxHeight: CGFloat = 260

    private var isDarkMode: Bool {
        settingsStore.isDark(systemColorScheme: colorScheme)
    }

    private var currentTheme: AppThemePreset {
        settingsStore.currentThemePreset
    }

    var body: some View {
        if let current = service.active {
            VStack(alignment: .leading, spacing: 8) {
                headerRow(for: current)
                questionRow(for: current)
                answerArea(for: current)
                historyList(sessionID: current.sessionID)
                footerRow(for: current)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                currentTheme.surface(isDark: isDarkMode).opacity(0.96),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        currentTheme.border(isDark: isDarkMode).opacity(settingsStore.contrast),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(isDarkMode ? 0.30 : 0.08), radius: 8, y: 3)
            // Besteci gövdesiyle aynı kap (820) ve aynı dış dolgu: iki kartın
            // sol/sağ kenarları her bölme genişliğinde üst üste biner.
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, PaneResponsive.outerPadding(forWidth: paneWidth))
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .center)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Satırlar

    private func headerRow(for current: SideQuestionService.ActiveSideQuestion) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.bubble.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.blue)

            Text("Side question")
                .font(.system(size: 12, weight: .semibold))

            Text("not written to the transcript")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            if current.phase == .streaming {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
            } else if current.phase == .done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            } else if current.phase == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .interactiveHoverCircle()
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .keyboardShortcut(.cancelAction)
            .help("Close the side question (stops a running answer)")
        }
    }

    private func questionRow(for current: SideQuestionService.ActiveSideQuestion) -> some View {
        Text(current.question)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private func answerArea(for current: SideQuestionService.ActiveSideQuestion) -> some View {
        if current.phase == .failed {
            Text(current.errorText ?? "The side question could not be answered.")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
        } else if current.answer.isEmpty {
            Text(current.phase == .cancelled ? "Stopped." : "Waiting for an answer…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                MarkdownContentView(
                    markdown: current.answer,
                    allowsPlanDocuments: false,
                    isStreaming: current.phase == .streaming
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Self.answerMaxHeight)
        }
    }

    @ViewBuilder
    private func historyList(sessionID: UUID) -> some View {
        let prior = service.exchanges(for: sessionID)
        if !prior.isEmpty {
            DisclosureGroup("Earlier questions (\(prior.count))") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(prior.suffix(5).reversed()) { exchange in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(exchange.question)
                                .font(.system(size: 11.5, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(exchange.answer)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 2)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .help("Show earlier side questions in this conversation")
        }
    }

    private func footerRow(for current: SideQuestionService.ActiveSideQuestion) -> some View {
        HStack(spacing: 8) {
            if current.phase == .streaming {
                Button {
                    service.cancelStreaming()
                } label: {
                    footerLabel(symbol: "stop.fill", text: "Stop")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointingHandCursor()
                .help("Stop the running side answer")
            }

            Button {
                copyConfirmation.copy(current.answer)
            } label: {
                footerLabel(
                    symbol: copyConfirmation.isCopied ? "checkmark" : "doc.on.doc",
                    text: copyConfirmation.isCopied ? "Copied" : "Copy"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointingHandCursor()
            .disabled(current.answer.isEmpty)
            .help("Copy the side answer to the clipboard")

            Button {
                onInsertToComposer(current.answer)
            } label: {
                footerLabel(symbol: "text.insert", text: "Add to composer")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointingHandCursor()
            .disabled(current.answer.isEmpty)
            .help("Insert the side answer into the composer draft")

            Spacer(minLength: 0)
        }
    }

    private func footerLabel(symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10.5))
            Text(text)
                .font(.system(size: 11.5))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
}
