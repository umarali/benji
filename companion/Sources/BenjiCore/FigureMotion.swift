import Foundation

/// When each part of a figure appears and how the camera turns: pure functions of time, like
/// `PointingSequence`, so the stage can later be paced by speech by moving the cue times.
public struct FigureTimeline: Equatable, Sendable {
    /// Each part grows in over this long, with a small overshoot.
    public static let grow = 0.35
    /// The floor between one part and the next.
    public static let partFloor = 0.25
    /// A camera move to a new view.
    public static let tween = 0.35
    /// The slow idle turn: one revolution in this many seconds, so a still figure still reads as 3D.
    public static let idleRevolution = 80.0

    /// Seconds from the reveal's start at which part k starts to grow.
    public let cues: [Double]

    /// Parts one after another in order; `span` (the spoken sentence, when known) spreads them
    /// over that time, never closer than `partFloor`.
    public init(parts: Int, span: Double? = nil) {
        let step = max(Self.partFloor, span.map { $0 / Double(max(parts, 1)) } ?? Self.partFloor)
        cues = (0..<parts).map { Double($0) * step }
    }

    /// 0 before its cue, 1 at rest, slightly over 1 near the end of its growth.
    public func scale(part k: Int, at t: Double) -> Double {
        guard k < cues.count else { return 1 }
        let x = (t - cues[k]) / Self.grow
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let c1 = 1.2, c3 = c1 + 1   // ease out back
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }

    /// When the last part comes to rest.
    public var settled: Double { (cues.last ?? 0) + Self.grow }

    /// The idle turn's angle in degrees, `seconds` after rest; 0 under Reduce Motion.
    public static func idleTurn(after seconds: Double, reduceMotion: Bool) -> Double {
        reduceMotion || seconds <= 0 ? 0 : seconds / idleRevolution * 360
    }
}

/// The camera that frames a figure: where it sits for a view, in figure space.
public enum FigureCamera {
    public static let fieldOfView = 30.0   // degrees, vertical

    /// The camera's position for a view, looking at `centre`; turn swings it right (towards +x)
    /// from the front (+z), tilt raises it. Distance frames a sphere of `radius` at zoom 1.
    public static func position(view: FigureView, centre: SIMD3<Double>, radius: Double, aspect: Double = 1.5,
                                extraTurn: Double = 0) -> SIMD3<Double> {
        let turn = (view.turn + extraTurn) * .pi / 180, tilt = view.tilt * .pi / 180
        let distance = distanceFor(radius: radius, aspect: aspect) / view.zoom
        return centre + SIMD3(sin(turn) * cos(tilt), sin(tilt), cos(turn) * cos(tilt)) * distance
    }

    /// Far enough that the sphere fits both the height and (for narrow stages) the width.
    public static func distanceFor(radius: Double, aspect: Double) -> Double {
        let half = fieldOfView / 2 * .pi / 180
        let horizontal = atan(tan(half) * aspect)
        return radius / sin(min(half, horizontal)) * 1.04
    }
}

/// Label pills beside a figure: in the margins left and right of the model (or above and below
/// when a label asks), in the order of their anchors so leaders don't cross, never over the model.
/// The same rules as the overlay's label: a label that doesn't fit is not drawn (the words are in
/// the answer).
public enum FigureLabelLayout {
    public static let gap: CGFloat = 16          // between the model's box and a pill
    public static let spacing: CGFloat = 8       // between pills in a column
    public static let maxWidth: CGFloat = 180

    public struct Item: Equatable, Sendable {
        public var anchor: CGPoint
        public var size: CGSize
        public var side: String
        public init(anchor: CGPoint, size: CGSize, side: String) { self.anchor = anchor; self.size = size; self.side = side }
    }

    /// Frames (top-left origin, y down) for each item, nil where it doesn't fit. `model` is the
    /// model's projected box; `area` the space labels may use.
    public static func place(_ items: [Item], model: CGRect, area: CGRect) -> [CGRect?] {
        let first = placeOnce(items, model: model, area: area)
        // A label with no side of its own that found no room tries the other side.
        var moved = items
        var any = false
        for (i, it) in items.enumerated() where first[i] == nil && it.side.isEmpty {
            moved[i].side = it.anchor.x < model.midX ? "right" : "left"
            any = true
        }
        return any ? placeOnce(moved, model: model, area: area) : first
    }

