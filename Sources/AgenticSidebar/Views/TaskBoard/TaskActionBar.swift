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

    /// Kanonik eylem sırasının tek kaynağı. Görünür birincil butonlar ve taşma
    /// menüsü bu sıradan türetilir; klavye odak sırası `keyboardTabOrder` ile
    /// aynı sırayı izler.
    static let displayOrder: [TaskBoardAction] = [
        .start, .pause, .resume, .stop, .retry, .requestChanges, .accept, .reopen,
    ]

    /// Çubukta her zaman görünen birincil eylemler; kanonik sıranın alt dizisi.
    static let primaryActions: [TaskBoardAction] = [.start, .pause, .resume, .stop, .accept]

    /// Taşma menüsünde toplanan ikincil eylemler; kanonik sıranın alt dizisi.
    static let secondaryActions: [TaskBoardAction] = [.retry, .requestChanges, .reopen]

    static let busyExplanation = "Bu görev için bir işlem sürüyor; sonuç gelene kadar bekleyin."
    static let missingFeedbackReason = "Değişiklik isteği için geri bildirim gerekli"

    static func actions(
        availability: [TaskBoardActionAvailability],
        isInFlight: Bool,
        actor: String,
        feedback: String
    ) -> [TaskBoardActionPresentation] {
        let trimmedActor = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFeedback = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
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
            } else if isEnabled, requiresFeedback(action), trimmedFeedback.isEmpty {
                isEnabled = false
                disabledReason = missingFeedbackReason
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

    /// Birincil butonlar kanonik sırayı korur; taşma menüsü kalanları taşır.
    static func primary(_ actions: [TaskBoardActionPresentation]) -> [TaskBoardActionPresentation] {
        actions.filter { primaryActions.contains($0.action) }
    }

    static func overflow(_ actions: [TaskBoardActionPresentation]) -> [TaskBoardActionPresentation] {
        actions.filter { secondaryActions.contains($0.action) }
    }

    /// Başarısız bir eylem sonucunu sesli/görsel gerekçeye çevirir; başarı sessizdir.
    static func refusalMessage(_ result: TaskBoardActionResult) -> String? {
        guard case .refused(let refusal) = result else { return nil }
        return "İşlem uygulanmadı (\(refusal.kind.rawValue)): \(refusal.message)"
    }

    private static func requiresHumanActor(_ action: TaskBoardAction) -> Bool {
        // Başlatma, güncel parmak izine bağlı bir `executeRecipe` onayı yazar;
        // bu yüzden kabul ve değişiklik isteğiyle aynı insan aktörünü ister.
        action == .start || action == .accept || action == .requestChanges
    }

    private static func requiresFeedback(_ action: TaskBoardAction) -> Bool {
        action == .requestChanges
    }

    private static func humanActorReason(_ action: TaskBoardAction) -> String {
        switch action {
        case .start: "Canlı koşu başlatmak için insan aktör adı gerekir"
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
        case .reopen: "Yeniden aç"
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
        case .reopen: "arrow.counterclockwise"
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

    @FocusState private var focusedAction: TaskBoardAction?
    @State private var lastRefusalMessage: String?

    private var actions: [TaskBoardActionPresentation] {
        TaskActionBarPresenter.actions(
            availability: store.actionAvailability(for: taskID),
            isInFlight: store.isActionInFlight(for: taskID),
            actor: actor,
            feedback: feedback
        )
    }

    private var primaryActions: [TaskBoardActionPresentation] {
        TaskActionBarPresenter.primary(actions)
    }

    private var overflowActions: [TaskBoardActionPresentation] {
        TaskActionBarPresenter.overflow(actions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let lastRefusalMessage {
                Label(lastRefusalMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(lastRefusalMessage)
            }

            HStack(spacing: 8) {
                ForEach(primaryActions) { action in
                    button(action)
                }
                if !overflowActions.isEmpty {
                    overflowMenu
                }
                Spacer(minLength: 0)
                if store.isActionInFlight(for: taskID) {
                    Text("İşlem sürüyor")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Bu görev için işlem sürüyor")
                }
            }
            .focusSection()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(overflowActions) { action in
                Button {
                    perform(action.action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .disabled(!action.isEnabled)
                .help(action.disabledReason ?? action.title)
                .accessibilityLabel(action.accessibilityLabel)
                .accessibilityHint(action.accessibilityHint ?? "")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12, weight: .semibold))
                .frame(minWidth: 28, minHeight: 28)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(overflowActions.contains(where: \.isEnabled) ? Color.primary : Color.secondary)
        .help("Diğer eylemler")
        .accessibilityLabel("Diğer eylemler")
    }

    private func button(_ action: TaskBoardActionPresentation) -> some View {
        Button {
            perform(action.action)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(action.title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(foreground(for: action))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minHeight: 28)
            .background(
                background(for: action),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(border(for: action), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.45)
        .pointingHandCursor()
        .animation(.easeInOut(duration: 0.18), value: action.isEnabled)
        .help(action.disabledReason ?? action.title)
        .accessibilityLabel(action.accessibilityLabel)
        .accessibilityHint(action.accessibilityHint ?? "")
        .focused($focusedAction, equals: action.action)
    }

    private func foreground(for action: TaskBoardActionPresentation) -> Color {
        if !action.isEnabled { return .secondary }
        if action.isDestructive { return .red }
        if action.action == .accept { return preset.accentGradient.first ?? .accentColor }
        return .primary
    }

    private func background(for action: TaskBoardActionPresentation) -> Color {
        if action.action == .accept && action.isEnabled {
            return (preset.accentGradient.first ?? .accentColor).opacity(isDark ? 0.20 : 0.12)
        }
        return Color.primary.opacity(action.isEnabled ? 0.07 : 0.04)
    }

    /// Buton çerçevesi arka planla aynı tonda kalır; kabul eylemi vurgu
    /// rengini taşır, diğerleri tema sınırında erir (renk kararı değişmedi).
    private func border(for action: TaskBoardActionPresentation) -> Color {
        if action.action == .accept && action.isEnabled {
            return (preset.accentGradient.first ?? .accentColor).opacity(0.45)
        }
        return Color.primary.opacity(0.08)
    }

    private func perform(_ action: TaskBoardAction) {
        Task {
            let result: TaskBoardActionResult
            switch action {
            case .start:
                result = await store.startRun(taskID: taskID, actor: actor)
            case .pause:
                result = await store.pause(taskID: taskID)
            case .resume:
                result = await store.resume(taskID: taskID)
            case .stop:
                result = await store.stop(taskID: taskID)
            case .retry:
                result = await store.retry(taskID: taskID)
            case .requestChanges:
                result = await store.requestChanges(taskID: taskID, actor: actor, feedback: feedback)
            case .accept:
                result = await store.accept(taskID: taskID, actor: actor)
            case .reopen:
                result = await store.reopen(taskID: taskID)
            }
            lastRefusalMessage = TaskActionBarPresenter.refusalMessage(result)
        }
    }
}
