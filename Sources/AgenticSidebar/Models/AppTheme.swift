import AppKit
import SwiftUI

enum ColorSchemeMode: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// What SwiftUI should be handed: `nil` keeps following the system.
    ///
    /// Passing the *resolved* mode instead (`isDark ? .dark : .light`) would
    /// freeze `.system` at whatever it resolved to, because a preferred scheme
    /// is written back into the environment the app reads for the decision.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// The matching window-level `NSAppearance`, or `nil` for "follow the system".
    ///
    /// Clearing the override matters more than setting it: an explicit
    /// `NSAppearance` pins every AppKit-drawn surface (sidebars, materials,
    /// scroll bars, list selection), so a window left with a concrete appearance
    /// stops tracking later system switches no matter what SwiftUI is told.
    var windowAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum ThemeIdentifier: String, CaseIterable, Identifiable, Sendable {
    case monolith = "monolith"
    case nebula = "nebula"
    case grove = "grove"
    case ocean = "ocean"
    case ember = "ember"
    case iris = "iris"
    case auroraNocturne = "auroraNocturne"
    case codex = "codex"
    case claude = "claude"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .monolith: "Monolith"
        case .nebula: "Nebula"
        case .grove: "Grove"
        case .ocean: "Ocean"
        case .ember: "Ember"
        case .iris: "Iris"
        case .auroraNocturne: "Aurora Nocturne"
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}

struct AppThemePreset: Identifiable, Sendable {
    let id: ThemeIdentifier
    let displayName: String
    let lightSwatchColors: [Color]
    let darkSwatchColors: [Color]
    let accentGradient: [Color]
    let backgroundDark: Color
    let backgroundLight: Color
    let surfaceDark: Color
    let surfaceLight: Color
    let userBubbleDark: [Color]
    let userBubbleLight: [Color]
    let assistantBubbleDark: Color
    let assistantBubbleLight: Color
    let borderSubtleDark: Color
    let borderSubtleLight: Color

    func background(isDark: Bool) -> Color {
        isDark ? backgroundDark : backgroundLight
    }

    func surface(isDark: Bool) -> Color {
        isDark ? surfaceDark : surfaceLight
    }

    func border(isDark: Bool) -> Color {
        isDark ? borderSubtleDark : borderSubtleLight
    }

    func composerBackground(isDark: Bool) -> Color {
        isDark ? surfaceDark : surfaceLight
    }

    func composerBorder(isDark: Bool) -> Color {
        isDark ? borderSubtleDark : borderSubtleLight
    }

    func foreground(isDark: Bool) -> Color {
        isDark ? .white : Color(red: 0.12, green: 0.13, blue: 0.15)
    }

    /// Text drawn on top of a user bubble. The light bubble gradients are pale
    /// by design, so a hard-coded white foreground disappears in light mode.
    func userBubbleForeground(isDark: Bool) -> Color {
        foreground(isDark: isDark)
    }

    /// Code and terminal surfaces sit one step deeper than the surrounding
    /// background. A translucent black composites with whatever the theme's
    /// background is, so it stays coherent per theme *and* flips with the
    /// appearance, unlike a fixed near-black that also swallowed `.primary` text
    /// in light mode.
    func codeBackground(isDark: Bool) -> Color {
        Color.black.opacity(isDark ? 0.35 : 0.05)
    }
}

