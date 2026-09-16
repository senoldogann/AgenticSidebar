import SwiftUI

// MARK: - Appearance Tab

extension SettingsView {
    @ViewBuilder
    var appearanceTabContent: some View {
        @Bindable var settings = settingsStore

        settingsCard(
            title: "Color Scheme",
            subtitle: "Select your preferred visual appearance mode.",
            icon: "sun.max.fill"
        ) {
            HStack(spacing: 12) {
                ForEach(ColorSchemeMode.allCases) { mode in
                    colorSchemeCard(mode: mode, selected: settings.colorSchemeMode == mode) {
                        settings.colorSchemeMode = mode
                    }
                }
            }
        }

        settingsCard(
            title: "Theme Presets",
            subtitle: "Pick from custom coordinated color palettes across all components.",
            icon: "paintpalette.fill"
        ) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(AppThemes.allPresets) { preset in
                    themePresetCard(
                        preset: preset,
                        isSelected: settings.activeThemeID == preset.id.rawValue
                    ) {
                        settings.activeThemeID = preset.id.rawValue
                    }
                }
            }
        }

        settingsCard(
            title: "Interface Tuning",
            subtitle: "Fine-tune contrast, glassmorphic opacity, and window transparency.",
            icon: "slider.horizontal.3"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                // Contrast
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Border & Contrast")
                            .font(.system(size: 13, weight: .medium))

                        Button {
                            settings.contrast = 1.10
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Reset contrast to 110%")

                        Spacer()

                        Text("\(Int(settings.contrast * 100))%")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }

                    Slider(value: $settings.contrast, in: 0.80...1.50, step: 0.05)
                        .tint(currentTheme.accentGradient.first ?? .accentColor)

                    Text("Enhance visibility and border emphasis across all cards and text elements.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Divider().opacity(0.3)

                // Glass opacity
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Glass Opacity")
                            .font(.system(size: 13, weight: .medium))

                        Button {
                            settings.glassOpacity = 1.00
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Reset glass opacity to 100%")

                        Spacer()

                        Text("\(Int(settings.glassOpacity * 100))%")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }

                    Slider(value: $settings.glassOpacity, in: 0.30...1.00, step: 0.05)
                        .tint(currentTheme.accentGradient.first ?? .accentColor)

                    Text("Higher values produce a more solid, opaque look; lower values reveal more backdrop blur.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Divider().opacity(0.3)

                // Window Opacity
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Window Transparency")
                            .font(.system(size: 13, weight: .medium))

                        Spacer()

                        Text("\(Int(settings.windowOpacity * 100))%")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }

                    Slider(value: $settings.windowOpacity, in: 0.40...1.00, step: 0.05)
                        .tint(currentTheme.accentGradient.first ?? .accentColor)

                    HStack(spacing: 8) {
                        ForEach([0.60, 0.80, 0.95, 1.00], id: \.self) { preset in
                            Button("\(Int(preset * 100))%") {
                                settings.windowOpacity = preset
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .pointingHandCursor()
                        }
                    }
                }
            }
        }

        settingsCard(
            title: "Typography & Reading",
            subtitle: "Customize fonts, sizing, line spacing, and code wrapping across the chat workspace.",
            icon: "textformat.size"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                // Font Family
                VStack(alignment: .leading, spacing: 8) {
                    Text("Font Family")
                        .font(.system(size: 13, weight: .medium))

                    HStack(spacing: 8) {
                        ForEach(AppFontFamily.allCases) { family in
                            let isSelected = settings.fontFamily == family
                            Button {
                                settings.fontFamily = family
                            } label: {
                                VStack(spacing: 4) {
                                    Text("Aa")
                                        .font(.system(size: 18, weight: .semibold, design: family.fontDesign))
                                        .foregroundStyle(isSelected ? (currentTheme.accentGradient.first ?? .primary) : .secondary)

                                    Text(family.displayName)
                                        .font(.caption.weight(isSelected ? .semibold : .regular))
                                        .foregroundStyle(isSelected ? .primary : .secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .padding(.horizontal, 6)
                                .background(
                                    isSelected
                                        ? (currentTheme.accentGradient.first ?? .accentColor).opacity(0.12)
                                        : Color.primary.opacity(0.03),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(
                                            isSelected
                                                ? (currentTheme.accentGradient.first ?? .accentColor).opacity(0.7)
                                                : Color.primary.opacity(0.08),
                                            lineWidth: isSelected ? 1.5 : 1
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                        }
                    }
                }

                Divider().opacity(0.3)

                // Font Size & Line Spacing
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Chat Font Size")
                                .font(.system(size: 13, weight: .medium))

                            Spacer()

                            Text(settings.fontSize.displayName)
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        Picker("Font Size", selection: $settings.fontSize) {
                            ForEach(AppFontSize.allCases) { size in
                                Text(size.displayName).tag(size)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Line Spacing")
                                .font(.system(size: 13, weight: .medium))

                            Spacer()

                            Text(settings.lineSpacing.displayName)
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        Picker("Line Spacing", selection: $settings.lineSpacing) {
                            ForEach(AppLineSpacing.allCases) { spacing in
                                Text(spacing.displayName).tag(spacing)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    .frame(maxWidth: .infinity)
                }

                Divider().opacity(0.3)

                // Code Typography: Code Font Size & Word Wrap
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Code Block Font Size")
                                .font(.system(size: 13, weight: .medium))

                            Spacer()

                            Text(settings.codeFontSize.displayName)
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        Picker("Code Font Size", selection: $settings.codeFontSize) {
                            ForEach(CodeFontSize.allCases) { size in
                                Text(size.displayName).tag(size)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: $settings.codeWordWrap) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Code Word Wrap")
                                    .font(.system(size: 13, weight: .medium))
                                Text(settings.codeWordWrap ? "Lines wrap within view" : "Horizontal scrolling enabled")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                    .frame(maxWidth: .infinity)
                }

                Divider().opacity(0.3)

                // Live Preview Card
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("LIVE PREVIEW")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("The quick brown fox jumps over the lazy dog. Modern agentic sidebar adapts seamlessly to your typography and color scheme.")
                            .font(.system(size: settings.fontSize.pointSize, weight: .regular, design: settings.fontFamily.fontDesign))
                            .lineSpacing(settings.lineSpacing.spacing)
                            .foregroundStyle(.primary)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("swift")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.top, 6)

                            if settings.codeWordWrap {
                                Text("func optimizeUI(theme: AppTheme, font: AppFontFamily) -> PerformanceMetrics { return .optimal }")
                                    .font(.system(size: settings.codeFontSize.pointSize, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 10)
                                    .padding(.bottom, 8)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    Text("func optimizeUI(theme: AppTheme, font: AppFontFamily) -> PerformanceMetrics { return .optimal }")
                                        .font(.system(size: settings.codeFontSize.pointSize, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .padding(.horizontal, 10)
                                        .padding(.bottom, 8)
                                }
                            }
                        }
                        .background(
                            currentTheme.codeBackground(isDark: isDarkMode),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(currentTheme.border(isDark: isDarkMode), lineWidth: 1)
                        )
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.primary.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                }
            }
        }
    }

    @ViewBuilder
    func colorSchemeCard(
        mode: ColorSchemeMode,
        selected: Bool,
        onSelect: @escaping () -> Void
    ) -> some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(white: 0.15))
                        .frame(height: 60)

                    switch mode {
                    case .system:
                        HStack(spacing: 0) {
                            Color(red: 0.95, green: 0.94, blue: 0.96)
                            Color(red: 0.12, green: 0.11, blue: 0.15)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    case .light:
                        Color(red: 0.96, green: 0.95, blue: 0.97)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    case .dark:
                        Color(red: 0.12, green: 0.11, blue: 0.15)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(mode == .light ? Color.black.opacity(0.18) : Color.white.opacity(0.30))
                            .frame(width: 32, height: 5)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(mode == .light ? Color.black.opacity(0.10) : Color.white.opacity(0.15))
                            .frame(width: 50, height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(mode == .light ? Color.black.opacity(0.10) : Color.white.opacity(0.15))
                            .frame(width: 42, height: 4)
                    }
                    .padding(.horizontal, 8)
                }

                Text(mode.displayName)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .padding(6)
            .background(
                Color.primary.opacity(selected ? 0.08 : 0.02),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        selected ? (currentTheme.accentGradient.first ?? .accentColor) : Color.primary.opacity(0.08),
                        lineWidth: selected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    @ViewBuilder
    func themePresetCard(
        preset: AppThemePreset,
        isSelected: Bool,
        onSelect: @escaping () -> Void
    ) -> some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: preset.lightSwatchColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                        )

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: preset.darkSwatchColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                        )

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(preset.accentGradient.first ?? .primary)
                    }
                }

                Text(preset.displayName)
                    .font(.caption.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .padding(10)
            .background(
                Color.primary.opacity(isSelected ? 0.08 : 0.03),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected ? (preset.accentGradient.first ?? .accentColor) : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}
