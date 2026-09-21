import SwiftUI

// MARK: - Sunum katmanı

/// Kabul ölçütü satırı; kanıt kimliği yokluğu gizlenmez.
struct TaskBoardCriterionPresentation: Identifiable, Equatable {
    let id: UUID
    let text: String
    let isCompleted: Bool
    let evidenceLabel: String
    let accessibilityLabel: String
}

enum TaskBoardDependencyDirection: Equatable {
    case prerequisite
    case dependent
}

/// Bağımlılık satırı; önkoşulun tatmin durumu yalnızca pano kartlarından okunur.
struct TaskBoardDependencyPresentation: Identifiable, Equatable {
    let id: String
    let direction: TaskBoardDependencyDirection
    let taskID: UUID
    let title: String?
    let isSatisfied: Bool?
    let accessibilityLabel: String
}

/// Doğrulama kanıtı satırı; eski parmak izi stale olarak işaretlenir, tonu başarıyı yalanlamaz.
struct TaskBoardEvidenceRow: Identifiable, Equatable {
    let id: UUID
    let stepLabel: String
    let statusLabel: String
    let fingerprintLabel: String?
    let isStale: Bool
    let tone: TaskBoardBadgeTone
    let blockedBy: String?
    let accessibilityLabel: String
}

/// Denetçinin kanıt/çalışma alanı/diff özeti.
struct TaskBoardEvidenceSummary: Equatable {
    let isWired: Bool
    let badge: TaskBoardVerificationBadge
    let rows: [TaskBoardEvidenceRow]
    let worktreeLabel: String
    let diffNotice: String
    let accessibilityLabel: String
}

/// İnceleme bulgusu satırı; yalnızca geçerli bir insan kaydıyla kapanır.
struct TaskBoardFindingRow: Identifiable, Equatable {
    let id: UUID
    let severityLabel: String
    let statusLabel: String
    let summary: String
    let blocksAcceptance: Bool
    let accessibilityLabel: String
}

struct TaskBoardFindingsPresentation: Equatable {
    let isWired: Bool
    let rows: [TaskBoardFindingRow]
    let blockingCount: Int
    let accessibilityLabel: String
}

/// İçerik parmak izine bağlı onay kontrolünün sunumu.
struct TaskBoardApprovalPresentation: Equatable {
    let isEnabled: Bool
    let scopeDescription: String
    let actorRequirement: String
    let disabledReason: String?
    let accessibilityLabel: String
}

/// Sağlayıcı yeteneği özeti; eksik yetenek gerekçesi gizlenmez.
struct TaskBoardProviderCapabilityPresentation: Equatable {
    let providerLabel: String
    let modelLabel: String
    let notice: String?
    let accessibilityLabel: String
}

/// Denetçinin store dışından beslenen verileri; bağlanmayan kaynak açıkça söylenir.
struct TaskBoardInspectorInput: Equatable {
    let evidence: [VerificationEvidence]?
    let currentFingerprint: String?
    let findings: [ReviewFinding]?
    let workspaceID: UUID?
    let diffSummary: String?
    /// Denetçi okuma uyarısı (`nil` = kayıp yok).
    let warning: String?

    /// `warning` sonradan eklendi: `let` + varsayılan üye-init'e girmediği
    /// için açık init gerekir, yoksa eski 5-argümanlı çağrılar derlenmez.
    init(
        evidence: [VerificationEvidence]?,
        currentFingerprint: String?,
        findings: [ReviewFinding]?,
        workspaceID: UUID?,
        diffSummary: String?,
        warning: String? = nil
    ) {
        self.evidence = evidence
        self.currentFingerprint = currentFingerprint
        self.findings = findings
        self.workspaceID = workspaceID
        self.diffSummary = diffSummary
        self.warning = warning
    }

    static let unwired: TaskBoardInspectorInput = TaskBoardInspectorInput(
        evidence: nil,
        currentFingerprint: nil,
        findings: nil,
        workspaceID: nil,
        diffSummary: nil,
        warning: nil
    )
}

/// Detay bölmesinin görünümden bağımsız durumu; yutulan yükleme hatası "seçim yok" gibi görünmez.
enum TaskBoardDetailPaneState: Equatable {
    case idle
    case loading(taskID: UUID)
    case failed(taskID: UUID, message: String)
    case loaded
}