enum AppThemes {
    static let allPresets: [AppThemePreset] = [
        AppThemePreset(
            id: .monolith,
            displayName: "Monolith",
            lightSwatchColors: [Color(white: 0.95), Color(white: 0.85)],
            darkSwatchColors: [Color(white: 0.20), Color(white: 0.10)],
            accentGradient: [Color(white: 0.70), Color(white: 0.40)],
            backgroundDark: Color(red: 0.07, green: 0.07, blue: 0.09),
            backgroundLight: Color(red: 0.96, green: 0.96, blue: 0.97),
            surfaceDark: Color(red: 0.12, green: 0.12, blue: 0.15),
            surfaceLight: Color(white: 1.0),
            userBubbleDark: [Color(red: 0.22, green: 0.22, blue: 0.26), Color(red: 0.16, green: 0.16, blue: 0.20)],
            userBubbleLight: [Color(white: 0.90), Color(white: 0.85)],
            assistantBubbleDark: Color(red: 0.11, green: 0.11, blue: 0.14),
            assistantBubbleLight: Color(white: 0.97),
            borderSubtleDark: Color.white.opacity(0.08),
            borderSubtleLight: Color.black.opacity(0.08)
        ),
        AppThemePreset(
            id: .nebula,
            displayName: "Nebula",
            lightSwatchColors: [Color(red: 1.0, green: 0.48, blue: 0.72), Color(red: 0.95, green: 0.25, blue: 0.55)],
            darkSwatchColors: [Color(red: 0.55, green: 0.10, blue: 0.35), Color(red: 0.30, green: 0.05, blue: 0.20)],
            accentGradient: [Color(red: 0.95, green: 0.25, blue: 0.58), Color(red: 0.65, green: 0.12, blue: 0.45)],
            backgroundDark: Color(red: 0.09, green: 0.06, blue: 0.10),
            backgroundLight: Color(red: 0.98, green: 0.95, blue: 0.97),
            surfaceDark: Color(red: 0.15, green: 0.09, blue: 0.16),
            surfaceLight: Color(white: 1.0),
            userBubbleDark: [Color(red: 0.45, green: 0.14, blue: 0.35), Color(red: 0.28, green: 0.08, blue: 0.24)],
            userBubbleLight: [Color(red: 0.96, green: 0.82, blue: 0.90), Color(red: 0.92, green: 0.74, blue: 0.85)],
            assistantBubbleDark: Color(red: 0.13, green: 0.08, blue: 0.14),
            assistantBubbleLight: Color(red: 0.97, green: 0.94, blue: 0.96),
            borderSubtleDark: Color(red: 0.95, green: 0.25, blue: 0.58).opacity(0.18),
            borderSubtleLight: Color(red: 0.95, green: 0.25, blue: 0.58).opacity(0.20)
        ),
        AppThemePreset(
            id: .grove,
            displayName: "Grove",
            lightSwatchColors: [Color(red: 0.62, green: 0.88, blue: 0.75), Color(red: 0.45, green: 0.78, blue: 0.62)],
            darkSwatchColors: [Color(red: 0.20, green: 0.45, blue: 0.35), Color(red: 0.12, green: 0.30, blue: 0.22)],
            accentGradient: [Color(red: 0.30, green: 0.75, blue: 0.55), Color(red: 0.18, green: 0.55, blue: 0.40)],
            backgroundDark: Color(red: 0.06, green: 0.10, blue: 0.08),
            backgroundLight: Color(red: 0.95, green: 0.98, blue: 0.96),
            surfaceDark: Color(red: 0.10, green: 0.16, blue: 0.13),
            surfaceLight: Color(white: 1.0),
            userBubbleDark: [Color(red: 0.15, green: 0.35, blue: 0.25), Color(red: 0.10, green: 0.25, blue: 0.18)],
            userBubbleLight: [Color(red: 0.80, green: 0.93, blue: 0.85), Color(red: 0.72, green: 0.88, blue: 0.80)],
            assistantBubbleDark: Color(red: 0.09, green: 0.14, blue: 0.11),
            assistantBubbleLight: Color(red: 0.94, green: 0.97, blue: 0.95),
            borderSubtleDark: Color(red: 0.30, green: 0.75, blue: 0.55).opacity(0.18),
            borderSubtleLight: Color(red: 0.30, green: 0.75, blue: 0.55).opacity(0.20)
        ),
        AppThemePreset(
            id: .ocean,
            displayName: "Ocean",
            lightSwatchColors: [Color(red: 0.55, green: 0.82, blue: 0.98), Color(red: 0.35, green: 0.68, blue: 0.92)],
            darkSwatchColors: [Color(red: 0.18, green: 0.38, blue: 0.55), Color(red: 0.10, green: 0.22, blue: 0.38)],
            accentGradient: [Color(red: 0.28, green: 0.65, blue: 0.95), Color(red: 0.15, green: 0.45, blue: 0.80)],
            backgroundDark: Color(red: 0.06, green: 0.09, blue: 0.14),
            backgroundLight: Color(red: 0.95, green: 0.97, blue: 1.0),
            surfaceDark: Color(red: 0.10, green: 0.15, blue: 0.22),
            surfaceLight: Color(white: 1.0),
            userBubbleDark: [Color(red: 0.15, green: 0.30, blue: 0.48), Color(red: 0.10, green: 0.20, blue: 0.36)],
            userBubbleLight: [Color(red: 0.82, green: 0.90, blue: 0.98), Color(red: 0.74, green: 0.85, blue: 0.95)],
            assistantBubbleDark: Color(red: 0.09, green: 0.13, blue: 0.19),
            assistantBubbleLight: Color(red: 0.94, green: 0.96, blue: 0.99),
            borderSubtleDark: Color(red: 0.28, green: 0.65, blue: 0.95).opacity(0.18),
            borderSubtleLight: Color(red: 0.28, green: 0.65, blue: 0.95).opacity(0.20)
        ),
        AppThemePreset(
            id: .ember,
            displayName: "Ember",
            lightSwatchColors: [Color(red: 0.98, green: 0.78, blue: 0.60), Color(red: 0.92, green: 0.60, blue: 0.40)],
            darkSwatchColors: [Color(red: 0.55, green: 0.35, blue: 0.20), Color(red: 0.35, green: 0.20, blue: 0.10)],
            accentGradient: [Color(red: 0.95, green: 0.58, blue: 0.25), Color(red: 0.80, green: 0.40, blue: 0.15)],
            backgroundDark: Color(red: 0.10, green: 0.07, blue: 0.05),
            backgroundLight: Color(red: 0.99, green: 0.97, blue: 0.95),
            surfaceDark: Color(red: 0.17, green: 0.12, blue: 0.09),
            surfaceLight: Color(white: 1.0),
            userBubbleDark: [Color(red: 0.45, green: 0.28, blue: 0.16), Color(red: 0.30, green: 0.18, blue: 0.10)],
            userBubbleLight: [Color(red: 0.97, green: 0.88, blue: 0.80), Color(red: 0.93, green: 0.82, blue: 0.72)],
            assistantBubbleDark: Color(red: 0.14, green: 0.10, blue: 0.08),
            assistantBubbleLight: Color(red: 0.97, green: 0.95, blue: 0.93),
            borderSubtleDark: Color(red: 0.95, green: 0.58, blue: 0.25).opacity(0.18),
            borderSubtleLight: Color(red: 0.95, green: 0.58, blue: 0.25).opacity(0.20)
        ),
        AppThemePreset(
            id: .iris,
            displayName: "Iris",
            lightSwatchColors: [Color(red: 0.85, green: 0.75, blue: 0.98), Color(red: 0.72, green: 0.58, blue: 0.92)],
            darkSwatchColors: [Color(red: 0.40, green: 0.25, blue: 0.60), Color(red: 0.25, green: 0.15, blue: 0.40)],
            accentGradient: [Color(red: 0.65, green: 0.45, blue: 0.95), Color(red: 0.48, green: 0.30, blue: 0.80)],
            backgroundDark: Color(red: 0.08, green: 0.06, blue: 0.12),
            backgroundLight: Color(red: 0.97, green: 0.96, blue: 0.99),
            surfaceDark: Color(red: 0.14, green: 0.11, blue: 0.20),
            surfaceLight: Color(white: 1.0),
            userBubbleDark: [Color(red: 0.32, green: 0.22, blue: 0.50), Color(red: 0.22, green: 0.14, blue: 0.36)],
            userBubbleLight: [Color(red: 0.90, green: 0.85, blue: 0.98), Color(red: 0.84, green: 0.77, blue: 0.94)],
            assistantBubbleDark: Color(red: 0.12, green: 0.09, blue: 0.16),
            assistantBubbleLight: Color(red: 0.96, green: 0.94, blue: 0.98),
            borderSubtleDark: Color(red: 0.65, green: 0.45, blue: 0.95).opacity(0.18),
            borderSubtleLight: Color(red: 0.65, green: 0.45, blue: 0.95).opacity(0.20)
        ),
        AppThemePreset(
            id: .auroraNocturne,
            displayName: "Aurora Nocturne",
            lightSwatchColors: [Color(red: 0.35, green: 0.85, blue: 0.78), Color(red: 0.65, green: 0.40, blue: 0.92)],
            darkSwatchColors: [Color(red: 0.15, green: 0.55, blue: 0.52), Color(red: 0.35, green: 0.18, blue: 0.55)],
            accentGradient: [Color(red: 0.20, green: 0.85, blue: 0.75), Color(red: 0.68, green: 0.35, blue: 0.92)],
            backgroundDark: Color(red: 0.06, green: 0.08, blue: 0.12),
            backgroundLight: Color(red: 0.96, green: 0.98, blue: 0.98),
            surfaceDark: Color(red: 0.10, green: 0.14, blue: 0.20),
            surfaceLight: Color(white: 1.0),
            userBubbleDark: [Color(red: 0.15, green: 0.35, blue: 0.40), Color(red: 0.28, green: 0.15, blue: 0.42)],
            userBubbleLight: [Color(red: 0.82, green: 0.94, blue: 0.92), Color(red: 0.88, green: 0.82, blue: 0.95)],
            assistantBubbleDark: Color(red: 0.09, green: 0.12, blue: 0.17),
            assistantBubbleLight: Color(red: 0.94, green: 0.97, blue: 0.97),
            borderSubtleDark: Color(red: 0.20, green: 0.85, blue: 0.75).opacity(0.20),
            borderSubtleLight: Color(red: 0.20, green: 0.85, blue: 0.75).opacity(0.22)
        ),
        AppThemePreset(
            id: .codex,
            displayName: "Codex",
            lightSwatchColors: [Color(white: 1.0), Color(red: 0.06, green: 0.64, blue: 0.50)],
            darkSwatchColors: [Color(red: 0.09, green: 0.09, blue: 0.09), Color(red: 0.06, green: 0.64, blue: 0.50)],
            accentGradient: [Color(red: 0.06, green: 0.64, blue: 0.50), Color(red: 0.08, green: 0.72, blue: 0.58)],
            backgroundDark: Color(red: 0.09, green: 0.09, blue: 0.09),
            backgroundLight: Color(white: 1.0),
            surfaceDark: Color(red: 0.12, green: 0.12, blue: 0.12),
            surfaceLight: Color(red: 0.97, green: 0.97, blue: 0.98),
            userBubbleDark: [Color(red: 0.18, green: 0.18, blue: 0.20), Color(red: 0.14, green: 0.14, blue: 0.16)],
            userBubbleLight: [Color(red: 0.94, green: 0.94, blue: 0.96), Color(red: 0.90, green: 0.90, blue: 0.93)],
            assistantBubbleDark: Color(red: 0.09, green: 0.09, blue: 0.09),
            assistantBubbleLight: Color(white: 1.0),
            borderSubtleDark: Color(white: 0.20).opacity(0.4),
            borderSubtleLight: Color(white: 0.85).opacity(0.8)
        ),
        AppThemePreset(
            id: .claude,
            displayName: "Claude",
            lightSwatchColors: [Color(red: 0.98, green: 0.97, blue: 0.93), Color(red: 0.85, green: 0.47, blue: 0.34)],
            darkSwatchColors: [Color(red: 0.12, green: 0.12, blue: 0.11), Color(red: 0.85, green: 0.47, blue: 0.34)],
            accentGradient: [Color(red: 0.85, green: 0.47, blue: 0.34), Color(red: 0.79, green: 0.39, blue: 0.26)],
            backgroundDark: Color(red: 0.12, green: 0.12, blue: 0.11),
            backgroundLight: Color(red: 0.98, green: 0.97, blue: 0.93),
            surfaceDark: Color(red: 0.16, green: 0.15, blue: 0.13),
            surfaceLight: Color(red: 0.95, green: 0.93, blue: 0.88),
            userBubbleDark: [Color(red: 0.22, green: 0.21, blue: 0.18), Color(red: 0.18, green: 0.17, blue: 0.15)],
            userBubbleLight: [Color(red: 0.92, green: 0.90, blue: 0.84), Color(red: 0.88, green: 0.85, blue: 0.79)],
            assistantBubbleDark: Color(red: 0.12, green: 0.12, blue: 0.11),
            assistantBubbleLight: Color(red: 0.98, green: 0.97, blue: 0.93),
            borderSubtleDark: Color(red: 0.85, green: 0.47, blue: 0.34).opacity(0.18),
            borderSubtleLight: Color(red: 0.85, green: 0.47, blue: 0.34).opacity(0.20)
        ),
    ]

    /// Single source of truth for resolving a stored theme identifier, including
    /// the legacy identifiers written by earlier builds.
    static func normalizedThemeID(from idString: String) -> String {
        switch idString {
        case "t3Code":
            ThemeIdentifier.monolith.rawValue
        case "t3Chat":
            ThemeIdentifier.nebula.rawValue
        default:
            idString
        }
    }

    static func preset(for idString: String) -> AppThemePreset {
        let normalizedID = normalizedThemeID(from: idString)

        return allPresets.first { $0.id.rawValue == normalizedID }
            ?? allPresets.first { $0.id == .nebula }
            ?? allPresets[0]
    }
}
