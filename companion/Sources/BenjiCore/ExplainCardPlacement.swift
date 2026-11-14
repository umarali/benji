import Foundation

/// How busy each 64-point tile of a screenshot is (D-125): the share of its pixels on a sharp
/// edge in brightness. Text, photos and controls are busy; wallpaper, empty window space and
/// flat panels are calm. Coordinates are a display's points, top-left origin, y down.
public struct BusyMap: Equatable, Sendable {
    /// Points per tile side.
    public static let tile: CGFloat = 64
    /// A tile is busy when this share of its pixels sit on an edge.
    public static let busyTile = 0.02
    /// A neighbour this much brighter or darker (0–255, across and down summed) makes an edge.
    public static let edgeStep = 40

    public let cols: Int
    public let rows: Int
    /// Points per tile (64, unless built otherwise for a test).
    public let tile: CGFloat
    /// Row-major, 0–1.
    public let density: [Double]

    public init(cols: Int, rows: Int, tile: CGFloat = BusyMap.tile, density: [Double]) {
        precondition(density.count == cols * rows)
        self.cols = cols
        self.rows = rows
        self.tile = tile
        self.density = density
    }

    /// From an 8-bit brightness image of a display whose width is `pointsWide` points.
    public static func measure(luma: [UInt8], width: Int, height: Int, pointsWide: CGFloat) -> BusyMap? {
        guard width > 1, height > 1, luma.count >= width * height, pointsWide > 0 else { return nil }
        let px = max(4, Int((tile * CGFloat(width) / pointsWide).rounded()))   // pixels per tile
        let cols = (width + px - 1) / px, rows = (height + px - 1) / px
        var edges = [Int](repeating: 0, count: cols * rows), counts = [Int](repeating: 0, count: cols * rows)
        // Every other pixel each way: a quarter of the work, and text still shows on every row it crosses.
        luma.withUnsafeBufferPointer { l in
            for y in stride(from: 0, to: height - 1, by: 2) {
                let row = y * width, ty = (y / px) * cols
                for x in stride(from: 0, to: width - 1, by: 2) {
                    let v = Int(l[row + x])
                    let step = abs(Int(l[row + x + 1]) - v) + abs(Int(l[row + width + x]) - v)
                    let t = ty + x / px
                    counts[t] += 1
                    if step >= edgeStep { edges[t] += 1 }
                }
            }
        }
        let density = zip(edges, counts).map { e, c in c == 0 ? 0 : Double(e) / Double(c) }
        return BusyMap(cols: cols, rows: rows, tile: tile, density: density)
    }

    public func isBusy(col: Int, row: Int) -> Bool {
        guard col >= 0, row >= 0, col < cols, row < rows else { return false }
        return density[row * cols + col] >= Self.busyTile
    }

    /// The share of `rect`'s area over busy tiles (0–1); off the map counts as calm.
    public func coverage(of rect: CGRect) -> Double {
        guard rect.width > 0, rect.height > 0 else { return 0 }
        var busy: CGFloat = 0
        let c0 = max(0, Int(floor(rect.minX / tile))), c1 = min(cols - 1, Int(floor((rect.maxX - 0.001) / tile)))
        let r0 = max(0, Int(floor(rect.minY / tile))), r1 = min(rows - 1, Int(floor((rect.maxY - 0.001) / tile)))
        guard c0 <= c1, r0 <= r1 else { return 0 }
        for r in r0...r1 {
            for c in c0...c1 where density[r * cols + c] >= Self.busyTile {
                let cell = CGRect(x: CGFloat(c) * tile, y: CGFloat(r) * tile, width: tile, height: tile)
                let i = cell.intersection(rect)
                busy += i.width * i.height
            }
        }
        return Double(busy / (rect.width * rect.height))
    }
}

