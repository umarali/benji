import AppKit
import BenjiCore
import SwiftUI

// The overlay's drawing (Overlay.md, Anatomy, Variants, Label, Reveal), kept free of windows,
// timers and the rest of the app so it can also be rendered offscreen (companion/tools/overlay-render).
// Everything is a function of the time `now`: the live overlay redraws only while something
// moves; at rest nothing is scheduled.

/// One mark as drawn, and when it came and went (seconds of system uptime).
struct ShownMark: Identifiable, Equatable {
    let id: Int
    /// Its place in the answer's targets.
    let index: Int
    /// Snapped to the backing pixel grid, AppKit global points.
    var mark: PointingMark
    let labelFrame: CGRect?
    let step: MarkStep
    /// While gliding: the label of the ring it glides from, fading out where it was.
    var previousLabel: String?
    var previousLabelFrame: CGRect?
    let start: Double
    var end: Double?
    /// Going because the next mark replaced it (a crossfade), not erased.
    var replaced = false
}

/// One pen mark as drawn, and when it came and went (seconds of system uptime).
struct ShownSketch: Identifiable, Equatable {
    let id: Int
    /// Its place in the drawing's parts (the answer's targets, for an answer that starts one).
    let index: Int
    /// AppKit global points.
    var sketch: Sketch
    /// Fixes its wobble, so every frame (and every render) draws the same ink.
    let seed: UInt64
    /// A note's, callout's or written words' box, in the overlay's own coordinates (origin top-left, y down).
    var noteFrame: CGRect?
    var start: Double
    var end: Double?
    /// Its draw time over the pen's: 1 except in a spoken picture fitted to its sentence (D-106) or
    /// a part paced to its sentence (chilly-whiteboard).
    var pace: Double = 1
    /// Edits (chilly-whiteboard): another colour; a move or scale gliding in from where it was
    /// (`tweenFrom` maps where it is to where it was); the pen running backwards to erase it.
    var color: InkColor?
    var tweenFrom: CGAffineTransform?
    var tweenStart: Double?
    var unwriteStart: Double?

    /// How long an edit's glide takes.
    static let tween = 0.35
    /// Erasing runs the pen backwards in this share of its drawing time.
    static let unwriteShare = 0.6
    var unwriteDuration: Double { max(SketchTimeline.drawDuration(sketch) * Self.unwriteShare, 0.2) }
}

/// Words written on the screen (TEXT, chilly-whiteboard) in Benji's handwriting: the bundled
/// Kalam, registered from the app's Resources/Fonts (or a folder the renders point at), else the
/// Mac's Noteworthy.
enum OverlayHandwriting {
    static var searchFolders: [URL] = []
    private static let registered: Void = {
        var folders = searchFolders
        if let res = Bundle.main.resourceURL { folders.append(res.appendingPathComponent("Fonts")) }
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for f in files where ["ttf", "otf"].contains(f.pathExtension.lowercased()) {
                CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
            }
        }
    }()

    static func font(_ size: TextSize) -> NSFont {
        _ = registered
        return NSFont(name: "Kalam-Bold", size: size.points) ?? NSFont(name: "Noteworthy-Bold", size: size.points)
            ?? .systemFont(ofSize: size.points, weight: .semibold)
    }

    static func size(_ text: String, _ size: TextSize) -> CGSize {
        let s = (text as NSString).size(withAttributes: [.font: font(size)])
        return CGSize(width: ceil(s.width) + 8, height: ceil(s.height) + 4)
    }
}

/// The board behind a drawing on busy space (chilly-whiteboard): Benji's black card with a
/// faint grid, as the explanation card's board is drawn.
enum OverlayBoard {
    static let fill = Color(nsColor: NSColor(srgbRed: 0x0b / 255.0, green: 0x0c / 255.0, blue: 0x0d / 255.0, alpha: 1))
    static let grid: CGFloat = 22
    static let gridLine = Color.white.opacity(0.045)
    static let radius: CGFloat = 14
}

extension InkColor {
    var swiftUI: Color { let (r, g, b) = rgb; return Color(nsColor: NSColor(srgbRed: r, green: g, blue: b, alpha: 1)) }
}