/// Detay bölmesi kimliği; görev değişince yerel form durumu sıfırlanır.
struct TaskBoardDetailPaneIdentity: Equatable, Hashable {
    let taskID: UUID
}

/// Detay denetçisinin saf sunum fonksiyonları.
enum TaskDetailPresenter {

    /// Seçim, yükleme, hata ve yüklü durumlarını ayırır; hata mesajı kaybolmaz.
    static func paneState(
        selectedTaskID: UUID?,
        detail: TaskBoardTaskDetail?,
        lastFailure: String?
    ) -> TaskBoardDetailPaneState {
        if detail != nil { return .loaded }
        guard let selectedTaskID else { return .idle }
        guard let lastFailure else { return .loading(taskID: selectedTaskID) }
        return .failed(taskID: selectedTaskID, message: lastFailure)
    }

    static func paneIdentity(for taskID: UUID) -> TaskBoardDetailPaneIdentity {
        TaskBoardDetailPaneIdentity(taskID: taskID)
    }

    static func criteria(_ detail: TaskBoardTaskDetail) -> [TaskBoardCriterionPresentation] {
        detail.criteria.map { criterion in
            let evidenceLabel: String
            if !criterion.isCompleted {
                evidenceLabel = "Bekliyor"
            } else if criterion.evidenceID != nil {
                evidenceLabel = "Kanıt kayıtlı"
            } else {
                evidenceLabel = "Kanıt kimliği yok"
            }
            let stateLabel = criterion.isCompleted ? "Tamamlandı" : "Bekliyor"
            return TaskBoardCriterionPresentation(
                id: criterion.id,
                text: criterion.description,
                isCompleted: criterion.isCompleted,
                evidenceLabel: evidenceLabel,
                accessibilityLabel: "\(criterion.description). \(stateLabel). \(evidenceLabel)"
            )
        }
    }

    static func dependencies(
        _ detail: TaskBoardTaskDetail,
        cards: [TaskBoardCard]
    ) -> [TaskBoardDependencyPresentation] {
        detail.dependencies.map { dependency in
            let isPrerequisite = dependency.dependentTaskID == detail.card.id
            let otherTaskID = isPrerequisite ? dependency.prerequisiteTaskID : dependency.dependentTaskID
            let otherCard = cards.first { $0.id == otherTaskID }
            let satisfied: Bool? = isPrerequisite ? otherCard.map { $0.status == .done } : nil

            var label = isPrerequisite ? "Önkoşul: " : "Bağımlı: "
            label += otherCard?.title ?? otherTaskID.uuidString
            if let satisfied {
                label += satisfied ? ". Tamamlandı" : ". Tamamlanmadı"
            }

            return TaskBoardDependencyPresentation(
                id: dependency.id,
                direction: isPrerequisite ? .prerequisite : .dependent,
                taskID: otherTaskID,
                title: otherCard?.title,
                isSatisfied: satisfied,
                accessibilityLabel: label
            )
        }
        .sorted { $0.id < $1.id }
    }

    static func evidenceSummary(
        card: TaskBoardCard,
        evidence: [VerificationEvidence]?,
        currentFingerprint: String?,
        workspaceID: UUID?,
        diffSummary: String?
    ) -> TaskBoardEvidenceSummary {
        let badge = TaskBoardPresenter.verificationBadge(
            card: card,
            evidence: evidence,
            currentFingerprint: currentFingerprint
        )
        let rows = (evidence ?? []).map { entry in
            evidenceRow(entry, currentFingerprint: currentFingerprint)
        }
        let worktreeLabel: String
        if let workspaceID {
            worktreeLabel = "Çalışma alanı: \(workspaceID.uuidString.prefix(8))"
        } else {
            worktreeLabel = "Çalışma alanı kaydı yok"
        }
        let diffNotice = diffSummary ?? "Diff özeti bu sürümde bağlı değil"

        var accessibilityLabel = badge.accessibilityLabel ?? "Doğrulama durumu bilinmiyor"
        accessibilityLabel += ". \(rows.count) kanıt kaydı"
        accessibilityLabel += ". \(worktreeLabel)"

        return TaskBoardEvidenceSummary(
            isWired: evidence != nil,
            badge: badge,
            rows: rows,
            worktreeLabel: worktreeLabel,
            diffNotice: diffNotice,
            accessibilityLabel: accessibilityLabel
        )
    }

