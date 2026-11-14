import Foundation

// An explanation card drawn as Benji speaks (chilly-beats): each part appears on the sentence
// that talks about it. The model writes card lines between its spoken sentences
// (`ExplainCardLine`); a spoken sentence owns the parts written after it, up to the next one.
// The voice is the clock: a sentence's parts are spread over its real playing time, or over an
// estimate when there is no voice. Pure values only: the app feeds them events and the time.

/// One reply's card as it streams: the card so far, the spoken sentences, and which sentence
/// each part belongs to.
public struct CardScript: Equatable, Sendable {
    public private(set) var draft: ExplainCardDraft?
    /// One per part, in drawing order (items and the takeaway, as they came): the sentence it
    /// belongs to, nil when it came before any sentence.
    public private(set) var owners: [Int?] = []
    /// Which part is the takeaway, if one came.
    public private(set) var takeawayPart: Int?
    /// The spoken sentences so far, and when each one's text was complete.
    public private(set) var lines: [String] = []
    public private(set) var lineReady: [Double] = []
    /// The answer arrived: no more sentences or parts.
    public private(set) var ended = false
    private var raw = ""
    private var stream = SentenceStream()

    public init() {}

    /// A piece of the spoken text (the engine's deltas, card lines already taken out).
    public mutating func delta(_ piece: String, at t: Double) {
        guard !ended else { return }
        raw += piece
        for s in stream.feed(StreamingReply.visible(raw)) {
            lines.append(s)
            lineReady.append(t)
        }
    }

    /// The sentence a part arriving now belongs to: the one being written, else the last one
    /// finished, else none (the part comes before anything is said).
    var currentOwner: Int? {
        if !stream.pending.isEmpty { return lines.count }
        return lines.isEmpty ? nil : lines.count - 1
    }

    /// A card line; true when it changed the card. The first `card:` line opens it (a later one
    /// is ignored: one card per reply); an item before any `card:` line opens a plain one.
    public mutating func card(_ line: ExplainCardLine) -> Bool {
        guard !ended else { return false }
        switch line {
        case .open(let header):
            guard draft == nil else { return false }
            draft = ExplainCardDraft(header: header)
        case .item(let item):
            if draft == nil { draft = ExplainCardDraft(header: ExplainCardHeader(title: "Benji")) }
            guard draft!.add(item) else { return false }
            // Items keep their order among the parts; a takeaway that came early stays last drawn.
            owners.append(currentOwner)
        case .takeaway(let text):
            guard draft != nil else { return false }
            draft!.takeaway = text
            if takeawayPart == nil {
                takeawayPart = owners.count
                owners.append(currentOwner)
            }
        case .chips(let chips):
            guard draft != nil else { return false }
            draft!.chips = chips
        }
        return true
    }

    /// The engine took back what streamed (a tool call followed it): the card goes with it.
    public mutating func reset() {
        self = CardScript()
    }

    /// The answer arrived (`spoken`: its text without card lines): the last sentences are known.
    public mutating func finish(spoken: String, at t: Double) {
        guard !ended else { return }
        if let rest = stream.finish(StreamingReply.visible(spoken)) {
            for s in SentenceStream.sentences(rest) {
                lines.append(s)
                lineReady.append(t)
            }
        }
        ended = true
    }

    /// Card lines that came only with the answer (the engine streamed nothing), each with how many
    /// characters (Unicode scalars) of `spoken` came before it: the script as if it had streamed.
    public static func replay(spoken: String, lines: [(line: ExplainCardLine, at: Int)], at t: Double) -> CardScript {
        var script = CardScript()
        let scalars = Array(spoken.unicodeScalars)
        var said = 0
        for (line, at) in lines {
            let upTo = min(max(at, said), scalars.count)
            if upTo > said {
                script.delta(String(String.UnicodeScalarView(scalars[said..<upTo])), at: t)
                said = upTo
            }
            _ = script.card(line)
        }
        if said < scalars.count { script.delta(String(String.UnicodeScalarView(scalars[said...])), at: t) }
        script.finish(spoken: spoken, at: t)
        return script
    }

    /// A whole card from an older reply's fenced block (D-125): its parts come before any
    /// sentence, so they are drawn at once, as that card was.
    public static func fenced(_ card: ExplainCard, spoken: String, at t: Double) -> CardScript {
        var script = CardScript()
        _ = script.card(.open(ExplainCardHeader(title: card.title, heading: card.heading, layout: card.layout)))
        for item in card.items { _ = script.card(.item(item)) }
        if let takeaway = card.takeaway { _ = script.card(.takeaway(takeaway)) }
        if !card.chips.isEmpty { _ = script.card(.chips(card.chips)) }
        script.delta(spoken, at: t)
        script.finish(spoken: spoken, at: t)
        return script
    }