enum OverlayNoteMetrics {
    static let font: NSFont = {
        let base = NSFont.systemFont(ofSize: 15, weight: .semibold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 15) } ?? base
    }()

    static func size(_ text: String) -> CGSize {
        let s = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(s.width) + 20, height: ceil(s.height) + 10)
    }

    /// A callout's pill: the same words, with room for its round ends.
    static func calloutSize(_ text: String) -> CGSize {
        let s = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(s.width) + 28, height: ceil(s.height) + 12)
    }
}

/// What the HUD material blurs. Live: the real screen through `NSVisualEffectView`. Offscreen
/// renders can't draw that, so they stand in with the picture underneath, blurred as the
/// design preview does (band: 6 pt blur, 0.7 saturation; label: 20 pt blur, 1.8 saturation,
/// rgba(28, 28, 30, 0.72) on top).
enum OverlayBackdrop {
    case live
    case picture(Image)
}

enum OverlayColors {
    /// `benji-mint`: the dark-appearance systemMint, fixed in both appearances.
    static let mint = Color(nsColor: NSColor(srgbRed: 102 / 255, green: 212 / 255, blue: 207 / 255, alpha: 1))
    static let notchRaised = Color(nsColor: NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1))
    static let hairline = Color.white.opacity(0.12)          // notch-hairline
    static let labelSecondary = Color.white.opacity(0.55)    // notch-label-secondary

    static func keyline(_ k: MarkLayers.Keyline) -> Color {
        switch k {
        case .black60: return .black.opacity(0.6)
        case .black: return .black
        case .notchRaised: return notchRaised
        }
    }
}

enum OverlayLabelMetrics {
    static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)   // `callout` semibold

    /// The label pill padded 4 × 10 pt; capped at 240 pt by the layout, which truncates the text.
    static func size(_ text: String) -> CGSize {
        let s = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(s.width) + 20, height: ceil(s.height) + 8)
    }
}

/// Every mark on one display at the moment `now`.
struct OverlayFrame: View {
    let marks: [ShownMark]
    var sketches: [ShownSketch] = []
    let screenFrame: CGRect
    let appearance: OverlayAppearance
    let now: Double
    let backdrop: OverlayBackdrop
    /// The drawing's board (AppKit global points), when it sits on one; and when it came.
    var board: CGRect? = nil
    var boardStart: Double = 0

    private struct Resolved {
        let shown: ShownMark
        let phase: MarkPhase
        let layers: MarkLayers
        let geometry: Geometry
    }

    /// A mark in this view's coordinates (origin top-left of the display, y down).
    enum Geometry {
        case ring(CGPoint)
        case region(CGRect)

        /// The layer `distance` from the target: a circle of that radius, or the box outset by it
        /// with concentric corners; both start at the top centre and run clockwise.
        func path(at distance: CGFloat) -> Path {
            switch self {
            case let .ring(c):
                var p = Path()
                p.addArc(center: c, radius: distance, startAngle: .degrees(-90), endAngle: .degrees(270), clockwise: false)
                return p
            case let .region(r):
                let b = r.insetBy(dx: -distance, dy: -distance)
                let k = min(MarkLayers.cornerRadius(atOutset: distance), b.width / 2, b.height / 2)
                var p = Path()
                p.move(to: CGPoint(x: b.midX, y: b.minY))
                p.addArc(tangent1End: CGPoint(x: b.maxX, y: b.minY), tangent2End: CGPoint(x: b.maxX, y: b.maxY), radius: k)
                p.addArc(tangent1End: CGPoint(x: b.maxX, y: b.maxY), tangent2End: CGPoint(x: b.minX, y: b.maxY), radius: k)
                p.addArc(tangent1End: CGPoint(x: b.minX, y: b.maxY), tangent2End: CGPoint(x: b.minX, y: b.minY), radius: k)
                p.addArc(tangent1End: CGPoint(x: b.minX, y: b.minY), tangent2End: CGPoint(x: b.maxX, y: b.minY), radius: k)
                p.closeSubpath()
                return p
            }
        }

        /// The ring of screen between two distances (for the material band), even-odd filled.
        func band(_ band: MarkBand) -> Path {
            var p = path(at: band.outer)
            p.addPath(path(at: band.inner))
            return p
        }
    }