    static func placeOnce(_ items: [Item], model: CGRect, area: CGRect) -> [CGRect?] {
        var out = [CGRect?](repeating: nil, count: items.count)
        var columns: [String: [Int]] = ["left": [], "right": [], "top": [], "bottom": []]
        for (i, it) in items.enumerated() {
            let side = ["left", "right", "top", "bottom"].contains(it.side) ? it.side
                : (it.anchor.x < model.midX ? "left" : "right")
            columns[side, default: []].append(i)
        }
        for side in ["left", "right"] {
            let ids = (columns[side] ?? []).sorted { items[$0].anchor.y < items[$1].anchor.y }
            var frames: [CGRect] = ids.map { i in
                let s = items[i].size
                let x = side == "left" ? max(area.minX, model.minX - gap - s.width) : min(area.maxX - s.width, model.maxX + gap)
                return CGRect(x: x, y: items[i].anchor.y - s.height / 2, width: s.width, height: s.height)
            }
            stack(&frames, lo: area.minY, hi: area.maxY, vertical: true)
            for (k, i) in ids.enumerated() where fits(frames[k], model: model, area: area) { out[i] = frames[k] }
        }
        for side in ["top", "bottom"] {
            let ids = (columns[side] ?? []).sorted { items[$0].anchor.x < items[$1].anchor.x }
            var frames: [CGRect] = ids.map { i in
                let s = items[i].size
                let y = side == "top" ? max(area.minY, model.minY - gap - s.height) : min(area.maxY - s.height, model.maxY + gap)
                return CGRect(x: items[i].anchor.x - s.width / 2, y: y, width: s.width, height: s.height)
            }
            stack(&frames, lo: area.minX, hi: area.maxX, vertical: false)
            for (k, i) in ids.enumerated() where fits(frames[k], model: model, area: area) { out[i] = frames[k] }
        }
        return out
    }

    static func fits(_ r: CGRect, model: CGRect, area: CGRect) -> Bool {
        area.insetBy(dx: -0.5, dy: -0.5).contains(r) && !r.intersects(model)
    }

    /// Push overlapping frames apart along one direction, then back inside [lo, hi].
    static func stack(_ frames: inout [CGRect], lo: CGFloat, hi: CGFloat, vertical: Bool) {
        guard !frames.isEmpty else { return }
        func start(_ r: CGRect) -> CGFloat { vertical ? r.minY : r.minX }
        func length(_ r: CGRect) -> CGFloat { vertical ? r.height : r.width }
        func set(_ k: Int, _ v: CGFloat) { if vertical { frames[k].origin.y = v } else { frames[k].origin.x = v } }
        set(0, max(start(frames[0]), lo))
        for k in 1..<frames.count {
            set(k, max(start(frames[k]), start(frames[k - 1]) + length(frames[k - 1]) + spacing))
        }
        let last = frames.count - 1
        if start(frames[last]) + length(frames[last]) > hi {
            set(last, hi - length(frames[last]))
            for k in stride(from: last - 1, through: 0, by: -1) {
                set(k, min(start(frames[k]), start(frames[k + 1]) - spacing - length(frames[k])))
            }
        }
    }
}

/// Where the figure card goes: centred in the display's visible area, moved clear of Benji's
/// own panels (below them, else above), kept `margin` inside the visible area. `flipped`: y runs
/// down (the renders) rather than up (AppKit).
public enum FigureCardPlacement {
    public static let margin: CGFloat = 12

    public static func frame(cardSize: CGSize, visible: CGRect, avoid: [CGRect], flipped: Bool = false) -> CGRect {
        let safe = visible.insetBy(dx: margin, dy: margin)
        var r = CGRect(x: safe.midX - cardSize.width / 2, y: safe.midY - cardSize.height / 2,
                       width: cardSize.width, height: cardSize.height)
        func clamp(_ r: CGRect) -> CGRect {
            CGRect(x: min(max(r.minX, safe.minX), safe.maxX - r.width), y: min(max(r.minY, safe.minY), safe.maxY - r.height),
                   width: r.width, height: r.height)
        }
        for a in avoid where r.intersects(a.insetBy(dx: -margin, dy: -margin)) {
            // "Below" is larger y when flipped, smaller y in AppKit.
            let below = flipped ? CGRect(x: r.minX, y: a.maxY + margin, width: r.width, height: r.height)
                                : CGRect(x: r.minX, y: a.minY - margin - r.height, width: r.width, height: r.height)
            let above = flipped ? CGRect(x: r.minX, y: a.minY - margin - r.height, width: r.width, height: r.height)
                                : CGRect(x: r.minX, y: a.maxY + margin, width: r.width, height: r.height)
            r = safe.contains(below) ? below : safe.contains(above) ? above : clamp(below)
        }
        return clamp(r)
    }
}

