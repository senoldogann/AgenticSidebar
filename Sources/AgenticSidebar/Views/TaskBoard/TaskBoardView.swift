import SwiftUI

// MARK: - Sunum katmanı

/// Pano yükleme durumunun görünümden bağımsız kopyası.
///
/// Sunum katmanı `TaskBoardStore.Phase` türünü bilmez; eşleme görünümde yapılır,
/// böylece sunum testleri SwiftUI olmadan çalışır.
enum TaskBoardLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(message: String)
}

/// Durum ve aşama adlarının tek kaynağı; pano, detay ve etkinlik aynı dili konuşur.
enum TaskBoardStatusText {
    static func label(for status: TaskStatus) -> String {
        switch status {
        case .backlog: "Backlog"
        case .ready: "Hazır"
        case .running: "Çalışıyor"
        case .blocked: "Engellendi"
        case .review: "İnceleme"
        case .done: "Tamamlandı"
        case .cancelled: "İptal edildi"
        }
    }

    static func stageLabel(for stage: TaskStage) -> String {
        switch stage {
        case .analysis: "Analiz"
        case .plan: "Plan"
        case .implementation: "Uygulama"
        case .verification: "Doğrulama"
        case .codeReview: "Kod incelemesi"
        case .qa: "QA"
        case .acceptance: "Kabul"
        }
    }

    static func outcomeLabel(for outcome: AttemptOutcome) -> String {
        switch outcome {
        case .inProgress: "Sürüyor"
        case .succeeded: "Başarılı"
        case .failed: "Başarısız"
        case .cancelled: "İptal edildi"
        case .timedOut: "Zaman aşımı"
        }
    }

    static func roleLabel(for role: AgentRole) -> String {
        switch role {
        case .architect: "Mimar"
        case .developer: "Geliştirici"
        case .reviewer: "İnceleyici"
        case .qa: "QA"
        }
    }

    static func blockReason(_ reason: TaskBlockReason) -> String {
        switch reason {
        case .prerequisitesNotSatisfied: "önkoşullar tamamlanmadı"
        case .unsupportedCapability(let capability): "desteklenmeyen yetenek: \(capability)"
        case .rateLimited: "çalışma ortamı hız sınırında"
        case .approvalRequired: "onay gerekli"
        case .verificationFailed(let details): "doğrulama başarısız: \(details)"
        case .uncertainExecution(let details): "yürütme belirsiz: \(details)"
        case .custom(let value): value
        }
    }
}

/// Panonun beş aktif kolonu; engellenen ve iptal edilen görevler ayrı bölümlerde yaşar.
enum TaskBoardColumnKind: String, CaseIterable, Identifiable, Sendable {
    case backlog
    case ready
    case running
    case review
    case done

    var id: String { rawValue }

    var status: TaskStatus {
        switch self {
        case .backlog: .backlog
        case .ready: .ready
        case .running: .running
        case .review: .review
        case .done: .done
        }
    }

    var title: String {
        switch self {
        case .backlog: "Backlog"
        case .ready: "Hazır"
        case .running: "Çalışıyor"
        case .review: "İnceleme"
        case .done: "Tamamlandı"
        }
    }
}

struct TaskBoardColumnSection: Identifiable, Equatable {
    let kind: TaskBoardColumnKind
    let cards: [TaskBoardCard]

    var id: String { kind.rawValue }
}

/// Engellenen filtresi; engellenen görev varsa görsel olarak öne çıkar.
struct TaskBoardBlockedFilter: Equatable {
    let count: Int

    var isProminent: Bool { count > 0 }

    var label: String {
        count == 0 ? "Engellenen yok" : "Engellenenler (\(count))"
    }

    var accessibilityLabel: String {
        count == 0
            ? "Engellenen görev yok"
            : "\(count) engellenen görev var; yalnızca engellenenleri göster"
    }
}

/// Pano üstünde gösterilen yükleme/hata şeridi.
struct TaskBoardBanner: Equatable {
    enum Kind: Equatable {
        case loading
        case failure
    }

    let kind: Kind
    let message: String

    var accessibilityLabel: String {
        switch kind {
        case .loading: "Pano yükleniyor"
        case .failure: "Pano yüklenemedi: \(message)"
        }
    }
}

/// Sürükle-bırak sonucu: bırakma bir durum geçişi değildir, yalnızca açıklama üretir.
struct TaskBoardDropFeedback: Equatable {
    let target: TaskBoardColumnKind
    let message: String
    let mutatesStatus: Bool
}

