import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// The screen as Benji's whiteboard: words written on the screen (TEXT),
// tags between sentences (each owned by the sentence before it, as card items are), edits of the
// drawing already up by part id, what Benji has on the screen for the model's next turn, and a
// board behind a drawing that would land on busy content. Pure values; the overlay and the
// offscreen renders feed them the time. `benji/pointing.py` mirrors the grammar case for case
// (companion/Tests/whiteboard-cases.json).

/// How large a TEXT mark is written.
public enum TextSize: String, Equatable, Sendable, CaseIterable {
    case small, medium, large

    /// The handwriting's size in points.
    public var points: CGFloat {
        switch self {
        case .small: return 20
        case .medium: return 28
        case .large: return 40
        }
    }

    /// A TEXT tag's label as its size and words: "large:a² + b² = c²", or just the words (medium).
    public static func split(_ label: String) -> (TextSize, String) {
        if let colon = label.firstIndex(of: ":"),
           let size = TextSize(rawValue: label[..<colon].trimmingCharacters(in: .whitespaces).lowercased()) {
            return (size, label[label.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (.medium, label.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// A colour the model may give a part (`[EDIT:p3:recolor red]`); mint is Benji's own ink.
public enum InkColor: String, Equatable, Sendable, CaseIterable {
    case mint, red, orange, yellow, green, blue, purple, pink, white

    /// sRGB, 0…1.
    public var rgb: (Double, Double, Double) {
        switch self {
        case .mint: return (102 / 255, 212 / 255, 207 / 255)
        case .red: return (1.0, 0.42, 0.42)
        case .orange: return (1.0, 0.62, 0.30)
        case .yellow: return (1.0, 0.85, 0.35)
        case .green: return (0.45, 0.85, 0.45)
        case .blue: return (0.42, 0.65, 1.0)
        case .purple: return (0.72, 0.55, 1.0)
        case .pink: return (1.0, 0.55, 0.80)
        case .white: return (0.96, 0.96, 0.96)
        }
    }
}

/// A change to a part of the drawing already up: `[EDIT:p3:move dx,dy]`, `scale f`,
/// `relabel words`, `erase`, `recolor name`, and `[EDIT:all:erase]` / `[EDIT:all:keep]`. A reply
/// with any edit adds its own new parts to the drawing instead of replacing it.
public struct DrawingEdit: Equatable, Sendable {
    public enum Op: String, Equatable, Sendable { case move, scale, relabel, erase, recolor, keep }

    public static let maxEdits = 20
    public static let maxMove = 4000
    public static let scaleRange = 0.2...5.0

    /// "p3", or "all" (erase, keep).
    public let part: String
    public let op: Op
    /// move: dx, dy in screenshot pixels; scale: the factor.
    public let numbers: [Double]
    /// relabel's words, recolor's colour name.
    public let text: String

    public init(part: String, op: Op, numbers: [Double] = [], text: String = "") {
        self.part = part
        self.op = op
        self.numbers = numbers
        self.text = text
    }

    /// The part's place in the drawing (p1 is 0); nil for "all".
    public var index: Int? { part.hasPrefix("p") ? Int(part.dropFirst()).map { $0 - 1 } : nil }

    /// `body` is the tag without brackets, e.g. `EDIT:p3:move 10,-20`. Nil unless well formed.
    public static func parse(_ body: Substring) -> DrawingEdit? {
        guard let c1 = body.firstIndex(of: ":"),
              body[..<c1].trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "EDIT" else { return nil }
        let rest = body[body.index(after: c1)...]
        guard let c2 = rest.firstIndex(of: ":") else { return nil }
        let rawPart = rest[..<c2].trimmingCharacters(in: .whitespacesAndNewlines)
        let whole = rawPart.lowercased() == "all"
        var number: Int?
        if rawPart.range(of: #"^[pP][1-9][0-9]{0,2}$"#, options: .regularExpression) != nil {
            number = Int(rawPart.dropFirst())
        }
        guard whole || number != nil else { return nil }
        let action = rest[rest.index(after: c2)...].trimmingCharacters(in: .whitespacesAndNewlines)
        let space = action.firstIndex(of: " ")
        let op = String(action[..<(space ?? action.endIndex)]).lowercased()
        let arg = space.map { action[$0...].trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        if whole {
            guard (op == "erase" || op == "keep"), arg.isEmpty else { return nil }
            return DrawingEdit(part: "all", op: Op(rawValue: op)!)
        }
        let id = "p\(number!)"
        switch op {
        case "move":
            let n = arg.split(separator: ",", omittingEmptySubsequences: false).map(PointingTags.number)
            guard n.count == 2, let dx = n[0], let dy = n[1], abs(dx) <= maxMove, abs(dy) <= maxMove,
                  dx != 0 || dy != 0 else { return nil }
            return DrawingEdit(part: id, op: .move, numbers: [Double(dx), Double(dy)])
        case "scale":
            guard arg.range(of: #"^[0-9]{1,2}(\.[0-9]{1,3})?$"#, options: .regularExpression) != nil,
                  let f = Double(arg), scaleRange.contains(f), f != 1 else { return nil }
            return DrawingEdit(part: id, op: .scale, numbers: [f])
        case "relabel":
            guard (1...PointMapping.maxTextLength).contains(arg.unicodeScalars.count) else { return nil }
            return DrawingEdit(part: id, op: .relabel, text: arg)
        case "erase":
            return arg.isEmpty ? DrawingEdit(part: id, op: .erase) : nil
        case "recolor":
            return InkColor(rawValue: arg.lowercased()).map { DrawingEdit(part: id, op: .recolor, text: $0.rawValue) }
        default:
            return nil
        }
    }
}

// MARK: tags anywhere

extension PointingTags {
    /// One tag's body: an edit or a target.
    static func tag(_ body: Substring) -> PointingTarget? {
        if let e = DrawingEdit.parse(body) { return PointingTarget(shape: .edit(e), label: "") }
        return target(from: body)
    }

    /// Every tag in the answer, wherever it stands, taken out of the text (the beats form puts each
    /// one right after the sentence it belongs to): the text as shown and spoken, and the targets
    /// (capped as `capped` does; edits after the marks). In the beats form (any tag before the end
    /// of the words) each target's `at` is the characters of text before it. A tag alone on its
    /// line goes with its line break; one inside a line takes the spaces before it. Tags only at the
    /// end come out exactly as `parse` gives them, with no `at`. Mirrors `split_tags` in
    /// benji/pointing.py.
    public static func split(_ text: String) -> (text: String, targets: [PointingTarget]) {
        let (rest, trailing) = trailingRun(text)
        let s = Array(rest.unicodeScalars)
        // Every well-formed tag: [ … ] with no bracket or line break inside, 1-2000 long.
        var tags: [(start: Int, end: Int, target: PointingTarget)] = []
        var k = 0
        while k < s.count {
            guard s[k] == "[" else { k += 1; continue }
            var j = k + 1
            while j < s.count, s[j] != "]", s[j] != "[", s[j] != "\n", j - k <= 2000 { j += 1 }
            if j < s.count, s[j] == "]", j > k + 1, let t = tag(Substring(String(String.UnicodeScalarView(s[(k + 1)..<j])))) {
                tags.append((k, j + 1, t))
                k = j + 1
            } else {
                k += 1
            }
        }
        let hasEdit = trailing.contains { $0.shape.edit != nil }
        if tags.isEmpty && !hasEdit {
            return trailing.isEmpty ? (text, []) : (rest, capped(trailing))
        }
        func str(_ a: Int, _ b: Int) -> String { String(String.UnicodeScalarView(s[a..<max(a, b)])) }
        func blank(_ x: String) -> Bool { x.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var pieces: [String] = [], found: [(PointingTarget, Int)] = []
        var said = 0, i = 0
        for (n, t) in tags.enumerated() {
            let lineStart = (s[..<t.start].lastIndex(of: "\n").map { $0 + 1 }) ?? 0
            let lineEnd = s[t.end...].firstIndex(of: "\n") ?? s.count
            var bare = ""
            var cursor = lineStart
            for o in tags where o.start >= lineStart && o.start < lineEnd {
                bare += str(cursor, o.start)
                cursor = o.end
            }
            bare += str(cursor, lineEnd)
            let alone = blank(bare)
            var before = alone ? str(i, max(i, lineStart)) : str(i, t.start)
            if !alone { while let last = before.unicodeScalars.last, last == " " || last == "\t" { before.unicodeScalars.removeLast() } }
            pieces.append(before)
            said += before.unicodeScalars.count
            found.append((t.target, said))
            i = t.end
            let lastOnLine = n + 1 == tags.count || tags[n + 1].start >= lineEnd
            if alone && lastOnLine { i = min(lineEnd + 1, s.count) }
        }
        pieces.append(str(i, s.count))
        let joined = pieces.joined()
        let lead = joined.unicodeScalars.prefix { CharacterSet.whitespacesAndNewlines.contains($0) }.count
        let shown = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        let length = shown.unicodeScalars.count
        var placed = found.map { ($0.0, min(max($0.1 - lead, 0), length)) }
        placed += trailing.map { ($0, length) }
        let beats = placed.contains { $0.1 < length }
        let marks = capped(placed.filter { $0.0.shape.edit == nil }.map { t, at in
            var t = t
            t.at = beats ? at : nil
            return t
        })
        let edits = placed.filter { $0.0.shape.edit != nil }.prefix(DrawingEdit.maxEdits).map { t, at in
            var t = t
            t.at = beats ? at : nil
            return t
        }
        return (shown, marks + edits)
    }

    /// The trailing run of tags (targets and edits) and the text before it, trimmed.
    static func trailingRun(_ text: String) -> (String, [PointingTarget]) {
        var rest = Substring(text)
        var found: [PointingTarget] = []
        while true {
            var trimmed = rest
            while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
            guard trimmed.hasSuffix("]"), let open = trimmed.lastIndex(of: "["),
                  let t = tag(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]) else { break }
            found.insert(t, at: 0)
            rest = trimmed[..<open]
        }
        guard !found.isEmpty else { return (text, []) }
        return (String(rest).trimmingCharacters(in: .whitespacesAndNewlines), found)
    }

    /// The text with every well-formed tag taken out, as `split` shows it.
    public static func stripped(_ text: String) -> String { split(text).text }
}

// MARK: beats on the overlay

/// Which sentence owns each mark of a beats-form answer: the one being written when the tag came,
/// else the last one finished, else none (the mark comes before anything is said), as card items
/// are owned (`CardScript`).
public enum MarkOwners {
    /// `text` is the answer as shown; `ats` each target's place in it (Unicode scalars).
    public static func of(text: String, ats: [Int]) -> (lines: [String], owners: [Int?]) {
        var stream = SentenceStream()
        var lines: [String] = []
        var owners: [Int?] = []
        let scalars = Array(text.unicodeScalars)
        for at in ats {
            let upTo = min(max(at, 0), scalars.count)
            lines += stream.feed(StreamingReply.visible(String(String.UnicodeScalarView(scalars[..<upTo]))))
            if !stream.pending.isEmpty { owners.append(lines.count) } else { owners.append(lines.isEmpty ? nil : lines.count - 1) }
        }
        if let rest = stream.finish(StreamingReply.visible(text)) { lines += SentenceStream.sentences(rest) }
        // An owner past the sentences found (text that never ended a sentence) is the last one.
        let last = lines.isEmpty ? nil : lines.count - 1
        return (lines, owners.map { $0.map { min($0, last ?? $0) } })
    }
}

/// A beats-form answer's marks drawn on their sentences: the same planner as
/// a card's parts (`BeatPlanner`), the same clock (`BeatLines`: the voice's word marks, else the
/// estimate). Feed it the voice and the time; it says which parts to draw, and at what pace.
public struct OverlayBeats: Equatable, Sendable {
    public var lines: BeatLines
    public private(set) var track = BeatTrack()
    public let naturals: [Double]

    /// `texts`: the answer's sentences; `owners`: each part's sentence; `naturals`: each part's
    /// own drawing time. `clock` is `.voice` when the answer is read aloud.
    public init(texts: [String], owners: [Int?], naturals: [Double], clock: BeatLines.Clock, now: Double) {
        precondition(owners.count == naturals.count)
        lines = BeatLines(clock: clock)
        lines.sync(lines: texts, ready: Array(repeating: now, count: texts.count), closed: true, at: now)
        self.naturals = naturals
        for (o, n) in zip(owners, naturals) { track.add(.init(owner: o, natural: n), now: now) }
    }

    /// Releases every part due by `now`; returns their indices.
    public mutating func advance(now: Double) -> [Int] {
        let before = track.released.count
        track.advance(lines.timings(now: now), now: now)
        return Array(before..<track.released.count)
    }

    public func nextDue(now: Double) -> Double? { track.nextDue(lines.timings(now: now), now: now) }

    public mutating func heard(spoken: String, marks: [SpokenProgress.Mark]) { lines.heard(spoken: spoken, marks: marks) }
    public mutating func speechEnded(at t: Double) { lines.speechEnded(at: t) }
    /// The next turn began or the user cut in: the rest is drawn at once, in order.
    public mutating func hurry(now: Double) { track.hurry(now: now) }

    /// Part i's draw time over its own: its slot's pace once released, else 1.
    public func pace(_ i: Int) -> Double {
        guard i < track.released.count, naturals[i] > 0 else { return 1 }
        return track.released[i].draw / naturals[i]
    }

    public func releasedAt(_ i: Int) -> Double? { i < track.released.count ? track.released[i].at : nil }
    public var isDone: Bool { track.isDone }
}

// MARK: the drawing up, by part

extension OverlayItem {
    /// The same item with every point mapped by `f` (AppKit global points).
    public func converted(_ f: (CGPoint) -> CGPoint) -> OverlayItem {
        switch self {
        case let .sketch(s): return .sketch(s.converted(f))
        case let .mark(.ring(c, l)): return .mark(.ring(center: f(c), label: l))
        case let .mark(.region(r, l)):
            let a = f(CGPoint(x: r.minX, y: r.minY)), b = f(CGPoint(x: r.maxX, y: r.maxY))
            return .mark(.region(rect: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x),
                                              height: abs(a.y - b.y)), label: l))
        }
    }

    /// What it covers (AppKit global points); a ring is its centre with a little room.
    public var bounds: CGRect {
        switch self {
        case let .sketch(s): return s.extent
        case let .mark(.ring(c, _)): return CGRect(x: c.x - 22, y: c.y - 22, width: 44, height: 44)
        case let .mark(.region(r, _)): return r
        }
    }

    /// The model's name for its kind, as the canvas lists it.
    public var kindName: String {
        switch self {
        case .mark(.ring): return "point"
        case .mark(.region): return "box"
        case let .sketch(s):
            switch s {
            case .circle: return "circle"
            case .arrow: return "arrow"
            case .underline: return "underline"
            case .highlight: return "highlight"
            case .path: return "path"
            case let .polyline(_, closed, _): return closed ? "shape" : "line"
            case .oval: return "oval"
            case .group: return "group"
            case .note: return "note"
            case .callout: return "callout"
            case .text: return "text"
            }
        }
    }

    /// With new words (TEXT, note, callout) or a new name (anything else).
    public func relabeled(_ words: String) -> OverlayItem {
        switch self {
        case let .mark(.ring(c, _)): return .mark(.ring(center: c, label: words))
        case let .mark(.region(r, _)): return .mark(.region(rect: r, label: words))
        case let .sketch(s):
            switch s {
            case let .circle(r, _): return .sketch(.circle(rect: r, label: words))
            case let .arrow(a, b, _): return .sketch(.arrow(from: a, to: b, label: words))
            case let .underline(a, b, _): return .sketch(.underline(from: a, to: b, label: words))
            case let .highlight(r, _): return .sketch(.highlight(rect: r, label: words))
            case let .path(p, _): return .sketch(.path(points: p, label: words))
            case let .polyline(p, c, _): return .sketch(.polyline(points: p, closed: c, label: words))
            case let .oval(r, _): return .sketch(.oval(rect: r, label: words))
            case let .group(r, _): return .sketch(.group(rect: r, label: words))
            case let .note(p, _): return .sketch(.note(at: p, text: String(words.prefix(PointMapping.maxNoteLength))))
            case let .callout(p, _): return .sketch(.callout(at: p, text: String(words.prefix(PointMapping.maxNoteLength))))
            case let .text(p, _, size): return .sketch(.text(at: p, text: words, size: size))
            }
        }
    }
}

extension Sketch {
    /// What it covers, words included at an estimate (a TEXT mark runs right from its point).
    public var extent: CGRect {
        if case let .text(p, words, size) = self {
            let w = CGFloat(words.count) * size.points * 0.5, h = size.points * 1.2
            return CGRect(x: p.x, y: p.y - h / 2, width: w, height: h)
        }
        return bounds
    }
}

/// The drawing up on the screen, part by part (p1 is the first): what the model is told it has
/// drawn, and what its edits change.
public struct DrawingParts: Equatable, Sendable {
    public struct Part: Equatable, Sendable {
        public var item: OverlayItem
        public var color: InkColor?
        public var erased = false

        public init(item: OverlayItem, color: InkColor? = nil) {
            self.item = item
            self.color = color
        }
    }

    /// What an edit did to one part.
    public enum Change: Equatable, Sendable {
        /// Moved or scaled: `transform` maps where it was to where it is (global points).
        case moved(index: Int, transform: CGAffineTransform)
        case relabeled(index: Int)
        case recolored(index: Int)
        case erased(index: Int)
    }

    public private(set) var parts: [Part] = []
    public init() {}

    public mutating func append(_ items: [OverlayItem]) {
        parts += items.map { Part(item: $0) }
    }

    /// Every part moved by `v` (AppKit global points): the drawing went onto a board, or the board
    /// was dragged.
    public mutating func shift(by v: CGVector) {
        for i in parts.indices { parts[i].item = parts[i].item.converted { CGPoint(x: $0.x + v.dx, y: $0.y + v.dy) } }
    }

    /// What the parts still up cover (AppKit global points); nil when none is.
    public var extent: CGRect? {
        let boxes = parts.filter { !$0.erased }.map(\.item.bounds)
        return boxes.isEmpty ? nil : boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
    }

    /// A picture is up: any part still up draws (a path, line, shape, oval or words).
    public var isDrawing: Bool { parts.contains { !$0.erased && $0.item.sketch?.isDrawing == true } }

    /// New marks that only mark up the picture already up: none of them draws (no path, line,
    /// shape, oval or words), and every one lands on a part of the picture still up. They add to
    /// it instead of replacing it: "highlight those lines" means the lines stay. `offset`
    /// moves the new marks the way the drawing was moved (onto a board); both places count.
    public func isMarkedUp(by items: [OverlayItem], offset: CGVector? = nil) -> Bool {
        let pictures = parts.filter { !$0.erased && $0.item.sketch?.isDrawing == true }.map(\.item.bounds)
        guard !items.isEmpty, !pictures.isEmpty else { return false }
        func lands(_ r: CGRect) -> Bool { pictures.contains { $0.insetBy(dx: -6, dy: -6).intersects(r) } }
        return items.allSatisfy { item in
            guard item.sketch?.isDrawing != true else { return false }
            let r = item.bounds
            return lands(r) || offset.map { lands(r.offsetBy(dx: $0.dx, dy: $0.dy)) } == true
        }
    }

    /// The parts still up, with their ids.
    public var live: [(id: String, part: Part)] {
        parts.enumerated().filter { !$0.element.erased }.map { ("p\($0.offset + 1)", $0.element) }
    }

    /// Applies one edit. `pointsPerPixel` turns the screenshot's pixels into the display's points
    /// (y down in the screenshot, up in AppKit). Returns what changed; nothing for an unknown part.
    public mutating func apply(_ edit: DrawingEdit, pointsPerPixel k: CGSize) -> [Change] {
        if edit.part == "all" {
            guard edit.op == .erase else { return [] }
            return parts.indices.filter { !parts[$0].erased }.map { i in
                parts[i].erased = true
                return .erased(index: i)
            }
        }
        guard let i = edit.index, parts.indices.contains(i), !parts[i].erased else { return [] }
        switch edit.op {
        case .move:
            let t = CGAffineTransform(translationX: CGFloat(edit.numbers[0]) * k.width, y: -CGFloat(edit.numbers[1]) * k.height)
            parts[i].item = parts[i].item.converted { $0.applying(t) }
            return [.moved(index: i, transform: t)]
        case .scale:
            let b = parts[i].item.bounds, f = CGFloat(edit.numbers[0])
            let t = CGAffineTransform(translationX: b.midX, y: b.midY).scaledBy(x: f, y: f).translatedBy(x: -b.midX, y: -b.midY)
            parts[i].item = parts[i].item.converted { $0.applying(t) }
            return [.moved(index: i, transform: t)]
        case .relabel:
            parts[i].item = parts[i].item.relabeled(edit.text)
            return [.relabeled(index: i)]
        case .recolor:
            parts[i].color = InkColor(rawValue: edit.text)
            return [.recolored(index: i)]
        case .erase:
            parts[i].erased = true
            return [.erased(index: i)]
        case .keep:
            return []
        }
    }
}

// MARK: what Benji has on the screen, for the model

/// What the app tells the engine Benji has on the screen now (`canvas` in a send), in the pixels
/// of the screenshot sent with this message (`benji/canvas.py` reads it).
public struct CanvasSnapshot: Equatable, Sendable {
    public struct Part: Equatable, Sendable {
        public let id: String
        public let kind: String
        public let label: String
        /// Nil: up on another display than the screenshot's.
        public let box: ScreenshotGeometry.PixelRect?

        public init(id: String, kind: String, label: String, box: ScreenshotGeometry.PixelRect?) {
            self.id = id
            self.kind = kind
            self.label = label
            self.box = box
        }
    }

    public var parts: [Part] = []
    public var board: ScreenshotGeometry.PixelRect?
    public var figureTitle = ""
    public var figureParts: [String] = []
    public var figureLabels: [String] = []
    public var cardTitle = ""
    public var cardItems: [String] = []

    public init() {}

    public var isEmpty: Bool {
        parts.isEmpty && figureTitle.isEmpty && figureParts.isEmpty && cardTitle.isEmpty && cardItems.isEmpty
    }

    public var object: [String: Any] {
        var o: [String: Any] = [:]
        func box(_ r: ScreenshotGeometry.PixelRect) -> [Int] { [r.x1, r.y1, r.x2, r.y2] }
        if !parts.isEmpty {
            o["parts"] = parts.map { p -> [String: Any] in
                var d: [String: Any] = ["id": p.id, "kind": p.kind, "label": p.label]
                if let b = p.box { d["box"] = box(b) }
                return d
            }
            if let b = board { o["board"] = box(b) }
        }
        if !figureTitle.isEmpty || !figureParts.isEmpty {
            o["figure"] = ["title": figureTitle, "parts": figureParts, "labels": figureLabels]
        }
        if !cardTitle.isEmpty || !cardItems.isEmpty { o["card"] = ["title": cardTitle, "items": cardItems] }
        return o
    }

    /// A rect in AppKit global points as pixels of a screenshot of `screenFrame` sent at
    /// `pixelSize`; nil when it isn't on that display.
    public static func pixels(_ r: CGRect, screenFrame f: CGRect, pixelSize: CGSize) -> ScreenshotGeometry.PixelRect? {
        guard f.width > 0, f.height > 0, pixelSize.width > 0, r.intersects(f) || (r.width == 0 && f.contains(r.origin)) else { return nil }
        let sx = pixelSize.width / f.width, sy = pixelSize.height / f.height
        let w = Int(pixelSize.width.rounded(.down)), h = Int(pixelSize.height.rounded(.down))
        func cx(_ x: CGFloat) -> Int { min(max(Int(((x - f.minX) * sx).rounded()), 0), w) }
        func cy(_ y: CGFloat) -> Int { min(max(Int(((f.maxY - y) * sy).rounded()), 0), h) }
        return .init(x1: cx(r.minX), y1: cy(r.maxY), x2: cx(r.maxX), y2: cy(r.minY))
    }

    /// The drawing's parts as the model should see them in this turn's screenshot. `drawnOn` is
    /// the display the drawing is on; parts on another display get no box.
    public static func parts(_ drawing: DrawingParts, drawnOn: CGRect, screenFrame: CGRect, pixelSize: CGSize) -> [Part] {
        drawing.live.map { id, part in
            let box = drawnOn == screenFrame ? pixels(part.item.bounds, screenFrame: screenFrame, pixelSize: pixelSize) : nil
            return Part(id: id, kind: part.item.kindName, label: String(part.item.label.prefix(80)), box: box)
        }
    }
}

// MARK: a board behind a drawing on busy space

/// Where a drawing goes when the box the model picked lands on busy content (the explanation
/// card's `BusyMap`, the same 8%): onto Benji's board, a dark card with a faint grid, placed on
/// calm space near the panel by `ExplainCardPlacement`, with every part moved by the same offset
/// so it is drawn there exactly as on bare screen. Display-local points, top-left origin, y down.
public enum DrawingBoard {
    /// Room around the parts inside the board.
    public static let padding: CGFloat = 28
    /// A board is never smaller than this.
    public static let minimumSize = CGSize(width: 240, height: 180)

    public struct Result: Equatable, Sendable {
        /// The board, and how far every part moves to sit on it.
        public var frame: CGRect
        public var offset: CGVector
    }

    /// `drawing`: the parts' extent. Nil when it sits on calm space (no board).
    public static func place(drawing: CGRect, visible: CGRect, busy: BusyMap?, prefer: CGPoint,
                             avoid: [CGRect] = []) -> Result? {
        guard let busy, !drawing.isNull, drawing.width > 0 || drawing.height > 0,
              busy.coverage(of: drawing) >= ExplainCardPlacement.busySpace else { return nil }
        let size = CGSize(width: max(drawing.width + 2 * padding, minimumSize.width),
                          height: max(drawing.height + 2 * padding, minimumSize.height))
        let placed = ExplainCardPlacement.place(size: size, visible: visible, prefer: prefer, avoid: avoid, busy: busy)
        let f = placed.frame
        // The parts keep their middle at the board's middle.
        return Result(frame: f, offset: CGVector(dx: f.midX - drawing.midX, dy: f.midY - drawing.midY))
    }
}