    private func local(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - screenFrame.minX, y: screenFrame.maxY - p.y)
    }
    private func local(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX - screenFrame.minX, y: screenFrame.maxY - r.maxY, width: r.width, height: r.height)
    }

    private var resolved: [Resolved] {
        marks.map { m in
            let rm = appearance.reduceMotion
            var phase = MarkTimeline.phase(kind: m.mark.kind, step: m.step, reduceMotion: rm, at: now - m.start)
            if let end = m.end {
                phase.opacity *= m.replaced ? MarkTimeline.replacedOpacity(at: now - end, reduceMotion: rm)
                                            : MarkTimeline.eraseOpacity(at: now - end)
            }
            let geometry: Geometry
            switch m.mark {
            case let .ring(center, _):
                var c = center
                if case let .glide(from) = m.step {
                    c = CGPoint(x: from.x + (center.x - from.x) * phase.travel, y: from.y + (center.y - from.y) * phase.travel)
                }
                geometry = .ring(local(c))
            case let .region(rect, _):
                geometry = .region(local(rect))
            }
            return Resolved(shown: m, phase: phase, layers: MarkLayers.of(m.mark.kind, appearance), geometry: geometry)
        }
    }

    var body: some View {
        let items = resolved
        ZStack(alignment: .topLeading) {
            if let board {
                boardView(local(board)).opacity(appearance.reduceMotion ? 1 : MotionTokens.fadeIn.value(at: (now - boardStart) / MotionTokens.fadeDuration))
            }
            // Material band under each halo: calms busy content right around the mark, never inside it.
            ForEach(items, id: \.shown.id) { item in
                if let halo = item.layers.halo {
                    material(shape: item.geometry.band(halo), blur: 6, saturation: 0.7)
                        .opacity(item.phase.halo * item.phase.opacity)
                }
            }
            Canvas { context, _ in
                for item in items { draw(item, in: &context) }
            }
            SketchLayer(sketches: sketches, screenFrame: screenFrame, appearance: appearance, now: now)
            ForEach(items, id: \.shown.id) { item in
                if let text = item.shown.previousLabel, let frame = item.shown.previousLabelFrame {
                    label(text, frame: local(frame), background: item.layers.labelBackground)
                        .opacity(item.phase.previousLabel * item.phase.opacity)
                }
                if let frame = item.shown.labelFrame {
                    label(item.shown.mark.label, frame: local(frame), background: item.layers.labelBackground)
                        .opacity(item.phase.label * item.phase.opacity)
                }
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The board: the black card, its faint grid inside the corners, a hairline edge.
    private func boardView(_ r: CGRect) -> some View {
        Canvas { context, _ in
            let card = Path(roundedRect: r, cornerRadius: OverlayBoard.radius, style: .continuous)
            context.fill(card, with: .color(OverlayBoard.fill))
            var grid = Path()
            var x = r.minX + OverlayBoard.grid
            while x < r.maxX { grid.addRect(CGRect(x: x, y: r.minY, width: 1, height: r.height)); x += OverlayBoard.grid }
            var y = r.minY + OverlayBoard.grid
            while y < r.maxY { grid.addRect(CGRect(x: r.minX, y: y, width: r.width, height: 1)); y += OverlayBoard.grid }
            context.drawLayer { layer in
                layer.clip(to: card)
                layer.fill(grid, with: .color(OverlayBoard.gridLine))
            }
            context.stroke(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: OverlayBoard.radius - 0.5, style: .continuous),
                           with: .color(OverlayColors.hairline), lineWidth: 1)
        }
    }

    /// Inside out: halo, the one pulse, keylines and the mint stroke (drawn together). The
    /// interior is never filled.
    private func draw(_ item: Resolved, in context: inout GraphicsContext) {
        let p = item.phase, l = item.layers, g = item.geometry
        guard p.opacity > 0.001 else { return }
        context.opacity = p.opacity
        if let halo = l.halo {
            context.stroke(g.path(at: halo.middle), with: .color(OverlayColors.mint.opacity(MarkTimeline.haloOpacity * p.halo)),
                           lineWidth: halo.width)
            if let q = p.pulse {
                context.stroke(g.path(at: halo.middle + MarkTimeline.pulseGrow * q),
                               with: .color(OverlayColors.mint.opacity(MarkTimeline.haloOpacity * Double(1 - q))),
                               lineWidth: halo.width)
            }
        }
        guard p.draw > 0.001 else { return }
        func stroke(_ band: MarkBand, _ color: Color) {
            let path = p.draw >= 1 ? g.path(at: band.middle) : g.path(at: band.middle).trimmedPath(from: 0, to: p.draw)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: band.width, lineCap: .butt))
        }
        stroke(l.innerKeyline, OverlayColors.keyline(l.keyline))
        stroke(l.outerKeyline, OverlayColors.keyline(l.keyline))
        stroke(l.mint, OverlayColors.mint)
    }

    private func label(_ text: String, frame f: CGRect, background: MarkLayers.LabelBackground) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(width: f.width, height: f.height)
            .background { labelBackground(background, frame: f) }
            .environment(\.colorScheme, .dark)
            .position(x: f.midX, y: f.midY)
    }

    @ViewBuilder
    private func labelBackground(_ kind: MarkLayers.LabelBackground, frame f: CGRect) -> some View {
        switch kind {
        case .material:
            ZStack {
                labelMaterial(frame: f)
                Capsule().strokeBorder(OverlayColors.hairline, lineWidth: 1)
            }
        case .opaqueBordered:
            Capsule().fill(OverlayColors.notchRaised)
                .overlay(Capsule().strokeBorder(OverlayColors.labelSecondary, lineWidth: 1))
        case .opaque:
            Capsule().fill(OverlayColors.notchRaised)
                .overlay(Capsule().strokeBorder(OverlayColors.hairline, lineWidth: 1))
        }
    }

    /// HUD material in the dark appearance, limited to `shape` (this view's coordinates).
    @ViewBuilder
    private func material(shape: Path, blur: CGFloat, saturation: Double) -> some View {
        let box = shape.boundingRect
        switch backdrop {
        case .live:
            HUDMaterial(mask: shape.offsetBy(dx: -box.minX, dy: -box.minY))
                .frame(width: box.width, height: box.height)
                .position(x: box.midX, y: box.midY)
        case let .picture(image):
            image.resizable()
                .frame(width: screenFrame.width, height: screenFrame.height)
                .blur(radius: blur)
                .saturation(saturation)
                .mask(shape.fill(style: FillStyle(eoFill: true)))
        }
    }

    /// The label's capsule of HUD material; `f` in this view's coordinates.
    @ViewBuilder
    private func labelMaterial(frame f: CGRect) -> some View {
        switch backdrop {
        case .live:
            HUDMaterial(mask: Path(roundedRect: CGRect(origin: .zero, size: f.size), cornerRadius: f.height / 2,
                                   style: .continuous))
        case let .picture(image):
            ZStack(alignment: .topLeading) {
                image.resizable()
                    .frame(width: screenFrame.width, height: screenFrame.height)
                    .blur(radius: 20)
                    .saturation(1.8)
                Color(white: 28 / 255).opacity(0.72)
            }
            .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
            .offset(x: -f.minX, y: -f.minY)
            .frame(width: f.width, height: f.height, alignment: .topLeading)
            .clipShape(Capsule())
        }
    }
}