    static func findings(_ findings: [ReviewFinding]?) -> TaskBoardFindingsPresentation {
        guard let findings else {
            return TaskBoardFindingsPresentation(
                isWired: false,
                rows: [],
                blockingCount: 0,
                accessibilityLabel: "İnceleme bulguları bu sürümde bağlı değil"
            )
        }
        let rows =
            findings
            .map { finding in
                let severityLabel = severityText(finding.severity)
                let statusLabel = finding.isOpen ? "Açık" : "Kapatıldı"
                let blocksAcceptance = finding.isOpen && finding.severity.blocksAcceptance
                var label = "\(severityLabel) önem, \(statusLabel): \(finding.summary)"
                if blocksAcceptance { label += ". Kabulü engelliyor" }
                return TaskBoardFindingRow(
                    id: finding.id,
                    severityLabel: severityLabel,
                    statusLabel: statusLabel,
                    summary: finding.summary,
                    blocksAcceptance: blocksAcceptance,
                    accessibilityLabel: label
                )
            }
            .sorted { (lhs: TaskBoardFindingRow, rhs: TaskBoardFindingRow) in
                if lhs.blocksAcceptance != rhs.blocksAcceptance {
                    return lhs.blocksAcceptance && !rhs.blocksAcceptance
                }
                return lhs.summary < rhs.summary
            }
        let blockingCount = rows.filter(\.blocksAcceptance).count
        return TaskBoardFindingsPresentation(
            isWired: true,
            rows: rows,
            blockingCount: blockingCount,
            accessibilityLabel: "\(rows.count) inceleme bulgusu; \(blockingCount) tanesi kabulü engelliyor"
        )
    }

    static func approval(
        card: TaskBoardCard,
        attemptID: UUID?,
        availability: TaskBoardActionAvailability?
    ) -> TaskBoardApprovalPresentation {
        let scopeDescription: String
        if let attemptID {
            scopeDescription =
                "Onay kart sürümü \(card.version) ve \(attemptID.uuidString.prefix(8)) denemesinin içerik parmak izine bağlanır"
        } else {
            scopeDescription = "Onaylanacak aktif deneme yok"
        }
        let actorRequirement = "Kabul, insan aktör adı gerektirir"
        let isEnabled = availability?.isEnabled ?? false
        let disabledReason = isEnabled ? nil : (availability?.disabledReason ?? "Kabul bu kartta kullanılamıyor")

        var accessibilityLabel = scopeDescription
        accessibilityLabel += ". \(actorRequirement)"
        if let disabledReason {
            accessibilityLabel += ". Devre dışı: \(disabledReason)"
        }

        return TaskBoardApprovalPresentation(
            isEnabled: isEnabled,
            scopeDescription: scopeDescription,
            actorRequirement: actorRequirement,
            disabledReason: disabledReason,
            accessibilityLabel: accessibilityLabel
        )
    }

    static func providerCapability(
        card: TaskBoardCard,
        attempts: [TaskBoardAttemptSummary],
        startAvailability: TaskBoardActionAvailability?
    ) -> TaskBoardProviderCapabilityPresentation {
        let latest = attempts.max { $0.attemptSequence < $1.attemptSequence }
        let providerLabel = latest?.providerID ?? "Kayıtlı sağlayıcı yok"
        let modelLabel = latest?.modelID ?? "—"
        let notice: String?
        if card.status == .backlog || card.status == .ready {
            if let startAvailability, !startAvailability.isEnabled {
                notice = startAvailability.disabledReason
            } else {
                notice = nil
            }
        } else {
            notice = nil
        }

        var accessibilityLabel = "Sağlayıcı: \(providerLabel), model: \(modelLabel)"
        if let notice {
            accessibilityLabel += ". \(notice)"
        }
        return TaskBoardProviderCapabilityPresentation(
            providerLabel: providerLabel,
            modelLabel: modelLabel,
            notice: notice,
            accessibilityLabel: accessibilityLabel
        )
    }

