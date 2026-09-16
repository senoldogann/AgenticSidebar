import SwiftUI

enum AppFontFamily: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case rounded = "rounded"
    case serif = "serif"
    case monospaced = "monospaced"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System (SF Pro)"
        case .rounded: "Rounded"
        case .serif: "Serif (New York)"
        case .monospaced: "Monospace"
        }
    }

    var fontDesign: Font.Design {
        switch self {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}

enum AppFontSize: String, CaseIterable, Identifiable, Sendable {
    case small = "small"
    case regular = "regular"
    case medium = "medium"
    case large = "large"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: "Small (12.5pt)"
        case .regular: "Default (14pt)"
        case .medium: "Medium (15.5pt)"
        case .large: "Large (17pt)"
        }
    }

    var pointSize: CGFloat {
        switch self {
        case .small: 12.5
        case .regular: 14.0
        case .medium: 15.5
        case .large: 17.0
        }
    }
}

enum CodeFontSize: String, CaseIterable, Identifiable, Sendable {
    case compact = "compact"
    case standard = "standard"
    case comfortable = "comfortable"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compact: "Compact (11.5pt)"
        case .standard: "Default (12.5pt)"
        case .comfortable: "Comfortable (14pt)"
        }
    }

    var pointSize: CGFloat {
        switch self {
        case .compact: 11.5
        case .standard: 12.5
        case .comfortable: 14.0
        }
    }
}

enum AppLineSpacing: String, CaseIterable, Identifiable, Sendable {
    case tight = "tight"
    case normal = "normal"
    case relaxed = "relaxed"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tight: "Tight"
        case .normal: "Normal"
        case .relaxed: "Relaxed"
        }
    }

    var spacing: CGFloat {
        switch self {
        case .tight: 2.5
        case .normal: 4.5
        case .relaxed: 7.0
        }
    }
}
