import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Benji's pen marks (circle, arrow, underline, highlight, path, polyline, oval, dashed group,
// note, callout): their geometry, the
// hand-drawn stroke, and the pen reveal as functions of time. Our own design (D-56): a mint
// pen with a dark edge, a light deterministic wobble and a pressure taper, drawn at a steady
// pen speed from the moment the answer's words reach the mark. Nothing here depends on a
// clock or a window, so the live overlay and the offscreen renders draw the same frames.

extension Sketch {
    /// The same sketch with every point mapped by `f` (e.g. from AppKit global points to a
    /// view's y-down coordinates). Rectangles map by their corners and are put right again.
    public func converted(_ f: (CGPoint) -> CGPoint) -> Sketch {
        func rect(_ r: CGRect) -> CGRect {
            let a = f(CGPoint(x: r.minX, y: r.minY)), b = f(CGPoint(x: r.maxX, y: r.maxY))
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        }
        switch self {
        case let .circle(r, l): return .circle(rect: rect(r), label: l)
        case let .arrow(a, b, l): return .arrow(from: f(a), to: f(b), label: l)
        case let .underline(a, b, l): return .underline(from: f(a), to: f(b), label: l)
        case let .highlight(r, l): return .highlight(rect: rect(r), label: l)
        case let .path(p, l): return .path(points: p.map(f), label: l)
        case let .polyline(p, c, l): return .polyline(points: p.map(f), closed: c, label: l)
        case let .oval(r, l): return .oval(rect: rect(r), label: l)
        case let .group(r, l): return .group(rect: rect(r), label: l)
        case let .note(p, t): return .note(at: f(p), text: t)
        case let .callout(p, t): return .callout(at: f(p), text: t)
        case let .text(p, t, size): return .text(at: f(p), text: t, size: size)
        }
    }

    /// What the sketch covers, before its pen width (a note's or callout's text box is laid out
    /// apart).
    public var bounds: CGRect {
        func box(_ p: [CGPoint]) -> CGRect {
            let xs = p.map(\.x), ys = p.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        switch self {
        case let .circle(r, _):
            let (a, b) = PenGeometry.loopRadii(r)
            let grow = 1 + PenGeometry.loopSwell
            return CGRect(x: r.midX - a * grow, y: r.midY - b * grow, width: 2 * a * grow, height: 2 * b * grow)
        case let .highlight(r, _), let .oval(r, _): return r
        case let .group(r, _): return r.insetBy(dx: -PenGeometry.groupPad, dy: -PenGeometry.groupPad)
        case let .arrow(a, b, _), let .underline(a, b, _): return box([a, b])
        case let .path(p, _), let .polyline(p, _, _): return box(p)
        case let .note(p, _), let .callout(p, _), let .text(p, _, _): return CGRect(origin: p, size: .zero)
        }
    }

    /// Where a click erases it: what it covers, plus a finger's width.
    public var hitArea: CGRect { bounds.insetBy(dx: -8, dy: -8) }
}

/// One line of ink: points along it and the pen's width at each.
public struct PenStroke: Equatable, Sendable {
    public var points: [CGPoint]
    public var widths: [CGFloat]
    /// Arc length at each point, from 0.
    public var distances: [CGFloat]

    public init(points: [CGPoint], widths: [CGFloat]) {
        self.points = points
        self.widths = widths
        var d: [CGFloat] = [0]
        for (a, b) in zip(points, points.dropFirst()) { d.append(d.last! + hypot(b.x - a.x, b.y - a.y)) }
        distances = d
    }

    public var length: CGFloat { distances.last ?? 0 }

    /// The point at arc length `d` along the stroke.
    public func point(at d: CGFloat) -> CGPoint {
        trimmed(to: d).points.last ?? .zero
    }

    /// The stroke cut at arc length `upTo`, the last point interpolated.
    public func trimmed(to upTo: CGFloat) -> PenStroke {
        guard upTo < length else { return self }
        guard upTo > 0, points.count > 1 else { return PenStroke(points: Array(points.prefix(1)), widths: Array(widths.prefix(1))) }
        let i = distances.firstIndex { $0 >= upTo }!
        let span = distances[i] - distances[i - 1]
        let f = span > 0 ? (upTo - distances[i - 1]) / span : 0
        let p = CGPoint(x: points[i - 1].x + (points[i].x - points[i - 1].x) * f,
                        y: points[i - 1].y + (points[i].y - points[i - 1].y) * f)
        let w = widths[i - 1] + (widths[i] - widths[i - 1]) * f
        return PenStroke(points: Array(points[..<i]) + [p], widths: Array(widths[..<i]) + [w])
    }