    /// A finished answer that still holds its card lines (one-shot mode, an older engine): its
    /// spoken text, and the script as if it had streamed.
    public static func whole(_ answer: String, at t: Double) -> (text: String, script: CardScript) {
        var script = CardScript()
        var spoken = ""
        var lines = answer.components(separatedBy: "\n")
        let last = lines.removeLast()
        for (line, end) in lines.map({ ($0, "\n") }) + [(last, "")] {
            switch ExplainCardGrammar.line(line) {
            case .text:
                // A takeaway or chips later in the line is never spoken (chilly-whiteboard).
                if let (said, read) = ExplainCardGrammar.inlineSplit(line) {
                    spoken += said + end
                    script.delta(said + end, at: t)
                    if case .card(let l) = read { _ = script.card(l) }
                    continue
                }
                spoken += line + end
                script.delta(line + end, at: t)
            case .dropped:
                break
            case .card(let l):
                _ = script.card(l)
            }
        }
        script.finish(spoken: spoken, at: t)
        return (spoken, script)
    }
}

/// Spreads a card's parts over the sentences that own them (pure: re-run on every event).
///
/// A sentence's parts are drawn between a small lead after it starts and a small tail before
/// it ends, at the pace that fills that time: the fit (time available over natural drawing
/// time) is kept between `rush` and `slowest` (`openSlowest` while more parts may still come for
/// the sentence), and the pauses between parts stretch at most `gapStretch`, so spare time is
/// a rest at the end of the sentence, not gaps inside the card. Parts go in strict order: one
/// whose sentence hasn't started holds back every part after it. A sentence the voice is
/// already past has its parts drawn at once, at the rush pace; parts before any sentence are
/// drawn at once at their natural pace.
public enum BeatPlanner {
    public static let lead = 0.15
    public static let tail = 0.25
    public static let rush = 0.1
    public static let slowest = 1.4
    public static let openSlowest = 1.3
    public static let gapStretch = 1.25
    /// The natural pause between two parts of one sentence.
    public static let gap = 0.1

    /// What is known of a spoken sentence: when it starts and ends being heard (nil: not yet
    /// known; the end may be an estimate), and whether more parts may still come for it.
    public struct Line: Equatable, Sendable {
        public var start: Double?
        public var end: Double?
        public var open: Bool

        public init(start: Double?, end: Double?, open: Bool = false) {
            self.start = start
            self.end = end
            self.open = open
        }
    }

    public struct Part: Equatable, Sendable {
        /// The sentence it belongs to (nil: before any).
        public var owner: Int?
        /// How long it takes to draw at its own pace.
        public var natural: Double

        public init(owner: Int?, natural: Double) {
            self.owner = owner
            self.natural = natural
        }
    }

    /// When a part starts drawing and how long it takes.
    public struct Slot: Equatable, Sendable {
        public var at: Double
        public var draw: Double

        public init(at: Double, draw: Double) {
            self.at = at
            self.draw = draw
        }

        public var end: Double { at + draw }
    }

    /// Slots for `parts` after the `released` ones (which are fixed), as of `now`; nil for a
    /// part held back (its sentence hasn't started, or one before it is held).
    public static func plan(lines: [Line], parts: [Part], released: [Slot], now: Double) -> [Slot?] {
        var out: [Slot?] = []
        var cursor = released.last?.end ?? -.infinity
        var i = released.count
        // The part before was released: one of the same sentence keeps the pause after it.
        if let last = released.last, i < parts.count, parts[i].owner != nil, parts[i - 1].owner == parts[i].owner {
            cursor = last.end + gap * min(last.draw / max(parts[i - 1].natural, 1e-6), gapStretch)
        }
        while i < parts.count {
            let owner = parts[i].owner
            var j = i
            while j < parts.count, parts[j].owner == owner { j += 1 }
            let group = parts[i..<j]
            guard let o = owner else {
                for p in group {
                    let at = max(now, cursor)
                    out.append(Slot(at: at, draw: p.natural))
                    cursor = at + p.natural + gap
                }
                cursor -= gap
                i = j
                continue
            }
            guard o < lines.count, let start = lines[o].start else { break }
            let line = lines[o]
            let from = max(now, start + lead, cursor)
            let natural = group.reduce(0) { $0 + $1.natural } + gap * Double(group.count - 1)
            var fit = 1.0
            if let end = line.end {
                if now >= end {
                    fit = rush                  // the voice is past it: draw it now
                } else {
                    fit = (end - tail - from) / max(natural, 1e-6)
                    fit = min(max(fit, rush), line.open ? openSlowest : slowest)
                }
            }
            let pause = gap * min(fit, gapStretch)
            var at = from
            for p in group {
                out.append(Slot(at: at, draw: p.natural * fit))
                at += p.natural * fit + pause
            }
            cursor = at - pause
            i = j
        }
        return out + Array(repeating: nil, count: parts.count - released.count - out.count)
    }
}

