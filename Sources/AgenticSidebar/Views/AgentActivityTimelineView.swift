import AppKit
import SwiftUI

struct AgentActivityTimelineView: View, Equatable {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(SettingsStore.self) private var settingsStore: SettingsStore?

    let group: AgentTurnActivityGroup
    let isTurnActive: Bool
    let isSessionBusy: Bool
    let hasPendingApproval: Bool
    /// Bitmiş bir alt ajanın raporunu sağ panelde açmak için; verilmezse düğme
    /// çizilmez.
    let onOpenReport: ((AgentActivity) -> Void)?
    let onOpenReview: ((TurnFileChangesSummary, FileChangeItem?) -> Void)?
    /// Altta oturum toplu kartı dururken satır içi tur kartı gizlenir: aynı
    /// dosyalar iki ayrı kartta sayılmaz. Oturum bitince toplu kart her zaman
    /// çizildiği için (tek turlu değişim dahil) bu bayrak boşta `true` kalır.
    let suppressesInlineFileCard: Bool
    /// Grup ya da kart açılıp kapandığında üst görünüme haber verir: transkript
    /// boyu yüzlerce pt değişir, üst görünüm kaydırma konumunu sabitler.
    /// `==` dışında tutulur (`onOpenReport` ile aynı gerekçe).
    let onCollapseChange: (() -> Void)?

    nonisolated static func == (lhs: AgentActivityTimelineView, rhs: AgentActivityTimelineView) -> Bool {
        lhs.group == rhs.group && lhs.isTurnActive == rhs.isTurnActive && lhs.isSessionBusy == rhs.isSessionBusy
            && lhs.hasPendingApproval == rhs.hasPendingApproval && lhs.sessionID == rhs.sessionID
            && lhs.suppressesInlineFileCard == rhs.suppressesInlineFileCard
    }

    /// Kartların açık/kapalı durumu sohbet değişiminde yaşasın diye görünüm
    /// dışında tutulur; eskiden buradaki `@State` kümeleri alt ağaç yok
    /// olunca sıfırlanıyor ve kapatılan kartlar geri açılıyordu.
    /// Depo anahtarları oturum-ad-alanlıdır, o yüzden hangi sohbetin
    /// kartı olduğu buradan verilir.
    let sessionID: UUID
    let collapseStore: TimelineCollapseStore
    @State private var workingDotCount: Int = 1

    /// Açık grup listesinin saydam iç kaymaya geçtiği yükseklik. Arka plan
    /// eklenmez: kayan içerik altındaki görünümle birebir aynı kalır, yalnızca
    /// kaydırma göstergesi belirir.
    private static let expandedListMaxHeight: CGFloat = 320

    /// Kalabalık grubun spring ile canlandırılmadığı eşik: 30+ satırı spring
    /// ile açmak ana iş parçacığını bloklar (150 tool vakası). Üstünde kısa ve
    /// taşmasız geçiş kullanılır.
    private static let largeGroupAnimationThreshold = 30

    /// Açık grupta çizilen en fazla aktivite. Satır sayısı sınırsızken her
    /// yerleşim turu yüzlerce satırı ölçüyordu; liste artık bu pencereye
    /// sabitlenir, eskiler tek satırlık sayıyla bildirilir.
    private static let expandedListMaximumActivities = 40

    /// Araç çıktısı ve düşünme gövdesinde gösterilen satır penceresi. İç
    /// `ScrollView`'lar transkript satırının ölçümünde içeriğin tamamını
    /// ölçtürüyordu; kartlar artık kaydırmaz, son satırları gösterir.
    private static let cardMaximumLines = 20
    private static let thinkingMaximumLines = 24

    /// Satır içi diff önizlemesinde gösterilen en fazla satır. Tamamı zaten
    /// Review panelinde okunur.
    private static let diffMaximumLines = 40

    init(
        group: AgentTurnActivityGroup,
        isTurnActive: Bool,
        isSessionBusy: Bool,
        hasPendingApproval: Bool,
        sessionID: UUID,
        collapseStore: TimelineCollapseStore,
        onOpenReport: ((AgentActivity) -> Void)?,
        onOpenReview: ((TurnFileChangesSummary, FileChangeItem?) -> Void)?,
        suppressesInlineFileCard: Bool,
        onCollapseChange: (() -> Void)? = nil
    ) {
        self.group = group
        self.isTurnActive = isTurnActive
        self.isSessionBusy = isSessionBusy
        self.hasPendingApproval = hasPendingApproval
        self.sessionID = sessionID
        self.collapseStore = collapseStore
        self.onOpenReport = onOpenReport
        self.onOpenReview = onOpenReview
        self.suppressesInlineFileCard = suppressesInlineFileCard
        self.onCollapseChange = onCollapseChange
    }

    private var isTurnRunning: Bool {
        isTurnActive || group.activities.contains { $0.phase == .running }
    }