private extension Path {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> Path {
        applying(CGAffineTransform(translationX: dx, y: dy))
    }
}

/// `NSVisualEffectView` with the HUD material, dark, blending what's behind the window, cut
/// to a shape by its mask image.
struct HUDMaterial: NSViewRepresentable {
    let mask: Path   // in the view's own coordinates (origin top-left)

    final class Coordinator { var lastMask: Path? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        guard context.coordinator.lastMask != mask else { return }
        context.coordinator.lastMask = mask
        let size = mask.boundingRect.size
        let cgPath = mask.cgPath
        v.maskImage = NSImage(size: CGSize(width: max(size.width, 1), height: max(size.height, 1)), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(cgPath)
            ctx.setFillColor(.black)
            ctx.fillPath(using: .evenOdd)
            return true
        }
    }
}

/// Benji's pen marks at the moment `now` (Sketching.swift has the ink; this only paints it).
/// Each line is a dark edge with the mint on top, so it reads on any background; a highlight is
/// a translucent mint band with a faint edge; a note is a dot and its words, written in; a
/// callout is a short pen arrow to its target, then its words in a pill.
struct SketchLayer: View {
    let sketches: [ShownSketch]
    let screenFrame: CGRect
    let appearance: OverlayAppearance
    let now: Double

    private struct Resolved {
        let shown: ShownSketch
        let local: Sketch
        let draw: CGFloat
        let opacity: Double
    }

