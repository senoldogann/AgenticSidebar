import SwiftUI

// MARK: - Sunum katmanı

/// Tek eylem butonunun sunumu; devre dışılık her zaman gerekçesiyle birlikte gelir.
struct TaskBoardActionPresentation: Identifiable, Equatable {
    let action: TaskBoardAction
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let disabledReason: String?
    let isInFlight: Bool
    let isDestructive: Bool
    let accessibilityLabel: String
    let accessibilityHint: String?

    var id: String { action.rawValue }
}

/// Eylem çubuğunun saf sunum fonksiyonları.
enum TaskActionBarPresenter {

    /// Kanonik eylem sırası; klavye sekme sırası da bu sırayı izler.
    static let displayOrder: [TaskBoardAction] = [
        .start, .pause, .resume, .stop, .retry, .requestChanges, .accept,
    ]

    static let busyExplanation = "Bu görev için bir işlem sürüyor; sonuç gelene kadar bekleyin."

    static func actions(
        availability: [TaskBoardActionAvailability],
        isInFlight: Bool,
        actor: String
    ) -> [TaskBoardActionPresentation] {
        let trimmedActor = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        return displayOrder.map { action in
            let base = availability.first { $0.action == action }
            var isEnabled = base?.isEnabled ?? false
            var disabledReason: String? = isEnabled ? nil : (base?.disabledReason ?? "Bu eylem panoda kullanılamıyor")

            if isEnabled, isInFlight {
                isEnabled = false
                disabledReason = busyExplanation
            } else if isEnabled, requiresHumanActor(action), trimmedActor.isEmpty {
                isEnabled = false
                disabledReason = humanActorReason(action)
            }

            let title = title(for: action)
            let accessibilityLabel: String
            if isEnabled {
                accessibilityLabel = title
            } else {
                accessibilityLabel = "\(title), devre dışı: \(disabledReason ?? "gerekçe yok")"
            }

            return TaskBoardActionPresentation(
                action: action,
                title: title,
                systemImage: systemImage(for: action),
                isEnabled: isEnabled,
                disabledReason: disabledReason,
                isInFlight: isInFlight,
                isDestructive: action == .stop,
                accessibilityLabel: accessibilityLabel,
                accessibilityHint: isEnabled ? "\(title) eylemini bu göreve uygular" : disabledReason
            )
        }
    }

    static func keyboardTabOrder(_ actions: [TaskBoardActionPresentation]) -> [TaskBoardAction] {
        actions.filter(\.isEnabled).map(\.action)
    }

    static func busyMessage(isInFlight: Bool) -> String? {
        isInFlight ? busyExplanation : nil
    }

    static func failureMessage(_ lastFailure: String?) -> String? {
        guard let lastFailure else { return nil }
        return "Son işlem uygulanmadı: \(lastFailure)"
    }

    private static func requiresHumanActor(_ action: TaskBoardAction) -> Bool {
        action == .accept || action == .requestChanges
    }

    private static func humanActorReason(_ action: TaskBoardAction) -> String {
        switch action {
        case .accept: "Kabul için insan aktör adı gerekir"
        case .requestChanges: "Değişiklik isteği için insan aktör adı gerekir"
        default: "İnsan aktör adı gerekir"
        }
    }

    static func title(for action: TaskBoardAction) -> String {
        switch action {
        case .start: "Başlat"
        case .pause: "Duraklat"
        case .resume: "Sürdür"
        case .stop: "Durdur"
        case .retry: "Yeniden dene"
        case .requestChanges: "Değişiklik iste"
        case .accept: "Kabul et"
        }
    }

    private static func systemImage(for action: TaskBoardAction) -> String {
        switch action {
        case .start: "play.fill"
        case .pause: "pause.fill"
        case .resume: "play.circle.fill"
        case .stop: "stop.fill"
        case .retry: "arrow.clockwise"
        case .requestChanges: "arrow.uturn.backward"
        case .accept: "checkmark.seal.fill"
        }
    }
}

// MARK: - Eylem çubuğu

/// Görev eylemi butonları: her buton yalnızca `TaskBoardStore`'a konuşur.
///
/// Devre dışı buton gerekçesini yardım metninde ve VoiceOver ipucunda taşır;
/// gönderilen her eylem store'un döndürdüğü sonuca göre yeniden çizilir, bu
/// yüzden hiçbir sonuç iyimser gösterilmez.
@MainActor
struct TaskActionBar: View {
    let store: TaskBoardStore
    let taskID: UUID
    let actor: String
    let feedback: String
    let preset: AppThemePreset
    let isDark: Bool

    private var actions: [TaskBoardActionPresentation] {
        TaskActionBarPresenter.actions(
            availability: store.actionAvailability(for: taskID),
            isInFlight: store.isActionInFlight(for: taskID),
            actor: actor
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = TaskActionBarPresenter.failureMessage(store.lastFailure) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(message)
            }

            HStack(spacing: 6) {
                ForEach(actions) { action in
                    button(action)
                }
                Spacer(minLength: 0)
                if store.isActionInFlight(for: taskID) {
                    Text("İşlem sürüyor")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Bu görev için işlem sürüyor")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func button(_ action: TaskBoardActionPresentation) -> some View {
        Button {
            perform(action.action)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(action.title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(foreground(for: action))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                background(for: action),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.45)
        .pointingHandCursor()
        .help(action.disabledReason ?? action.title)
        .accessibilityLabel(action.accessibilityLabel)
        .accessibilityHint(action.accessibilityHint ?? "")
    }

    private func foreground(for action: TaskBoardActionPresentation) -> Color {
        if !action.isEnabled { return .secondary }
        if action.isDestructive { return .red }
        if action.action == .accept { return preset.accentGradient.first ?? .accentColor }
        return .primary
    }

    private func background(for action: TaskBoardActionPresentation) -> Color {
        if action.action == .accept && action.isEnabled {
            return (preset.accentGradient.first ?? .accentColor).opacity(isDark ? 0.18 : 0.12)
        }
        return Color.primary.opacity(0.06)
    }

    private func perform(_ action: TaskBoardAction) {
        Task {
            switch action {
            case .start:
                _ = await store.start(taskID: taskID)
            case .pause:
                _ = await store.pause(taskID: taskID)
            case .resume:
                _ = await store.resume(taskID: taskID)
            case .stop:
                _ = await store.stop(taskID: taskID)
            case .retry:
                _ = await store.retry(taskID: taskID)
            case .requestChanges:
                _ = await store.requestChanges(taskID: taskID, actor: actor, feedback: feedback)
            case .accept:
                _ = await store.accept(taskID: taskID, actor: actor)
            }
        }
    }
}
