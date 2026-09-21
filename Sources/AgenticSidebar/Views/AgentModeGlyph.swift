import SwiftUI

/// The mark for the agent mode control.
///
/// Plan is drawn as vector paths — a sheet with ticked steps — so the mode reads
/// as a document before it is selected, which is what the mode actually produces.
/// Build has no drawn mark; it keeps the system symbol, which is already legible
/// at this size.
struct AgentModeGlyph: View {
    let mode: AgentMode
    var size: CGFloat = 11
    var tint: Color = .secondary

    var body: some View {
        switch mode {
        case .plan:
            Canvas { context, canvasSize in
                drawPlan(in: &context, size: canvasSize)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        case .build, .review, .exam, .ask:
            Image(systemName: mode.symbolName)
                .font(.system(size: size * 0.95, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    /// A sheet whose steps are ticked off: the plan a turn in this mode returns.
    private func drawPlan(in context: inout GraphicsContext, size: CGSize) {
        let lineWidth = max(1, size.width * 0.085)
        let inset = size.width * 0.12
        let sheet = CGRect(
            x: inset,
            y: inset,
            width: size.width - inset * 2,
            height: size.height - inset * 2
        )

        context.stroke(
            Path(
                roundedRect: sheet,
                cornerRadius: size.width * 0.14,
                style: .continuous
            ),
            with: .color(tint),
            lineWidth: lineWidth
        )

        let rowHeight = sheet.height / 4
        for row in 0..<3 {
            let centerY = sheet.minY + rowHeight * (CGFloat(row) + 0.5)

            // The tick box, and the step it belongs to.
            let boxSide = sheet.width * 0.20
            let box = CGRect(
                x: sheet.minX + sheet.width * 0.16,
                y: centerY - boxSide / 2,
                width: boxSide,
                height: boxSide
            )
            context.stroke(
                Path(
                    roundedRect: box,
                    cornerRadius: boxSide * 0.22,
                    style: .continuous
                ),
                with: .color(tint),
                lineWidth: lineWidth
            )

            if row == 0 {
                // The first step is the one already done: a tick in its box.
                var tick = Path()
                tick.move(
                    to: CGPoint(x: box.minX + box.width * 0.22, y: box.midY)
                )
                tick.addLine(
                    to: CGPoint(x: box.midX - box.width * 0.04, y: box.maxY - box.height * 0.22)
                )
                tick.addLine(
                    to: CGPoint(x: box.maxX - box.width * 0.18, y: box.minY + box.height * 0.24)
                )
                context.stroke(
                    tick,
                    with: .color(tint),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
            }

            var step = Path()
            step.move(
                to: CGPoint(x: box.maxX + sheet.width * 0.10, y: centerY)
            )
            step.addLine(
                to: CGPoint(x: sheet.maxX - sheet.width * 0.12, y: centerY)
            )
            context.stroke(
                step,
                with: .color(tint),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
        }
    }
}
