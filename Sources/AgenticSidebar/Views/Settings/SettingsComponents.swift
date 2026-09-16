import AppKit
import SwiftUI

/// Shared building blocks for every settings tab.
///
/// The tab files only describe their content; card chrome, action buttons and
/// appearance resolution live here so all four tabs stay visually identical.
extension SettingsView {
    var isDarkMode: Bool {
        settingsStore.isDark(systemColorScheme: systemColorScheme)
    }

    var currentTheme: AppThemePreset {
        settingsStore.currentThemePreset
    }

    @ViewBuilder
    func settingsCard<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(currentTheme.accentGradient.first ?? .primary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            content()
        }
        .padding(18)
        .background(
            currentTheme.surface(isDark: isDarkMode)
                .opacity(settingsStore.glassOpacity),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    currentTheme.border(isDark: isDarkMode)
                        .opacity(settingsStore.contrast),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(isDarkMode ? 0.20 : 0.04), radius: 6, x: 0, y: 2)
    }

    @ViewBuilder
    func primaryActionButton(
        title: String,
        icon: String?,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
                if isDisabled {
                    Color.secondary.opacity(0.3)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    LinearGradient(
                        colors: currentTheme.accentGradient,
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(isDisabled ? 0.0 : 0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .pointingHandCursor()
    }

    /// The quiet counterpart to `primaryActionButton`: for a card that offers an
    /// action without proposing one (refresh, revoke, reveal in Finder).
    @ViewBuilder
    func secondaryActionButton(
        title: String,
        icon: String?,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let accent = currentTheme.accentGradient.first ?? .accentColor

        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                accent.opacity(isDarkMode ? 0.20 : 0.12),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(accent.opacity(0.32), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
        .pointingHandCursor()
    }

    @ViewBuilder
    func destructiveActionButton(
        title: String,
        icon: String?,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Color.red.opacity(isDisabled ? 0.4 : 0.9))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Color.red.opacity(isDisabled ? 0.05 : 0.12),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.red.opacity(isDisabled ? 0.1 : 0.25), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .pointingHandCursor()
    }
}

struct SettingsWindowAppearanceBridge: NSViewRepresentable {
    let mode: ColorSchemeMode

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView)
    }

    /// Writing the *resolved* mode would pin the settings window forever; the
    /// mode itself is applied so System can clear the override.
    private func apply(to view: NSView) {
        DispatchQueue.main.async {
            view.window?.appearance = mode.windowAppearance
        }
    }
}
