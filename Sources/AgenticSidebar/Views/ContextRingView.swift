import SwiftUI

/// Bestecideki bağlam halkası: sağlayıcının bildirdiği pencere doluluğu.
///
/// Pay son turun bildirilen girdisi, payda seçili modelin gerçek
/// penceresidir (OpenCode `limit.context`, OpenAI katalog değeri).
/// Sağlayıcı bildirim ya da pencere vermiyorsa halka tahmin uydurmaz,
/// bilinmeyen gösterir ("–").
///
/// Üzerine gelince detay kartı açılır: yüzde + kullanılan/pencere, ilerleme
/// çubuğu, oturum boyu işlenen toplam ve Compact düğmesi (engelliyse
/// gerekçesiyle). Kart halkanın kaplamasıdır, düzeni oynatmaz; kartın
/// kendisi de kapsayıcının parçası olduğu için düğmeye fare taşınabilir.
struct ContextRingView: View {
    let usage: SessionContextUsage
    /// Oturum ömrünce işlenen toplam (giren + çıkan).
    let totalProcessedTokens: Int
    /// `nil` ise Compact basılabilir; değilse gerekçesi kartın altında yazar.
    let compactionBlocker: CompactionFailureReason?
    let onCompact: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: ringTrim)
                    .stroke(
                        ringColor,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.25), value: usage.fraction)
            }
            .frame(width: 16, height: 16)

            Text(shortLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .overlay(alignment: .bottomTrailing) {
            if isHovering {
                detailPanel
                    // Kart halkanın üstünde durur, alt kenarı satıra hafif
                    // biner: arada boşluk kalmaz, fare karta geçerken
                    // hover sönmez.
                    .offset(y: -28)
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .help(exactHelp)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Detay kartı

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Context Window")
                    .font(.system(size: 13, weight: .semibold))

                Spacer(minLength: 8)

                Text(windowSummary)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(ringColor)
                        .frame(width: barWidth(in: geometry.size.width))
                }
            }
            .frame(height: 6)

            HStack(spacing: 8) {
                Text("Total processed")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Text(Self.compactTokens(totalProcessedTokens))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
            }

            Button {
                onCompact()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .medium))
                    Text("Compact context")
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(compactionBlocker != nil)
            .help(
                compactionBlocker == nil
                    ? "Summarize older turns into a compact handoff note"
                    : compactionBlocker!.message
            )

            Text(footerText)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 264)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 12, y: 4)
    }

    private var windowSummary: String {
        switch (usage.usedTokens, usage.limitTokens) {
        case (let used?, let limit?):
            return "\(shortLabel) · \(Self.compactTokens(used))/\(Self.compactTokens(limit))"
        case (let used?, nil):
            return "\(Self.compactTokens(used)) · window unknown"
        case (nil, let limit?):
            return "– · \(Self.compactTokens(limit)) window"
        case (nil, nil):
            return "no provider data"
        }
    }

    private var footerText: String {
        if let compactionBlocker {
            return compactionBlocker.message
        }
        if usage.usedTokens == nil {
            return "The provider has not reported token usage yet."
        }
        if usage.limitTokens == nil {
            return "Model window unknown; showing the reported input count without a percentage."
        }
        return "Oldest turns auto-compact when the window fills."
    }

    /// Bildirim yoksa halka boş görünür; gri renk tahmin olmadığını söyler.
    private var ringTrim: Double {
        guard let fraction = usage.fraction else {
            return 0
        }
        return max(0.02, fraction)
    }

    private func barWidth(in totalWidth: Double) -> Double {
        guard let fraction = usage.fraction else {
            return 0
        }
        return max(6, totalWidth * fraction)
    }

    private var ringColor: Color {
        guard let fraction = usage.fraction else {
            return .gray.opacity(0.6)
        }
        if fraction >= 0.9 {
            return .red.opacity(0.9)
        }
        if fraction >= 0.7 {
            return .orange.opacity(0.9)
        }
        return .green.opacity(0.85)
    }

    private var shortLabel: String {
        guard let fraction = usage.fraction else {
            return "–"
        }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// Kesin sayılar: hover kartı kısaltılmış gösterir, erişilebilirlik ve
    /// ipucu tam değeri verir.
    private var exactHelp: String {
        let contextLine: String =
            switch (usage.usedTokens, usage.limitTokens) {
            case (let used?, let limit?):
                "Context: \(used) of \(limit) tokens (model window)."
            case (let used?, nil):
                "Context: \(used) tokens reported (model window unknown)."
            case (nil, let limit?):
                "Context: not reported yet (\(limit) token model window)."
            case (nil, nil):
                "Context: the provider has not reported token usage or window size."
            }
        var lines = [contextLine]
        if let input = usage.lastInputTokens, let output = usage.lastOutputTokens {
            lines.append(
                "Last turn reported: \(input) in, \(output) out."
            )
        } else {
            lines.append("Last turn not reported yet.")
        }
        lines.append("Total processed this session: \(totalProcessedTokens) tokens.")
        lines.append("Oldest turns auto-compact when the window fills.")
        return lines.joined(separator: " ")
    }

    private var accessibilityText: String {
        guard let used = usage.usedTokens, let limit = usage.limitTokens else {
            return "Context usage unknown, provider has not reported it"
        }
        return "Context usage \(shortLabel), \(used) of \(limit) tokens"
    }

    /// 24.100 → "24.1k", 200.000 → "200k", 1.050.000 → "1.1M".
    static func compactTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 100_000 {
            return "\(value / 1_000)k"
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }
}
