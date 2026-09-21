import SwiftUI

/// An interactive glassmorphic card presented to the user when the agent asks a mid-session question.
struct AgentQuestionCard: View {
    static let allOptionID = "__all__"

    /// Seçenek listesinin kapak yüksekliği: ~5 satır görünür, kartın başlığı
    /// ve alt düğmeleri her zaman ekranda kalır.
    static let optionsListMaxHeight: CGFloat = 300

    let question: AgentQuestion
    let preset: AppThemePreset
    let isDark: Bool
    let isSubmitting: Bool
    let submissionFailed: Bool
    let onAnswer: (AgentQuestionAnswer) -> Void
    let onDismiss: () -> Void

    @Environment(SettingsStore.self) private var settingsStore: SettingsStore?
    @Environment(\.paneWidth) private var paneWidth

    @State private var selectedOptionIDs: Set<String> = []
    @State private var customAnswerText: String = ""
    @FocusState private var isCustomInputFocused: Bool

    private var isTurkish: Bool {
        let sample = question.prompt + " " + question.options.map(\.label).joined(separator: " ")
        return sample.range(of: #"[üğşıçöĞÜŞİÇÖ]"#, options: .regularExpression) != nil
            || sample.localizedCaseInsensitiveContains("soru")
            || sample.localizedCaseInsensitiveContains("öneri")
            || sample.localizedCaseInsensitiveContains("seç")
            || sample.localizedCaseInsensitiveContains("uygula")
            || sample.localizedCaseInsensitiveContains("hepsi")
    }

    private var effectiveOptions: [AgentQuestionOption] {
        guard settingsStore?.autoOfferAllOption ?? true else {
            return question.options
        }
        guard question.options.count >= 2 else {
            return question.options
        }
        let hasAll = question.options.contains { opt in
            let lower = opt.label.lowercased()
            return lower.contains("hepsi")
                || lower.contains("all of the above")
                || lower.contains("tümünü uygula")
                || lower.contains("tümünü seç")
        }
        guard !hasAll else {
            return question.options
        }

        let allOption = AgentQuestionOption(
            id: Self.allOptionID,
            label: isTurkish ? "Hepsi (Tümünü uygula)" : "All of the above",
            description: isTurkish
                ? "Yukarıdaki tüm maddeleri sırayla uygula"
                : "Apply all options listed above",
            isRecommended: false
        )
        return question.options + [allOption]
    }

    private var isAllSelected: Bool {
        let baseIDs = Set(question.options.map(\.id))
        return !baseIDs.isEmpty && baseIDs.isSubset(of: selectedOptionIDs)
    }

    private func toggleAllSelection() {
        if isAllSelected {
            selectedOptionIDs.removeAll()
        } else {
            selectedOptionIDs = Set(effectiveOptions.map(\.id))
        }
    }

    var body: some View {
        let accent = preset.accentGradient.first ?? .accentColor

        VStack(alignment: .leading, spacing: 12) {
            // Header: Status badge, Title, and Dismiss button
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "questionmark.bubble.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accent)

                    Text(isTurkish ? "Açıklama / Seçim Gerekli" : "Clarification Needed")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    accent.opacity(isDark ? 0.20 : 0.12),
                    in: Capsule()
                )

                Spacer(minLength: 0)

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(isDark ? 0.08 : 0.05))
                        )
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
                .help("Dismiss question")
                .pointingHandCursor()
            }

            // Question Prompt & Optional Select All Helper
            HStack(alignment: .firstTextBaseline) {
                Text(question.prompt)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if question.isMultiSelect && question.options.count >= 2 {
                    Spacer(minLength: 8)

                    Button {
                        toggleAllSelection()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isAllSelected ? "checkmark.circle.fill" : "circle.dashed")
                                .font(.system(size: 10))
                            Text(isAllSelected ? (isTurkish ? "Temizle" : "Deselect All") : (isTurkish ? "Tümünü Seç" : "Select All"))
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(accent.opacity(isDark ? 0.18 : 0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help(isAllSelected ? "Deselect all options" : "Select all options")
                }
            }

            // Multi-choice Option Pills
            //
            // Liste kendi içinde kayar ve yükseklik kapaklıdır: çok seçenekli
            // soruda kart uzayıp alt düğmeler (Skip / Submit) görünmezdi.
            // Başlık ve alt düğmeler sabit durur, yalnız seçenekler kayar.
            if !effectiveOptions.isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(effectiveOptions.enumerated()), id: \.element.id) { index, option in
                            optionRow(
                                option: option,
                                index: index,
                                accent: accent
                            )
                        }
                    }
                }
                .frame(maxHeight: Self.optionsListMaxHeight)
            }

            // Custom Answer Text Input
            if question.allowCustomAnswer {
                HStack(spacing: 8) {
                    Image(systemName: "pencil.line")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    TextField("Or type a custom answer...", text: $customAnswerText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($isCustomInputFocused)
                        .onSubmit {
                            submitCurrentAnswer()
                        }

                    if !customAnswerText.isEmpty {
                        Button {
                            customAnswerText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear custom answer")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Color.primary.opacity(isDark ? 0.06 : 0.04),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isCustomInputFocused ? accent.opacity(0.6) : Color.primary.opacity(isDark ? 0.12 : 0.08),
                            lineWidth: 1
                        )
                )
            }

            if submissionFailed {
                Text("OpenCode could not receive this response. Retry or skip.")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else if isSubmitting {
                ProgressView("Sending response…")
                    .font(.system(size: 11))
            }

            // Action Footer
            HStack(spacing: 10) {
                Button {
                    onDismiss()
                } label: {
                    Text("Skip")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
                .pointingHandCursor()
                .help("Skip this question without answering")

                Spacer(minLength: 0)

                Button {
                    submitCurrentAnswer()
                } label: {
                    HStack(spacing: 5) {
                        Text("Submit Answer")
                            .font(.system(size: 12, weight: .semibold))

                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        LinearGradient(
                            colors: canSubmit ? preset.accentGradient : [Color.gray.opacity(0.5), Color.gray.opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .shadow(
                        color: canSubmit ? accent.opacity(0.35) : Color.clear,
                        radius: 6,
                        y: 2
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit || isSubmitting)
                .pointingHandCursor()
                .help("Send the selected answer to the assistant")
            }
        }
        .padding(14)
        .background(
            (isDark ? preset.surfaceDark : preset.surfaceLight).opacity(isDark ? 0.96 : 0.98),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(accent.opacity(0.35), lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(isDark ? 0.40 : 0.16),
            radius: 14,
            x: 0,
            y: 5
        )
        .frame(maxWidth: 820)
        .padding(.horizontal, PaneResponsive.outerPadding(forWidth: paneWidth))
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .center)
        .onAppear {
            let shouldAutoSelect = settingsStore?.autoSelectRecommendedOption ?? true
            if shouldAutoSelect && selectedOptionIDs.isEmpty {
                if let recommended = effectiveOptions.first(where: { $0.isRecommended }) {
                    selectedOptionIDs = [recommended.id]
                }
            }
        }
    }

    private var canSubmit: Bool {
        !selectedOptionIDs.isEmpty || !customAnswerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitCurrentAnswer() {
        guard canSubmit && !isSubmitting else { return }

        let answer = AgentQuestion.formatAnswer(
            options: effectiveOptions,
            selectedIDs: Array(selectedOptionIDs),
            customText: customAnswerText
        )
        onAnswer(answer)
    }

    private func cleanLabel(for raw: String) -> String {
        var cleaned = raw
        let tags = [
            "(Recommended)", "(recommended)", "(RECOMMENDED)",
            "(Önerilen)", "(önerilen)", "(ÖNERİLEN)",
            "(onerilen)", "(Onerilen)",
            "[Recommended]", "[recommended]",
            "[Önerilen]", "[önerilen]", "[onerilen]",
            "(Tavsiye Edilen)", "(tavsiye edilen)", "(tavsiye)",
        ]
        for tag in tags {
            cleaned = cleaned.replacingOccurrences(of: tag, with: "")
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private func optionRow(
        option: AgentQuestionOption,
        index: Int,
        accent: Color
    ) -> some View {
        let isSelected = selectedOptionIDs.contains(option.id)

        Button {
            toggleOption(option.id)
        } label: {
            HStack(spacing: 8) {
                // Number / Shortcut Badge
                if option.id == Self.allOptionID {
                    Image(systemName: "checklist")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(isSelected ? Color.white : accent)
                        .frame(width: 18, height: 18)
                        .background(
                            isSelected ? accent : accent.opacity(isDark ? 0.22 : 0.12),
                            in: Circle()
                        )
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.white : .secondary)
                        .frame(width: 18, height: 18)
                        .background(
                            isSelected ? accent : Color.primary.opacity(isDark ? 0.10 : 0.06),
                            in: Circle()
                        )
                }

                // Option Label and Description
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(cleanLabel(for: option.label))
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(.primary)

                        if option.isRecommended {
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 7.5))
                                Text(isTurkish ? "Önerilen" : "Recommended")
                                    .font(.system(size: 9.5, weight: .semibold))
                            }
                            .foregroundStyle(accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(accent.opacity(isDark ? 0.22 : 0.12), in: Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(accent.opacity(0.40), lineWidth: 0.8)
                            )
                        }
                    }

                    if let desc = option.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                // Selection checkmark or radio
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? accent : Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isSelected ? accent.opacity(isDark ? 0.16 : 0.10) : Color.primary.opacity(isDark ? 0.04 : 0.02),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isSelected ? accent.opacity(0.60) : Color.primary.opacity(isDark ? 0.08 : 0.05),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
        .pointingHandCursor()
        .help(isSelected ? "Deselect \(cleanLabel(for: option.label))" : "Select \(cleanLabel(for: option.label))")
    }

    private func toggleOption(_ id: String) {
        if id == Self.allOptionID {
            if question.isMultiSelect {
                let baseIDs = Set(question.options.map(\.id))
                if baseIDs.isSubset(of: selectedOptionIDs) {
                    selectedOptionIDs.removeAll()
                } else {
                    selectedOptionIDs = Set(effectiveOptions.map(\.id))
                }
            } else {
                if selectedOptionIDs.contains(Self.allOptionID) {
                    selectedOptionIDs.removeAll()
                } else {
                    selectedOptionIDs = [Self.allOptionID]
                }
            }
            return
        }

        if question.isMultiSelect {
            if selectedOptionIDs.contains(id) {
                selectedOptionIDs.remove(id)
                selectedOptionIDs.remove(Self.allOptionID)
            } else {
                selectedOptionIDs.insert(id)
                let baseIDs = Set(question.options.map(\.id))
                if baseIDs.isSubset(of: selectedOptionIDs) {
                    selectedOptionIDs.insert(Self.allOptionID)
                }
            }
        } else {
            if selectedOptionIDs.contains(id) {
                selectedOptionIDs.removeAll()
            } else {
                selectedOptionIDs = [id]
            }
        }
    }
}