    private static func evidenceRow(
        _ entry: VerificationEvidence,
        currentFingerprint: String?
    ) -> TaskBoardEvidenceRow {
        let stepLabel: String
        if let stepName = entry.stepName {
            stepLabel = "\(entry.recipeName) · \(stepName)"
        } else {
            stepLabel = entry.recipeName
        }
        let statusLabel: String
        switch entry.status {
        case .passed: statusLabel = "Geçti"
        case .failed: statusLabel = entry.timedOut ? "Zaman aşımı" : "Başarısız"
        case .skipped: statusLabel = "Atlandı"
        }
        let fingerprintLabel = entry.workspaceFingerprint.map { "Parmak izi: \($0.prefix(8))" }
        let isStale: Bool
        if entry.status == .passed {
            if let current = currentFingerprint, !current.isEmpty {
                isStale = entry.workspaceFingerprint != current
            } else {
                isStale = true
            }
        } else {
            isStale = false
        }

        var accessibilityLabel = "\(stepLabel). \(statusLabel)"
        if isStale { accessibilityLabel += ". Güncel içerikle eşleşmiyor" }
        if let blockedBy = entry.blockedBy { accessibilityLabel += ". Engel: \(blockedBy)" }

        let tone: TaskBoardBadgeTone
        switch entry.status {
        case .passed: tone = isStale ? .warning : .positive
        case .failed: tone = .negative
        case .skipped: tone = .neutral
        }

        return TaskBoardEvidenceRow(
            id: entry.id,
            stepLabel: stepLabel,
            statusLabel: statusLabel,
            fingerprintLabel: fingerprintLabel,
            isStale: isStale,
            tone: tone,
            blockedBy: entry.blockedBy,
            accessibilityLabel: accessibilityLabel
        )
    }

    private static func severityText(_ severity: ReviewFindingSeverity) -> String {
        switch severity {
        case .low: "Düşük"
        case .medium: "Orta"
        case .high: "Yüksek"
        case .critical: "Kritik"
        }
    }
}

// MARK: - Detay denetçisi

/// Görev denetçisi: ölçütler, bağımlılıklar, sağlayıcı yeteneği, kanıt/çalışma
/// alanı/diff özeti, inceleme bulguları ve içerik parmak izine bağlı onay.
///
/// Tüm eylemler `TaskActionBar` üzerinden store'a gider; görünüm servis türü bilmez.
@MainActor
struct TaskDetailView: View {
    let store: TaskBoardStore
    let preset: AppThemePreset
    let isDark: Bool
    let input: TaskBoardInspectorInput

    @State private var actor = ""
    @State private var feedback = ""
    /// Ölçüt anahtarının son sonucu; ret panoda kart değişmeden açıklamasıyla
    /// durur, başarıda temizlenir. Görev değişince görünüm kimliğiyle sıfırlanır.
    @State private var criterionFailureMessage: String?
    /// Düzenleme sayfası ve silme onayı; silme başarıyla dönünce mağaza
    /// seçimi düşürdüğü için detay bölmesi kendiliğinden kapanır.
    @State private var showsEditSheet = false
    @State private var showsDeleteConfirmation = false
    @State private var deleteFailureMessage: String?

    private var detail: TaskBoardTaskDetail? { store.detail }

    private var paneState: TaskBoardDetailPaneState {
        TaskDetailPresenter.paneState(
            selectedTaskID: store.selectedTaskID,
            detail: store.detail,
            lastFailure: store.lastFailure
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            switch paneState {
            case .loaded:
                if let detail {
                    loadedPane(detail)
                }
            case .idle:
                paneMessage(title: "Görev seçilmedi", systemImage: "sidebar.left")
            case .loading:
                paneMessage(title: "Görev yükleniyor…", systemImage: "clock")
            case .failed(let taskID, let message):
                failurePane(taskID: taskID, message: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background((isDark ? preset.surfaceDark : preset.surfaceLight).opacity(0.97))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill((isDark ? preset.borderSubtleDark : preset.borderSubtleLight).opacity(0.6))
                .frame(width: 1)
        }
    }

    private func loadedPane(_ detail: TaskBoardTaskDetail) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    headerSection(detail)

                    if !detail.criteria.isEmpty {
                        criteriaSection(detail)
                    }
                    if !detail.dependencies.isEmpty {
                        dependenciesSection(detail)
                    }
                    providerSection(detail)
                    evidenceSection(detail)
                    findingsSection(detail)
                    TaskActivityView(
                        attempts: detail.attempts,
                        isActionInFlight: store.isActionInFlight(for: detail.card.id),
                        preset: preset,
                        isDark: isDark
                    )
                    approvalSection(detail)
                }
                .padding(12)
            }

