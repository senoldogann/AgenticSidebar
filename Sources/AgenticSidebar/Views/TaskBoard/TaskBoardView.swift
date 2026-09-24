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

/// Rozet tonu; görünüm rengi bu tondan türetir, yeşil yalnızca kanıtlanmış doğrulamaya aittir.
enum TaskBoardBadgeTone: Equatable {
    case positive
    case neutral
    case warning
    case negative
}

/// Doğrulama rozeti; her durum adıyla konuşur, renk tek başına anlam taşımaz.
enum TaskBoardVerificationBadge: Equatable {
    case notLoaded
    case notWired
    case missing
    case verified
    case failed(reason: String)
    case stale(reason: String)

    /// Renk kararı sunum katmanında verilir; başarısız/engelli asla yeşil yanmaz.
    var tone: TaskBoardBadgeTone {
        switch self {
        case .verified: .positive
        case .notLoaded, .notWired, .missing: .neutral
        case .stale: .warning
        case .failed: .negative
        }
    }

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

    /// Boş-durum birincil eylemi: yalnız yüklü ve boş panoda "İlk görevi
    /// oluştur" çıkar; projesiz/yükleniyor/hatalı durumda eylem yoktur
    /// (proje kaydı pano altındaki satırdan yapılır).
    static func emptyCallToAction(cards: [TaskBoardCard], state: TaskBoardLoadState) -> String? {
        switch state {
        case .loaded where cards.isEmpty:
            "İlk görevi oluştur"
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

/// Pano yerleşiminin sayısal sözleşmesi: kolon genişliği kullanılabilir
/// alandan türetilir, sabit 248 pt değildir.
///
/// Dar pencerede kolonlar taban genişliğe iner ve yatay kaydırma devreye
/// girer; geniş pencerede beş kolon da kaydırmasız sığar. Saf fonksiyondur,
/// görünüm çalıştırmadan test edilir.
enum TaskBoardLayout {
    /// Kolonun inebileceği en dar genişlik; altında kart metni okunmaz.
    static let minimumColumnWidth: CGFloat = 220
    /// Kolonlar arası boşluk (`LazyHStack` aralığıyla aynı).
    static let columnSpacing: CGFloat = 12
    /// Pano iç boşluğu (`.padding(12)` ile aynı).
    static let boardPadding: CGFloat = 12

    /// Kullanılabilir genişliğe göre kolon genişliği: yer varsa kolonlar
    /// esneyip tamamı sığar, yoksa tabana inip yatay kaydırmaya bırakır.
    static func columnWidth(availableWidth: CGFloat, columnCount: Int) -> CGFloat {
        let count = max(1, columnCount)
        let gaps = columnSpacing * CGFloat(count - 1) + boardPadding * 2
        let fitted = (availableWidth - gaps) / CGFloat(count)
        return max(minimumColumnWidth, fitted)
    }

    /// Beş kolonun kaydırmasız sığdığı en dar pano genişliği.
    static func fittingWidth(columnCount: Int) -> CGFloat {
        let count = max(1, columnCount)
        return minimumColumnWidth * CGFloat(count) + columnSpacing * CGFloat(count - 1) + boardPadding * 2
    }
}

// MARK: - Pano görünümü

/// Görev panosu: beş kolon, belirgin engellenen filtresi ve iptal geçmişi.
///
/// Tüm eylemler yalnızca `TaskBoardStore` üzerinden gider; görünüm servis, SQL
/// veya sağlayıcı türü bilmez. Kartlar tembel listelerde çizilir ve hiçbir
/// sürükle-bırak durum mutasyonu bağlanmaz. Denetçi girdisi dışarıdan enjekte
/// edilir; gövdeye dokunmadan kanıt, bulgu ve diff bağlanabilir.
@MainActor
struct TaskBoardView: View {
    let store: TaskBoardStore
    let preset: AppThemePreset
    let isDark: Bool
    let inspectorInput: TaskBoardInspectorInput

    @State private var showsBlockedOnly = false
    @State private var showsCancelledHistory = false
    @State private var showsCreationSheet = false
    @FocusState private var focusedCardID: UUID?

    /// Denetçi kaynağı bağlanmayan çağrılar açıkça `unwired` sözleşmesini kullanır.
    init(store: TaskBoardStore, preset: AppThemePreset, isDark: Bool) {
        self.init(store: store, preset: preset, isDark: isDark, inspectorInput: .unwired)
    }

    init(
        store: TaskBoardStore,
        preset: AppThemePreset,
        isDark: Bool,
        inspectorInput: TaskBoardInspectorInput
    ) {
        self.store = store
        self.preset = preset
        self.isDark = isDark
        self.inspectorInput = inspectorInput
    }

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

    /// Detay bölmesine giden denetçi girdisi: mağaza seçili görev için
    /// kanıt/bulgu yüklediyse gerçek değerler kullanılır, yoksa çağrı
    /// anındaki enjekte girdi (üretimde `unwired`) korunur. Gövde mağaza
    /// değiştikçe yeniden hesaplandığı için seçim sonrası yüklenen
    /// değerler karta yansır.
    private var resolvedInspectorInput: TaskBoardInspectorInput {
        if let selected = store.selectedTaskID, store.selectedInspectorTaskID == selected {
            return TaskBoardInspectorInput(
                evidence: store.selectedTaskEvidence,
                currentFingerprint: store.selectedTaskFingerprint,
                findings: store.selectedTaskFindings,
                workspaceID: store.selectedTaskWorkspaceID,
                diffSummary: nil,
                warning: store.selectedInspectorWarning
            )
        }
        return inspectorInput
    }

    var body: some View {
        HStack(spacing: 0) {
            boardColumn

            if let selectedTaskID = store.selectedTaskID {
                Divider().opacity(0.4)
                TaskDetailView(store: store, preset: preset, isDark: isDark, input: resolvedInspectorInput)
                    .id(TaskDetailPresenter.paneIdentity(for: selectedTaskID))
                    .frame(minWidth: 320, idealWidth: 380, maxWidth: 460)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            Task { await store.selectTask(nil) }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 22, height: 22)
                                .interactiveHoverCircle()
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .help("Görev detayını kapat")
                        .accessibilityLabel("Görev detayını kapat")
                        .padding(6)
                    }
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
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                presentation.blockedFilter.isProminent
                    ? Color.orange.opacity(isDark ? 0.18 : 0.12)
                    : Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        presentation.blockedFilter.isProminent
                            ? Color.orange.opacity(0.35)
                            : (isDark ? preset.borderSubtleDark : preset.borderSubtleLight).opacity(0.8),
                        lineWidth: 1
                    )
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
            emptyState(
                emptyMessage,
                callToAction: TaskBoardPresenter.emptyCallToAction(cards: store.cards, state: loadState)
            )
        } else if showsBlockedOnly {
            blockedLane
        } else {
            columns
            cancelledHistory
        }
    }

    private var columns: some View {
        GeometryReader { proxy in
            let width = TaskBoardLayout.columnWidth(
                availableWidth: proxy.size.width,
                columnCount: presentation.columns.count
            )
            // Kolon yüksekliği KESİN verilir. Eskiden yükseklik belirsizken
            // dıştaki `LazyHStack` kolonun ideal boyunu soruyor, o da içteki
            // `ScrollView`'a tüm kartları ölçtürüyordu (`ScrollViewUtilities.
            // sizeThatFits` + `LazyStack.measureEstimates`): kart sayısıyla
            // büyüyen bu ölçüm her yerleşim turunda (özellikle animasyonlu
            // kart hareketlerinde) ana iş parçacığını kilitliyordu. Kesin
            // yükseklikte iç liste yalnız görünen kartları ölçer.
            //
            // Kolon sayısı bir elin parmakları kadar; `LazyHStack` yerine
            // düz `HStack` kullanılır. Tembel yerleşimin `initialPlacement`
            // turu tamamen kalkar, kartlar yine `LazyVStack` ile tembel kalır.
            let height = max(0, proxy.size.height - TaskBoardLayout.boardPadding * 2)
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: TaskBoardLayout.columnSpacing) {
                    ForEach(presentation.columns) { section in
                        columnView(section, width: width, height: height)
                    }
                }
                .padding(TaskBoardLayout.boardPadding)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func columnView(_ section: TaskBoardColumnSection, width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(columnTint(section.kind))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(section.kind.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("\(section.cards.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 8) {
                    ForEach(section.cards) { card in
                        cardButton(card)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(width: width)
        .padding(8)
        .frame(height: height)
        .background(
            (isDark ? preset.surfaceDark : preset.surfaceLight).opacity(isDark ? 0.45 : 0.7),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    (isDark ? preset.borderSubtleDark : preset.borderSubtleLight).opacity(0.7),
                    lineWidth: 1
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(section.kind.title) kolonu, \(section.cards.count) görev")
    }

    /// Kolon başındaki durum noktası kart rozetiyle aynı dili konuşur;
    /// bilgi zaten metinle taşındığı için nokta yalnızca görsel destektir.
    private func columnTint(_ kind: TaskBoardColumnKind) -> Color {
        switch kind {
        case .backlog: .secondary
        case .ready: .blue
        case .running: preset.accentGradient.first ?? .accentColor
        case .review: .purple
        case .done: .green
        }
    }

    private var blockedLane: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 8) {
                Text(presentation.blockedFilter.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                ForEach(presentation.blockedCards) { card in
                    cardButton(card)
                }
            }
            .frame(maxWidth: 336, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.blockedFilter.label)
    }

    private var cancelledHistory: some View {
        DisclosureGroup(isExpanded: $showsCancelledHistory) {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 8) {
                    ForEach(presentation.cancelledCards) { card in
                        cardButton(card)
                    }
                }
                .padding(.top, 8)
            }
            // Sınırsız büyümesin: açık tarihçe kolonları ezmesin, kendi içinde kaysın.
            .frame(maxHeight: 260)
        } label: {
            Text(presentation.cancelledHistoryLabel)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityLabel(presentation.cancelledHistoryLabel)
    }

    private func cardButton(_ card: TaskBoardCard) -> some View {
        TaskBoardCardView(
            card: card,
            isSelected: card.id == store.selectedTaskID,
            preset: preset,
            isDark: isDark,
            focusedCardID: $focusedCardID,
            onSelect: {
                Task { await store.selectTask(card.id) }
            }
        )
    }

    private func emptyState(_ message: String, callToAction: String?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            if loadState == .idle {
                Text("Başlayın: aşağıdaki satırdan projenizin Git klasörünü ekleyin")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if let callToAction {
                Button(callToAction) {
                    showsCreationSheet = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .pointingHandCursor()
                .help("Bu projeye ilk görevi ekleyin")
                .accessibilityLabel(callToAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }

    private func bannerView(_ banner: TaskBoardBanner) -> some View {
        HStack(spacing: 8) {
            Image(systemName: banner.kind == .failure ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(banner.kind == .failure ? Color.red : Color.secondary)

            Text(banner.message)
                .font(.system(size: 11.5))
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            (banner.kind == .failure ? Color.red : Color.primary).opacity(
                banner.kind == .failure ? (isDark ? 0.12 : 0.07) : 0.04
            ),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
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
    @FocusState.Binding var focusedCardID: UUID?
    let onSelect: () -> Void

    private var presentation: TaskBoardCardPresentation {
        TaskBoardPresenter.card(card, verification: .notLoaded)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                Text(presentation.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(presentation.objective)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    statusChip
                    Text(presentation.stageLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(presentation.criteriaLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                if let blockReasonText = presentation.blockReasonText {
                    Label(blockReasonText, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }

                if let dependencyLabel = presentation.dependencyLabel {
                    Label(dependencyLabel, systemImage: "link")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .background(
            (isDark ? preset.surfaceDark : preset.surfaceLight).opacity(isDark ? 0.9 : 1.0),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isSelected
                        ? (preset.accentGradient.first ?? .accentColor).opacity(0.85)
                        : (isDark ? preset.borderSubtleDark : preset.borderSubtleLight).opacity(0.9),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .shadow(color: .black.opacity(isSelected ? 0.14 : 0.07), radius: isSelected ? 10 : 6, x: 0, y: 1)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(statusTint)
                .frame(width: 3)
                .padding(.vertical, 12)
                .padding(.leading, 0.5)
                .accessibilityHidden(true)
        }
        .animation(.easeInOut(duration: 0.18), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .focused($focusedCardID, equals: card.id)
    }

    private var statusChip: some View {
        Text(presentation.statusLabel)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(statusTint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(statusTint.opacity(isDark ? 0.20 : 0.12), in: Capsule())
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

/// Oluşturma formunun görünümden bağımsız mantığı: doğrulama, öncelik
/// eşlemesi ve hazır şablonlar. Panodaki sıralama önceliği büyükten küçüğe
/// yaptığı için Yüksek her zaman Normal'in üstündedir.
enum TaskCreationForm {
    enum Priority: String, CaseIterable, Identifiable {
        case low = "Düşük"
        case normal = "Normal"
        case high = "Yüksek"

        var id: String { rawValue }
    }

    struct Template: Equatable {
        let name: String
        let title: String
        let objective: String
        let criteria: [String]
    }

    static let templates: [Template] = [
        Template(
            name: "Hata düzeltmesi",
            title: "Hata düzeltmesi: ",
            objective: "Hatayı yeniden üretin, kök nedeni düzeltin, regresyon testiyle doğrulayın.",
            criteria: ["Hata yeniden üretildi", "Kök neden düzeltildi", "Regresyon testi yeşil"]
        ),
        Template(
            name: "Küçük özellik",
            title: "Özellik: ",
            objective: "İstenen davranışı en küçük kapsamda uygulayın ve testle kanıtlayın.",
            criteria: ["Davranış çalışıyor", "Test eklendi ve yeşil", "Lint temiz"]
        ),
        Template(
            name: "Kod incelemesi",
            title: "İnceleme: ",
            objective: "Değişikliği okuyun, bulguları kaydedin, kabul kararını verin.",
            criteria: ["Değişiklik okundu", "Bulgular kaydedildi", "Kabul kararı verildi"]
        ),
    ]

    /// Pano sıralamasıyla aynı ölçek: büyük sayı üstte.
    static func priorityValue(for priority: Priority) -> Int {
        switch priority {
        case .low: 0
        case .normal: 1
        case .high: 2
        }
    }

    /// Formun eksik yanı varsa tek cümlelik Türkçe gerekçe, yoksa nil.
    static func validationError(title: String, objective: String) -> String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Başlık zorunlu — görevi tek cümleyle adlandırın"
        }
        if objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Amaç zorunlu — ajanın ne yapacağını yazın"
        }
        return nil
    }
}

/// Yeni görev formu; yalnızca store üzerinden yazar ve reddi gizlemez.
@MainActor
private struct TaskCreationSheet: View {
    let store: TaskBoardStore
    let preset: AppThemePreset
    let isDark: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var objective = ""
    @State private var priority: TaskCreationForm.Priority = .normal
    @State private var criteriaText = ""
    @State private var isSubmitting = false
    @State private var failureMessage: String?

    private var formError: String? {
        TaskCreationForm.validationError(title: title, objective: objective)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Yeni görev")
                .font(.system(size: 16, weight: .semibold))

            Text("Başlık ve amaç zorunlu; ölçütler her satırda bir tane. Öncelik pano sırasını belirler.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Menu("Şablondan doldur") {
                ForEach(TaskCreationForm.templates, id: \.name) { template in
                    Button(template.name) {
                        apply(template)
                    }
                }
            }
            .controlSize(.small)
            .help("Hazır bir şablonla formu doldurun, sonra kendinize göre düzenleyin")
            .accessibilityLabel("Şablondan doldur")

            TextField("Başlık (ör. Giriş ekranındaki çökme)", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Görev başlığı")

            TextField("Amaç (ör. Çökmenin kök nedenini bulup düzeltin)", text: $objective, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .accessibilityLabel("Görev amacı")

            Picker("Öncelik", selection: $priority) {
                ForEach(TaskCreationForm.Priority.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            .help("Yüksek öncelik panoda üstte görünür")
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
                    .disabled(isSubmitting || store.selectedProjectID == nil || formError != nil)
                    .help(formError ?? "Görevi backlog'a ekleyin")
                    .accessibilityLabel(isSubmitting ? "Görev oluşturuluyor" : "Görevi oluştur")
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(preset.background(isDark: isDark))
    }

    private func apply(_ template: TaskCreationForm.Template) {
        title = template.title
        objective = template.objective
        criteriaText = template.criteria.joined(separator: "\n")
        failureMessage = nil
    }

    private func submit() {
        guard let projectID = store.selectedProjectID else {
            failureMessage = "Proje seçilmedi"
            return
        }
        if let formError {
            failureMessage = formError
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
                priority: TaskCreationForm.priorityValue(for: priority),
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
