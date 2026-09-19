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
        settingsCardChrome {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            content()
        }
    }

    /// Başlığına tıklanınca açılan kart.
    ///
    /// Uzun bir listeyi sürekli ekranda tutmak yerine başlık görünür kalır;
    /// içerik yalnız açılınca kurulur, bu yüzden listeyi yükleyen `task` da
    /// içerikle birlikte ilk açılışta çalışır.
    @ViewBuilder
    func collapsibleSettingsCard<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        isExpanded: Binding<Bool>,
        trailingText: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        settingsCardChrome {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    if let trailingText {
                        Text(trailingText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                }
                .contentShape(Rectangle())
                .interactiveHoverPill(cornerRadius: 8)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(isExpanded.wrappedValue ? "Collapse \(title)" : "Expand \(title)")

            if isExpanded.wrappedValue {
                content()
            }
        }
    }

    /// Her kartın ortak gövdesi: zemin, çerçeve ve gölge tek yerde durur, kart
    /// çeşitleri yalnız içeriklerini anlatır.
    @ViewBuilder
    func settingsCardChrome<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
        .padding(16)
        .background(
            currentTheme.surface(isDark: isDarkMode)
                .opacity(settingsStore.glassOpacity),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    currentTheme.border(isDark: isDarkMode)
                        .opacity(settingsStore.contrast),
                    lineWidth: 0.5
                )
        )
        .shadow(color: Color.black.opacity(isDarkMode ? 0.12 : 0.03), radius: 4, x: 0, y: 1)
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
            .interactiveHoverOutline(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(title)
    }

    @ViewBuilder
    func secondaryActionButton(
        title: String,
        icon: String?,
        action: @escaping () -> Void
    ) -> some View {
        secondaryActionButton(title: title, icon: icon, isDisabled: false, action: action)
    }

    /// The quiet counterpart to `primaryActionButton`: for a card that offers an
    /// action without proposing one (refresh, revoke, reveal in Finder).
    @ViewBuilder
    func secondaryActionButton(
        title: String,
        icon: String?,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let accent = currentTheme.accentGradient.first ?? .accentColor

        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11.5, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.05), lineWidth: 0.5)
            )
            .interactiveHoverPill(cornerRadius: 8)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
        .help(title)
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
        .help(title)
    }

    @ViewBuilder
    func settingsTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 6.5)
            .background(
                isDarkMode ? Color.white.opacity(0.06) : Color.black.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 0.5)
            )
    }

    @ViewBuilder
    func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .foregroundStyle(color)
            .background(
                color.opacity(0.14),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
    }

    @ViewBuilder
    func emptyRow(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    func statusCard(_ status: ExtensionStatus) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: status.isFailure ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(status.isFailure ? Color.orange : Color.secondary)

            Text(status.message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
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
