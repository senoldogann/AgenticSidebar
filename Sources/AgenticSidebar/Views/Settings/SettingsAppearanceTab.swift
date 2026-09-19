import SwiftUI

// MARK: - Appearance Tab

extension SettingsView {
    @ViewBuilder
    var appearanceTabContent: some View {
        @Bindable var settings = settingsStore

        settingsCard(
            title: "Preview",
            subtitle: "How your current choices look together.",
            icon: "eye.fill"
        ) {
            appearancePreviewCard()
        }

        settingsCard(
            title: "Color Scheme",
            subtitle: "Light for daytime, dark for night, system to follow macOS.",
            icon: "sun.max.fill"
        ) {
            HStack(alignment: .top, spacing: 12) {
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
                        Image(systemName: "circle.lefthalf.striped.horizontal")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

                        Text("Border & Contrast")
                            .font(.system(size: 13, weight: .medium))

                        Button {
                            settings.contrast = 1.10
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.tertiary)
                                .padding(4)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .interactiveHoverCircle()
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

                    HStack(spacing: 8) {
                        ForEach([0.90, 1.10, 1.30], id: \.self) { preset in
                            Button("\(Int(preset * 100))%") {
                                settings.contrast = preset
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .pointingHandCursor()
                            .help("Set contrast to \(Int(preset * 100))%")
                        }

                        Text("Softer · Default · Bolder")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Text("Enhance visibility and border emphasis across all cards and text elements.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Divider().opacity(0.3)

                // Glass opacity
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

                        Text("Glass Opacity")
                            .font(.system(size: 13, weight: .medium))

                        Button {
                            settings.glassOpacity = 1.00
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.tertiary)
                                .padding(4)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .interactiveHoverCircle()
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
                        Image(systemName: "macwindow")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

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
                            .help("Set window opacity to \(Int(preset * 100))%")
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
                                .interactiveHoverOutline(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                            .help("Use \(family.displayName) for chat text")
                            .accessibilityLabel("\(family.displayName) font\(isSelected ? ", selected" : "")")
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
                        Text(
                            "The quick brown fox jumps over the lazy dog. Modern agentic sidebar adapts seamlessly to your typography and color scheme."
                        )
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

        settingsCard(
            title: "Reset Appearance",
            subtitle: "Contrast, opacity and typography back to defaults. Theme and color scheme stay as they are.",
            icon: "arrow.uturn.backward"
        ) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tuning & typography defaults")
                        .font(.system(size: 13, weight: .medium))
                    Text("Contrast 110% · Glass 100% · Window 95% · System font · Default sizes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                secondaryActionButton(
                    title: "Reset",
                    icon: "arrow.uturn.backward",
                    isDisabled: false
                ) {
                    settings.contrast = 1.10
                    settings.glassOpacity = 1.00
                    settings.windowOpacity = 0.95
                    settings.fontFamily = .system
                    settings.fontSize = .regular
                    settings.codeFontSize = .standard
                    settings.codeWordWrap = false
                    settings.lineSpacing = .normal
                }
            }
        }
    }

    /// Seçilen tema, mod ve yazı tipinin birlikte durduğu küçük önizleme.
    @ViewBuilder
    func appearancePreviewCard() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: currentTheme.accentGradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 30, height: 30)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(currentTheme.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(
                        "\(settingsStore.colorSchemeMode.displayName) · \(settingsStore.fontFamily.displayName) · \(settingsStore.fontSize.displayName)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("Aa")
                    .font(.system(size: 22, weight: .semibold, design: settingsStore.fontFamily.fontDesign))
                    .foregroundStyle(currentTheme.accentGradient.first ?? .primary)
            }

            HStack(spacing: 8) {
                Text("Looks great with your settings")
                    .font(
                        .system(size: settingsStore.fontSize.pointSize - 1, weight: .regular, design: settingsStore.fontFamily.fontDesign)
                    )
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                Spacer(minLength: 0)

                Text("Send")
                    .font(
                        .system(size: settingsStore.fontSize.pointSize - 1, weight: .semibold, design: settingsStore.fontFamily.fontDesign)
                    )
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        LinearGradient(
                            colors: currentTheme.accentGradient,
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
            }
        }
        .padding(12)
        .background(
            Color.primary.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    /// Mod simgesi ve kısa açıklaması.
    func colorSchemeIconName(_ mode: ColorSchemeMode) -> String {
        switch mode {
        case .system: "desktopcomputer"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    /// Mod kartının altındaki tek satırlık ipucu.
    func colorSchemeHint(_ mode: ColorSchemeMode) -> String {
        switch mode {
        case .system: "Follows macOS"
        case .light: "Bright daytime"
        case .dark: "Easy on eyes"
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
                ZStack(alignment: .topTrailing) {
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .background(Circle().fill(currentTheme.accentGradient.first ?? .accentColor))
                            .padding(5)
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: colorSchemeIconName(mode))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(selected ? (currentTheme.accentGradient.first ?? .primary) : .secondary)

                    Text(mode.displayName)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .primary : .secondary)
                }

                Text(colorSchemeHint(mode))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(8)
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
            .interactiveHoverOutline(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Use \(mode.displayName.lowercased()) appearance")
        .accessibilityLabel("\(mode.displayName) appearance\(selected ? ", selected" : "")")
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
            .interactiveHoverOutline(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Use the \(preset.displayName) theme")
        .accessibilityLabel("\(preset.displayName) theme\(isSelected ? ", selected" : "")")
    }
}