    /// The ink's outline as one polygon: down the left side, a round cap, back up the right
    /// side, a round cap. `grow` widens it on both sides (the dark edge under the mint).
    /// Filled with the non-zero rule, so tight turns that fold over stay solid.
    public func outline(grow: CGFloat = 0) -> [CGPoint] {
        guard let first = points.first else { return [] }
        func cap(_ c: CGPoint, radius r: CGFloat, from angle: CGFloat) -> [CGPoint] {
            (1..<6).map { k in
                let a = angle + .pi * CGFloat(k) / 6
                return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            }
        }
        if points.count == 1 {
            let r = widths[0] / 2 + grow
            return (0..<12).map { k in
                let a = 2 * .pi * CGFloat(k) / 12
                return CGPoint(x: first.x + r * cos(a), y: first.y + r * sin(a))
            }
        }
        var left: [CGPoint] = [], right: [CGPoint] = []
        var normals: [CGFloat] = []   // the direction of travel at each point, as an angle
        for i in points.indices {
            let a = points[max(i - 1, 0)], b = points[min(i + 1, points.count - 1)]
            let angle = atan2(b.y - a.y, b.x - a.x)
            normals.append(angle)
            let r = widths[i] / 2 + grow
            left.append(CGPoint(x: points[i].x - r * sin(angle), y: points[i].y + r * cos(angle)))
            right.append(CGPoint(x: points[i].x + r * sin(angle), y: points[i].y - r * cos(angle)))
        }
        // Caps run from one side to the other around the end: past the tip, then behind the start.
        let last = points.count - 1
        let endCap = cap(points[last], radius: widths[last] / 2 + grow, from: normals[last] - .pi / 2).reversed()
        let startCap = cap(points[0], radius: widths[0] / 2 + grow, from: normals[0] + .pi / 2).reversed()
        return left + endCap + right.reversed() + startCap
    }
}

/// How thick the pen is and how strong its edge, per display option (Overlay.md, Variants).
public struct PenStyle: Equatable, Sendable {
    public let width: CGFloat
    /// The dark edge under the mint, on each side.
    public let edge: CGFloat
    public let edgeOpacity: Double
    /// The highlighter's mint, over whatever is under it.
    public let highlightOpacity: Double

    public static func of(_ a: OverlayAppearance) -> PenStyle {
        if a.increaseContrast {
            return PenStyle(width: 4.5, edge: 1.5, edgeOpacity: 1, highlightOpacity: 0.42)
        }
        if a.reduceTransparency {
            return PenStyle(width: 3.5, edge: 1.5, edgeOpacity: 0.85, highlightOpacity: 0.42)
        }
        return PenStyle(width: 3.5, edge: 1.25, edgeOpacity: 0.55, highlightOpacity: 0.30)
    }
}

/// A small deterministic random source (SplitMix64): the same sketch always wobbles the same
/// way, so renders and tests are exact.
public struct PenRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `range`.
    public mutating func value(in range: ClosedRange<CGFloat>) -> CGFloat {
        let unit = CGFloat(next() >> 11) / CGFloat(1 << 53)
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }

    /// A seed from a sketch's place in the answer and its rounded coordinates.
    public static func seed(index: Int, sketch: Sketch) -> UInt64 {
        let b = sketch.bounds
        var h: UInt64 = 0xC0FF_EE00 &+ UInt64(index)
        for v in [b.minX, b.minY, b.width, b.height] {
            h = (h ^ UInt64(bitPattern: Int64(v.rounded()))) &* 0x100_0000_01B3
        }
        return h
    }
}

/// The strokes of each sketch, in the order the pen draws them (Benji's own hand).
public enum PenGeometry {
    /// A loop clears the corners of the thing it circles by about this much.
    public static let circlePad: CGFloat = 4
    /// The loop's squareness: a superellipse of this power hugs a box better than an oval.
    static let loopPower: CGFloat = 3
    /// How far the loop may swell past its radii as the hand drifts (a share of them).
    public static let loopSwell: CGFloat = 0.09

