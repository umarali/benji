import SwiftUI
import BenjiCore

/// Benji's arrow (`BenjiArrow`), the one drawing used beside the pointer and in the notch's wing. A
/// mint face lit from the top-left over a deep-mint lower edge, with a small soft shadow; nothing
/// glows and nothing moves by itself. `solid` (Increase Contrast or Reduce Transparency) draws one
/// flat mint face with a dark outline instead, readable on any desktop.
struct BenjiArrowMark: View {
    /// The drawing's side in points (the geometry's 20 pt box scaled to it).
    var size: CGFloat = BenjiArrow.box
    var solid = false

    /// `benji-mint`, `benji-mint-deep` and the face's light end.
    static let mint = Color(red: 0x66 / 255, green: 0xd4 / 255, blue: 0xcf / 255)
    static let deepMint = Color(red: 0x08 / 255, green: 0x96 / 255, blue: 0x8e / 255)
    static let light = Color(red: 0xbd / 255, green: 0xf6 / 255, blue: 0xf1 / 255)
    /// The lower edge's dark end: deep mint taken most of the way to black.
    static let edgeDark = Color(red: 0x03 / 255, green: 0x3d / 255, blue: 0x3a / 255)

    var body: some View {
        Canvas { context, canvas in
            let k = canvas.width / BenjiArrow.box
            let face = Self.path(BenjiArrow.outline, k)
            let round = StrokeStyle(lineWidth: BenjiArrow.rounding * k, lineJoin: .round)
            if solid {
                context.fill(face, with: .color(Self.mint))
                context.stroke(face, with: .color(.black.opacity(0.9)), style: StrokeStyle(lineWidth: 1.4 * k, lineJoin: .round))
                return
            }
            let corner = CGPoint(x: canvas.width, y: canvas.height)
            // The lower edge, with the only shadow: small, close and in the arrow's own deep mint.
            var edge = context
            edge.addFilter(.shadow(color: Self.deepMint.opacity(0.35), radius: 1.2 * k, x: 0, y: 0.8 * k))
            let lower = face.offsetBy(dx: 0, dy: BenjiArrow.edgeDepth * k)
            let edgeShade = GraphicsContext.Shading.linearGradient(Gradient(colors: [Self.deepMint, Self.edgeDark]),
                                                                   startPoint: .zero, endPoint: corner)
            edge.fill(lower, with: edgeShade)
            edge.stroke(lower, with: edgeShade, style: round)
            // The face, light at the tip and deepening toward the wings.
            let faceShade = GraphicsContext.Shading.linearGradient(
                Gradient(stops: [.init(color: Self.light, location: 0), .init(color: Self.mint, location: 0.5),
                                 .init(color: Self.deepMint, location: 1)]),
                startPoint: CGPoint(x: BenjiArrow.tip.x * k, y: BenjiArrow.tip.y * k), endPoint: corner)
            context.fill(face, with: faceShade)
            context.stroke(face, with: faceShade, style: round)
            // The top facet catches the light; the lower one stays the face's own mint.
            context.fill(Self.path(BenjiArrow.topFacet, k), with: .color(Self.light.opacity(0.38)))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static func path(_ points: [CGPoint], _ k: CGFloat) -> Path {
        var p = Path()
        p.addLines(points.map { CGPoint(x: $0.x * k, y: $0.y * k) })
        p.closeSubpath()
        return p
    }
}