/// Doğrulama rozeti; her durum adıyla konuşur, renk tek başına anlam taşımaz.
enum TaskBoardVerificationBadge: Equatable {
    case notLoaded
    case notWired
    case missing
    case verified
    case failed(reason: String)
    case stale(reason: String)

    var label: String? {
        switch self {
        case .notLoaded: nil
        case .notWired: "Doğrulama bağlı değil"
        case .missing: "Kanıt yok"
        case .verified: "Doğrulandı"
        case .failed: "Doğrulama başarısız"
        case .stale: "Doğrulama eskidi"
        }
    }

    var isStale: Bool {
        if case .stale = self { return true }
        return false
    }

    var accessibilityLabel: String? {
        switch self {
        case .notLoaded: nil
        case .notWired: "Doğrulama kaynağı bu sürümde bağlı değil"
        case .missing: "Doğrulama kanıtı yok"
        case .verified: "İçerik parmak iziyle doğrulandı"
        case .failed(let reason): "Doğrulama başarısız: \(reason)"
        case .stale(let reason): "Doğrulama eskimiş kanıta dayanıyor: \(reason)"
        }
    }
}

/// Tek kartın görünümden bağımsız sunumu.
struct TaskBoardCardPresentation: Equatable {
    let title: String
    let objective: String
    let statusLabel: String
    let stageLabel: String
    let criteriaLabel: String
    let dependencyLabel: String?
    let blockReasonText: String?
    let verificationBadge: TaskBoardVerificationBadge
    let accessibilityLabel: String
}

/// Klavye odak sırasının deterministik hedefleri.
enum TaskBoardFocusTarget: Equatable, Hashable {
    case card(UUID)
    case action(TaskBoardAction)
}

/// Panonun tamamının sunumu; kartlar hiçbir aşamada yeniden sıralanmaz.
struct TaskBoardPresentation: Equatable {
    let columns: [TaskBoardColumnSection]
    let blockedCards: [TaskBoardCard]
    let blockedFilter: TaskBoardBlockedFilter
    let cancelledCards: [TaskBoardCard]
    let cancelledHistoryLabel: String
    let banner: TaskBoardBanner?
    let emptyMessage: String?
}

/// Panonun saf sunum fonksiyonları: girdi projeksiyon, çıktı görünüm modeli.
enum TaskBoardPresenter {

    static func column(for status: TaskStatus) -> TaskBoardColumnKind? {
        TaskBoardColumnKind.allCases.first { $0.status == status }
    }

    static func present(cards: [TaskBoardCard], state: TaskBoardLoadState) -> TaskBoardPresentation {
        let columns = TaskBoardColumnKind.allCases.map { kind in
            TaskBoardColumnSection(kind: kind, cards: cards.filter { $0.status == kind.status })
        }
        let blocked = cards.filter { $0.status == .blocked }
        let cancelled = cards.filter { $0.status == .cancelled }
        return TaskBoardPresentation(
            columns: columns,
            blockedCards: blocked,
            blockedFilter: TaskBoardBlockedFilter(count: blocked.count),
            cancelledCards: cancelled,
            cancelledHistoryLabel: cancelled.isEmpty ? "İptal edilen görev yok" : "İptal edilenler (\(cancelled.count))",
            banner: banner(state: state),
            emptyMessage: emptyMessage(cards: cards, state: state)
        )
    }

    static func banner(state: TaskBoardLoadState) -> TaskBoardBanner? {
        switch state {
        case .loading:
            TaskBoardBanner(kind: .loading, message: "Pano yükleniyor…")
        case .failed(let message):
            TaskBoardBanner(kind: .failure, message: message)
        case .idle, .loaded:
            nil
        }
    }

    static func emptyMessage(cards: [TaskBoardCard], state: TaskBoardLoadState) -> String? {
        switch state {
        case .idle:
            "Proje seçilmedi"
        case .loaded where cards.isEmpty:
            "Bu projede henüz görev yok"
        default:
            nil
        }
    }

    /// Bırakma hiçbir durum mutasyonu üretmez; yalnızca kullanıcıya gerçeği söyler.
    static func dropFeedback(target: TaskBoardColumnKind) -> TaskBoardDropFeedback {
        TaskBoardDropFeedback(
            target: target,
            message: "Sürükle-bırak durum değiştirmez; \(target.title) kolonuna taşımak için görev eylemlerini kullanın",
            mutatesStatus: false
        )
    }

