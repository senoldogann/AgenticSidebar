import AppKit
import SwiftUI

struct PointingHandModifier: ViewModifier {
    @State private var isHovering: Bool = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering && !isHovering {
                    isHovering = true
                    NSCursor.pointingHand.push()
                } else if !hovering && isHovering {
                    isHovering = false
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering {
                    isHovering = false
                    NSCursor.pop()
                }
            }
    }
}

struct InteractiveHoverPillModifier: ViewModifier {
    let cornerRadius: CGFloat
    @State private var isHovered: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                isHovered ? Color.primary.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .onHover { hovering in
                if hovering && !isHovered {
                    isHovered = true
                    NSCursor.pointingHand.push()
                } else if !hovering && isHovered {
                    isHovered = false
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovered {
                    isHovered = false
                    NSCursor.pop()
                }
            }
    }
}

struct InteractiveHoverCircleModifier: ViewModifier {
    @State private var isHovered: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                Color.primary.opacity(isHovered ? 0.10 : 0.03),
                in: Circle()
            )
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .onHover { hovering in
                if hovering && !isHovered {
                    isHovered = true
                    NSCursor.pointingHand.push()
                } else if !hovering && isHovered {
                    isHovered = false
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovered {
                    isHovered = false
                    NSCursor.pop()
                }
            }
    }
}

extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandModifier())
    }

    func interactiveHoverPill(cornerRadius: CGFloat) -> some View {
        modifier(InteractiveHoverPillModifier(cornerRadius: cornerRadius))
    }

    func interactiveHoverCircle() -> some View {
        modifier(InteractiveHoverCircleModifier())
    }
}