    /// Araç satırları `Working for` durum satırıyla aynı renkte ve sohbet
    /// metniyle aynı boyutta çizilir: hepsi tek renk olur, biri parlamaz.
    private var toolFontSize: CGFloat {
        settingsStore?.fontSize.pointSize ?? 14
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let nonThinkingActivities = group.activities.filter { $0.kind != .thinking }

            if nonThinkingActivities.count > 1 {
                let isExpanded = isGroupSummaryExpanded(group.id)
                // O an koşan iş varsa en sondaki koşandır (canlı satır).
                let runningActivity = nonThinkingActivities.last(where: { $0.phase == .running })

                if isExpanded {
                    // Açıkken üst satır koşan işe sabitlenir (canlı düğme) ya
                    // da özet satırına düşer; liste her iki durumda da AYNI
                    // `ScrollView`'dur. Eski sürüm koşan varken/yokken iki ayrı
                    // liste kuruyordu: tool'lar arası kısa boşlukta
                    // (`running == nil` anı) ağaç yıkılıp yeniden kuruluyor,
                    // kaydırma konumu sıfırlanıp kullanıcı en üste fırlıyordu.
                    // Burada yalnız üst satır ve liste içeriği değişir, kayan
                    // alanın kimliği değişmez; kullanıcı dipteyse dipte kalır.
                    if let running = runningActivity {
                        // Açıkken özet satırı (`Received N updates`) kalkar:
                        // yerine o an çalışan komut sabitlenir ve her adımda
                        // güncellenir. Liste yalnız bitenleri kaydırır, koşan
                        // iş ScrollView dışında durur, dibe kaybolmaz.
                        liveButton(for: running)
                    } else {
                        summaryButton(for: nonThinkingActivities, isExpanded: true)
                    }

                    // Liste artık tembel değil, pencereli: transkript satırı
                    // içinde iç içe `ScrollView` + `LazyVStack` ölçümü
                    // (`LazyStack.measureEstimates` + `ScrollViewUtilities.
                    // sizeThatFits`) ana iş parçacığını kilitliyordu. Pencere
                    // son N aktiviteyle sınırlı; eskiler sayı olarak bildirilir.
                    let displayed = Self.displayedActivities(
                        from: group.activities,
                        isLiveRunning: runningActivity != nil
                    )
                    let window = Self.expandedWindow(
                        from: displayed,
                        maximumActivities: Self.expandedListMaximumActivities
                    )
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 4) {
                            if window.omitted > 0 {
                                Text("… (\(window.omitted) earlier steps)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(window.activities) { activity in
                                timelineRow(activity, isNested: true)
                            }
                        }
                        .padding(.leading, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: Self.expandedListMaxHeight)
                    .transition(.opacity)
                } else {
                    // Kapalıyken klasik özet satırı: daraltılınca
                    // `Received N updates` geri döner.
                    summaryButton(for: nonThinkingActivities, isExpanded: false)

                    if let preview = Self.collapsedPreviewActivity(from: nonThinkingActivities) {
                        // Kapalı özetin altında o anki işin tek satırlık önizlemesi:
                        // koşan varsa en son koşan, yoksa en son aktivite.
                        activityRow(preview, isNested: true)
                            .padding(.leading, 8)
                            .transition(.opacity)
                    }
                }
            } else {
                // Düşünme parçaları çağrıldıkları yerde durur: her reasoning
                // bloğu kendi satırında (`Thought 10s`), grubun üstünde tek
                // dev blokta toplanmaz.
                ForEach(group.activities) { activity in
                    timelineRow(activity, isNested: false)
                }
            }

            // Tur sonu dosya özeti: tur bitmişse ve dosya değişmişse listenin
            // altında "N files changed" kartı çizilir (Review düğmesiyle).
            // Koşarken çizilmez: liste canlı uzar, kartın sayıları yalan olur.
            // Bitmiş turların kartı oturum meşgulken de durur: sonraki tur
            // koşarken önceki turun özeti kaybolmamalıdır.
            // Oturum bitince altta toplu kart çizilir ve burası gizlenir: aynı
            // dosyalar üstte/ortada ve altta iki kez sayılırdı.
            let fileSummary = TurnFileChangesSummary.from(group: group)
            if !isTurnRunning, !suppressesInlineFileCard, !fileSummary.isEmpty, let onOpenReview {
                FileChangesSummaryCard(
                    summary: fileSummary,
                    isExpanded: Binding(
                        get: {
                            collapseStore.isFilesExpanded(groupID: group.id, sessionID: sessionID)
                        },
                        set: { expanded in
                            collapseStore.setFilesExpanded(expanded, groupID: group.id, sessionID: sessionID)
                            onCollapseChange?()
                        }
                    ),
                    onOpenReview: onOpenReview
                )
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Kapsayıcıda spring YOK: `isTurnRunning` tur boyunca yanıp söner ve
        // spring'in taşması (overshoot) tüm bloğu yukarı-aşağı zıplatırdı.
        // Açılma/kapanma zaten satırlardaki `withAnimation` ile canlanır;
        // burada yalnızca taşmasız, kısa bir geçiş kalır.
        .animation(.easeInOut(duration: 0.22), value: isTurnRunning)
    }

    private func isGroupSummaryExpanded(_ groupID: UUID) -> Bool {
        collapseStore.isGroupExpanded(groupID: groupID, sessionID: sessionID, isTurnRunning: isTurnRunning)
    }

    private func toggleGroupSummaryExpanded(_ groupID: UUID) {
        collapseStore.toggleGroup(groupID: groupID, sessionID: sessionID, isTurnRunning: isTurnRunning)
        onCollapseChange?()
    }

    /// Kalabalık grupta spring taşması yüzlerce satırı zıplatır; üstünde
    /// taşmasız kısa geçiş kullanılır.
    private static func toggleAnimation(for activityCount: Int) -> Animation {
        activityCount > largeGroupAnimationThreshold
            ? .easeInOut(duration: 0.2)
            : .spring(response: 0.28, dampingFraction: 0.82)
    }

    /// Kapalı grup özeti altında gösterilecek tek satırlık önizleme.
    ///
    /// O anda koşan iş varsa en sondaki koşan seçilir (canlı önizleme),
    /// yoksa en son aktivite gösterilir. Görünüm dışı saf fonksiyondur,
    /// böylece seçim mantığı görünüm çalıştırmadan test edilebilir.
    nonisolated static func collapsedPreviewActivity(from activities: [AgentActivity]) -> AgentActivity? {
        guard !activities.isEmpty else {
            return nil
        }
        if let running = activities.last(where: { $0.phase == .running }) {
            return running
        }
        return activities.last
    }

    /// Canlı başlık üstte sabit dururken listede yalnız bitenler kayar:
    /// koşan iş hem üstte hem listede iki kez görünmez. Görünüm dışı saf
    /// fonksiyondur, seçim mantığı test edilebilir.
    nonisolated static func finishedActivities(from activities: [AgentActivity]) -> [AgentActivity] {
        activities.filter { $0.phase != .running }
    }

    /// Genişletilmiş listenin içeriği: koşan iş üstte sabitlenmişken liste
    /// yalnız bitenleri kaydırır, tur boşluğundaysa tamamını gösterir.
    /// `ScrollView` kimliği daldan bağımsız tek kaldığı için kaydırma konumu
    /// koşu geçişlerinde korunur. Görünüm dışı saf fonksiyondur.
    nonisolated static func displayedActivities(
        from activities: [AgentActivity],
        isLiveRunning: Bool
    ) -> [AgentActivity] {
        isLiveRunning ? finishedActivities(from: activities) : activities
    }

    /// Genişletilmiş listenin çizilen penceresi: son `maximumActivities`
    /// aktivite tutulur, düşenlerin sayısı döndürülür. Ölçüm maliyeti satır
    /// sayısıyla büyüdüğü için pencere zorunludur.
    nonisolated static func expandedWindow(
        from activities: [AgentActivity],
        maximumActivities: Int
    ) -> (activities: [AgentActivity], omitted: Int) {
        guard activities.count > maximumActivities else {
            return (activities, 0)
        }
        let kept = Array(activities.suffix(maximumActivities))
        return (kept, activities.count - kept.count)
    }

    /// Uzun bir metni son `maximumLines` satıra indirger; düşen satır sayısını
    /// döndürür. Kartlar iç `ScrollView` taşımaz: transkript satırı ölçülürken
    /// kaydırma kabı içeriğin tamamını ölçtürüyordu.
    nonisolated static func boundedLineWindow(
        _ text: String,
        maximumLines: Int
    ) -> (text: String, omitted: Int) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maximumLines else {
            return (text, 0)
        }
        let kept = lines.suffix(maximumLines)
        return (kept.joined(separator: "\n"), lines.count - kept.count)
    }