    /// Klavye sırası: kolon sırası, sonra engellenenler, sonra iptaller; en sonda açık eylemler.
    static func keyboardFocusOrder(
        cards: [TaskBoardCard],
        actions: [TaskBoardActionPresentation]
    ) -> [TaskBoardFocusTarget] {
        let orderedStatuses = TaskBoardColumnKind.allCases.map(\.status) + [.blocked, .cancelled]
        var targets: [TaskBoardFocusTarget] = []
        for status in orderedStatuses {
            for card in cards where card.status == status {
                targets.append(.card(card.id))
            }
        }
        for action in actions where action.isEnabled {
            targets.append(.action(action.action))
        }
        return targets
    }

    static func card(_ card: TaskBoardCard, verification: TaskBoardVerificationBadge) -> TaskBoardCardPresentation {
        let statusLabel = TaskBoardStatusText.label(for: card.status)
        let stageLabel = TaskBoardStatusText.stageLabel(for: card.stage)
        let criteriaLabel =
            card.criteriaTotal == 0
            ? "Ölçüt yok"
            : "\(card.criteriaCompleted)/\(card.criteriaTotal) ölçüt"
        let dependencyLabel =
            card.unmetPrerequisiteIDs.isEmpty
            ? nil
            : "\(card.unmetPrerequisiteIDs.count) önkoşul bekliyor"
        let blockReasonText = card.blockReason.map(TaskBoardStatusText.blockReason)

        var accessibilityLabel = "\(card.title). Durum: \(statusLabel). Aşama: \(stageLabel). \(criteriaLabel)"
        if let blockReasonText {
            accessibilityLabel += ". Engel: \(blockReasonText)"
        }
        if let dependencyLabel {
            accessibilityLabel += ". \(dependencyLabel)"
        }
        if let badgeLabel = verification.accessibilityLabel {
            accessibilityLabel += ". \(badgeLabel)"
        }

        return TaskBoardCardPresentation(
            title: card.title,
            objective: card.objective,
            statusLabel: statusLabel,
            stageLabel: stageLabel,
            criteriaLabel: criteriaLabel,
            dependencyLabel: dependencyLabel,
            blockReasonText: blockReasonText,
            verificationBadge: verification,
            accessibilityLabel: accessibilityLabel
        )
    }

    /// Kanıt yoksa asla yeşil yanmaz; eski parmak izli kanıt stale sayılır.
    static func verificationBadge(
        card: TaskBoardCard,
        evidence: [VerificationEvidence]?,
        currentFingerprint: String?
    ) -> TaskBoardVerificationBadge {
        guard let evidence else { return .notWired }
        if let failure = evidence.first(where: { $0.status == .failed }) {
            return .failed(reason: failure.blockedBy ?? failure.detailsRedacted)
        }
        if evidence.isEmpty, case .verificationFailed(let details)? = card.blockReason {
            return .failed(reason: details)
        }
        guard let current = currentFingerprint, !current.isEmpty else {
            if evidence.contains(where: { $0.status == .passed }) {
                return .stale(reason: "kanıt var ama güncel içerik parmak izi bilinmiyor")
            }
            return .missing
        }
        let passed = evidence.filter { $0.status == .passed }
        guard !passed.isEmpty else { return .missing }
        if passed.contains(where: { $0.workspaceFingerprint == current }) {
            return .verified
        }
        let witness = passed.first { $0.workspaceFingerprint != nil } ?? passed[0]
        let witnessFingerprint = witness.workspaceFingerprint ?? "bilinmiyor"
        return .stale(
            reason: "\(witness.stepName ?? witness.recipeName) parmak izi \(witnessFingerprint), güncel parmak izi \(current)"
        )
    }
}

// MARK: - Pano görünümü

/// Görev panosu: beş kolon, belirgin engellenen filtresi ve iptal geçmişi.
///
/// Tüm eylemler yalnızca `TaskBoardStore` üzerinden gider; görünüm servis, SQL
/// veya sağlayıcı türü bilmez. Kartlar tembel listelerde çizilir ve hiçbir
/// sürükle-bırak durum mutasyonu bağlanmaz.
@MainActor
struct TaskBoardView: View {
    let store: TaskBoardStore
    let preset: AppThemePreset
    let isDark: Bool

