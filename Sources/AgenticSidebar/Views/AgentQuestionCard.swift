import SwiftUI

/// An interactive glassmorphic card presented to the user when the agent asks a mid-session question.
struct AgentQuestionCard: View {
    let question: AgentQuestion
    let preset: AppThemePreset
    let isDark: Bool
    let isSubmitting: Bool
    let submissionFailed: Bool
    let onAnswer: (AgentQuestionAnswer) -> Void
    let onDismiss: () -> Void

    @State private var selectedOptionIDs: Set<String> = []
    @State private var customAnswerText: String = ""
    @FocusState private var isCustomInputFocused: Bool

    var body: some View {
        let accent = preset.accentGradient.first ?? .accentColor

        VStack(alignment: .leading, spacing: 12) {
            // Header: Status badge, Title, and Dismiss button
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "questionmark.bubble.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accent)

                    Text("Clarification Needed")
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

            // Question Prompt
            Text(question.prompt)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            // Multi-choice Option Pills
            if !question.options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                        optionRow(
                            option: option,
                            index: index,
                            accent: accent
                        )
                    }
                }
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
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .center)
        .onAppear {
            if !question.isMultiSelect, let recommended = question.options.first(where: { $0.isRecommended }) {
                selectedOptionIDs = [recommended.id]
            }
        }
    }

    private var canSubmit: Bool {
        !selectedOptionIDs.isEmpty || !customAnswerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitCurrentAnswer() {
        guard canSubmit && !isSubmitting else { return }

        let answer = AgentQuestion.formatAnswer(
            options: question.options,
            selectedIDs: Array(selectedOptionIDs),
            customText: customAnswerText
        )
        onAnswer(answer)
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
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white : .secondary)
                    .frame(width: 18, height: 18)
                    .background(
                        isSelected ? accent : Color.primary.opacity(isDark ? 0.10 : 0.06),
                        in: Circle()
                    )

                // Option Label and Description
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(.primary)

                        if option.isRecommended {
                            Text("Recommended")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(accent.opacity(isDark ? 0.20 : 0.12), in: Capsule())
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
    }

    private func toggleOption(_ id: String) {
        if question.isMultiSelect {
            if selectedOptionIDs.contains(id) {
                selectedOptionIDs.remove(id)
            } else {
                selectedOptionIDs.insert(id)
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
