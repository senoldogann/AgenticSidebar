import SwiftUI

/// A small square mark for a plugin, derived from its module name.
///
/// A plugin has no logo to fetch, and showing nothing loses the thing the
/// catalogue screen is actually about — telling modules apart at a glance. The
/// initial plus a colour picked from the name is stable, needs no network, and
/// makes the same module recognisable in the list, in the chips and after a
/// restart.
struct PluginMark: View {
    let name: String
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        tint.opacity(0.95),
                        tint.opacity(0.65)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay(
                Text(PluginMark.initials(for: name))
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
            .accessibilityLabel(name)
    }

    /// The letters: the first meaningful part of the module name, skipping the
    /// noise every OpenCode plugin shares.
    static func initials(for name: String) -> String {
        // A scope is a namespace, not the module's name: `@scope/thing` is “TH”.
        var bare = name
        if bare.hasPrefix("@"), let slash = bare.firstIndex(of: "/") {
            bare = String(bare[bare.index(after: slash)...])
        }

        let stripped = bare
            .split(whereSeparator: { $0 == "/" || $0 == "-" || $0 == "_" || $0 == "." })
            .map(String.init)
            .filter { !["opencode", "plugin", "plugins", "oc", "ai"].contains($0.lowercased()) }

        let words = stripped.isEmpty
            ? name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            : stripped

        guard let first = words.first, !first.isEmpty else {
            return "?"
        }

        if words.count >= 2, let initial = words[1].first {
            return (String(first.prefix(1)) + String(initial)).uppercased()
        }

        return String(first.prefix(2)).uppercased()
    }

    /// A stable colour from the name: the same module always gets the same one.
    private var tint: Color {
        let palette: [Color] = [
            Color(red: 0.36, green: 0.55, blue: 0.98),
            Color(red: 0.85, green: 0.42, blue: 0.36),
            Color(red: 0.30, green: 0.72, blue: 0.58),
            Color(red: 0.72, green: 0.45, blue: 0.88),
            Color(red: 0.93, green: 0.66, blue: 0.25)
        ]

        var hash = 5381
        for byte in name.utf8 {
            hash = (hash &* 33) &+ Int(byte)
        }

        return palette[abs(hash) % palette.count]
    }
}
