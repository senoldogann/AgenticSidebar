import SwiftUI

/// Where one bar sits on the prompt rail.
struct PromptRailBarLayout: Equatable {
    let width: CGFloat
    let leadingOffset: CGFloat
    let opacity: Double
}

/// The rail is a map of the conversation: one bar per sent prompt, drawn in a
/// narrow column whose bars grow and drift right toward the middle, so the
/// column reads as a spindle rather than a list.
enum PromptRailMetrics {
    /// The column the bars live in, including the room they drift into.
    static let columnWidth: CGFloat = 52

    static let barHeight: CGFloat = 3

    static let barSpacing: CGFloat = 5

    /// Only the newest prompts are mapped: past this the column would run off
    /// the window, and the recent turns are the ones worth navigating.
    static let maximumBarCount = 60

    /// The bar for `index` of `count`, top to bottom.
    ///
    /// `centrality` is 1 at the exact middle of the column and 0 at either end;
    /// both the length and the horizontal drift grow with it.
    static func layout(at index: Int, of count: Int) -> PromptRailBarLayout {
        let ratio = count <= 1 ? 0.5 : Double(index) / Double(count - 1)
        let centrality = max(0, 1 - abs(ratio - 0.5) * 2)

        return PromptRailBarLayout(
            width: 12 + 18 * centrality,
            leadingOffset: 3 + 8 * centrality,
            opacity: 0.22 + 0.50 * centrality
        )
    }
}

/// Which prompt the transcript is reading: the lowest one still at or above the
/// top of the viewport, falling back to the highest measured prompt when the
/// reader has scrolled above everything that has been measured.
///
/// Rows are only measured while they are on screen, so the values are the most
/// recent positions rather than a live map of the whole conversation.
enum PromptRailSelection {
    static let readingThreshold: CGFloat = 24

    static func activeID(
        among order: [UUID],
        offsets: [UUID: CGFloat],
        threshold: CGFloat = readingThreshold
    ) -> UUID? {
        var nearestAbove: (id: UUID, offset: CGFloat)?
        var highest: (id: UUID, offset: CGFloat)?

        for id in order {
            guard let offset = offsets[id] else {
                continue
            }

            if highest == nil || offset < highest!.offset {
                highest = (id, offset)
            }

            if offset <= threshold, nearestAbove == nil || offset > nearestAbove!.offset {
                nearestAbove = (id, offset)
            }
        }

        return nearestAbove?.id ?? highest?.id
    }
}

/// One clickable bar per prompt: a jump target, and — through the highlighted
/// bar — an answer to "where am I in this conversation".
struct PromptNavigatorRail: View {
    struct Item: Identifiable, Equatable {
        let id: UUID
        let title: String
        let prompt: String
    }

    let items: [Item]
    let activeID: UUID?
    let onSelect: (UUID) -> Void

    @State private var hoveredID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: PromptRailMetrics.barSpacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                bar(for: item, at: index)
            }
        }
        .padding(.leading, 6)
        .frame(
            width: PromptRailMetrics.columnWidth,
            alignment: .leading
        )
        .frame(maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Prompt navigation")
    }

    @ViewBuilder
    private func bar(for item: Item, at index: Int) -> some View {
        let layout = PromptRailMetrics.layout(at: index, of: items.count)
        let isActive = item.id == activeID
        let isHovered = item.id == hoveredID

        Button {
            onSelect(item.id)
        } label: {
            // The rail is deliberately theme-neutral: the prompt being read is
            // the brightest bar in both appearances, and every other bar is the
            // same ink at the weight its distance from the middle earns.
            Capsule(style: .continuous)
                .fill(
                    isActive
                        ? Color.primary
                        : Color.primary.opacity(layout.opacity)
                )
                .frame(
                    width: layout.width + (isActive ? 4 : (isHovered ? 3 : 0)),
                    height: PromptRailMetrics.barHeight + (isActive ? 1 : 0)
                )
                .offset(x: layout.leadingOffset + (isHovered ? 2 : 0))
                .frame(
                    width: PromptRailMetrics.columnWidth - 6,
                    alignment: .leading
                )
                .contentShape(Rectangle())
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isHovered)
                .animation(.easeInOut(duration: 0.2), value: isActive)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(helpText(for: item, at: index))
        .accessibilityLabel("Go to prompt \(index + 1)")
        .accessibilityValue(item.title)
        .onHover { hovering in
            if hovering {
                hoveredID = item.id
            } else if hoveredID == item.id {
                hoveredID = nil
            }
        }
    }

    private func helpText(for item: Item, at index: Int) -> String {
        let body = item.prompt.isEmpty ? item.title : item.prompt
        return "Prompt \(index + 1) · \(body)"
    }
}