    /// The loop's half-width and half-height: the box's half-sides plus one margin on both,
    /// the smallest that puts the corners on the curve (so a wide field gets a snug, flat loop,
    /// not a sprawling one), then `circlePad` more.
    public static func loopRadii(_ r: CGRect) -> (CGFloat, CGFloat) {
        let w = max(r.width / 2, 0.5), h = max(r.height / 2, 0.5)
        func reach(_ m: CGFloat) -> CGFloat { pow(w / (w + m), loopPower) + pow(h / (h + m), loopPower) }
        var lo: CGFloat = 0, hi = max(w, h)
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if reach(mid) > 1 { lo = mid } else { hi = mid }
        }
        return (w + hi + circlePad, h + hi + circlePad)
    }
    /// Points along a stroke are about this far apart.
    static let step: CGFloat = 3

    /// The pressure profile along a stroke, 0…1: the pen lands lighter, presses through the
    /// middle and lifts off thinner.
    public static func pressure(at f: CGFloat) -> CGFloat {
        let landing = min(f / 0.12, 1)
        let lift = min((1 - f) / 0.3, 1)
        return 0.55 + 0.45 * min(landing, 0.35 + 0.65 * lift)
    }

    /// The strokes for `sketch` (in the view's coordinates), drawn with `style`. A highlight is
    /// one stroke as thick as its box, without a taper; a dashed group is one stroke per dash; a
    /// note has none (its words are set apart), nor has a callout (its pointer depends on where
    /// its words go: `calloutPointer`).
    public static func strokes(for sketch: Sketch, seed: UInt64, style: PenStyle) -> [PenStroke] {
        var rng = PenRandom(seed: seed)
        switch sketch {
        case let .circle(r, _):
            return [loop(around: r, rng: &rng, width: style.width)]
        case let .arrow(a, b, _):
            return arrow(from: a, to: b, rng: &rng, width: style.width)
        case let .underline(a, b, _):
            return [line(through: [a, b], rng: &rng, width: style.width, wobble: 0.8)]
        case let .path(p, _):
            return [line(through: smooth(p), rng: &rng, width: style.width, wobble: 0.6, resample: false)]
        case let .polyline(p, closed, _):
            let corners = closed ? p + [p[0]] : p
            return [line(through: densify(corners), rng: &rng, width: style.width, wobble: 0.5, resample: false,
                         closed: closed)]
        case let .oval(r, _):
            return [ellipse(in: r, rng: &rng, width: style.width)]
        case let .group(r, _):
            return dashes(around: r, width: style.width * 0.8)
        case let .highlight(r, _):
            let y = r.midY + rng.value(in: -0.6...0.6)
            let n = max(Int(r.width / step), 2)
            let pts = (0...n).map { k -> CGPoint in
                let f = CGFloat(k) / CGFloat(n)
                return CGPoint(x: r.minX + r.width * f, y: y + 0.5 * sin(f * 5.3 + 1.1))
            }
            return [PenStroke(points: pts, widths: Array(repeating: r.height + 2, count: pts.count))]
        case .note, .callout, .text:
            return []
        }
    }

    /// Ramanujan's approximation.
    public static func ellipsePerimeter(_ rx: CGFloat, _ ry: CGFloat) -> CGFloat {
        let h: CGFloat = sqrt((3 * rx + ry) * (rx + 3 * ry))
        return CGFloat.pi * (3 * (rx + ry) - h)
    }

    /// A rounded loop just outside `r`, started a little left of the top and carried past the
    /// start so the two ends cross; it swells and settles a few percent as a hand's would, and
    /// only ever outward, so it never cuts into what it circles.
    static func loop(around r: CGRect, rng: inout PenRandom, width: CGFloat) -> PenStroke {
        let c = CGPoint(x: r.midX, y: r.midY)
        let (rx, ry) = loopRadii(r)
        let start = -CGFloat.pi / 2 - rng.value(in: 0.35...0.6)    // y-down: from upper left, clockwise
        let sweep = 2 * CGFloat.pi + rng.value(in: 0.28...0.45)
        let drift = rng.value(in: 0.03...0.05)                      // ends a little inside where it began
        let phase = rng.value(in: 0...(2 * .pi))
        let n = max(Int(ellipsePerimeter(rx, ry) * 1.08 * sweep / (2 * .pi) / step), 24)
        let e = 2 / loopPower
        func lobe(_ v: CGFloat) -> CGFloat { (v < 0 ? -1 : 1) * pow(abs(v), e) }
        var pts: [CGPoint] = [], widths: [CGFloat] = []
        for k in 0...n {
            let f = CGFloat(k) / CGFloat(n)
            let a = start + sweep * f
            let swell: CGFloat = 0.02 * (1 + sin(2 * a + phase)) + drift * (1 - f)
            let scale = 1 + swell
            pts.append(CGPoint(x: c.x + rx * scale * lobe(cos(a)), y: c.y + ry * scale * lobe(sin(a))))
            widths.append(width * pressure(at: f))
        }
        return PenStroke(points: pts, widths: widths)
    }

    /// A shaft that bows slightly, then the two sides of the head, each drawn from the tip.
    static func arrow(from a: CGPoint, to b: CGPoint, rng: inout PenRandom, width: CGFloat,
                      headScale: CGFloat = 1) -> [PenStroke] {
        let length = hypot(b.x - a.x, b.y - a.y)
        let angle = atan2(b.y - a.y, b.x - a.x)
        let bow = min(length * 0.05, 10) * (rng.next() & 1 == 0 ? 1 : -1)
        let mid = CGPoint(x: (a.x + b.x) / 2 - bow * sin(angle), y: (a.y + b.y) / 2 + bow * cos(angle))
        let n = max(Int(length / step), 8)
        let shaftPoints = (0...n).map { k -> CGPoint in
            let t = CGFloat(k) / CGFloat(n), u = 1 - t
            let wa: CGFloat = u * u, wm: CGFloat = 2 * u * t, wb: CGFloat = t * t
            let x: CGFloat = wa * a.x + wm * mid.x + wb * b.x
            let y: CGFloat = wa * a.y + wm * mid.y + wb * b.y
            return CGPoint(x: x, y: y)
        }
        let shaft = line(through: shaftPoints, rng: &rng, width: width, wobble: 0.5, resample: false)
        // The head follows the shaft's last direction, not the chord's.
        let p = shaftPoints[shaftPoints.count - 2]
        let tipAngle = atan2(b.y - p.y, b.x - p.x)
        let head = min(max(length * 0.16, 11), 18) * headScale
        let barbs = [CGFloat(-1), 1].map { side -> PenStroke in
            let spread = 0.5 + rng.value(in: -0.06...0.06)
            let back = tipAngle + .pi + side * spread
            let end = CGPoint(x: b.x + head * cos(back), y: b.y + head * sin(back))
            return line(through: [b, end], rng: &rng, width: width * 0.9, wobble: 0.25)
        }
        return [shaft] + barbs
    }

    /// Where a line turns by more than this, it has a corner, which stays sharp (a wing tip, a
    /// roof's peak); gentler bends are smoothed.
    public static let cornerAngle: CGFloat = .pi / 3

    /// How far the line turns at `b`, coming from `a` and going on to `c` (0 = straight on,
    /// π = straight back).
    static func turn(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        let d1 = atan2(b.y - a.y, b.x - a.x), d2 = atan2(c.y - b.y, c.x - b.x)
        var d = abs(d2 - d1)
        if d > .pi { d = 2 * .pi - d }
        return d
    }

    /// The points with repeats next to each other left out.
    static func distinct(_ p: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for q in p where out.last.map({ hypot(q.x - $0.x, q.y - $0.y) > 0.5 }) ?? true { out.append(q) }
        return out
    }

    /// A path through the points that bends smoothly where it turns gently and keeps its
    /// corners: it is cut at every turn sharper than `cornerAngle` and each run between corners
    /// is a centripetal Catmull–Rom curve, which never loops or cusps inside a segment. Every
    /// given point is on the result.
    public static func smooth(_ input: [CGPoint]) -> [CGPoint] {
        let p = distinct(input)
        guard p.count > 2 else { return densify(p) }
        var runs: [[CGPoint]] = []
        var run = [p[0]]
        for i in 1..<p.count {
            run.append(p[i])
            if i < p.count - 1, turn(p[i - 1], p[i], p[i + 1]) > cornerAngle {
                runs.append(run)
                run = [p[i]]
            }
        }
        runs.append(run)
        var out = [p[0]]
        for r in runs { out += (r.count > 2 ? catmullRom(r) : densify(r)).dropFirst() }
        return out
    }

    /// Centripetal Catmull–Rom (α = ½) through three or more points, its ends extended by
    /// mirroring so the curve starts and ends heading at its neighbours.
    static func catmullRom(_ p: [CGPoint]) -> [CGPoint] {
        func mirror(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: 2 * a.x - b.x, y: 2 * a.y - b.y) }
        let q = [mirror(p[0], p[1])] + p + [mirror(p[p.count - 1], p[p.count - 2])]
        func knot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { max(sqrt(hypot(b.x - a.x, b.y - a.y)), 1e-4) }
        func lerp(_ a: CGPoint, _ b: CGPoint, _ ta: CGFloat, _ tb: CGFloat, _ t: CGFloat) -> CGPoint {
            let f = (t - ta) / (tb - ta)
            return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
        }
        var out: [CGPoint] = [p[0]]
        for i in 1..<(q.count - 2) {
            let p0 = q[i - 1], p1 = q[i], p2 = q[i + 1], p3 = q[i + 2]
            let t0: CGFloat = 0, t1 = t0 + knot(p0, p1), t2 = t1 + knot(p1, p2), t3 = t2 + knot(p2, p3)
            let n = max(Int(hypot(p2.x - p1.x, p2.y - p1.y) / step), 2)
            for k in 1...n {
                let t = t1 + (t2 - t1) * CGFloat(k) / CGFloat(n)
                let a1 = lerp(p0, p1, t0, t1, t), a2 = lerp(p1, p2, t1, t2, t), a3 = lerp(p2, p3, t2, t3, t)
                let b1 = lerp(a1, a2, t0, t2, t), b2 = lerp(a2, a3, t1, t3, t)
                out.append(k == n ? p2 : lerp(b1, b2, t1, t2, t))
            }
        }
        return out
    }

    /// Straight segments through the points, with a point every `step` or so along each and
    /// every given point kept (so corners stay exactly where they are).
    public static func densify(_ p: [CGPoint]) -> [CGPoint] {
        guard let first = p.first else { return [] }
        var out = [first]
        for (a, b) in zip(p, p.dropFirst()) {
            let n = max(Int(hypot(b.x - a.x, b.y - a.y) / step), 1)
            for k in 1...n {
                let f = CGFloat(k) / CGFloat(n)
                out.append(k == n ? b : CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            }
        }
        return out
    }

    /// An ellipse filling `r`, started at the upper left and carried a little past its start so
    /// it closes without a gap; it swells by at most 1% as a hand's would, never into a loop.
    static func ellipse(in r: CGRect, rng: inout PenRandom, width: CGFloat) -> PenStroke {
        let c = CGPoint(x: r.midX, y: r.midY)
        let rx = r.width / 2, ry = r.height / 2
        let start = -CGFloat.pi / 2 - rng.value(in: 0.4...0.7)
        let sweep = 2 * CGFloat.pi + rng.value(in: 0.08...0.14)
        let phase = rng.value(in: 0...(2 * .pi))
        let n = max(Int(ellipsePerimeter(rx, ry) * sweep / (2 * .pi) / step), 16)
        var pts: [CGPoint] = [], widths: [CGFloat] = []
        for k in 0...n {
            let f = CGFloat(k) / CGFloat(n)
            let a = start + sweep * f
            // The swell is the same at both ends, so the overlap retraces the start.
            let scale = 1 + 0.01 * sin(2 * a + phase) * sin(.pi * f)
            pts.append(CGPoint(x: c.x + rx * scale * cos(a), y: c.y + ry * scale * sin(a)))
            widths.append(width * max(pressure(at: f), closedPressure))
        }
        return PenStroke(points: pts, widths: widths)
    }

    /// A closed outline or ellipse keeps at least this much of the pen's width at its ends, so
    /// where the pen comes back to its start reads as one line, not a thin gap.
    static let closedPressure: CGFloat = 0.85

    /// The dashed group's box sits this far outside the region it surrounds.
    public static let groupPad: CGFloat = 6
    static let dashLength: CGFloat = 9
    static let dashGap: CGFloat = 6

    /// Dashes around a rounded box just outside `r`, clockwise from the top-left corner, every
    /// dash a short even stroke.
    static func dashes(around region: CGRect, width: CGFloat) -> [PenStroke] {
        let r = region.insetBy(dx: -groupPad, dy: -groupPad)
        let radius = min(12, r.width / 2, r.height / 2)
        // Corners' centres, clockwise in y-down coordinates: top right, bottom right, bottom left, top left.
        let centres = [CGPoint(x: r.maxX - radius, y: r.minY + radius), CGPoint(x: r.maxX - radius, y: r.maxY - radius),
                       CGPoint(x: r.minX + radius, y: r.maxY - radius), CGPoint(x: r.minX + radius, y: r.minY + radius)]
        var outline: [CGPoint] = [CGPoint(x: r.minX + radius, y: r.minY)]
        for (k, c) in centres.enumerated() {
            let from = -CGFloat.pi / 2 + CGFloat(k) * .pi / 2
            for j in 0...6 {
                let a = from + CGFloat(j) / 6 * .pi / 2
                outline.append(CGPoint(x: c.x + radius * cos(a), y: c.y + radius * sin(a)))
            }
        }
        outline.append(outline[0])
        let path = densify(outline)
        let ring = PenStroke(points: path, widths: Array(repeating: width, count: path.count))
        let period = dashLength + dashGap
        let count = max(Int((ring.length / period).rounded()), 4)
        let stretch = ring.length / (CGFloat(count) * period)   // dashes meet evenly where they started
        var j = 0
        return (0..<count).map { i in
            let a = CGFloat(i) * period * stretch, b = a + dashLength * stretch
            var pts = [ring.point(at: a)]
            while j < ring.points.count, ring.distances[j] <= a { j += 1 }
            while j < ring.points.count, ring.distances[j] < b { pts.append(ring.points[j]); j += 1 }
            pts.append(ring.point(at: b))
            return PenStroke(points: pts, widths: Array(repeating: width, count: pts.count))
        }
    }

    /// The pointer from a callout's words (`frame`) to what it labels: from the edge of the
    /// frame nearest the target to just short of it. Nil when the target is too close to point at.
    public static func calloutPointer(from frame: CGRect, to target: CGPoint) -> (CGPoint, CGPoint)? {
        let edge = CGPoint(x: min(max(target.x, frame.minX), frame.maxX), y: min(max(target.y, frame.minY), frame.maxY))
        let d = hypot(target.x - edge.x, target.y - edge.y)
        guard d >= 14 else { return nil }
        let ux = (target.x - edge.x) / d, uy = (target.y - edge.y) / d
        return (CGPoint(x: edge.x + 4 * ux, y: edge.y + 4 * uy), CGPoint(x: target.x - 2 * ux, y: target.y - 2 * uy))
    }

    /// The callout's pointer, drawn with the pen as a short arrow.
    public static func calloutStrokes(from frame: CGRect, to target: CGPoint, seed: UInt64, style: PenStyle) -> [PenStroke] {
        guard let (a, b) = calloutPointer(from: frame, to: target) else { return [] }
        var rng = PenRandom(seed: seed)
        return arrow(from: a, to: b, rng: &rng, width: style.width * 0.85, headScale: 0.7)
    }

    /// A stroke along `through` (resampled every `step` unless already dense), nudged sideways
    /// by two slow waves of at most `wobble` pt, with the pressure taper.
    static func line(through input: [CGPoint], rng: inout PenRandom, width: CGFloat, wobble: CGFloat,
                     resample: Bool = true, closed: Bool = false) -> PenStroke {
        let base = PenStroke(points: input, widths: Array(repeating: width, count: input.count))
        let total = base.length
        var pts: [CGPoint]
        if resample, total > 0 {
            let n = max(Int(total / step), 2)
            pts = (0...n).map { k in base.trimmed(to: total * CGFloat(k) / CGFloat(n)).points.last! }
        } else {
            pts = input
        }
        let f1 = rng.value(in: 0.6...1.1), f2 = rng.value(in: 1.7...2.6)
        let p1 = rng.value(in: 0...(2 * .pi)), p2 = rng.value(in: 0...(2 * .pi))
        let amp = min(wobble, total * 0.012)
        let along = PenStroke(points: pts, widths: Array(repeating: width, count: pts.count))
        var out: [CGPoint] = [], widths: [CGFloat] = []
        for i in pts.indices {
            let f = total > 0 ? along.distances[i] / total : 0
            let a = pts[max(i - 1, 0)], b = pts[min(i + 1, pts.count - 1)]
            let angle = atan2(b.y - a.y, b.x - a.x)
            // Pinned at both ends so arrows still reach their tips.
            let wave1: CGFloat = 0.6 * sin(2 * .pi * f1 * f + p1)
            let wave2: CGFloat = 0.4 * sin(2 * .pi * f2 * f + p2)
            let w: CGFloat = amp * (wave1 + wave2) * sin(.pi * f)
            out.append(CGPoint(x: pts[i].x - w * sin(angle), y: pts[i].y + w * cos(angle)))
            widths.append(width * (closed ? max(pressure(at: f), closedPressure) : pressure(at: f)))
        }
        return PenStroke(points: out, widths: widths)
    }

    /// The strokes as far as the pen has got: `progress` 0…1 of their total length, drawn one
    /// after the other.
    public static func revealed(_ strokes: [PenStroke], progress: CGFloat) -> [PenStroke] {
        let total = strokes.reduce(0) { $0 + $1.length }
        var left = total * min(max(progress, 0), 1)
        var out: [PenStroke] = []
        for s in strokes {
            guard left > 0 else { break }
            out.append(s.trimmed(to: left))
            left -= s.length
        }
        return out
    }
}