/// The user turning the figure by hand (D-108, after the stage went live): a drag orbits the
/// camera, scroll or pinch zooms, a double-click or reset returns to the model's view. Turn, tilt
/// and zoom stay in the ranges a figure block's `view` is clamped to.
public struct FigureOrbit: Equatable, Sendable {
    /// Degrees of turn per point dragged across (about 900 pt for a full turn).
    public static let turnPerPoint = 0.4
    /// Degrees of tilt per point dragged up or down.
    public static let tiltPerPoint = 0.3
    public static let tiltRange = -80.0...80.0
    public static let zoomRange = 0.5...3.0
    /// Zoom changes by e^(this × points scrolled): about 1.35× for 30 points of scroll.
    public static let zoomPerScrollPoint = 0.01

    /// The model's view, which reset returns to.
    public let base: FigureView
    /// The pose shown now.
    public private(set) var view: FigureView

    public init(base: FigureView) {
        self.base = base
        view = base
    }

    public var isMoved: Bool { view != base }

    /// A drag of (dx, dy) points, AppKit's way up (dy > 0 is up). Grab-the-object: dragging right
    /// turns the figure's front to the right (the camera swings left); dragging up shows more of
    /// its underside (the camera goes down).
    public mutating func drag(dx: Double, dy: Double) {
        view.turn = Self.wrap(view.turn - dx * Self.turnPerPoint)
        view.tilt = min(max(view.tilt - dy * Self.tiltPerPoint, Self.tiltRange.lowerBound), Self.tiltRange.upperBound)
    }

    /// Scroll: `dy` points of vertical scroll (up, away from the user, zooms in).
    public mutating func scroll(dy: Double) {
        // Clamped so a huge flick still lands on the range's end rather than overflowing exp.
        zoom(by: exp(min(max(dy * Self.zoomPerScrollPoint, -20), 20)))
    }

    /// Pinch: AppKit's magnification (0.1 is 10% larger).
    public mutating func pinch(_ magnification: Double) {
        zoom(by: 1 + magnification)
    }

    public mutating func zoom(by factor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        view.zoom = min(max(view.zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    public mutating func reset() { view = base }

    static func wrap(_ degrees: Double) -> Double {
        var t = fmod(degrees, 360)
        if t > 180 { t -= 360 } else if t < -180 { t += 360 }
        return t
    }
}

/// The slow idle turn's clock, paused while the user handles the figure: it stops at the first
/// touch and starts again `resumeAfter` seconds after the last one, from where it stopped.
public struct FigureIdleClock: Equatable, Sendable {
    public static let resumeAfter = 3.0

    private var pausedTotal = 0.0
    private var pauseStart: Double?
    private var lastTouch: Double?

    public init() {}

    /// The user touched the figure (a drag step, a scroll, a pinch, a reset) at time t.
    public mutating func touch(at t: Double) {
        if pauseStart == nil { pauseStart = t }
        lastTouch = t
    }

    public func isPaused(at t: Double) -> Bool {
        guard pauseStart != nil, let last = lastTouch else { return false }
        return t < last + Self.resumeAfter
    }

    /// Seconds the idle turn has run by time t, counting from `start` (when the figure settled).
    /// Without touches this is t - start, as before.
    public mutating func turning(at t: Double, from start: Double) -> Double {
        if let p = pauseStart, let last = lastTouch, t >= last + Self.resumeAfter {
            pausedTotal += max(0, (last + Self.resumeAfter) - max(p, start))
            pauseStart = nil
        }
        var paused = pausedTotal
        if let p = pauseStart { paused += max(0, t - max(p, start)) }
        return max(0, t - start - paused)
    }
}