    @State private var showsBlockedOnly = false
    @State private var showsCancelledHistory = false
    @State private var showsCreationSheet = false

    private var loadState: TaskBoardLoadState {
        switch store.phase {
        case .idle: .idle
        case .loading: .loading
        case .loaded: .loaded
        case .failed(let message): .failed(message: message)
        }
    }

    private var presentation: TaskBoardPresentation {
        TaskBoardPresenter.present(cards: store.cards, state: loadState)
    }

    var body: some View {
        HStack(spacing: 0) {
            boardColumn

            if store.selectedTaskID != nil {
                Divider().opacity(0.4)
                TaskDetailView(store: store, preset: preset, isDark: isDark, input: .unwired)
                    .frame(minWidth: 320, idealWidth: 380, maxWidth: 460)
            }
        }
        .background(preset.background(isDark: isDark))
        .sheet(isPresented: $showsCreationSheet) {
            TaskCreationSheet(store: store, preset: preset, isDark: isDark)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Görev panosu")
    }

    // MARK: Header

    private var boardColumn: some View {
        VStack(spacing: 0) {
            header

            Divider().opacity(0.35)

            if let banner = presentation.banner {
                bannerView(banner)
            }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.split.3x1.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(preset.accentGradient.first ?? .accentColor)

            Text("Görev Panosu")
                .font(.system(size: 13, weight: .semibold))

            Spacer(minLength: 8)

            blockedFilterButton

            Button {
                showsCreationSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .interactiveHoverCircle()
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .disabled(store.selectedProjectID == nil)
            .opacity(store.selectedProjectID == nil ? 0.45 : 1)
            .help(store.selectedProjectID == nil ? "Görev oluşturmak için önce proje seçin" : "Yeni görev")
            .accessibilityLabel(store.selectedProjectID == nil ? "Yeni görev, devre dışı: proje seçilmedi" : "Yeni görev")

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .interactiveHoverCircle()
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Panoyu yenile")
            .accessibilityLabel("Panoyu yenile")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var blockedFilterButton: some View {
        Button {
            showsBlockedOnly.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: presentation.blockedFilter.isProminent ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .semibold))
                Text(presentation.blockedFilter.label)
                    .font(.system(size: 11, weight: presentation.blockedFilter.isProminent ? .semibold : .regular))
            }
            .foregroundStyle(presentation.blockedFilter.isProminent ? Color.orange : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                presentation.blockedFilter.isProminent
                    ? Color.orange.opacity(isDark ? 0.18 : 0.12)
                    : Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(presentation.blockedFilter.accessibilityLabel)
        .accessibilityLabel(presentation.blockedFilter.accessibilityLabel)
        .accessibilityAddTraits(showsBlockedOnly ? .isSelected : [])
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if store.cards.isEmpty, let emptyMessage = presentation.emptyMessage {
            emptyState(emptyMessage)
        } else if showsBlockedOnly {
            blockedLane
        } else {
            columns
            cancelledHistory
        }
    }

    private var columns: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(presentation.columns) { section in
                    columnView(section)
                }
            }
            .padding(10)
        }
        .frame(maxHeight: .infinity)
    }

