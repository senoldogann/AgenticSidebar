import SwiftUI

// MARK: - Sunum katmanı

/// Tek denemenin etkinlik satırı; süre ve araç sayısı bilinmiyorsa uydurulmaz.
struct TaskBoardAttemptPresentation: Identifiable, Equatable {
    let id: UUID
    let sequenceLabel: String
    let roleLabel: String
    let providerLabel: String
    let outcomeLabel: String
    let timingLabel: String
    let toolCallLabel: String?
    let isActive: Bool
    let accessibilityLabel: String
}

/// Etkinlik listesinin saf sunum fonksiyonları.
enum TaskActivityPresenter {

    static func rows(_ attempts: [TaskBoardAttemptSummary]) -> [TaskBoardAttemptPresentation] {
        attempts
            .sorted { lhs, rhs in
                if lhs.attemptSequence != rhs.attemptSequence {
                    return lhs.attemptSequence < rhs.attemptSequence
                }
                return lhs.startedAt < rhs.startedAt
            }
            .map { attempt in
                let roleLabel = TaskBoardStatusText.roleLabel(for: attempt.role)
                let outcomeLabel = TaskBoardStatusText.outcomeLabel(for: attempt.outcome)
                let timingLabel = timingText(attempt)
                let toolCallLabel = attempt.toolCallCount.map { "\($0) araç çağrısı" }
                let isActive = attempt.outcome == .inProgress && attempt.endedAt == nil

                var accessibilityLabel =
                    "Deneme \(attempt.attemptSequence). \(roleLabel). \(outcomeLabel). \(timingLabel). \(attempt.providerID) · \(attempt.modelID)"
                if let toolCallLabel {
                    accessibilityLabel += ". \(toolCallLabel)"
                }
                if isActive {
                    accessibilityLabel += ". Şu an sürüyor"
                }

                return TaskBoardAttemptPresentation(
                    id: attempt.id,
                    sequenceLabel: "Deneme \(attempt.attemptSequence)",
                    roleLabel: roleLabel,
                    providerLabel: "\(attempt.providerID) · \(attempt.modelID)",
                    outcomeLabel: outcomeLabel,
                    timingLabel: timingLabel,
                    toolCallLabel: toolCallLabel,
                    isActive: isActive,
                    accessibilityLabel: accessibilityLabel
                )
            }
    }

    static func summary(_ attempts: [TaskBoardAttemptSummary]) -> String {
        attempts.isEmpty ? "Etkinlik yok" : "\(attempts.count) deneme"
    }

    private static func timingText(_ attempt: TaskBoardAttemptSummary) -> String {
        if let durationSeconds = attempt.durationSeconds {
            let minutes = durationSeconds / 60
            let seconds = durationSeconds % 60
            if minutes > 0 {
                return "\(minutes) dk \(seconds) sn"
            }
            return "\(seconds) sn"
        }
        if attempt.outcome == .inProgress && attempt.endedAt == nil {
            return "Sürüyor"
        }
        return "Süre kaydedilmedi"
    }
}

// MARK: - Etkinlik görünümü

/// Deneme geçmişi; sahte ilerleme çubuğu çizmez, yalnızca kaydı gösterir.
/// Yükleme hataları seçimle taşınmaması için burada değil, pano/detay hata
/// yüzeylerinde gösterilir.
@MainActor
struct TaskActivityView: View {
    let attempts: [TaskBoardAttemptSummary]
    let isActionInFlight: Bool
    let preset: AppThemePreset
    let isDark: Bool

    private var rows: [TaskBoardAttemptPresentation] {
        TaskActivityPresenter.rows(attempts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Etkinlik")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.tertiary)
                Text(TaskActivityPresenter.summary(attempts))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                Spacer(minLength: 0)
                if isActionInFlight {
                    Text(TaskActionBarPresenter.busyExplanation)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(TaskActionBarPresenter.busyExplanation)
                }
            }

            if rows.isEmpty {
                Text("Bu görev için henüz deneme kaydı yok")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows) { row in
                        attemptRow(row)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            (isDark ? preset.surfaceDark : preset.surfaceLight).opacity(isDark ? 0.6 : 0.85),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    (isDark ? preset.borderSubtleDark : preset.borderSubtleLight).opacity(0.8),
                    lineWidth: 1
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Etkinlik. \(TaskActivityPresenter.summary(attempts))")
    }

    private func attemptRow(_ row: TaskBoardAttemptPresentation) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(row.isActive ? (preset.accentGradient.first ?? .accentColor) : Color.secondary.opacity(0.45))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.sequenceLabel)
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(row.roleLabel)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(row.outcomeLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(row.isActive ? (preset.accentGradient.first ?? .accentColor) : .secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            (row.isActive ? (preset.accentGradient.first ?? .accentColor) : Color.secondary)
                                .opacity(isDark ? 0.20 : 0.10),
                            in: Capsule()
                        )
                }
                Text(row.providerLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(row.timingLabel)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    if let toolCallLabel = row.toolCallLabel {
                        Text("·")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                        Text(toolCallLabel)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.primary.opacity(isDark ? 0.05 : 0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
    }
}