/// When the pen is where (Overlay.md, Reveal, for drawings).
public enum SketchTimeline {
    /// pt/s along the ink: unhurried enough to follow, quick enough to keep up with speech.
    public static let penSpeed: CGFloat = 650
    public static let shortest = 0.45
    public static let longest = 1.4
    /// A picture's parts (path, polyline, oval) come one after another, so a small one (an
    /// eye, a window) takes less.
    public static let partShortest = 0.25
    /// A dashed group goes round this much faster than the pen draws a line.
    public static let dashSpeedup: CGFloat = 1.6
    /// A note writes itself in at this many characters a second.
    public static let noteCharactersPerSecond = 32.0
    /// Words written on the screen (TEXT) go in at a hand's pace.
    public static let textCharactersPerSecond = 16.0

    /// How long the pen takes over `sketch`.
    public static func drawDuration(_ sketch: Sketch) -> Double {
        let length: CGFloat
        switch sketch {
        case let .circle(r, _):
            let (rx, ry) = PenGeometry.loopRadii(r)
            length = PenGeometry.ellipsePerimeter(rx, ry) * 1.15
        case let .arrow(a, b, _):
            let l = hypot(b.x - a.x, b.y - a.y)
            length = l + 2 * min(max(l * 0.16, 11), 18)
        case let .underline(a, b, _):
            length = hypot(b.x - a.x, b.y - a.y)
        case let .highlight(r, _):
            length = r.width
        case let .path(p, _), let .polyline(p, false, _):
            length = zip(p, p.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        case let .polyline(p, true, _):
            let ring = p + [p[0]]
            length = zip(ring, ring.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        case let .oval(r, _):
            length = PenGeometry.ellipsePerimeter(r.width / 2, r.height / 2) * 1.02
        case let .group(r, _):
            let g = r.insetBy(dx: -PenGeometry.groupPad, dy: -PenGeometry.groupPad)
            length = 2 * (g.width + g.height) / dashSpeedup
        case let .note(_, text), let .callout(_, text):
            return min(max(Double(text.count) / noteCharactersPerSecond, shortest), longest)
        case let .text(_, text, _):
            return min(max(Double(text.count) / textCharactersPerSecond, partShortest), longest)
        }
        return min(max(Double(length / penSpeed), sketch.isDrawing ? partShortest : shortest), longest)
    }

    /// From the reveal to rest: the pen's time, or the Reduce Motion fade.
    public static func restTime(_ sketch: Sketch, reduceMotion: Bool) -> Double {
        reduceMotion ? MotionTokens.reduceDuration : drawDuration(sketch)
    }

    /// How far the pen has got (0…1, eased in and out like a hand) and how visible the ink is.
    /// Under Reduce Motion everything is there at once and fades in.
    public static func phase(_ sketch: Sketch, reduceMotion: Bool, at t: Double) -> (draw: CGFloat, opacity: Double) {
        if reduceMotion {
            return (1, MotionTokens.reduceCurve.value(at: t / MotionTokens.reduceDuration))
        }
        let d = drawDuration(sketch)
        return (CGFloat(TimingCurve.easeInOut.value(at: t / d)), t >= 0 ? 1 : 0)
    }
}

/// Where a note's words go: beside the point, after a small gap, on the side that fits.
public enum SketchLayout {
    public static let noteGap: CGFloat = 10
    public static let maxNoteWidth: CGFloat = 280

    /// `size` is the text's; `at` and the result are in the view's y-down coordinates,
    /// `bounds` the visible area (the menu bar and the Dock left out).
    public static func noteFrame(size: CGSize, at p: CGPoint, bounds: CGRect) -> CGRect {
        let w = min(size.width, maxNoteWidth), h = size.height
        let safe = bounds.insetBy(dx: OverlayLayout.safeInset, dy: OverlayLayout.safeInset)
        var x = p.x + noteGap
        if x + w > safe.maxX { x = p.x - noteGap - w }          // trailing, else leading
        x = min(max(x, safe.minX), max(safe.maxX - w, safe.minX))
        let y = min(max(p.y - h / 2, safe.minY), max(safe.maxY - h, safe.minY))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Where a TEXT mark's words go: from the point rightwards, centred on it in height, kept
    /// inside `bounds` (the visible area, as for a note). Same coordinates as `noteFrame`.
    public static func textFrame(size: CGSize, at p: CGPoint, bounds: CGRect) -> CGRect {
        let safe = bounds.insetBy(dx: OverlayLayout.safeInset, dy: OverlayLayout.safeInset)
        let w = min(size.width, safe.width), h = size.height
        let x = min(max(p.x, safe.minX), max(safe.maxX - w, safe.minX))
        let y = min(max(p.y - h / 2, safe.minY), max(safe.maxY - h, safe.minY))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// A callout's words sit this far from what they label, leaving room for the pointer.
    public static let calloutGap: CGFloat = 34

    /// Where a callout's pill goes: `calloutGap` from the target, to its right, else its left,
    /// below or above, whichever fits first in `bounds` (else to the right, kept on screen).
    /// Same coordinates as `noteFrame`.
    public static func calloutFrame(size: CGSize, at p: CGPoint, bounds: CGRect) -> CGRect {
        let w = min(size.width, maxNoteWidth), h = size.height
        let safe = bounds.insetBy(dx: OverlayLayout.safeInset, dy: OverlayLayout.safeInset)
        let g = calloutGap
        let candidates = [CGRect(x: p.x + g, y: p.y - h / 2, width: w, height: h),
                          CGRect(x: p.x - g - w, y: p.y - h / 2, width: w, height: h),
                          CGRect(x: p.x - w / 2, y: p.y + g, width: w, height: h),
                          CGRect(x: p.x - w / 2, y: p.y - g - h, width: w, height: h)]
        if let fit = candidates.first(where: { safe.contains($0) }) { return fit }
        let r = candidates[0]
        return CGRect(x: min(max(r.minX, safe.minX), max(safe.maxX - w, safe.minX)),
                      y: min(max(r.minY, safe.minY), max(safe.maxY - h, safe.minY)), width: w, height: h)
    }
}

extension PointingAnnouncement {
    /// What VoiceOver hears when a drawing appears.
    public static func text(for sketch: Sketch) -> String {
        let name = sketch.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let what = name.isEmpty ? "something on screen" : name
        let line: String
        switch sketch {
        case .circle: line = "Circling \(what)"
        case .arrow: line = name.isEmpty ? "Arrow on screen" : "Arrow to \(name)"
        case .underline: line = "Underlining \(what)"
        case .highlight: line = "Highlighting \(what)"
        case .path, .polyline, .oval: line = name.isEmpty ? "Drawing on screen" : "Drawing: \(name)"
        case .group: line = "Marking \(what)"
        case .note: line = "Note on screen: \(name)"
        case .callout: line = "Label on screen: \(name)"
        case .text: line = "Written on screen: \(name)"
        }
        guard let last = line.last, !".!?".contains(last) else { return line }
        return line + "."
    }
}
