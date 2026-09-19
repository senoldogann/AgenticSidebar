import SwiftUI

/// Which mark to draw for a provider.
///
/// Recognised from the identifier the provider reports, so a new model on a known
/// provider needs no change here, and an unknown provider still gets something
/// honest (its own initial) rather than nothing.
enum ProviderLogo: Equatable, Sendable {
    case openAI
    case anthropic
    case google
    case openCode
    case xAI
    case generic(String)

    static func matching(_ identifier: String) -> ProviderLogo {
        let lowered = identifier.lowercased()

        if lowered.contains("openai") || lowered.contains("gpt")
            || lowered.contains("codex") || lowered.contains("o1") || lowered.contains("o3")
        {
            return .openAI
        }
        if lowered.contains("anthropic") || lowered.contains("claude") || lowered.contains("sonnet")
            || lowered.contains("opus") || lowered.contains("haiku")
        {
            return .anthropic
        }
        if lowered.contains("google") || lowered.contains("gemini") || lowered.contains("gemma") {
            return .google
        }
        if lowered.contains("opencode") {
            return .openCode
        }
        if lowered.hasPrefix("xai") || lowered.contains("grok") {
            return .xAI
        }

        let initial =
            identifier
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .first
            .map { String($0.prefix(2)).uppercased() } ?? "?"

        return .generic(initial)
    }

    var accessibilityName: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .google: "Google"
        case .openCode: "OpenCode"
        case .xAI: "xAI"
        case .generic(let initial): initial
        }
    }
}

/// Provider logos as vector paths.
///
/// Drawn rather than shipped as images: the app has no asset catalogue for
/// bitmaps, and a `Path` stays sharp in the model menu, in Settings and on a
/// Retina display without a second file to keep in step. The marks are stylised
/// readings of each provider's identity, not the trademarked artwork.
struct ProviderLogoView: View {
    let logo: ProviderLogo
    var size: CGFloat = 16
    var tint: Color?

    var body: some View {
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            let ink = tint ?? Color.primary
            let lineWidth = max(1, canvasSize.width * 0.085)

            switch logo {
            case .openAI:
                drawRosette(in: &context, rect: rect, ink: ink, lineWidth: lineWidth)
            case .anthropic:
                drawSunburst(in: &context, rect: rect, ink: ink)
            case .google:
                drawSparkle(in: &context, rect: rect, ink: ink)
            case .openCode:
                drawBlock(in: &context, rect: rect, ink: ink, lineWidth: lineWidth)
            case .xAI:
                drawCross(in: &context, rect: rect, ink: ink, lineWidth: lineWidth * 1.2)
            case .generic:
                break
            }
        }
        .overlay {
            if case .generic(let initial) = logo {
                Text(initial)
                    .font(.system(size: size * 0.52, weight: .bold, design: .rounded))
                    .foregroundStyle(tint ?? .secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(logo.accessibilityName)
    }

    /// Six petals around a centre: the shape the OpenAI knot reads as at small
    /// sizes, without pretending to be the exact curve.
    private func drawRosette(
        in context: inout GraphicsContext,
        rect: CGRect,
        ink: Color,
        lineWidth: CGFloat
    ) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width * 0.30
        let petalLength = rect.width * 0.44
        let petalWidth = rect.width * 0.20

        for index in 0..<6 {
            let angle = Double(index) * .pi / 3
            var petal = Path()
            petal.addRoundedRect(
                in: CGRect(
                    x: -petalWidth / 2,
                    y: -petalLength / 2,
                    width: petalWidth,
                    height: petalLength
                ),
                cornerSize: CGSize(width: petalWidth / 2, height: petalWidth / 2)
            )

            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: angle)
                .translatedBy(x: 0, y: -radius)
            petal = petal.applying(transform)

            context.stroke(petal, with: .color(ink), lineWidth: lineWidth)
        }
    }

    /// The Claude mark: a burst of tapered rays.
    private func drawSunburst(
        in context: inout GraphicsContext,
        rect: CGRect,
        ink: Color
    ) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let inner = rect.width * 0.12
        let outer = rect.width * 0.46
        let halfWidth = rect.width * 0.075