/// When each spoken sentence is heard: from the voice's word marks when there is a voice, from
/// an estimate (`RevealTiming`'s syllables, about 2.6 words a second) when there isn't.
public struct BeatLines: Equatable, Sendable {
    public enum Clock: Equatable, Sendable { case voice, estimate }
    /// A turn that should speak but has made no sound this long after its answer arrived is
    /// timed by the estimate instead.
    public static let voiceGrace = 4.0

    public var clock: Clock
    /// The sentences as the voice says them (`SpeechText.plain`), and when each one's text was
    /// complete.
    public private(set) var texts: [String] = []
    public private(set) var ready: [Double] = []
    /// When the answer arrived (no more sentences); nil while it streams.
    public private(set) var closedAt: Double?
    /// The text the voice was given (UTF-16 offsets in it) and when each word is heard.
    public private(set) var spoken = ""
    public private(set) var marks: [SpokenProgress.Mark] = []
    public private(set) var speechEndedAt: Double?

    public init(clock: Clock) { self.clock = clock }

    /// The script's sentences (only ever more of them).
    public mutating func sync(lines: [String], ready: [Double], closed: Bool, at t: Double) {
        if lines.count > texts.count {
            texts += lines[texts.count...].map(SpeechText.plain)
            self.ready += ready[self.ready.count..<lines.count]
        }
        if closed, closedAt == nil { closedAt = t }
    }

    /// The voice's text so far and new word marks. Text that doesn't go on from what the voice
    /// said before is a new answer: earlier marks are dropped.
    public mutating func heard(spoken text: String, marks new: [SpokenProgress.Mark]) {
        if !text.hasPrefix(spoken) {
            marks = []
            speechEndedAt = nil
        }
        spoken = text
        marks += new
    }

    /// The voice stopped. Counted only once it has said something of this answer (a stop
    /// reported late for the answer before must not hurry this card).
    public mutating func speechEnded(at t: Double) {
        guard !marks.isEmpty, speechEndedAt == nil else { return }
        speechEndedAt = t
    }

    /// Estimated seconds to say `text`.
    public static func seconds(_ text: String) -> Double {
        let tokens = RevealTiming.tokenize(text)
        return RevealTiming.seconds(before: tokens.count, in: tokens)
    }

    public func timings(now: Double) -> [BeatPlanner.Line] {
        switch clock {
        case .estimate:
            return estimated(from: -.infinity)
        case .voice:
            if marks.isEmpty, speechEndedAt == nil, let closed = closedAt, now >= closed + Self.voiceGrace {
                return estimated(from: closed + Self.voiceGrace)
            }
            return voiced()
        }
    }

    private func open(_ i: Int) -> Bool { i == texts.count - 1 && closedAt == nil }

    /// Each sentence from when its text is there and the one before has been said.
    private func estimated(from base: Double) -> [BeatPlanner.Line] {
        var out: [BeatPlanner.Line] = []
        var previous = base
        for i in texts.indices {
            let start = max(ready[i], previous)
            let end = start + Self.seconds(texts[i])
            out.append(.init(start: start, end: end, open: open(i)))
            previous = end
        }
        return out
    }

    private func voiced() -> [BeatPlanner.Line] {
        let ns = spoken as NSString
        // Where each sentence is in what the voice was given, in order (nil: not found; a later
        // one may still be, when the voice's text was cleaned differently).
        var ranges: [NSRange?] = []
        var cursor = 0
        for text in texts {
            if text.isEmpty { ranges.append(NSRange(location: cursor, length: 0)); continue }
            let found = ns.range(of: text, options: [], range: NSRange(location: cursor, length: ns.length - cursor))
            if found.location == NSNotFound { ranges.append(nil); continue }
            ranges.append(found)
            cursor = found.location + found.length
        }
        func heard(_ r: NSRange) -> [SpokenProgress.Mark] {
            marks.filter { r.length > 0 && $0.offset >= r.location && $0.offset < r.location + r.length }
        }
        /// When the first located sentence after `i` is first heard.
        func nextHeard(after i: Int) -> Double? {
            for k in (i + 1)..<max(i + 1, texts.count) {
                if let r = ranges[k] { return heard(r).map(\.at).min() }
            }
            return nil
        }
        var out: [BeatPlanner.Line] = []
        for i in texts.indices {
            var start: Double?, end: Double?
            if ranges[i] == nil, let next = nextHeard(after: i) {
                // Not found, but the voice has reached a sentence after it: it was said in between.
                start = min(out.last?.end ?? next, next)
                end = next
            }
            if let r = ranges[i] {
                let own = heard(r)
                if r.length == 0 {
                    start = out.last?.end ?? out.last?.start
                    end = start
                } else if let first = own.min(by: { $0.at < $1.at }) {
                    start = first.at
                    if let nextFirst = nextHeard(after: i) {
                        end = nextFirst
                    } else if let last = own.max(by: { $0.offset < $1.offset }) {
                        let rest = ns.substring(with: NSRange(location: last.offset, length: r.location + r.length - last.offset))
                        end = max(last.at + Self.seconds(rest), first.at)
                    }
                }
            }
            if let stop = speechEndedAt {
                start = min(start ?? stop, stop)
                end = min(end ?? stop, stop)
            }
            if let s = start, end == nil { end = s + Self.seconds(texts[i]) }
            out.append(.init(start: start, end: end.map { max($0, start ?? $0) }, open: open(i)))
        }
        return out
    }
}

