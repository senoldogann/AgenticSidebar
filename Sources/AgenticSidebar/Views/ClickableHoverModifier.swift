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

/// Hover feedback for a control that paints its own background.
///
/// `InteractiveHoverPillModifier` draws a translucent plate *behind* the
/// content, which an opaque filled button hides completely — the send and stop
/// buttons showed no hover at all because of exactly that. On those the
/// highlight has to be drawn on the shape itself: the outline lifts and the
/// pointer becomes a hand, the same pair of signals the rest of the app gives.
struct InteractiveHoverOutlineModifier<Outline: Shape>: ViewModifier {
    let outline: Outline
    @State private var isHovered: Bool = false

    func body(content: Content) -> some View {
        content
            .overlay(
                outline.stroke(
                    Color.primary.opacity(isHovered ? 0.35 : 0),
                    lineWidth: 1
                )
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

/// Hover feedback for a control that sits on a dark plate.
///
/// The halo the other controls use is tinted with the label colour, which
/// disappears against the image preview's black backdrop — there it has to be
/// drawn in white.
struct InteractiveHoverHaloModifier: ViewModifier {
    @State private var isHovered: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                Color.white.opacity(isHovered ? 0.16 : 0),
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

    func interactiveHoverOutline(_ outline: some Shape) -> some View {
        modifier(InteractiveHoverOutlineModifier(outline: outline))
    }

    func interactiveHoverOutlineCircle() -> some View {
        modifier(InteractiveHoverOutlineModifier(outline: Circle()))
    }

    func interactiveHoverHalo() -> some View {
        modifier(InteractiveHoverHaloModifier())
    }

    func interactiveHoverPill(cornerRadius: CGFloat) -> some View {
        modifier(InteractiveHoverPillModifier(cornerRadius: cornerRadius))
    }

    func interactiveHoverCircle() -> some View {
        modifier(InteractiveHoverCircleModifier())
    }
}
