import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A place on the screenshot the model wants to show the user (a `[POINT:x,y:label]` tag).
/// Kept for the app's current ring-only overlay; new code uses `PointingTarget`.
public struct PointTarget: Equatable, Sendable {
    public let x: Int        // pixels in the sent screenshot, origin top-left
    public let y: Int
    public let label: String

    public init(x: Int, y: Int, label: String) {
        self.x = x
        self.y = y
        self.label = label
    }
}

/// What the model sent, in pixels of the sent screenshot (origin top-left): a point or a box
/// to point at (top-left and bottom-right corners), or something to draw.
public enum PointingShape: Equatable, Sendable {
    case point(x: Int, y: Int)
    case box(x1: Int, y1: Int, x2: Int, y2: Int)
    /// A loop around the box.
    case circle(x1: Int, y1: Int, x2: Int, y2: Int)
    /// From x1,y1 to the tip at x2,y2.
    case arrow(x1: Int, y1: Int, x2: Int, y2: Int)
    case underline(x1: Int, y1: Int, x2: Int, y2: Int)
    /// A translucent marker over the box.
    case highlight(x1: Int, y1: Int, x2: Int, y2: Int)
    /// x1, y1, x2, y2, …: a freehand line through two or more points (the mapping drops more
    /// than forty), smoothed where it bends gently and kept sharp at its corners.
    case path([Int])
    /// x1, y1, x2, y2, …: straight segments through two or more points, corners kept.
    case line([Int])
    /// x1, y1, x2, y2, …: a closed outline through three or more points, corners kept.
    case shape([Int])
    /// An ellipse filling the box (not a loop around something: that's `circle`).
    case oval(x1: Int, y1: Int, x2: Int, y2: Int)
    /// A dashed rounded box around a whole region, such as a sidebar list.
    case group(x1: Int, y1: Int, x2: Int, y2: Int)
    /// The target's label is the note's text.
    case note(x: Int, y: Int)
    /// A small label pill beside x,y with a short pointer to it; the target's label is its text.
    case callout(x: Int, y: Int)
    /// Words written on the screen in Benji's hand from x,y (its left end, mid-letter); the
    /// target's label is "size:words" or the words (chilly-whiteboard).
    case text(x: Int, y: Int)
    /// A change to a part of the drawing already up (chilly-whiteboard). Not a mark of its own.
    case edit(DrawingEdit)

    /// POINT and BOX: the ring-and-region pointer, at most three per answer.
    public var isPointer: Bool {
        switch self {
        case .point, .box: return true
        default: return false
        }
    }

    /// PATH, LINE, SHAPE and OVAL: a picture drawn from parts, not a mark on something. An answer
    /// with one may use up to twenty tags, and its drawing stays up (D-97).
    public var isDrawing: Bool {
        switch self {
        case .path, .line, .shape, .oval, .text: return true
        default: return false
        }
    }

    public var edit: DrawingEdit? {
        if case let .edit(e) = self { return e }
        return nil
    }
}

/// One target of a pointing answer (D-66, D-67).
public struct PointingTarget: Equatable, Sendable {
    public let shape: PointingShape
    public let label: String
    /// In the beats form (chilly-whiteboard): characters (Unicode scalars) of the answer's text
    /// before this tag, so the sentence it follows owns it. Nil when every tag came at the end.
    public var at: Int?

    public init(shape: PointingShape, label: String, at: Int? = nil) {
        self.shape = shape
        self.label = label
        self.at = at
    }
}

/// Parses the pointing and drawing tags the engine may put at the end of a screen-context
/// answer, in the order the user should look at them: `[POINT:x,y:label]`,
/// `[BOX:x1,y1,x2,y2:label]`, `[CIRCLE|ARROW|UNDERLINE|HIGHLIGHT:x1,y1,x2,y2:label]`,
/// `[PATH|LINE|SHAPE:x1,y1,x2,y2,…:label]`, `[OVAL|GROUP:x1,y1,x2,y2:label]` and
/// `[NOTE|CALLOUT:x,y:text]`. Our own parser (D-56);
/// `benji/pointing.py` mirrors it, case for case.
public enum PointingTags {
    /// POINT and BOX tags kept.
    public static let maxTargets = 3
    /// Tags kept in all.
    public static let maxMarks = 6
    /// Tags kept in all when the answer draws a picture (any PATH, LINE, SHAPE or OVAL).
    public static let maxDrawingMarks = 20