    private func summaryTitle(for activities: [AgentActivity]) -> String {
        // Düşünme parçaları kendi satırlarında durur, sayıya katılmaz:
        // yoksa 5 komut + 3 düşünme "Received 8 updates" olurdu.
        let countable = activities.filter { $0.kind != .thinking }
        guard !countable.isEmpty else {
            return activities.count == 1 ? "Thought once" : "Thought \(activities.count) times"
        }
        let commands = countable.filter { $0.kind == .command }.count
        let computers = countable.filter { $0.kind == .computer }.count
        let otherUpdates = countable.filter { $0.kind != .command && $0.kind != .computer }.count

        // Salt computer turu kendi adıyla anılır, genel "updates"e gömülmez.
        if commands == 0 && otherUpdates == 0 && computers > 0 {
            return computers == 1 ? "Ran 1 computer action" : "Ran \(computers) computer actions"
        }

        // Karışık grupta computer adımları sayıya dahildir, kaybolmaz.
        let updates = otherUpdates + computers

        if commands > 0 && updates > 0 {
            let cmdWord = commands == 1 ? "command" : "commands"
            let updWord = updates == 1 ? "update" : "updates"
            if commands >= updates {
                return "Ran \(commands) \(cmdWord) and received \(updates) \(updWord)"
            } else {
                return "Received \(updates) \(updWord) and ran \(commands) \(cmdWord)"
            }
        } else if commands > 1 {
            return "Ran \(commands) commands"
        } else if commands == 1 {
            return "Ran 1 command"
        } else if updates > 1 {
            return "Received \(updates) updates"
        } else if updates == 1 {
            return "Received 1 update"
        } else {
            return "Ran \(countable.count) actions"
        }
    }

    @ViewBuilder
    private func summaryIcon(for activities: [AgentActivity]) -> some View {
        let commands = activities.filter { $0.kind == .command }.count
        let updates = activities.filter { $0.kind != .command }.count

        if commands > 0 && updates == 0 {
            terminalPromptIcon
        } else {
            Image(systemName: "hammer")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        }
    }