        for index in 0..<10 {
            let angle = Double(index) * .pi / 5
            let tip = CGPoint(
                x: center.x + outer * cos(angle),
                y: center.y + outer * sin(angle)
            )
            let perpendicular = CGPoint(x: -sin(angle), y: cos(angle))
            let base = CGPoint(
                x: center.x + inner * cos(angle),
                y: center.y + inner * sin(angle)
            )

            var ray = Path()
            ray.move(to: tip)
            ray.addLine(
                to: CGPoint(
                    x: base.x + perpendicular.x * halfWidth,
                    y: base.y + perpendicular.y * halfWidth
                )
            )
            ray.addLine(
                to: CGPoint(
                    x: base.x - perpendicular.x * halfWidth,
                    y: base.y - perpendicular.y * halfWidth
                )
            )
            ray.closeSubpath()
            context.fill(ray, with: .color(ink))
        }

        let coreRadius = rect.width * 0.10
        context.fill(
            Path(
                ellipseIn: CGRect(
                    x: center.x - coreRadius,
                    y: center.y - coreRadius,
                    width: coreRadius * 2,
                    height: coreRadius * 2
                )
            ),
            with: .color(ink)
        )
    }

    /// The four-point sparkle used by Gemini.
    private func drawSparkle(
        in context: inout GraphicsContext,
        rect: CGRect,
        ink: Color
    ) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width * 0.46
        let waist = rect.width * 0.075

        var sparkle = Path()
        sparkle.move(to: CGPoint(x: center.x, y: center.y - radius))
        sparkle.addQuadCurve(
            to: CGPoint(x: center.x + radius, y: center.y),
            control: CGPoint(x: center.x + waist, y: center.y - waist)
        )
        sparkle.addQuadCurve(
            to: CGPoint(x: center.x, y: center.y + radius),
            control: CGPoint(x: center.x + waist, y: center.y + waist)
        )
        sparkle.addQuadCurve(
            to: CGPoint(x: center.x - radius, y: center.y),
            control: CGPoint(x: center.x - waist, y: center.y + waist)
        )
        sparkle.addQuadCurve(
            to: CGPoint(x: center.x, y: center.y - radius),
            control: CGPoint(x: center.x - waist, y: center.y - waist)
        )
        sparkle.closeSubpath()

        context.fill(sparkle, with: .color(ink))
    }

    /// OpenCode: a squared block with a corner cut out.
    private func drawBlock(
        in context: inout GraphicsContext,
        rect: CGRect,
        ink: Color,
        lineWidth: CGFloat
    ) {
        let inset = rect.width * 0.10
        let side = rect.width - inset * 2

        let outline = Path(
            roundedRect: CGRect(x: inset, y: inset, width: side, height: side),
            cornerRadius: rect.width * 0.16,
            style: .continuous
        )
        context.stroke(outline, with: .color(ink), lineWidth: lineWidth)

        let notch = Path(
            roundedRect: CGRect(
                x: rect.midX - rect.width * 0.04,
                y: rect.midY - rect.width * 0.26,
                width: rect.width * 0.30,
                height: rect.width * 0.30
            ),
            cornerRadius: rect.width * 0.07,
            style: .continuous
        )
        context.fill(notch, with: .color(ink))
    }

    /// xAI: a crossed slash.
    private func drawCross(
        in context: inout GraphicsContext,
        rect: CGRect,
        ink: Color,
        lineWidth: CGFloat
    ) {
        let start = rect.width * 0.16
        let end = rect.width - start

        var first = Path()
        first.move(to: CGPoint(x: start, y: end))
        first.addLine(to: CGPoint(x: end, y: start))
        context.stroke(
            first,
            with: .color(ink),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        )

        var second = Path()
        second.move(to: CGPoint(x: rect.width * 0.62, y: rect.height * 0.62))
        second.addLine(to: CGPoint(x: rect.width * 0.84, y: rect.height * 0.84))
        context.stroke(
            second,
            with: .color(ink),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        )
    }
}