    private func columnView(_ section: TaskBoardColumnSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(section.kind.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(section.cards.count)")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(section.cards) { card in
                        cardButton(card)
                    }
                }
            }
        }
        .frame(width: 236)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(section.kind.title) kolonu, \(section.cards.count) görev")
    }

    private var blockedLane: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 6) {
                Text(presentation.blockedFilter.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                ForEach(presentation.blockedCards) { card in
                    cardButton(card)
                }
            }
            .frame(maxWidth: 320, alignment: .leading)
            .padding(.horizontal, 10)
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.blockedFilter.label)
    }

    private var cancelledHistory: some View {
        DisclosureGroup(isExpanded: $showsCancelledHistory) {
            LazyVStack(spacing: 6) {
                ForEach(presentation.cancelledCards) { card in
                    cardButton(card)
                }
            }
            .padding(.top, 6)
        } label: {
            Text(presentation.cancelledHistoryLabel)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityLabel(presentation.cancelledHistoryLabel)
    }

    private func cardButton(_ card: TaskBoardCard) -> some View {
        TaskBoardCardView(
            card: card,
            isSelected: card.id == store.selectedTaskID,
            preset: preset,
            isDark: isDark,
            onSelect: {
                Task { await store.selectTask(card.id) }
            }
        )
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }

    private func bannerView(_ banner: TaskBoardBanner) -> some View {
        HStack(spacing: 6) {
            Image(systemName: banner.kind == .failure ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(banner.kind == .failure ? Color.red : Color.secondary)

            Text(banner.message)
                .font(.system(size: 11))
                .foregroundStyle(banner.kind == .failure ? .primary : .secondary)
                .lineLimit(2)

            Spacer(minLength: 0)

            if banner.kind == .failure {
                Button("Yeniden dene") {
                    Task { await store.refresh() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
                .pointingHandCursor()
                .accessibilityLabel("Panoyu yeniden yükle")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.red.opacity(banner.kind == .failure ? 0.08 : 0.0))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(banner.accessibilityLabel)
    }
}

/// Tek kart: yalnızca özet alanları çizer, detay seçim olmadan yüklenmez.
@MainActor
private struct TaskBoardCardView: View {
    let card: TaskBoardCard
    let isSelected: Bool
    let preset: AppThemePreset
    let isDark: Bool
    let onSelect: () -> Void

    private var presentation: TaskBoardCardPresentation {
        TaskBoardPresenter.card(card, verification: .notLoaded)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                Text(presentation.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(presentation.objective)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 5) {
                    statusChip
                    Text(presentation.stageLabel)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Text(presentation.criteriaLabel)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                if let blockReasonText = presentation.blockReasonText {
                    Label(blockReasonText, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }

                if let dependencyLabel = presentation.dependencyLabel {
                    Text(dependencyLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .background(
            (isDark ? preset.surfaceDark : preset.surfaceLight).opacity(isDark ? 0.9 : 0.98),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isSelected
                        ? (preset.accentGradient.first ?? .accentColor).opacity(0.8)
                        : (isDark ? preset.borderSubtleDark : preset.borderSubtleLight).opacity(0.7),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var statusChip: some View {
        Text(presentation.statusLabel)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(statusTint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(statusTint.opacity(0.14), in: Capsule())
    }

    private var statusTint: Color {
        switch card.status {
        case .backlog: .secondary
        case .ready: .blue
        case .running: preset.accentGradient.first ?? .accentColor
        case .blocked: .orange
        case .review: .purple
        case .done: .green
        case .cancelled: .secondary
        }
    }
}

// MARK: - Görev oluşturma

/// Yeni görev formu; yalnızca store üzerinden yazar ve reddi gizlemez.
@MainActor
private struct TaskCreationSheet: View {
    let store: TaskBoardStore
    let preset: AppThemePreset
    let isDark: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var objective = ""
    @State private var priorityText = "1"
    @State private var criteriaText = ""
    @State private var isSubmitting = false
    @State private var failureMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Yeni görev")
                .font(.system(size: 14, weight: .semibold))

            TextField("Başlık", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Görev başlığı")

            TextField("Amaç", text: $objective, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .accessibilityLabel("Görev amacı")

            TextField("Öncelik (sayı)", text: $priorityText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .accessibilityLabel("Öncelik")

            TextField("Ölçütler (her satır bir ölçüt)", text: $criteriaText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
                .accessibilityLabel("Kabul ölçütleri, her satır bir ölçüt")

            if let failureMessage {
                Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .accessibilityLabel("Görev oluşturulamadı: \(failureMessage)")
            }

            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .pointingHandCursor()
                Button("Oluştur") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting || store.selectedProjectID == nil)
                    .accessibilityLabel(isSubmitting ? "Görev oluşturuluyor" : "Görevi oluştur")
            }
        }
        .padding(16)
        .frame(width: 440)
        .background(preset.background(isDark: isDark))
    }

    private func submit() {
        guard let projectID = store.selectedProjectID else {
            failureMessage = "Proje seçilmedi"
            return
        }
        guard let priority = Int(priorityText.trimmingCharacters(in: .whitespacesAndNewlines)), priority >= 0 else {
            failureMessage = "Öncelik sıfır veya pozitif bir sayı olmalı"
            return
        }
        let criteria =
            criteriaText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        isSubmitting = true
        failureMessage = nil
        Task {
            let result = await store.createTask(
                projectID: projectID,
                title: title,
                objective: objective,
                priority: priority,
                criteria: criteria
            )
            isSubmitting = false
            switch result {
            case .applied:
                dismiss()
            case .refused(let refusal):
                failureMessage = refusal.message
            }
        }
    }
}