    private var resolved: [Resolved] {
        sketches.compactMap { s in
            let rm = appearance.reduceMotion
            var phase = SketchTimeline.phase(s.sketch, reduceMotion: rm, at: (now - s.start) / s.pace)
            if let u = s.unwriteStart {
                // Erased by an edit: the pen runs backwards (a fade under Reduce Motion).
                let f = (now - u) / s.unwriteDuration
                if rm { phase.opacity *= 1 - MotionTokens.reduceCurve.value(at: f) } else {
                    phase.draw = min(phase.draw, CGFloat(1 - TimingCurve.easeInOut.value(at: f)))
                }
                if f >= 1 { return nil }
            } else if let end = s.end {
                phase.opacity *= MarkTimeline.eraseOpacity(at: now - end)
            }
            guard phase.opacity > 0.001 else { return nil }
            var sketch = s.sketch
            if let back = s.tweenFrom, let t0 = s.tweenStart, now - t0 < ShownSketch.tween, !rm {
                // Glides from where it was (a move or scale edit).
                let e = CGFloat(TimingCurve.easeInOut.value(at: (now - t0) / ShownSketch.tween))
                sketch = sketch.converted { p in
                    let q = p.applying(back)
                    return CGPoint(x: q.x + (p.x - q.x) * e, y: q.y + (p.y - q.y) * e)
                }
            }
            let local = sketch.converted { CGPoint(x: $0.x - screenFrame.minX, y: screenFrame.maxY - $0.y) }
            return Resolved(shown: s, local: local, draw: phase.draw, opacity: phase.opacity)
        }
    }

    var body: some View {
        let items = resolved
        let style = PenStyle.of(appearance)
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for item in items { ink(item, style: style, in: &context) }
            }
            ForEach(items, id: \.shown.id) { item in
                if case let .note(_, text) = item.local, let f = item.shown.noteFrame {
                    note(text, frame: f, draw: item.draw).opacity(item.opacity)
                }
                if case let .callout(_, text) = item.local, let f = item.shown.noteFrame {
                    callout(text, frame: f, draw: Self.calloutWords(item.draw)).opacity(item.opacity)
                }
                if case let .text(p, words, size) = item.local, let f = item.shown.noteFrame {
                    written(words, size: size, frame: glided(f, to: p, from: item.shown), draw: item.draw,
                            ink: item.shown.color?.swiftUI ?? OverlayColors.mint).opacity(item.opacity)
                }
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func polygon(_ points: [CGPoint]) -> Path {
        var p = Path()
        p.addLines(points)
        p.closeSubpath()
        return p
    }

    private func ink(_ item: Resolved, style: PenStyle, in context: inout GraphicsContext) {
        context.opacity = item.opacity
        let edge = Color.black.opacity(style.edgeOpacity)
        if case let .note(p, _) = item.local {
            // The pen touches down where the note belongs.
            let r: CGFloat = 3.5
            context.fill(Path(ellipseIn: CGRect(x: p.x - r - style.edge, y: p.y - r - style.edge,
                                                width: 2 * (r + style.edge), height: 2 * (r + style.edge))),
                         with: .color(.black.opacity(style.edgeOpacity)))
            context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(OverlayColors.mint))
            return
        }
        let strokes: [PenStroke]
        if case let .callout(p, _) = item.local {
            guard let f = item.shown.noteFrame else { return }
            strokes = PenGeometry.revealed(PenGeometry.calloutStrokes(from: f, to: p, seed: item.shown.seed, style: style),
                                           progress: Self.calloutPointer(item.draw))
        } else {
            strokes = PenGeometry.revealed(PenGeometry.strokes(for: item.local, seed: item.shown.seed, style: style),
                                           progress: item.draw)
        }
        if case .highlight = item.local {
            for s in strokes {
                let band = polygon(s.outline())
                context.fill(band, with: .color(OverlayColors.mint.opacity(style.highlightOpacity)))
                context.stroke(band, with: .color(.black.opacity(style.edgeOpacity * 0.5)), lineWidth: 1)
            }
            return
        }
        for s in strokes { context.fill(polygon(s.outline(grow: style.edge)), with: .color(edge)) }
        let ink = item.shown.color?.swiftUI ?? OverlayColors.mint
        for s in strokes { context.fill(polygon(s.outline()), with: .color(ink)) }
    }