    /// Returns the answer with every trailing tag removed (what's shown and spoken) and the
    /// targets in order. Only tags at the end count; a tag followed by text is left alone.
    /// Every trailing tag is removed from the text; the first six (twenty in a drawing) are
    /// kept, skipping POINT and BOX tags after the third.
    public static func parse(_ text: String) -> (text: String, targets: [PointingTarget]) {
        var rest = Substring(text)
        var found: [PointingTarget] = []
        while true {
            let trimmed = rest.trimmingTrailingWhitespace()
            guard trimmed.hasSuffix("]"), let open = trimmed.lastIndex(of: "["),
                  let target = target(from: trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
            else { break }
            found.insert(target, at: 0)
            rest = trimmed[..<open]
        }
        guard !found.isEmpty else { return (text, []) }
        let clean = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        return (clean, capped(found))
    }

    /// At most six (twenty when any of them draws a picture), of which at most three POINT or
    /// BOX, in order.
    public static func capped(_ targets: [PointingTarget]) -> [PointingTarget] {
        let marks = targets.filter { $0.shape.edit == nil }
        let limit = marks.contains(where: \.shape.isDrawing) ? maxDrawingMarks : maxMarks
        var kept: [PointingTarget] = []
        var pointers = 0
        for t in marks {
            if kept.count == limit { break }
            if t.shape.isPointer {
                if pointers == maxTargets { continue }
                pointers += 1
            }
            kept.append(t)
        }
        // Edits don't count against the marks; they keep their own limit, after them.
        return kept + targets.filter { $0.shape.edit != nil }.prefix(DrawingEdit.maxEdits)
    }

    /// `body` is the tag without its brackets, e.g. `BOX:10,20,30,40:Search field`.
    static func target(from body: Substring) -> PointingTarget? {
        guard !body.contains("]"), let colon = body.firstIndex(of: ":") else { return nil }
        let kind = body[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let afterKind = body[body.index(after: colon)...]
        let coordsPart: Substring
        var label = ""
        if let labelColon = afterKind.firstIndex(of: ":") {
            coordsPart = afterKind[..<labelColon]
            label = afterKind[afterKind.index(after: labelColon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            coordsPart = afterKind
        }
        let numbers = coordsPart.split(separator: ",", omittingEmptySubsequences: false).map(number)
        guard !numbers.contains(where: { $0 == nil }) else { return nil }
        return shape(kind: kind, numbers.compactMap { $0 }).map { PointingTarget(shape: $0, label: label) }
    }

    /// The shape for an upper-case tag name and its numbers; nil for an unknown name or the
    /// wrong count. Shared with the serve protocol, which sends the name in lower case.
    static func shape(kind: String, _ n: [Int]) -> PointingShape? {
        switch (kind, n.count) {
        case ("POINT", 2):     return .point(x: n[0], y: n[1])
        case ("BOX", 4):       return .box(x1: n[0], y1: n[1], x2: n[2], y2: n[3])
        case ("CIRCLE", 4):    return .circle(x1: n[0], y1: n[1], x2: n[2], y2: n[3])
        case ("ARROW", 4):     return .arrow(x1: n[0], y1: n[1], x2: n[2], y2: n[3])
        case ("UNDERLINE", 4): return .underline(x1: n[0], y1: n[1], x2: n[2], y2: n[3])
        case ("HIGHLIGHT", 4): return .highlight(x1: n[0], y1: n[1], x2: n[2], y2: n[3])
        case ("OVAL", 4):      return .oval(x1: n[0], y1: n[1], x2: n[2], y2: n[3])
        case ("GROUP", 4):     return .group(x1: n[0], y1: n[1], x2: n[2], y2: n[3])
        case ("NOTE", 2):      return .note(x: n[0], y: n[1])
        case ("CALLOUT", 2):   return .callout(x: n[0], y: n[1])
        case ("TEXT", 2):      return .text(x: n[0], y: n[1])
        case ("PATH", let c) where c >= 4 && c % 2 == 0: return .path(n)
        case ("LINE", let c) where c >= 4 && c % 2 == 0: return .line(n)
        case ("SHAPE", let c) where c >= 6 && c % 2 == 0: return .shape(n)
        default:               return nil
        }
    }

    /// A whole or decimal number, optionally negative; decimals round half up.
    static func number(_ s: Substring) -> Int? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.range(of: #"^-?[0-9]{1,6}(\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let v = Double(t) else { return nil }
        return Int((v + 0.5).rounded(.down))
    }
}

/// The current single-target API: the first POINT or BOX, a box given as its centre.
public enum PointingTag {
    public static func parse(_ text: String) -> (text: String, target: PointTarget?) {
        let r = PointingTags.parse(text)
        return (r.text, r.targets.lazy.compactMap(\.ringTarget).first)
    }
}

extension PointingTarget {
    /// For the single-ring API: a point as it is, a box as its centre; nil for a drawing.
    public var ringTarget: PointTarget? {
        switch shape {
        case let .point(x, y):
            return PointTarget(x: x, y: y, label: label)
        case let .box(x1, y1, x2, y2):
            return PointTarget(x: (x1 + x2) / 2, y: (y1 + y2) / 2, label: label)
        default:
            return nil
        }
    }
}

/// The mark Benji draws for a target (Overlay.md, Marks), in AppKit global points.
public enum PointingMark: Equatable, Sendable {
    case ring(center: CGPoint, label: String)
    case region(rect: CGRect, label: String)
}

/// A pen mark Benji draws on the screen, in AppKit global points (origin bottom-left).
/// `label` names what it marks: it times the reveal and is what VoiceOver hears; only a note
/// shows words.
public enum Sketch: Equatable, Sendable {
    case circle(rect: CGRect, label: String)
    case arrow(from: CGPoint, to: CGPoint, label: String)
    case underline(from: CGPoint, to: CGPoint, label: String)
    case highlight(rect: CGRect, label: String)
    case path(points: [CGPoint], label: String)
    /// Straight segments; `closed` joins the last point back to the first (SHAPE).
    case polyline(points: [CGPoint], closed: Bool, label: String)
    case oval(rect: CGRect, label: String)
    /// A dashed rounded box around the rect.
    case group(rect: CGRect, label: String)
    case note(at: CGPoint, text: String)
    /// A label pill beside `at`, pointing to it.
    case callout(at: CGPoint, text: String)
    /// Words in Benji's hand starting at `at` (left end, mid-letter): chilly-whiteboard.
    case text(at: CGPoint, text: String, size: TextSize)

    public var label: String {
        switch self {
        case let .circle(_, l), let .arrow(_, _, l), let .underline(_, _, l),
             let .highlight(_, l), let .path(_, l), let .polyline(_, _, l), let .oval(_, l),
             let .group(_, l), let .note(_, l), let .callout(_, l), let .text(_, l, _):
            return l
        }
    }

    /// Part of a picture (path, polyline, oval, written words) rather than a mark on something on screen.
    public var isDrawing: Bool {
        switch self {
        case .path, .polyline, .oval, .text: return true
        default: return false
        }
    }
}

/// One thing an answer shows, in order: a pointer mark or a pen mark.
public enum OverlayItem: Equatable, Sendable {
    case mark(PointingMark)
    case sketch(Sketch)

    public var label: String {
        switch self {
        case let .mark(m): return m.label
        case let .sketch(s): return s.label
        }
    }

    public var mark: PointingMark? {
        if case let .mark(m) = self { return m }
        return nil
    }

    public var sketch: Sketch? {
        if case let .sketch(s) = self { return s }
        return nil
    }
}

/// Maps targets in the sent screenshot back to the screen it was taken from.
public enum PointMapping {
    /// A box no bigger than this on both sides (points) gets a ring at its centre.
    public static let ringMaxSide: CGFloat = 44
    /// A box covering more than this share of the display's area gets no mark.
    public static let maxAreaFraction: CGFloat = 1.0 / 3.0
    /// Nor does a box wider or taller than this share of the display.
    public static let maxSideFraction: CGFloat = 0.8

    /// `screenFrame` is the display's frame in AppKit coordinates (origin bottom-left, points);
    /// `pixelSize` is the size of the image that was sent. Returns nil for a point outside the image.
    public static func screenPoint(for target: PointTarget, pixelSize: CGSize, screenFrame: CGRect) -> CGPoint? {
        screenPoint(x: target.x, y: target.y, pixelSize: pixelSize, screenFrame: screenFrame)
    }

    static func screenPoint(x: Int, y: Int, pixelSize: CGSize, screenFrame: CGRect) -> CGPoint? {
        guard pixelSize.width > 0, pixelSize.height > 0,
              x >= 0, y >= 0,
              CGFloat(x) <= pixelSize.width, CGFloat(y) <= pixelSize.height else { return nil }
        let sx = screenFrame.width / pixelSize.width
        let sy = screenFrame.height / pixelSize.height
        return CGPoint(x: screenFrame.minX + CGFloat(x) * sx,
                       y: screenFrame.maxY - CGFloat(y) * sy)
    }

    /// The box in screen points. Nil if either corner is outside the image. Corners given in
    /// the wrong order are put right.
    public static func screenRect(x1: Int, y1: Int, x2: Int, y2: Int,
                                  pixelSize: CGSize, screenFrame: CGRect) -> CGRect? {
        guard let a = screenPoint(x: x1, y: y1, pixelSize: pixelSize, screenFrame: screenFrame),
              let b = screenPoint(x: x2, y: y2, pixelSize: pixelSize, screenFrame: screenFrame) else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Picks the mark for one target: a point gets a ring; a box up to 44 × 44 pt a ring at its
    /// centre; a larger box a region, unless it covers more than a third of the display or more
    /// than 80% of its width or height (then no mark: say it in words). Nil also when outside the image.
    public static func mark(for target: PointingTarget, pixelSize: CGSize, screenFrame: CGRect) -> PointingMark? {
        switch target.shape {
        case let .point(x, y):
            return screenPoint(x: x, y: y, pixelSize: pixelSize, screenFrame: screenFrame)
                .map { .ring(center: $0, label: target.label) }
        case let .box(x1, y1, x2, y2):
            guard let r = screenRect(x1: x1, y1: y1, x2: x2, y2: y2,
                                     pixelSize: pixelSize, screenFrame: screenFrame) else { return nil }
            if r.width <= ringMaxSide && r.height <= ringMaxSide {
                return .ring(center: CGPoint(x: r.midX, y: r.midY), label: target.label)
            }
            return tooBig(r.width, r.height, screenFrame: screenFrame) ? nil : .region(rect: r, label: target.label)
        default:
            return nil
        }
    }

    /// The pointer marks for an ordered answer (POINT and BOX only), skipping targets that get
    /// none. At most three.
    public static func marks(for targets: [PointingTarget], pixelSize: CGSize, screenFrame: CGRect) -> [PointingMark] {
        Array(targets.filter(\.shape.isPointer).prefix(PointingTags.maxTargets)
            .compactMap { mark(for: $0, pixelSize: pixelSize, screenFrame: screenFrame) })
    }

    // Pen marks (all in points): limits shared with benji/pointing.py.
    /// Path, line and shape.
    public static let maxPathPoints = 40
    /// Unicode scalars, as Python's `len` counts them.
    public static let maxNoteLength = 40
    /// A TEXT mark's words.
    public static let maxTextLength = 80
    /// A smaller loop is grown to this around its centre.
    public static let minCircleSide: CGFloat = 24
    /// A thinner highlight is dropped.
    public static let minHighlightSide: CGFloat = 6
    public static let minArrowLength: CGFloat = 24
    /// Underline and path.
    public static let minLineLength: CGFloat = 8
    /// Arrow and underline: at most this share of the display's long side.
    public static let maxLineFraction: CGFloat = 0.8
    /// Path, line and shape: total length at most this share of the long side.
    public static let maxPathFraction: CGFloat = 3
    /// A thinner oval is grown to this around its centre.
    public static let minOvalSide: CGFloat = 6
    /// A dashed group thinner than this is dropped.
    public static let minGroupSide: CGFloat = 12
    /// A group may run the display's full height (a sidebar), but cover at most half of it.
    public static let maxGroupAreaFraction: CGFloat = 0.5

    static func tooBig(_ w: CGFloat, _ h: CGFloat, screenFrame f: CGRect) -> Bool {
        w * h > f.width * f.height * maxAreaFraction || w > f.width * maxSideFraction || h > f.height * maxSideFraction
    }

    /// What one target shows: a pointer mark, or a pen mark. Nil when a point is outside the
    /// image, or the shape is too big or too small to draw (Benji says it in words instead).
    public static func item(for target: PointingTarget, pixelSize: CGSize, screenFrame: CGRect) -> OverlayItem? {
        func pt(_ x: Int, _ y: Int) -> CGPoint? { screenPoint(x: x, y: y, pixelSize: pixelSize, screenFrame: screenFrame) }
        let label = target.label
        let longSide = max(screenFrame.width, screenFrame.height)

        func line(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int, shortest: CGFloat) -> (CGPoint, CGPoint)? {
            guard let a = pt(x1, y1), let b = pt(x2, y2) else { return nil }
            let length = hypot(b.x - a.x, b.y - a.y)
            return length < shortest || length > longSide * maxLineFraction ? nil : (a, b)
        }
        func rect(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) -> CGRect? {
            screenRect(x1: x1, y1: y1, x2: x2, y2: y2, pixelSize: pixelSize, screenFrame: screenFrame)
        }

        switch target.shape {
        case .edit:
            return nil
        case let .text(x, y):
            let (size, words) = TextSize.split(label)
            guard (1...maxTextLength).contains(words.unicodeScalars.count), let p = pt(x, y) else { return nil }
            return .sketch(.text(at: p, text: words, size: size))
        case .point, .box:
            return mark(for: target, pixelSize: pixelSize, screenFrame: screenFrame).map(OverlayItem.mark)
        case let .note(x, y), let .callout(x, y):
            guard (1...maxNoteLength).contains(label.unicodeScalars.count), let p = pt(x, y) else { return nil }
            if case .callout = target.shape { return .sketch(.callout(at: p, text: label)) }
            return .sketch(.note(at: p, text: label))
        case let .arrow(x1, y1, x2, y2):
            return line(x1, y1, x2, y2, shortest: minArrowLength).map { .sketch(.arrow(from: $0.0, to: $0.1, label: label)) }
        case let .underline(x1, y1, x2, y2):
            return line(x1, y1, x2, y2, shortest: minLineLength).map { .sketch(.underline(from: $0.0, to: $0.1, label: label)) }
        case let .path(n), let .line(n), let .shape(n):
            let points = stride(from: 0, to: n.count - 1, by: 2).map { pt(n[$0], n[$0 + 1]) }
            guard points.count <= maxPathPoints, !points.contains(where: { $0 == nil }) else { return nil }
            let p = points.compactMap { $0 }
            let closed: Bool
            if case .shape = target.shape { closed = true } else { closed = false }
            let ring = closed ? p + [p[0]] : p
            let length = zip(ring, ring.dropFirst()).reduce(CGFloat(0)) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
            let xs = p.map(\.x), ys = p.map(\.y)
            guard length >= minLineLength, length <= longSide * maxPathFraction,
                  !tooBig(xs.max()! - xs.min()!, ys.max()! - ys.min()!, screenFrame: screenFrame) else { return nil }
            if case .path = target.shape { return .sketch(.path(points: p, label: label)) }
            return .sketch(.polyline(points: p, closed: closed, label: label))
        case let .oval(x1, y1, x2, y2):
            guard var r = rect(x1, y1, x2, y2) else { return nil }
            if r.width < minOvalSide { r = CGRect(x: r.midX - minOvalSide / 2, y: r.minY, width: minOvalSide, height: r.height) }
            if r.height < minOvalSide { r = CGRect(x: r.minX, y: r.midY - minOvalSide / 2, width: r.width, height: minOvalSide) }
            return tooBig(r.width, r.height, screenFrame: screenFrame) ? nil : .sketch(.oval(rect: r, label: label))
        case let .group(x1, y1, x2, y2):
            guard let r = rect(x1, y1, x2, y2), r.width >= minGroupSide, r.height >= minGroupSide,
                  r.width * r.height <= screenFrame.width * screenFrame.height * maxGroupAreaFraction else { return nil }
            return .sketch(.group(rect: r, label: label))
        case let .circle(x1, y1, x2, y2):
            guard var r = rect(x1, y1, x2, y2) else { return nil }
            if r.width < minCircleSide { r = CGRect(x: r.midX - minCircleSide / 2, y: r.minY, width: minCircleSide, height: r.height) }
            if r.height < minCircleSide { r = CGRect(x: r.minX, y: r.midY - minCircleSide / 2, width: r.width, height: minCircleSide) }
            return tooBig(r.width, r.height, screenFrame: screenFrame) ? nil : .sketch(.circle(rect: r, label: label))
        case let .highlight(x1, y1, x2, y2):
            guard let r = rect(x1, y1, x2, y2), r.width >= minHighlightSide, r.height >= minHighlightSide,
                  !tooBig(r.width, r.height, screenFrame: screenFrame) else { return nil }
            return .sketch(.highlight(rect: r, label: label))
        }
    }

    /// Everything an ordered answer shows, skipping targets that get nothing. At most six (twenty
    /// in a drawing), of which at most three pointer marks.
    public static func items(for targets: [PointingTarget], pixelSize: CGSize, screenFrame: CGRect) -> [OverlayItem] {
        PointingTags.capped(targets).compactMap { item(for: $0, pixelSize: pixelSize, screenFrame: screenFrame) }
    }
}

private extension Substring {
    func trimmingTrailingWhitespace() -> Substring {
        var s = self
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return s
    }
}