            Divider().opacity(0.35)

            actorField

            TaskActionBar(
                store: store,
                taskID: detail.card.id,
                actor: actor,
                feedback: feedback,
                preset: preset,
                isDark: isDark
            )
        }
    }

    private func paneMessage(title: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    private func failurePane(taskID: UUID, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.orange)
            Text("Görev yüklenemedi")
                .font(.system(size: 12, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Yeniden dene") {
                retry(taskID: taskID)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.orange)
            .pointingHandCursor()
            .accessibilityLabel("Görevi yeniden yükle")
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Görev yüklenemedi: \(message)")
    }

    private func retry(taskID: UUID) {
        Task {
            await store.selectTask(nil)
            await store.selectTask(taskID)
        }
    }

    // MARK: Sections

    private func headerSection(_ detail: TaskBoardTaskDetail) -> some View {
        let card = TaskBoardPresenter.card(detail.card, verification: .notLoaded)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(card.statusLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(preset.accentGradient.first ?? .accentColor)
                Text(card.stageLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("sürüm \(detail.card.version)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Text(detail.card.title)
                .font(.system(size: 14, weight: .semibold))

            Text(detail.card.objective)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let blockReason = card.blockReasonText {
                Label(blockReason, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            metadataActions(detail)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.accessibilityLabel)
        .sheet(isPresented: $showsEditSheet) {
            TaskEditSheet(detail: detail, store: store, preset: preset, isDark: isDark)
        }
        .confirmationDialog(
            "Görevi sil",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Görevi sil", role: .destructive) { deleteTask(detail.card.id) }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("“\(detail.card.title)” panodan kalıcı olarak silinir. Bu işlem geri alınamaz.")
        }
    }

    /// Başlık altı üstveri eylemleri: düzenleme sayfası ve silme onayı.
    /// Silme ve düzenleme koşan görevde kapalıdır; ret gerekçesi satırda durur.
    private func metadataActions(_ detail: TaskBoardTaskDetail) -> some View {
        let isRunning = detail.card.status == .running
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    showsEditSheet = true
                } label: {
                    Label("Düzenle", systemImage: "pencil")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .pointingHandCursor()
                .disabled(isRunning || store.isActionInFlight(for: detail.card.id))
                .help(isRunning ? "Koşan görev düzenlenemez — önce durdurun" : "Başlık, amaç ve önceliği düzenleyin")
                .accessibilityLabel("Görevi düzenle")

                Button {
                    showsDeleteConfirmation = true
                } label: {
                    Label("Sil", systemImage: "trash")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.85))
                .pointingHandCursor()
                .disabled(isRunning || store.isActionInFlight(for: detail.card.id))
                .help(isRunning ? "Koşan görev silinemez — önce durdurun" : "Görevi panodan kalıcı olarak silin")
                .accessibilityLabel("Görevi sil")
            }
            if let deleteFailureMessage {
                Label(deleteFailureMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Görev silinemedi: \(deleteFailureMessage)")
            }
        }
    }

    private func deleteTask(_ taskID: UUID) {
        Task {
            let result = await store.deleteTask(taskID: taskID)
            deleteFailureMessage = TaskActionBarPresenter.refusalMessage(result)
        }
    }

    private func criteriaSection(_ detail: TaskBoardTaskDetail) -> some View {
        section(title: "Kabul ölçütleri") {
            if let criterionFailureMessage {
                Label(criterionFailureMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Ölçüt güncellenemedi: \(criterionFailureMessage)")
            }
            ForEach(TaskDetailPresenter.criteria(detail)) { criterion in
                HStack(alignment: .top, spacing: 6) {
                    Button {
                        toggleCriterion(detail.card.id, criterionID: criterion.id, isCompleted: criterion.isCompleted)
                    } label: {
                        Image(systemName: criterion.isCompleted ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11))
                            .foregroundStyle(criterion.isCompleted ? Color.green : Color.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isActionInFlight(for: detail.card.id))
                    .pointingHandCursor()
                    .help(criterion.isCompleted ? "Ölçütü geri al" : "Ölçütü tamamlandı işaretle")
                    .accessibilityLabel(
                        criterion.isCompleted
                            ? "\(criterion.text). Tamamlandı işaretini geri al"
                            : "\(criterion.text). Tamamlandı işaretle"
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(criterion.text)
                            .font(.system(size: 11.5))
                            .strikethrough(criterion.isCompleted, color: .secondary)
                        Text(criterion.evidenceLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(criterion.accessibilityLabel)
            }
        }
    }

    private func toggleCriterion(_ taskID: UUID, criterionID: UUID, isCompleted: Bool) {
        Task {
            let result = await store.setCriterionCompletion(
                taskID: taskID,
                criterionID: criterionID,
                isCompleted: !isCompleted
            )
            criterionFailureMessage = TaskActionBarPresenter.refusalMessage(result)
        }
    }

    private func dependenciesSection(_ detail: TaskBoardTaskDetail) -> some View {
        section(title: "Bağımlılıklar") {
            ForEach(TaskDetailPresenter.dependencies(detail, cards: store.cards)) { dependency in
                HStack(spacing: 6) {
                    Image(systemName: dependency.direction == .prerequisite ? "arrow.right" : "arrow.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(dependency.title ?? dependency.taskID.uuidString)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let satisfied = dependency.isSatisfied {
                        Text(satisfied ? "Tamamlandı" : "Bekliyor")
                            .font(.system(size: 10))
                            .foregroundStyle(satisfied ? Color.green : Color.orange)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(dependency.accessibilityLabel)
            }
        }
    }

    private func providerSection(_ detail: TaskBoardTaskDetail) -> some View {
        let startAvailability = store.actionAvailability(for: detail.card.id).first { $0.action == .start }
        let capability = TaskDetailPresenter.providerCapability(
            card: detail.card,
            attempts: detail.attempts,
            startAvailability: startAvailability
        )
        return section(title: "Sağlayıcı yeteneği") {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(capability.providerLabel) · \(capability.modelLabel)")
                    .font(.system(size: 11.5, design: .monospaced))
                if let notice = capability.notice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(capability.accessibilityLabel)
        }
    }

    private func evidenceSection(_ detail: TaskBoardTaskDetail) -> some View {
        let summary = TaskDetailPresenter.evidenceSummary(
            card: detail.card,
            evidence: input.evidence,
            currentFingerprint: input.currentFingerprint,
            workspaceID: input.workspaceID,
            diffSummary: input.diffSummary
        )
        return section(title: "Doğrulanmış iş: kanıt, çalışma alanı, diff") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let badgeLabel = summary.badge.label {
                        Text(badgeLabel)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(toneColor(summary.badge.tone))
                    }
                    Spacer(minLength: 0)
                }

                if let inspectorWarning = input.warning {
                    Label(inspectorWarning, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !summary.isWired {
                    if detail.card.status == .review {
                        Text("Bu görev incelemede ama kanıt bu süreçte görünmüyor — uygulama yeniden başlatıldıysa normaldir; kanıtı görmek için koşunun bu açılışta üretilmesi gerekir")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Henüz kanıt yok — görev çalışıp doğrulama ürettiğinde burada listelenir; o zamana dek yeşil rozet gösterilmez")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(summary.rows) { row in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: evidenceIcon(row.tone))
                            .font(.system(size: 10.5))
                            .foregroundStyle(toneColor(row.tone))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(row.stepLabel) — \(row.statusLabel)")
                                .font(.system(size: 11))
                            if let fingerprintLabel = row.fingerprintLabel {
                                Text(fingerprintLabel)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            if let blockedBy = row.blockedBy {
                                Text(blockedBy)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(row.accessibilityLabel)
                }

                Text(summary.worktreeLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Text(summary.diffNotice)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(summary.accessibilityLabel)
        }
    }

    private func findingsSection(_ detail: TaskBoardTaskDetail) -> some View {
        let presentation = TaskDetailPresenter.findings(input.findings)
        return section(title: "İnceleme bulguları") {
            if !presentation.isWired {
                Text("Henüz bulgu kaydı yok — inceleme bulguları burada listelenir")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(presentation.accessibilityLabel)
            } else if presentation.rows.isEmpty {
                Text("Bulgu yok")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(presentation.rows) { row in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: row.blocksAcceptance ? "exclamationmark.octagon.fill" : "info.circle")
                            .font(.system(size: 10.5))
                            .foregroundStyle(row.blocksAcceptance ? Color.red : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(row.severityLabel) · \(row.statusLabel)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Text(row.summary)
                                .font(.system(size: 11))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(row.accessibilityLabel)
                }
            }
        }
    }

    private func approvalSection(_ detail: TaskBoardTaskDetail) -> some View {
        let acceptAvailability = store.actionAvailability(for: detail.card.id).first { $0.action == .accept }
        let approval = TaskDetailPresenter.approval(
            card: detail.card,
            attemptID: detail.card.activeAttempt?.id ?? detail.card.currentAttemptID,
            availability: acceptAvailability
        )
        return section(title: "Kabul ve onay") {
            VStack(alignment: .leading, spacing: 4) {
                Text(approval.scopeDescription)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(approval.actorRequirement)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                if let disabledReason = approval.disabledReason {
                    Label(disabledReason, systemImage: "lock")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(approval.accessibilityLabel)
        }
    }

    private var actorField: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("İnceleyen adı", text: $actor)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .help("Başlatma ve kabul, onayı size bağlamak için adınızı ister")
                    .accessibilityLabel("İnceleyen insan aktör adı")
                Divider().frame(height: 14).opacity(0.4)
                Image(systemName: "text.bubble")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Değişiklik geri bildirimi", text: $feedback)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .accessibilityLabel("Değişiklik isteği geri bildirimi")
            }
            if actor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Başlatma ve kabul için adınızı yazın — onay size bağlanır, bir kez yazmanız yeterli")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    /// Rozet ve kanıt satırı renkleri sunum tonundan türetilir; görünüm kendi kararını vermez.
    private func toneColor(_ tone: TaskBoardBadgeTone) -> Color {
        switch tone {
        case .positive: .green
        case .neutral: .secondary
        case .warning: .orange
        case .negative: .red
        }
    }

    private func evidenceIcon(_ tone: TaskBoardBadgeTone) -> String {
        switch tone {
        case .positive: "checkmark.seal.fill"
        case .neutral: "minus.circle"
        case .warning: "clock.badge.exclamationmark"
        case .negative: "xmark.octagon.fill"
        }
    }
}

// MARK: - Görev düzenleme

/// Başlık/amaç/öncelik düzenleme formu; doğrulama oluşturma formuyla aynı
/// dili konuşur, yazım yalnızca store üzerinden gider ve ret gizlenmez.
@MainActor
private struct TaskEditSheet: View {
    let card: TaskBoardCard
    let store: TaskBoardStore
    let preset: AppThemePreset
    let isDark: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var objective: String
    @State private var priority: TaskCreationForm.Priority
    @State private var isSubmitting = false
    @State private var failureMessage: String?

    init(detail: TaskBoardTaskDetail, store: TaskBoardStore, preset: AppThemePreset, isDark: Bool) {
        self.card = detail.card
        self.store = store
        self.preset = preset
        self.isDark = isDark
        self._title = State(initialValue: detail.card.title)
        self._objective = State(initialValue: detail.card.objective)
        self._priority = State(initialValue: Self.priority(for: detail.card.priority))
    }

    private static func priority(for value: Int) -> TaskCreationForm.Priority {
        switch value {
        case ...0: .low
        case 1: .normal
        default: .high
        }
    }

    private var formError: String? {
        TaskCreationForm.validationError(title: title, objective: objective)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Görevi düzenle")
                .font(.system(size: 14, weight: .semibold))

            Text("Yalnızca üstveri değişir; durum, aşama ve ölçütler aynen kalır.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("Başlık", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Görev başlığı")

            TextField("Amaç", text: $objective, axis: .vertical)
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

            if let failureMessage {
                Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .accessibilityLabel("Görev güncellenemedi: \(failureMessage)")
            }

            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .pointingHandCursor()
                Button("Kaydet") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting || formError != nil)
                    .help(formError ?? "Değişiklikleri kaydedin")
                    .accessibilityLabel(isSubmitting ? "Görev kaydediliyor" : "Değişiklikleri kaydet")
            }
        }
        .padding(16)
        .frame(width: 440)
        .background(preset.background(isDark: isDark))
    }

    private func submit() {
        if let formError {
            failureMessage = formError
            return
        }
        isSubmitting = true
        failureMessage = nil
        Task {
            let result = await store.updateTask(
                taskID: card.id,
                title: title,
                objective: objective,
                priority: TaskCreationForm.priorityValue(for: priority)
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
