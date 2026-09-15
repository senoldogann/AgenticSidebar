import Carbon.HIToolbox

struct GlobalShortcutSpec: Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let `default` = GlobalShortcutSpec(
        keyCode: UInt32(kVK_ANSI_B),
        modifiers: UInt32(cmdKey)
    )
}