    /// A written part's box follows its point while it glides (a move edit): the box was laid out
    /// at the final point, and `p` is where the point is drawn this frame (view coordinates).
    private func glided(_ f: CGRect, to p: CGPoint, from shown: ShownSketch) -> CGRect {
        guard shown.tweenStart != nil, case let .text(final, _, _) = shown.sketch else { return f }
        let at = CGPoint(x: final.x - screenFrame.minX, y: screenFrame.maxY - final.y)
        return f.offsetBy(dx: p.x - at.x, dy: p.y - at.y)
    }

    /// Words written on the screen in Benji's hand, in the pen's ink with a dark edge so they read
    /// on any background, written in from the left as the pen moves (chilly-whiteboard).
    private func written(_ text: String, size: TextSize, frame f: CGRect, draw: CGFloat, ink: Color) -> some View {
        Text(text)
            .font(Font(OverlayHandwriting.font(size)))
            .foregroundStyle(ink)
            .lineLimit(1)
            .fixedSize()
            .shadow(color: .black.opacity(0.75), radius: 0, x: 1, y: 1)
            .shadow(color: .black.opacity(0.55), radius: 1.5)
            .frame(width: f.width, height: f.height, alignment: .leading)
            .mask(alignment: .leading) { Rectangle().frame(width: f.width * draw) }
            .position(x: f.midX, y: f.midY)
    }

    /// A callout's pointer is drawn over the first 40% of its time; its words come in after.
    static func calloutPointer(_ draw: CGFloat) -> CGFloat { min(draw / 0.4, 1) }
    static func calloutWords(_ draw: CGFloat) -> CGFloat { min(max((draw - 0.3) / 0.7, 0), 1) }

    /// A callout's words: the note's mint on a dark pill with a mint rim, so it reads as a
    /// label that belongs to the pen's pointer.
    private func callout(_ text: String, frame f: CGRect, draw: CGFloat) -> some View {
        let solid = appearance.increaseContrast || appearance.reduceTransparency
        return Text(text)
            .font(Font(OverlayNoteMetrics.font))
            .foregroundStyle(OverlayColors.mint)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: f.width, height: f.height)
            .background {
                Capsule(style: .continuous)
                    .fill(OverlayColors.notchRaised.opacity(solid ? 1 : 0.9))
                    .overlay(Capsule(style: .continuous)
                        .strokeBorder(OverlayColors.mint.opacity(appearance.increaseContrast ? 1 : 0.75), lineWidth: 1.5))
            }
            .mask(alignment: .leading) { Rectangle().frame(width: f.width * draw) }
            .position(x: f.midX, y: f.midY)
    }

    /// The note's words in rounded semibold mint on a dark chip, so they read on any
    /// background, written in from the left as the pen moves. Increase Contrast and Reduce
    /// Transparency make the chip opaque; Increase Contrast adds a lighter border.
    private func note(_ text: String, frame f: CGRect, draw: CGFloat) -> some View {
        let solid = appearance.increaseContrast || appearance.reduceTransparency
        return Text(text)
            .font(Font(OverlayNoteMetrics.font))
            .foregroundStyle(OverlayColors.mint)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: f.width, height: f.height)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(OverlayColors.notchRaised.opacity(solid ? 1 : 0.86))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(appearance.increaseContrast ? OverlayColors.labelSecondary : OverlayColors.hairline))
            }
            .mask(alignment: .leading) { Rectangle().frame(width: f.width * draw) }
            .position(x: f.midX, y: f.midY)
    }
}