    private var terminalPromptIcon: some View {
        HStack(spacing: 0.5) {
            Text(">")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            Text("_")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(.secondary)
        .frame(width: 16, alignment: .leading)
    }

    @ViewBuilder
    private func summaryButton(for activities: [AgentActivity], isExpanded: Bool) -> some View {
        let isRunning = activities.contains { $0.phase == .running }

        Button {
            withAnimation(Self.toggleAnimation(for: activities.count)) {
                toggleGroupSummaryExpanded(group.id)
            }
        } label: {
            HStack(spacing: 8) {
                summaryIcon(for: activities)

                Text(summaryTitle(for: activities))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .sunshineShimmer(isActive: isRunning)

                Spacer(minLength: 8)

                // Sabit yuva: koşu sırasında `isRunning` yanıp söndükçe
                // gösterge takılıp çıkarılmıyor, yalnızca saydamlığı
                // değişiyor. Tak-çıkar hem satırı yeniden kuruyor (zıplama)
                // hem de sondaki oku yatayda gezdiriyordu.
                Group {
                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 12, height: 12)
                .opacity(isRunning ? 1 : 0)

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.8))
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .interactiveHoverPill(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse this turn's steps" : "Expand this turn's steps")
    }

    /// Açık grubun üstünde sabit duran canlı satır: o an koşan komut.
    ///
    /// Özet düğmesiyle aynı kromu taşır (tıklayınca grup kapanır, ok hep
    /// aşağı bakar), ama metni sayı değil koşan işin başlığıdır ve her
    /// adımda güncellenir. `rowLabel` yeniden kullanılır: başlık evrimi
    /// ("Running" → "Running ls") zıplamasız akar, shimmer koşarken sürer.
    @ViewBuilder
    private func liveButton(for activity: AgentActivity) -> some View {
        Button {
            withAnimation(Self.toggleAnimation(for: group.activities.count)) {
                toggleGroupSummaryExpanded(group.id)
            }
        } label: {
            HStack(spacing: 8) {
                activityIcon(for: activity)

                rowLabel(for: activity)

                Spacer(minLength: 8)

                // Sabit yuva: gösterge tak-çıkar yerine hep durur, sondaki
                // ok kımıldamaz.
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.8))
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .interactiveHoverPill(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .help("Collapse this turn's steps")
    }

    private func isActivityExpanded(_ activity: AgentActivity) -> Bool {
        collapseStore.isActivityExpanded(activity, groupID: group.id, sessionID: sessionID, isTurnRunning: isTurnRunning)
    }

    private func toggleActivityExpanded(_ activity: AgentActivity) {
        collapseStore.toggleActivity(activity, groupID: group.id, sessionID: sessionID, isTurnRunning: isTurnRunning)
        onCollapseChange?()
    }

    private var workingText: String {
        "Working" + String(repeating: ".", count: workingDotCount)
    }

    @ViewBuilder
    private func timelineRow(_ activity: AgentActivity, isNested: Bool) -> some View {
        if activity.kind == .thinking {
            thinkingRow(activity)
        } else {
            activityRow(activity, isNested: isNested)
        }
    }

    @ViewBuilder
    private func activityRow(_ activity: AgentActivity, isNested: Bool) -> some View {
        let isExpanded = isActivityExpanded(activity)
        let isRunning = activity.phase == .running

        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    toggleActivityExpanded(activity)
                }
            } label: {
                HStack(spacing: 8) {
                    // Action Icon
                    activityIcon(for: activity)

                    // Title & Description
                    rowLabel(for: activity)

                    Spacer(minLength: 8)

                    // Sabit yuva (özet satırdakiyle aynı gerekçe): gösterge
                    // tak-çıkar yerine saydamlıkla değişir, sondaki ok
                    // kımıldamaz, satır yeniden kurulmaz.
                    Group {
                        if isRunning {
                            ProgressView()
                                .controlSize(.mini)
                        } else if activity.phase == .failed {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 12, height: 12)
                    .opacity(isRunning || activity.phase == .failed ? 1 : 0)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .interactiveHoverPill(cornerRadius: 6)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse step details" : "Expand step details")

            // Inline Expanded Content (Terminal Box or File Detail)
            if isExpanded {
                expandedContent(for: activity)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func activityIcon(for activity: AgentActivity) -> some View {
        switch activity.kind {
        case .command:
            terminalPromptIcon
        case .read:
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        case .edit, .update:
            Image(systemName: "pencil")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        case .delete:
            Image(systemName: "trash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        case .webSearch:
            Image(systemName: "globe")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        case .todo:
            Image(systemName: "checklist")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        case .subagent:
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        case .mcp:
            Image(systemName: "server.rack")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        case .computer:
            Image(systemName: "computermouse")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        case .thinking:
            Image(systemName: "brain")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        case .tool:
            Image(systemName: "hammer")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        case .question:
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        }
    }

    @ViewBuilder
    private func rowLabel(for activity: AgentActivity) -> some View {
        if activity.kind == .command {
            let cmd = activity.detail ?? activity.title ?? "command"
            Text(cmd)
                .font(.system(size: toolFontSize, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .sunshineShimmer(isActive: activity.phase == .running)
        } else if activity.kind == .thinking {
            thinkingCompactLabel(thinking: activity)
        } else if let title = activity.title, !title.isEmpty {
            parseTitleText(title)
                .sunshineShimmer(isActive: activity.phase == .running)
        } else {
            let presentation = AgentActivityPresentation(kind: activity.kind)
            let fallbackTitle = activity.phase == .running ? presentation.runningStatusName : presentation.title
            HStack(spacing: 5) {
                Text(fallbackTitle)
                    .font(.system(size: toolFontSize, weight: .regular))
                    .foregroundStyle(.secondary)

                if let detail = activity.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: toolFontSize, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .sunshineShimmer(isActive: activity.phase == .running)
        }
    }

    /// Düşünme satırı ne zaman çizilir: içeriği varsa her zaman; boşsa
    /// yalnız tur koşarken ve aktivite koşuyorsa (canlı "düşünüyor" geri
    /// bildirimi). Bitmiş boş düşünme hiç çizilmez — süre rozeti de dahil.
    private func shouldShowThinking(_ thinking: AgentActivity) -> Bool {
        if ThinkingDurationPresentation.hasVisibleContent(output: thinking.output) {
            return true
        }
        return isTurnRunning && thinking.phase == .running
    }

    /// Her düşünme bloğu kendi satırında açılır-kapanır durur: bitince
    /// `Thought 10s` rozeti kalır, gövde varsayılan kapalıdır. Koşarken de
    /// varsayılan kapalıdır, süre satırda canlı akar; gövde yalnız kullanıcı
    /// açarsa görünür.
    @ViewBuilder
    private func thinkingRow(_ thinking: AgentActivity) -> some View {
        // Boş düşünme satırı çizilmez: reasoning paylaşmayan modellerde
        // `output` hiç dolmaz ve süre satırı tek başına anlamsız bir
        // rozete dönüşürdü.
        if shouldShowThinking(thinking) {
            let isExpanded = isActivityExpanded(thinking)

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        toggleActivityExpanded(thinking)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "brain")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

                        thinkingCompactLabel(thinking: thinking)

                        Spacer(minLength: 8)

                        // Sabit yuva düzeni burada yok: koşan düşünme zaten
                        // canlı süreyle belli olur, bitende rozet yeter.
                        if thinking.phase == .running {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(width: 12, height: 12)
                        }

                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary.opacity(0.8))
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                    .interactiveHoverPill(cornerRadius: 6)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse thought" : "Expand thought")

                if isExpanded,
                    ThinkingDurationPresentation.hasVisibleContent(output: thinking.output)
                {
                    thinkingBody(output: thinking.output ?? "")
                        .transition(.opacity)
                }
            }
        }
    }

    @ViewBuilder
    private func thinkingCompactLabel(thinking: AgentActivity) -> some View {
        let turnEndedAt = group.activities.compactMap(\.completedAt).max()

        // Bitmiş düşünme statiktir: saniye saati ve sunshine yalnız koşarken
        // yaşar. Eski sürüm turdaki araçlar koşarken bitmiş düşünmeyi de
        // `SecondTick` ile her saniye yeniden kuruyordu; süre zaten
        // `completedAt` ile donmuşken zamanlayıcı ve parlama katmanı boşuna
        // dönüyordu (`Thought` sonrası sunshine olmaz).
        if thinking.phase == .running {
            // Satır başına `TimelineView` yerine paylaşılan saniye saati:
            // N düşünen satır tek zamanlayıcıyı dinler.
            SecondTick { date in
                Text(
                    ThinkingDurationPresentation.compactText(
                        startedAt: thinking.startedAt,
                        completedAt: thinking.completedAt,
                        turnEndedAt: turnEndedAt,
                        isRunning: true,
                        hasRunningChildren: false,
                        now: date
                    )
                )
                .font(.system(size: toolFontSize, weight: .regular))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .sunshineShimmer(isActive: true)
            }
        } else {
            Text(
                ThinkingDurationPresentation.compactText(
                    startedAt: thinking.startedAt,
                    completedAt: thinking.completedAt,
                    turnEndedAt: turnEndedAt,
                    isRunning: false,
                    hasRunningChildren: false,
                    now: Date()
                )
            )
            .font(.system(size: toolFontSize, weight: .regular))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    @ViewBuilder
    private func parseTitleText(_ title: String) -> some View {
        // Yapısal kararlılık: başlık tur ortasında "Running" → "Running ls"
        // gibi tek parçadan iki parçaya evrilir. Eski `if/else` o anda
        // `Text` ile `HStack` arasında dal değiştirip satırı yıkıp yeniden
        // kuruyordu (zıplama). Her zaman aynı `HStack` kurulur, yalnızca
        // içeriği ve aralığı değişir; aralık yerleşim parametresidir,
        // görünüm kimliğini değiştirmez.
        let parts = title.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts.first ?? ""
        let target = parts.count == 2 ? parts[1] : ""

        HStack(spacing: parts.count == 2 ? 5 : 0) {
            Text(verb)
                .font(.system(size: toolFontSize, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(target)
                .font(.system(size: toolFontSize, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func expandedContent(for activity: AgentActivity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // A file change reads as a diff first: the `+`/`-` lines are the
            // point of the activity, and the tool's raw result adds little.
            if let diff = activity.diff, !diff.isEmpty {
                diffCard(diff: diff, path: activity.detail)
            }

            if activity.kind == .command {
                resultCard(
                    activity: activity,
                    header: activity.detail,
                    headerSymbol: "terminal",
                    body: activity.output
                )
            } else if activity.kind == .thinking {
                // Düşünme içeriği: modelin ara adımları. `output`'ta birikir
                // (arşiv sınırı orayı kırpar), kart kapalıyken yalnız süre
                // görünür; gövde varsayılan kapalıdır.
                // Zeminsiz düz metin: dış satır ("Thought Ns") zaten
                // başlığı söyler, iç kartın zemini ve ikinci "Thought"
                // başlığı çiftlik etkisi yapıyordu.
                if ThinkingDurationPresentation.hasVisibleContent(output: activity.output) {
                    thinkingBody(output: activity.output ?? "")
                }
            } else if activity.kind == .subagent {
                subagentExecutionCard(activity: activity)
            } else if activity.kind == .mcp {
                resultCard(
                    activity: activity,
                    header: activity.detail ?? activity.title ?? "MCP Tool Call",
                    headerSymbol: "server.rack",
                    body: activity.output ?? (activity.phase == .running ? "Executing MCP tool..." : nil)
                )
            } else if activity.kind == .computer {
                computerCard(activity: activity)
            } else if let output = activity.output, !output.isEmpty {
                // For reads and writes the tool's result *is* the file content,
                // so the card is labelled with the path it came from.
                resultCard(
                    activity: activity,
                    header: activity.detail,
                    headerSymbol: "doc.text",
                    body: output
                )
            } else if activity.diff == nil, let detail = activity.detail, !detail.isEmpty {
                HStack(spacing: 6) {
                    Text(detail)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 24)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Düşünme gövdesi: kart kromu yok, başlık yok — yalnız metin.
    ///
    /// İç `ScrollView` bilinçli olarak yok: transkript satırının ölçümü
    /// kaydırma kabının içeriğini de ölçtürüyor, uzun gövde her yerleşim
    /// turunu ağırlaştırıyordu. Gövde son `thinkingMaximumLines` satıra
    /// indirgenir.
    @ViewBuilder
    private func thinkingBody(output: String) -> some View {
        let window = Self.boundedLineWindow(
            output,
            maximumLines: Self.thinkingMaximumLines
        )

        VStack(alignment: .leading, spacing: 4) {
            Text(window.text)
                .font(.system(size: toolFontSize))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if window.omitted > 0 {
                Text("… (\(window.omitted) earlier lines)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 8)
    }

    /// Computer adımı: ekran görüntüsü varsa önizleme, metin çıktısı varsa
    /// kart. İkisi de varsa ikisi de çizilir (görsel üstte); hiçbiri yoksa
    /// boş kart değil, yalnız ayrıntı satırı düşer.
    @ViewBuilder
    private func computerCard(activity: AgentActivity) -> some View {
        let imageURL = Self.computerImageURL(for: activity)
        let textOutput = Self.computerTextOutput(for: activity, imageURL: imageURL)

        VStack(alignment: .leading, spacing: 6) {
            if let imageURL {
                computerImagePreview(url: imageURL)
            }
            if let textOutput, !textOutput.isEmpty {
                resultCard(
                    activity: activity,
                    header: activity.title ?? activity.detail ?? "Computer action",
                    headerSymbol: "computermouse",
                    body: textOutput
                )
            } else if imageURL == nil, activity.diff == nil,
                let detail = activity.detail, !detail.isEmpty
            {
                HStack(spacing: 6) {
                    Text(detail)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 24)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Computer çıktısındaki görsel dosya başvurusu: `output` satırları ve
    /// `detail` taranır, var olan ilk görsel dosya alınır. Görünüm dışı saf
    /// mantık ayrı test edilir; dosya varlığı burada denetlenir, gövdede
    /// disk okunmaz.
    nonisolated static func computerImageURL(for activity: AgentActivity) -> URL? {
        let lines =
            ((activity.output ?? "") + "\n" + (activity.detail ?? ""))
            .components(separatedBy: .newlines)
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            // "Screenshot saved: /tmp/x.png" biçimi: satırdaki ilk mutlak yol.
            let candidates: [String]
            if trimmed.hasPrefix("/") || trimmed.hasPrefix("file://") {
                candidates = [trimmed]
            } else if let slash = trimmed.firstIndex(of: "/") {
                candidates = [String(trimmed[slash...])]
            } else {
                candidates = []
            }
            for candidate in candidates {
                let path =
                    candidate.hasPrefix("file://")
                    ? String(candidate.dropFirst("file://".count))
                    : candidate
                let url = URL(fileURLWithPath: path)
                guard Self.isImageExtension(url.pathExtension),
                    FileManager.default.fileExists(atPath: url.path)
                else {
                    continue
                }
                return url
            }
        }
        return nil
    }

    /// Metin kartına gidecek çıktı: görsel yolu satırları çıkarılır, geriye
    /// metin kalmazsa `nil` (boş kart çizilmez).
    nonisolated static func computerTextOutput(for activity: AgentActivity, imageURL: URL?) -> String? {
        guard let output = activity.output, !output.isEmpty else {
            return nil
        }
        guard let imageURL else {
            return output
        }
        let rest =
            output
            .components(separatedBy: .newlines)
            .filter { !$0.contains(imageURL.path) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    nonisolated static func isImageExtension(_ ext: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "tiff", "tif", "heic", "bmp"].contains(ext.lowercased())
    }

    /// Ekran görüntüsü önizlemesi: küçük resim önbelleğinden kırpılmış kare
    /// değil, geniş önizleme; tıklayınca dosya varsayılan uygulamada açılır.
    @ViewBuilder
    private func computerImagePreview(url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            if let image = AttachmentPreviewCache.shared.imageThumbnail(for: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 280, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(url.lastPathComponent)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Open \(url.lastPathComponent)")
        .padding(.leading, 24)
        .padding(.trailing, 8)
    }

    /// The console-style surface shared by command output and file results.
    ///
    /// Kart kaydırmaz: son `cardMaximumLines` satır gösterilir, düşen satırlar
    /// sayıyla bildirilir ve tamamı sağ panelde açılabilir. İç `ScrollView`
    /// transkript satırı ölçülürken içeriğin tamamını ölçtürüp ana iş
    /// parçacığını kilitliyordu (CPU diag: `ScrollViewUtilities.sizeThatFits`).
    @ViewBuilder
    private func resultCard(
        activity: AgentActivity,
        header: String?,
        headerSymbol: String,
        body: String?
    ) -> some View {
        let isDark = colorScheme == .dark
        let text = body ?? ""
        let window = Self.boundedLineWindow(text, maximumLines: Self.cardMaximumLines)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: headerSymbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(isDark ? Color(white: 0.55) : Color(white: 0.45))

                Text(header ?? "command")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(.bottom, window.text.isEmpty ? 0 : 2)

            if !window.text.isEmpty {
                Text(window.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if window.omitted > 0 {
                HStack(spacing: 8) {
                    Text("… (\(window.omitted) earlier lines)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 4)

                    if let onOpenReport {
                        Button {
                            onOpenReport(activity)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .font(.system(size: 10, weight: .semibold))

                                Text("Full output")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.blue.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .help("Open the full output in the side panel")
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isDark
                ? Color.black.opacity(0.55)
                : Color.black.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isDark
                        ? Color.white.opacity(0.12)
                        : Color.black.opacity(0.10),
                    lineWidth: 1
                )
        )
        .padding(.leading, 24)
        .padding(.trailing, 8)
    }

    /// Real-time rich execution card for subagents, showing live inner tool steps and statuses.
    @ViewBuilder
    private func subagentExecutionCard(activity: AgentActivity) -> some View {
        let isDark = colorScheme == .dark

        VStack(alignment: .leading, spacing: 8) {
            // Header bar
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(activity.title ?? activity.detail ?? "Subagent Execution")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if activity.phase == .running {
                    if hasPendingApproval {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.shield")
                                .font(.system(size: 9, weight: .bold))
                            Text("Awaiting approval")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.orange.opacity(0.15))
                        )
                    } else {
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(minWidth: 10, minHeight: 10)
                            Text("Live")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.blue)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.blue.opacity(0.12))
                        )
                    }
                } else if activity.phase == .completed {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                        Text(Self.completionLabel(for: activity))
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.green.opacity(0.12))
                    )
                } else if activity.phase == .failed {
                    Text("Failed")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.red.opacity(0.12))
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            Divider()
                .opacity(0.3)

            // Body content
            subagentCardBody(activity: activity, isDark: isDark)
        }
        .background(
            isDark ? Color.black.opacity(0.55) : Color.black.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.10), lineWidth: 1)
        )
        .padding(.leading, 24)
        .padding(.trailing, 8)
    }

    /// Gövde: koşarken canlı araç satırları; bitince özet ve "Read report".
    ///
    /// Bitmiş bir alt ajanın `output`'u nihai rapordur ve kart onu gömmez — sağ
    /// panelde okunur. Kart yalnız araç kullanımını gösterir.
    @ViewBuilder
    private func subagentCardBody(activity: AgentActivity, isDark: Bool) -> some View {
        if activity.phase == .running || activity.phase == .cancelled {
            if let output = activity.output, !output.isEmpty {
                stepLines(output: output, isDark: isDark)
            } else {
                activityPlaceholder(activity: activity)
            }
        } else if activity.output?.isEmpty == false {
            HStack(spacing: 8) {
                Text(activity.detail ?? "Finished")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                reportButton(activity: activity)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        } else {
            activityPlaceholder(activity: activity)
        }
    }

    /// Raporu sağ panelde açar; eylem yoksa düğme çizilmez.
    @ViewBuilder
    private func reportButton(activity: AgentActivity) -> some View {
        if let onOpenReport {
            Button {
                onOpenReport(activity)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                    Text(activity.phase == .completed ? "Read report" : "Read output")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.blue.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Open in the side panel")
        }
    }

    private func stepLines(output: String, isDark: Bool) -> some View {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let displayLines = lines.count > 20 ? Array(lines.suffix(20)) : lines
        let omittedCount = lines.count - displayLines.count
        // Kimlik küresel satır indisidir: sonek içi `offset` her uzamada aynı
        // satıra başka kimlik verip listeyi yeniden kuruyor, kart en üste
        // sıçrıyordu. Küresel indis append-only'dir: eski satırlar kimliğini
        // korur, yeni satır eklenir, kayan pencere dışına düşen sessizce gider.
        let startIndex = lines.count - displayLines.count

        return VStack(alignment: .leading, spacing: 4) {
            if omittedCount > 0 {
                Text("… (\(omittedCount) earlier steps)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
            }
            ForEach(startIndex..<lines.count, id: \.self) { index in
                subagentStepLineView(line: displayLines[index - startIndex], isDark: isDark)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func activityPlaceholder(activity: AgentActivity) -> some View {
        HStack(spacing: 6) {
            if activity.phase == .running {
                ProgressView()
                    .controlSize(.mini)
                    .frame(minWidth: 12, minHeight: 12)
                Text("Subagent initializing and preparing tools…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("No output logged by subagent.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// "Completed · 3m 12s": bitiş rozeti geçen süreyi de söyler.
    private static func completionLabel(for activity: AgentActivity) -> String {
        guard let completedAt = activity.completedAt else {
            return "Completed"
        }

        let seconds = max(0, Int(completedAt.timeIntervalSince(activity.startedAt).rounded()))
        guard seconds >= 60 else {
            return "Completed · \(seconds)s"
        }

        return "Completed · \(seconds / 60)m \(seconds % 60)s"
    }

    @ViewBuilder
    private func subagentStepLineView(line: String, isDark: Bool) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("✓") {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.green)
                    .padding(.top, 2)
                Text(String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isDark ? Color(white: 0.88) : Color(white: 0.18))
            }
        } else if trimmed.hasPrefix("✗") {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.red)
                    .padding(.top, 2)
                Text(String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
            }
        } else if trimmed.hasPrefix("…") {
            HStack(alignment: .top, spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                    .frame(minWidth: 10, minHeight: 10)
                    .padding(.top, 2)
                Text(String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.blue)
            }
        } else if trimmed.hasPrefix("Subagent") {
            Text(trimmed)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
        } else {
            Text(trimmed)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isDark ? Color(white: 0.68) : Color(white: 0.38))
        }
    }

    /// The `+`/`-` preview of a file change, line by line, the way a diff is read
    /// everywhere else.
    @ViewBuilder
    private func diffCard(diff: String, path: String?) -> some View {
        let isDark = colorScheme == .dark
        let allLines = diff.components(separatedBy: "\n")
        // Satır içi önizleme kısa tutulur: iç `ScrollView` + `LazyVStack`
        // transkript ölçümünde içeriğin tamamını ölçtürüyordu. Tamamı zaten
        // Review panelinde okunur.
        let lines = Array(allLines.prefix(Self.diffMaximumLines))
        let omittedCount = max(0, allLines.count - lines.count)
        // Tek geçiş: her body çalışında satırlar zaten dilimleniyor,
        // iki ayrı `filter` turuna gerek yok.
        let (addedCount, removedCount) = lines.reduce(into: (added: 0, removed: 0)) { counts, line in
            if line.hasPrefix("+ ") {
                counts.added += 1
            } else if line.hasPrefix("- ") {
                counts.removed += 1
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "plusminus")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(isDark ? Color(white: 0.55) : Color(white: 0.45))

                if let path, !path.isEmpty {
                    Text(path)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(isDark ? Color(white: 0.82) : Color(white: 0.22))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 6)

                Text("+\(addedCount)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.green)

                Text("−\(removedCount)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(diffLineForeground(line, isDark: isDark))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 0.5)
                        .background(diffLineBackground(line, isDark: isDark))
                        .textSelection(.enabled)
                }
                if omittedCount > 0 {
                    Text("… \(omittedCount) satır gizlendi")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isDark
                ? Color.black.opacity(0.55)
                : Color.black.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isDark
                        ? Color.white.opacity(0.12)
                        : Color.black.opacity(0.10),
                    lineWidth: 1
                )
        )
        .padding(.leading, 24)
        .padding(.trailing, 8)
    }

    private func diffLineForeground(_ line: String, isDark: Bool) -> Color {
        if line.hasPrefix("+ ") {
            return isDark ? Color(red: 0.48, green: 0.88, blue: 0.55) : Color(red: 0.05, green: 0.42, blue: 0.14)
        }
        if line.hasPrefix("- ") {
            return isDark ? Color(red: 0.98, green: 0.55, blue: 0.55) : Color(red: 0.60, green: 0.08, blue: 0.10)
        }
        if line.hasPrefix("…") {
            return .secondary
        }

        return isDark ? Color(white: 0.62) : Color(white: 0.40)
    }

    private func diffLineBackground(_ line: String, isDark: Bool) -> Color {
        if line.hasPrefix("+ ") {
            return Color.green.opacity(isDark ? 0.14 : 0.12)
        }
        if line.hasPrefix("- ") {
            return Color.red.opacity(isDark ? 0.14 : 0.10)
        }

        return .clear
    }
}

/// Soldan sağa kayan sunshine parlaması.
///
/// Üç kuralı vardır:
/// 1. Yapısal kararlılık: `isActive` değişimi `if/else` dalı değiştirmez.
///    Eski sürüm aktif/pasif için iki ayrı ağaç kuruyordu; tur sırasında
///    bayrak yanıp söndükçe metin yıkılıp yeniden kuruluyor, satır ve
///    çevresi zıplıyordu. Burada ağaç hep aynıdır, yalnızca parlamanın
///    saydamlığı değişir.
/// 2. Görünmez iş yok: döngü yalnız satır koşarken döner. Durunca
///    `repeatForever` iptal edilip bant başa alınır; bitmiş satırlar render
///    döngüsünü beslemez.
/// 3. Harf-içi parlama: maske kayan bandın değil, overlay'in tamamınadır.
///    Maske bandın %55'lik çerçevesinde kalsaydı metin o dar şeride sıkışır,
///    parlama harflerden geçmek yerine düz çizgi gibi görünürdü. Burada
///    maske alttaki metinle aynı boyda kurulur, bant altında kayar ve ışık
///    yalnız harf formlarından görünür.
private struct SunshineShimmerModifier: ViewModifier {
    let isActive: Bool
    @State private var sweep: CGFloat = 0

    /// Tek geçiş süresi: hafif hızda, soldan sağa akan his için.
    private static let sweepDuration: TimeInterval = 2.6

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geometry in
                    let width = max(geometry.size.width, 1)
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: Self.sheenColor.opacity(0.0), location: 0.32),
                            .init(color: Self.sheenColor.opacity(0.85), location: 0.5),
                            .init(color: Self.sheenColor.opacity(0.0), location: 0.68),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: width * 0.55)
                    .offset(x: -width * 0.6 + sweep * width * 1.7)
                }
                // Maske overlay boyundadır: metin alttakiyle birebir aynı
                // yerleşir, bant altında kayar.
                .mask { content }
                .opacity(isActive ? 1 : 0)
                .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.35), value: isActive)
            .onAppear {
                if isActive {
                    startSweep()
                }
            }
            .onChange(of: isActive) { _, active in
                if active {
                    startSweep()
                } else {
                    stopSweep()
                }
            }
    }

    /// Ilık güneş tonu: açık ve koyu zeminde de okunur parlar.
    private static var sheenColor: Color {
        Color(red: 1.0, green: 0.96, blue: 0.86)
    }

    private func startSweep() {
        sweep = 0
        withAnimation(
            .linear(duration: Self.sweepDuration).repeatForever(autoreverses: false)
        ) {
            sweep = 1
        }
    }

    private func stopSweep() {
        // Yeni animasyon sürmekte olan `repeatForever` döngüsünü iptal
        // eder; bant başa döner ve saydamlıkla birlikte söner.
        withAnimation(.easeOut(duration: 0.25)) {
            sweep = 0
        }
    }
}

extension View {
    fileprivate func sunshineShimmer(isActive: Bool) -> some View {
        modifier(SunshineShimmerModifier(isActive: isActive))
    }
}
