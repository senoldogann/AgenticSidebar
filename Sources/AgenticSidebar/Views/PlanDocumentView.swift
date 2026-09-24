import AppKit
import SwiftUI

/// A plan the assistant proposed, rendered as a document instead of chat prose.
///
/// Plan mode is read-only until the user approves the proposal, so the plan is
/// the one thing worth reading carefully in that turn. It therefore gets a sheet
/// of its own — a file-like header, a page body with real markdown, and a copy
/// action — rather than being folded into the transcript as another paragraph of
/// text or a code block.
struct PlanDocumentView: View {
    let markdown: String
    /// Akış sırasında gövde kare kare büyür; bitmiş turda boş çit model
    /// hatasıdır. Boş gövde iki durumda da aynı karttır, yalnız satırın dili
    /// duruma göre seçilir.
    let isStreaming: Bool

    @Environment(SettingsStore.self) private var settingsStore: SettingsStore?
    @Environment(\.colorScheme) private var systemColorScheme

    @State private var isCopied = false

    private var isDark: Bool {
        settingsStore?.isDark(systemColorScheme: systemColorScheme)
            ?? (systemColorScheme == .dark)
    }

    private var preset: AppThemePreset {
        settingsStore?.currentThemePreset
            ?? AppThemes.preset(for: ThemeIdentifier.nebula.rawValue)
    }

    private var accent: Color {
        preset.accentGradient.first ?? .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Rectangle()
                .fill(preset.border(isDark: isDark))
                .frame(height: 1)

            if hasVisibleContent {
                // The body is parsed with plan documents disabled: a stray fence
                // inside a plan is a code block, never a nested sheet.
                MarkdownContentView(markdown: markdown, allowsPlanDocuments: false)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.primary)
            } else {
                loadingRow
            }
        }
        // Kart yalnız içeriği kadar yer tutar: boş gövde dalı (`loadingRow`)
        // esnek boy önerisini dolduracak genişleyen çocuk bırakmaz, o yüzden
        // ayrıca ideal-boy kilidi gerekmez. `.fixedSize(vertical: true)` burada
        // AppKit destekli satırların ideal boyunu yerleşim döngüsünün içine
        // sokuyordu: ölçü → kısıt turu → yeniden ölçü zinciri ana iş
        // parçacığını döndürüp "Yanıt Vermiyor"a ve 367-turlu kısıt istisnasına
        // (bug 309) gidiyordu. Dal değişimi görsel davranışı aynen korur.
        .background(
            pageBackground,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(preset.border(isDark: isDark), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            // A slim spine, so the sheet reads as one document rather than as a
            // stack of transcript paragraphs.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: preset.accentGradient,
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 3)
                .padding(.vertical, 10)
        }
        .shadow(
            color: .black.opacity(isDark ? 0.35 : 0.08),
            radius: 10,
            x: 0,
            y: 4
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Plan document")
    }

    /// Görünür karakter yoksa (akışta çit yeni açıldı ya da model boş
    /// kapattı) ölçülecek gövde yoktur: boş metin görünümü esnek boyda
    /// şişmek yerine sabit küçük satıra düşer. Tanım transkripttekiyle
    /// aynıdır, tek yerde durur.
    private var hasVisibleContent: Bool {
        ConversationDetailView.containsVisibleText(markdown)
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            if isStreaming {
                ProgressView()
                    .controlSize(.small)
            }

            Text(isStreaming ? "Plan hazırlanıyor…" : "Plan içeriği boş.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(accent)

            Text("PLAN.md")
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)

            Text("Plan")
                .font(.system(size: 9.5, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(
                    accent.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
                .foregroundStyle(accent)

            Spacer(minLength: 8)

            Button {
                copyToClipboard()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                    Text(isCopied ? "Copied" : "Copy")
                        .font(.caption2.weight(.medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .interactiveHoverPill(cornerRadius: 6)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .foregroundStyle(isCopied ? .green : .secondary)
            .help("Copy the plan")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.04))
        .clipShape(
            .rect(
                topLeadingRadius: 12,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 12
            )
        )
    }

    /// A page, not a bubble: slightly lifted from the transcript background with
    /// a hint of the theme colour in it.
    private var pageBackground: Color {
        if isDark {
            return preset.surfaceDark.opacity(0.92)
        }

        return preset.surfaceLight.opacity(0.98)
    }

    private func copyToClipboard() {
        Pasteboard.copy(markdown)

        withAnimation(.easeInOut(duration: 0.15)) {
            isCopied = true
        }

        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation {
                isCopied = false
            }
        }
    }
}