/// Where an explanation card goes (D-125): on the calmest space of the display that keeps clear
/// of Benji's own panels and of what the reply points at, near where the user is already looking
/// (just under the notch panel). On a busy screen it still goes somewhere: the card is opaque, so
/// it covers what is under it rather than drawing over it. Top-left origin, y down.
public enum ExplainCardPlacement {
    public static let margin: CGFloat = 16
    /// Candidate positions every this many points.
    public static let step: CGFloat = 16
    /// A rule of thumb, set as our own value: space with this share busy is busy space.
    public static let busySpace = 0.08
    /// How much one screen-diagonal of distance from the preferred spot weighs against covering
    /// a fully busy area: calm space a third of the screen away beats a busy spot under the panel,
    /// but on a page that is busy everywhere the card stays near the panel.
    public static let distanceWeight = 1.0

    public struct Result: Equatable, Sendable {
        public var frame: CGRect
        /// The share of the card's area over busy tiles.
        public var busyCover: Double
        public var overBusySpace: Bool { busyCover >= ExplainCardPlacement.busySpace }
    }

    /// `prefer`: where the card's top centre would ideally go. `avoid`: rects never to cover when
    /// some position avoids them all (Benji's panel, a figure card, pointed-at things).
    public static func place(size: CGSize, visible: CGRect, prefer: CGPoint, avoid: [CGRect] = [],
                             busy: BusyMap? = nil) -> Result {
        let safe = visible.insetBy(dx: margin, dy: margin)
        guard size.width <= safe.width, size.height <= safe.height else {
            let r = CGRect(x: safe.minX, y: safe.minY, width: size.width, height: size.height)
            return Result(frame: r, busyCover: busy?.coverage(of: r) ?? 0)
        }
        let diagonal = Double(hypot(safe.width, safe.height))
        let keepOut = avoid.map { $0.insetBy(dx: -margin, dy: -margin) }
        var best: (score: Double, clash: Int, result: Result)?
        var y = safe.minY
        while y + size.height <= safe.maxY + 0.001 {
            var x = safe.minX
            while x + size.width <= safe.maxX + 0.001 {
                let r = CGRect(x: x, y: y, width: size.width, height: size.height)
                let clash = keepOut.filter { $0.intersects(r) }.count
                let cover = busy?.coverage(of: r) ?? 0
                let distance = Double(hypot(r.midX - prefer.x, r.minY - prefer.y)) / diagonal
                let score = cover + distance * distanceWeight
                if best == nil || clash < best!.clash || (clash == best!.clash && score < best!.score - 1e-9) {
                    best = (score, clash, Result(frame: r, busyCover: cover))
                }
                x += step
            }
            y += step
        }
        return best!.result
    }
}

/// The card's reveal (D-125): the card lands, the heading appears, then each item in turn with
/// the arrow into it drawn like a pen stroke, then the closing line, then the chips once all of it
/// is drawn. Under Reduce Motion everything is there at once.
public struct ExplainCardReveal: Equatable, Sendable {
    public static let land = 0.18
    public static let headingAt = 0.12
    public static let firstItemAt = 0.32
    public static let perItem = 0.3
    public static let fade = 0.2
    public static let stroke = 0.22
    public static let chipsAfter = 0.15

    /// A card drawn on Benji's sentences (chilly-beats): when it opened, each item's released
    /// slot (nil: not yet), the takeaway's, and when the chips come (nil: not yet). Times are on
    /// the clock the view is drawn at.
    public struct Beats: Equatable, Sendable {
        public var opened: Double
        public var items: [BeatPlanner.Slot?]
        public var takeaway: BeatPlanner.Slot?
        public var chips: Double?

        public init(opened: Double, items: [BeatPlanner.Slot?], takeaway: BeatPlanner.Slot? = nil, chips: Double? = nil) {
            self.opened = opened
            self.items = items
            self.takeaway = takeaway
            self.chips = chips
        }
    }

    public let items: Int
    public let hasTakeaway: Bool
    public let reduceMotion: Bool
    /// Nil: the fixed timer from the moment the card lands (D-125).
    public let beats: Beats?

    public init(items: Int, hasTakeaway: Bool, reduceMotion: Bool = false) {
        self.items = items
        self.hasTakeaway = hasTakeaway
        self.reduceMotion = reduceMotion
        self.beats = nil
    }

    public init(beats: Beats, hasTakeaway: Bool, reduceMotion: Bool = false) {
        self.items = beats.items.count
        self.hasTakeaway = hasTakeaway
        self.reduceMotion = reduceMotion
        self.beats = beats
    }

