import Carbon.HIToolbox

struct GlobalShortcutSpec: Equatable, Hashable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    /// ⇧⌘B rather than ⌘B.
    ///
    /// `RegisterEventHotKey` consumes the chord before the frontmost application
    /// sees it, and plain ⌘B means "bold" in essentially every text field on the
    /// system — registering it globally would take a shortcut away from every
    /// other app to open this one.
    static let `default` = GlobalShortcutSpec(
        keyCode: UInt32(kVK_ANSI_B),
        modifiers: UInt32(cmdKey | shiftKey)
    )

    /// Snap Context (⇧⌘D): öndeki uygulamanın bağlamını besteciye taşır.
    ///
    /// D harfi "bold" gibi evrensel bir yazım kısayolu değildir, bu yüzden
    /// global kayıtta ⇧⌘B kadar sakıncalı değildir; yine de aynı imza
    /// ailesinden (ASBR) farklı bir kimlikle kaydedilir.
    static let contextSnap = GlobalShortcutSpec(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(cmdKey | shiftKey)
    )
}

/// User-selectable variants of the global show/hide shortcut.
///
/// The window controller and hot-key controller already take a spec, so adding a
/// variant never requires reworking either of them.
enum GlobalShortcutChoice: String, CaseIterable, Identifiable, Sendable {
    case commandB
    case commandShiftB
    case optionCommandB
    case controlCommandB

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .commandB:
            "⌘B"
        case .commandShiftB:
            "⇧⌘B"
        case .optionCommandB:
            "⌥⌘B"
        case .controlCommandB:
            "⌃⌘B"
        }
    }

    var spec: GlobalShortcutSpec {
        let keyCode = UInt32(kVK_ANSI_B)

        switch self {
        case .commandB:
            return GlobalShortcutSpec(
                keyCode: keyCode,
                modifiers: UInt32(cmdKey)
            )
        case .commandShiftB:
            return GlobalShortcutSpec(
                keyCode: keyCode,
                modifiers: UInt32(cmdKey | shiftKey)
            )
        case .optionCommandB:
            return GlobalShortcutSpec(
                keyCode: keyCode,
                modifiers: UInt32(cmdKey | optionKey)
            )
        case .controlCommandB:
            return GlobalShortcutSpec(
                keyCode: keyCode,
                modifiers: UInt32(cmdKey | controlKey)
            )
        }
    }
}
