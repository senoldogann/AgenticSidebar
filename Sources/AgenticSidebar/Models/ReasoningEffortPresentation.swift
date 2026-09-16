import Foundation

/// How the composer's single effort control describes itself.
///
/// The reasoning variant and the fast/normal mode used to be two chips saying
/// two things; they are the same decision at two levels of detail, so the chip
/// shows the variant and adds the mode only when it is switched on. Pure, so the
/// rule is testable without a window.
enum ReasoningEffortPresentation {
    /// The chip's text: `"XHigh · Fast"`, or just the effort when fast is off.
    static func label(variantName: String, isFast: Bool) -> String {
        isFast ? "\(variantName) · Fast" : variantName
    }

    /// The menu row's title, with the default marked in words.
    ///
    /// A SwiftUI menu flattens its labels — a badge view is dropped — so the
    /// word has to travel with the title, as the platform's own menus do.
    static func rowTitle(_ title: String, isDefault: Bool) -> String {
        isDefault ? "\(title) · Default" : title
    }

    /// What the effort control is currently set to, for the accessibility label
    /// and the tooltip.
    static func summary(variantName: String, isFast: Bool) -> String {
        isFast
            ? "Reasoning effort \(variantName), fast mode on"
            : "Reasoning effort \(variantName), fast mode off"
    }
}