/// A card's parts in order and the ones already released to draw (their slots are fixed).
public struct BeatTrack: Equatable, Sendable {
    public private(set) var parts: [BeatPlanner.Part] = []
    public private(set) var released: [BeatPlanner.Slot] = []
    /// The answer was cut off: everything left is drawn at once, at the rush pace.
    public private(set) var hurried = false

    public init() {}

    public mutating func add(_ part: BeatPlanner.Part, now: Double) {
        parts.append(part)
        if hurried { hurry(now: now) }
    }

    public func plan(_ lines: [BeatPlanner.Line], now: Double) -> [BeatPlanner.Slot?] {
        BeatPlanner.plan(lines: lines, parts: parts, released: released, now: now)
    }

    /// Releases every part due by `now`, in order; returns how many.
    @discardableResult
    public mutating func advance(_ lines: [BeatPlanner.Line], now: Double) -> Int {
        let before = released.count
        for slot in plan(lines, now: now) {
            guard let slot, slot.at <= now + 1e-9 else { break }
            released.append(slot)
        }
        return released.count - before
    }

    /// When the next part is due; nil when none is planned yet.
    public func nextDue(_ lines: [BeatPlanner.Line], now: Double) -> Double? {
        plan(lines, now: now).first.flatMap { $0?.at }
    }

    /// Draws everything not yet released one after another from `now`, at the rush pace.
    public mutating func hurry(now: Double) {
        hurried = true
        var at = max(now, released.last?.end ?? now)
        for p in parts[released.count...] {
            released.append(.init(at: at, draw: p.natural * BeatPlanner.rush))
            at += p.natural * BeatPlanner.rush
        }
    }

    public var isDone: Bool { released.count == parts.count }
}

/// Everything the card stage times: the sentences' clock and the parts' track, kept in step with
/// the script.
public struct CardBeat: Equatable, Sendable {
    /// How long a part takes to draw at its own pace (the arrow into it, then its fade).
    public static let itemNatural = ExplainCardReveal.stroke * 0.6 + ExplainCardReveal.fade
    public static let takeawayNatural = 0.2
    /// Chips come this long after the last part is drawn.
    public static let chipsAfter = 0.15

    public var lines: BeatLines
    public private(set) var track = BeatTrack()
    public private(set) var ended = false
    /// Which part is the takeaway (it isn't an item of the layout).
    public private(set) var takeawayPart: Int?

    public init(clock: BeatLines.Clock) { lines = BeatLines(clock: clock) }

    public mutating func sync(_ script: CardScript, now: Double) {
        lines.sync(lines: script.lines, ready: script.lineReady, closed: script.ended, at: now)
        takeawayPart = script.takeawayPart
        while track.parts.count < script.owners.count {
            let i = track.parts.count
            track.add(.init(owner: script.owners[i], natural: i == script.takeawayPart ? Self.takeawayNatural : Self.itemNatural),
                      now: now)
        }
        ended = script.ended
    }

    /// Releases what is due; true when something new is to be drawn.
    @discardableResult
    public mutating func advance(now: Double) -> Bool {
        track.advance(lines.timings(now: now), now: now) > 0
    }

    public func nextDue(now: Double) -> Double? {
        track.nextDue(lines.timings(now: now), now: now)
    }

    /// The user cut Benji off (or the turn was cancelled): the rest is drawn at once.
    public mutating func cutOff(now: Double) {
        track.hurry(now: now)
        ended = true
    }

    /// The released slot of item `i` (counting items only, not the takeaway).
    public func itemSlot(_ i: Int) -> BeatPlanner.Slot? {
        var k = -1
        for (p, slot) in track.released.enumerated() where p != takeawayPart {
            k += 1
            if k == i { return slot }
        }
        return nil
    }

    public var takeawaySlot: BeatPlanner.Slot? {
        guard let t = takeawayPart, t < track.released.count else { return nil }
        return track.released[t]
    }

    /// When the chips may show: once the reply is over and every part is drawn.
    public var chipsAt: Double? {
        guard ended, track.isDone else { return nil }
        return (track.released.map(\.end).max() ?? 0) + Self.chipsAfter
    }
}