    func ramp(_ t: Double, from start: Double, over length: Double) -> Double {
        if beats != nil, reduceMotion { return t >= start - 1e-9 ? 1 : 0 }   // on its sentence, without motion
        return reduceMotion || t >= start + length - 1e-9 ? 1 : max(0, (t - start) / length)
    }

    /// A part's pace: its draw time over its natural one.
    private func pace(_ slot: BeatPlanner.Slot) -> Double { slot.draw / CardBeat.itemNatural }

    public func itemStart(_ i: Int) -> Double {
        if let beats { return beats.items[i].map { $0.at + Self.stroke * 0.6 * pace($0) } ?? .infinity }
        return Self.firstItemAt + Double(i) * Self.perItem
    }
    public func card(at t: Double) -> Double { ramp(t, from: beats?.opened ?? 0, over: Self.land) }
    public func heading(at t: Double) -> Double { ramp(t, from: (beats?.opened ?? 0) + Self.headingAt, over: Self.fade) }
    public func item(_ i: Int, at t: Double) -> Double {
        if let beats {
            guard i < beats.items.count, let slot = beats.items[i] else { return 0 }
            return ramp(t, from: itemStart(i), over: Self.fade * pace(slot))
        }
        return ramp(t, from: itemStart(i), over: Self.fade)
    }
    /// The arrow from item i to item i+1 draws just before item i+1 appears.
    public func arrow(_ i: Int, at t: Double) -> Double {
        if let beats {
            guard i + 1 < beats.items.count, let slot = beats.items[i + 1] else { return 0 }
            return ramp(t, from: slot.at, over: Self.stroke * pace(slot))
        }
        return ramp(t, from: itemStart(i + 1) - Self.stroke * 0.6, over: Self.stroke)
    }
    var takeawayAt: Double { beats.map { $0.takeaway?.at ?? .infinity } ?? itemStart(items) }
    public func takeaway(at t: Double) -> Double {
        ramp(t, from: takeawayAt, over: beats?.takeaway?.draw ?? Self.fade)
    }
    public var chipsAt: Double {
        if let beats { return beats.chips ?? .infinity }
        return takeawayAt + (hasTakeaway ? Self.fade : 0) + Self.chipsAfter
    }
    public func chips(at t: Double) -> Double { ramp(t, from: chipsAt, over: Self.fade) }
    /// When the last thing has finished appearing (infinite while a card on beats still grows).
    public var duration: Double { reduceMotion && beats == nil ? 0 : chipsAt + Self.fade }
}

extension ExplainCardPlacement {
    /// What a pointing mark covers, in screenshot pixels with room for its label (a point or note
    /// gets a 120-pixel square around it): the card keeps clear of what the same reply points at.
    public static func pixelBounds(of shape: PointingShape) -> CGRect {
        func box(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) -> CGRect {
            CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1)).insetBy(dx: -24, dy: -24)
        }
        func points(_ v: [Int]) -> CGRect {
            let xs = stride(from: 0, to: v.count - 1, by: 2).map { v[$0] }
            let ys = stride(from: 1, to: v.count, by: 2).map { v[$0] }
            guard let x1 = xs.min(), let x2 = xs.max(), let y1 = ys.min(), let y2 = ys.max() else { return .zero }
            return box(x1, y1, x2, y2)
        }
        switch shape {
        case .edit:
            return .null
        case .text(let x, let y):
            return CGRect(x: x - 24, y: y - 40, width: 400, height: 80)
        case .point(let x, let y), .note(let x, let y), .callout(let x, let y):
            return CGRect(x: x - 60, y: y - 60, width: 120, height: 120)
        case .box(let x1, let y1, let x2, let y2), .circle(let x1, let y1, let x2, let y2),
             .arrow(let x1, let y1, let x2, let y2), .underline(let x1, let y1, let x2, let y2),
             .highlight(let x1, let y1, let x2, let y2), .oval(let x1, let y1, let x2, let y2),
             .group(let x1, let y1, let x2, let y2):
            return box(x1, y1, x2, y2)
        case .path(let v), .line(let v), .shape(let v):
            return points(v)
        }
    }
}
