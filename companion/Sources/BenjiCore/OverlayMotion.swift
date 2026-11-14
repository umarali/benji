import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension TimingCurve {
    /// The curve's output at input progress `x` (0…1), as Core Animation evaluates it.
    public func value(at x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
        }
        // x(t) is monotonic for valid control points: bisect for t, then read y(t).
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if bezier(mid, c1x, c2x) < x { lo = mid } else { hi = mid }
        }
        return bezier((lo + hi) / 2, c1y, c2y)
    }
}

extension SpringToken {
    /// When a step from rest first reaches `fraction` of the way (the label of a glide fades
    /// in when 35% of the hop remains: `time(toReach: 0.65)`).
    public func time(toReach fraction: Double) -> Double {
        var lo = 0.0, hi = 4 * duration
        for _ in 0..<50 {
            let mid = (lo + hi) / 2
            if stepResponse(at: mid) < fraction { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
}

/// How far along a mark is at one moment. Everything is 0…1; nothing here depends on a clock,
/// so the live overlay and the offscreen renders draw the same frames.
public struct MarkPhase: Equatable, Sendable {
    /// `strokeEnd` of the mint stroke and both keylines (drawn clockwise from 12 o'clock).
    public var draw: CGFloat = 1
    /// The whole mark and its label: the Reduce Motion fade-in, the erase fade-out.
    public var opacity: Double = 1
    /// The halo and the material band under it.
    public var halo: Double = 1
    public var label: Double = 1
    /// The previous target's label while a ring glides away from it.
    public var previousLabel: Double = 0
    /// The halo copy's progress while the one pulse runs; nil before and after.
    public var pulse: CGFloat?
    /// A glide's progress from the previous ring to this one.
    public var travel: CGFloat = 1

    public init() {}
}

/// The reveal, glide and erase of one mark as functions of time (Overlay.md, Reveal).
public enum MarkTimeline {
    /// The pulse: a copy of the halo grows this far outward while fading from 28% to 0.
    public static let pulseGrow: CGFloat = 10
    public static let haloOpacity = 0.28

    static func drawToken(_ kind: MarkKind) -> SpringToken {
        kind == .ring ? MotionTokens.content : MotionTokens.open
    }

    /// When the one pulse starts: once the stroke (or the glide) has settled.
    public static func pulseStart(kind: MarkKind, step: MarkStep) -> Double {
        if case .glide = step { return MotionTokens.follow.settleTime }
        return drawToken(kind).settleTime
    }

    /// From the start of the reveal to rest, after which nothing moves: ring ≈ 0.875 s,
    /// region ≈ 1.18 s, glide ≈ 1.0 s, any of them 0.2 s under Reduce Motion.
    public static func restTime(kind: MarkKind, step: MarkStep, reduceMotion: Bool) -> Double {
        if reduceMotion { return MotionTokens.reduceDuration }
        return pulseStart(kind: kind, step: step) + MotionTokens.open.settleTime
    }

    public static func phase(kind: MarkKind, step: MarkStep, reduceMotion: Bool, at t: Double) -> MarkPhase {
        var p = MarkPhase()
        if reduceMotion {
            // The whole mark fades in at once; no drawing, pulse or glide.
            p.opacity = MotionTokens.reduceCurve.value(at: t / MotionTokens.reduceDuration)
            return p
        }
        let fadeIn = { (t: Double) in MotionTokens.fadeIn.value(at: t / MotionTokens.fadeDuration) }
        switch step {
        case .reveal:
            let token = drawToken(kind)
            p.draw = t >= token.settleTime ? 1 : CGFloat(max(token.stepResponse(at: max(t, 0)), 0))
            p.halo = fadeIn(t)
            p.label = fadeIn(t - token.contentFadeInDelay)
        case .glide:
            let token = MotionTokens.follow
            p.travel = t >= token.settleTime ? 1 : CGFloat(max(token.stepResponse(at: max(t, 0)), 0))
            p.previousLabel = 1 - MotionTokens.fadeOut.value(at: t / MotionTokens.fadeDuration)
            p.label = fadeIn(t - token.time(toReach: 0.65))
        }
        let start = pulseStart(kind: kind, step: step)
        if t >= start && t < start + MotionTokens.open.settleTime {
            p.pulse = CGFloat(MotionTokens.open.stepResponse(at: t - start))
        }
        return p
    }

    /// Opacity while erasing (`motion-fade` out), `t` from the start of the erase.
    public static func eraseOpacity(at t: Double) -> Double {
        1 - MotionTokens.fadeOut.value(at: t / MotionTokens.fadeDuration)
    }

    /// Opacity of a mark being replaced by a new one that doesn't glide: `motion-fade` out, or
    /// the Reduce Motion crossfade.
    public static func replacedOpacity(at t: Double, reduceMotion: Bool) -> Double {
        guard reduceMotion else { return eraseOpacity(at: t) }
        return 1 - MotionTokens.reduceCurve.value(at: t / MotionTokens.reduceDuration)
    }

    public static func fadeOutDuration(reduceMotion: Bool) -> Double {
        reduceMotion ? MotionTokens.reduceDuration : MotionTokens.fadeDuration
    }
}

/// Which target is up, and when the next one comes or the current one goes (Overlay.md,
/// Reveal and Lifetime). A value driven by the clock and by speech, so it can be tested.
///
/// - Text pacing: the first target is revealed when the answer arrives, the rest at their
///   estimated distance from it.
/// - Speech pacing: each target at its anchor word, as the synthesizer reports reaching it
///   (`speechDidReach`), never before the one before has been up `minimumStep`. If no word
///   callback comes, a late estimate stands in; when speech ends, the rest follow in turn.
///   If speech hasn't started `speechStartGrace` after the answer, pacing falls back to text.
/// - A mark stays 8 s after it comes to rest, and at least until 3 s after speech ends.
/// - When the answer draws (`accumulate`), each reveal adds to what's up instead of replacing
///   it, and everything goes together, timed from the last one to come to rest.
/// - When it draws a picture (`drawing`, D-97), the first part comes at its cue and each of
///   the others as the pen finishes the one before, like a hand drawing; then it all stays up
///   `drawingHold` (until erased by the overlay's own rules), however speech goes.
/// - When a spoken picture has a `fit` (D-106), its parts are paced to end with the sentence
///   that names it: each part, as it's revealed, gets the pace that would end the rest of the
///   picture at that sentence's predicted end, between `PictureFit.fastest` and
///   `PictureFit.slowest`, never under `PictureFit.partFloor`. Once speech is over, or the
///   next turn starts (`hurry`), the rest come at the fastest pace, in order.
public struct PointingSequence: Sendable {
    public enum Pacing: Equatable, Sendable { case text, speech }
    public enum Action: Equatable, Sendable {
        case reveal(Int)   // replaces whatever is up
        case erase(Int)
    }

    public static let speechStartGrace = 2.0
    /// Without word callbacks a target is revealed at its estimate × 1.5 + 1 s: late rather
    /// than early, since a mark must never come before its word.
    public static let fallbackStretch = 1.5
    public static let fallbackSlack = 1.0
    /// However long speech runs, no mark stays longer than this after coming to rest.
    public static let maximumHold = 60.0
    /// A picture stays up this long after its last part comes to rest, unless erased sooner.
    public static let drawingHold = 120.0
    /// The pen lifts between a picture's parts for this long.
    public static let penLift = 0.06

    public let cues: [RevealCue]
    public let restTimes: [Double]
    public let accumulate: Bool
    public let drawing: Bool
    public private(set) var pacing: Pacing
    /// The latest one revealed, while it's up.
    public private(set) var shown: Int?
    /// Everything up, in the order revealed (only ever `shown` when not accumulating).
    public private(set) var up: [Int] = []
    public private(set) var nextIndex = 0
    /// How long each part takes to draw: its rest time, scaled by its pace in a fitted picture.
    public private(set) var durations: [Double]
    public let fit: PictureFit?

    private var origin: Double
    private var speechStarted = false
    private var speechEndedAt: Double?
    private var reachedAt: [Double?]
    private var lastRevealAt: Double?
    private var shownRestAt: Double?
    /// The furthest word the voice has reported within the fitted sentence, the earliest one
    /// past it, and whether the next turn has begun.
    private var heardWithin: (offset: Int, at: Double)?
    private var heardPast: Double?
    private var hurried = false

    /// `restTimes[i]`: seconds from mark i's reveal to rest. `now`: when the answer arrived.
    /// `drawing` implies `accumulate`. `fit` applies only to a drawing paced by speech.
    public init(cues: [RevealCue], restTimes: [Double], pacing: Pacing, now: Double, accumulate: Bool = false,
                drawing: Bool = false, fit: PictureFit? = nil) {
        precondition(cues.count == restTimes.count)
        precondition(fit.map { $0.parts.count == cues.count } ?? true)
        self.cues = cues
        self.restTimes = restTimes
        self.durations = restTimes
        self.accumulate = accumulate || drawing
        self.drawing = drawing
        self.fit = drawing && pacing == .speech ? fit : nil
        self.pacing = pacing
        self.origin = now
        self.reachedAt = Array(repeating: nil, count: cues.count)
    }

    /// Part i's draw time over its rest time: 1 except in a fitted picture.
    public func pace(_ i: Int) -> Double {
        restTimes[i] > 0 ? durations[i] / restTimes[i] : 1
    }

    /// The next turn has begun: a fitted picture's remaining parts come at the fastest pace.
    public mutating func hurry() {
        guard fit != nil else { return }
        hurried = true
    }

    public var isFinished: Bool { nextIndex >= cues.count && up.isEmpty }

    public mutating func speechDidStart(at t: Double) {
        guard pacing == .speech, !speechStarted else { return }
        speechStarted = true
        origin = t
    }

    /// The synthesizer is about to speak the text from UTF-16 `offset` on.
    public mutating func speechDidReach(offset: Int, at t: Double) {
        guard pacing == .speech else { return }
        speechDidStart(at: t)
        for i in cues.indices where reachedAt[i] == nil {
            if let o = cues[i].offset, o <= offset { reachedAt[i] = t }
        }
        heard(offset: offset, at: t)
    }

    /// The speech will reach UTF-16 `offset` at `t` (a voice that reports a sentence at a time
    /// and when each of its words falls). An earlier report for the same cue wins.
    public mutating func speechWillReach(offset: Int, at t: Double) {
        guard pacing == .speech, speechStarted else { return }
        for i in cues.indices {
            guard let o = cues[i].offset, o <= offset else { continue }
            reachedAt[i] = min(reachedAt[i] ?? t, t)
        }
        heard(offset: offset, at: t)
    }

    private mutating func heard(offset: Int, at t: Double) {
        guard let fit else { return }
        if offset > fit.endOffset {
            heardPast = min(heardPast ?? t, t)
        } else if heardWithin.map({ offset > $0.offset || (offset == $0.offset && t < $0.at) }) ?? true {
            heardWithin = (offset, t)
        }
    }

    public mutating func speechDidEnd(at t: Double) {
        guard pacing == .speech, speechEndedAt == nil else { return }
        if !speechStarted { speechStarted = true; origin = t }
        speechEndedAt = t
    }

    /// The next moment `advance` has something to do; nil when nothing is pending.
    public func deadline() -> Double? {
        [graceDue(), revealDue(), expireDue()].compactMap { $0 }.min()
    }

    /// Does everything due by `now`, in time order.
    public mutating func advance(to now: Double) -> [Action] {
        var out: [Action] = []
        while true {
            let grace = graceDue(), reveal = revealDue(), expire = expireDue()
            guard let due = [grace, reveal, expire].compactMap({ $0 }).min(), due <= now else { break }
            if due == grace {
                pacing = .text
                origin = due
            } else if due == reveal {
                let i = nextIndex
                shown = i
                up = accumulate ? up + [i] : [i]
                lastRevealAt = due
                if fit != nil { durations[i] = fittedDuration(i, at: due) }
                shownRestAt = due + durations[i]
                nextIndex += 1
                out.append(.reveal(i))
            } else {
                out += up.map(Action.erase)
                up = []
                shown = nil
                shownRestAt = nil
            }
        }
        return out
    }

    private func graceDue() -> Double? {
        guard pacing == .speech, !speechStarted else { return nil }
        return origin + Self.speechStartGrace
    }

    private func revealDue() -> Double? {
        guard nextIndex < cues.count else { return nil }
        let i = nextIndex
        if drawing, i > 0, let last = lastRevealAt { return last + durations[i - 1] + Self.penLift }
        let earliest = lastRevealAt.map { $0 + RevealTiming.minimumStep } ?? -.infinity
        let base: Double
        switch pacing {
        case .text:
            base = origin + cues[i].seconds - cues[0].seconds
        case .speech:
            guard speechStarted else { return nil }
            if i == 0, let fit, fit.startOffset == nil {
                base = origin   // no word names the picture: it's drawn as its sentence is spoken
            } else if let r = reachedAt[i] {
                base = r
            } else if let end = speechEndedAt {
                base = end
            } else if cues[i].offset == nil {
                base = i == 0 ? origin : earliest
            } else {
                base = origin + cues[i].seconds * Self.fallbackStretch + Self.fallbackSlack
            }
        }
        return max(base, earliest)
    }

    /// When the fitted sentence is expected to end: its estimate at the pace the voice has
    /// shown so far, and no later than the voice going past it or stopping.
    func fittedEnd() -> Double? {
        guard let fit, pacing == .speech, speechStarted else { return nil }
        var rate = 1.0
        if let h = heardWithin, let e = fit.estimate(at: h.offset), e >= PictureFit.paceAfter {
            rate = min(max((h.at - origin) / e, 1 / PictureFit.rateLimit), PictureFit.rateLimit)
        }
        var end = origin + fit.endSeconds * rate
        if let past = heardPast { end = min(end, past) }
        if let stop = speechEndedAt { end = min(end, stop) }
        return end
    }

    /// Part i's draw time when it's revealed at `t`: the pace that ends the rest of the picture
    /// with the sentence, within the limits.
    private func fittedDuration(_ i: Int, at t: Double) -> Double {
        // A voice that never started fell back to reading: today's timing.
        guard let fit, fit.parts[i], restTimes[i] > 0, pacing == .speech else { return restTimes[i] }
        var pace = PictureFit.fastest
        if !hurried, let end = fittedEnd() {
            let rest = i..<cues.count
            let paced = rest.filter { fit.parts[$0] }.reduce(0) { $0 + restTimes[$1] }
            let fixed = rest.filter { !fit.parts[$0] }.reduce(0) { $0 + restTimes[$1] }
                + Double(cues.count - 1 - i) * Self.penLift
            pace = min(max((end - t - fixed) / paced, PictureFit.fastest), PictureFit.slowest)
        }
        return max(restTimes[i] * pace, min(restTimes[i], PictureFit.partFloor))
    }

    private func expireDue() -> Double? {
        guard !up.isEmpty, let rest = shownRestAt else { return nil }
        if drawing { return nextIndex < cues.count ? nil : rest + Self.drawingHold }
        let lifetime = rest + MotionTiming.markLifetime
        guard pacing == .speech else { return lifetime }
        guard let end = speechEndedAt else { return rest + Self.maximumHold }
        return min(max(lifetime, end + MotionTiming.markAfterSpeech), rest + Self.maximumHold)
    }
}

/// What a spoken picture is fitted to (D-106): the sentence that names it. That's the sentence
/// holding the first part's anchor word, from that word on; when no word names it (the cue
/// fell back to the end of the first sentence, as `RevealTiming` does), the first sentence,
/// drawn from the start of speech.
public struct PictureFit: Equatable, Sendable {
    /// A part takes at least half and at most 1.4× its pen time (`SketchTimeline.penSpeed`), and
    /// never under `partFloor` unless its pen time is.
    public static let fastest = 0.5
    public static let slowest = 1.4
    public static let partFloor = SketchTimeline.partShortest
    /// The voice's pace is read once it has been heard this far into the estimate (seconds),
    /// and taken as at most this many times quicker or slower than the estimate.
    public static let paceAfter = 0.5
    public static let rateLimit = 2.0

    /// Where the first part waits for its word (UTF-16, in the spoken text); nil: at the start
    /// of speech.
    public let startOffset: Int?
    /// The naming sentence's end mark (or the text's end), and its estimated time.
    public let endOffset: Int
    public let endSeconds: Double
    /// Which items may be paced (pen marks; a ring or region keeps its own timing).
    public let parts: [Bool]
    /// Each word's offset and estimated time, to read the voice's pace from what it reports.
    let words: [RevealCue]

    /// `text` is the spoken text the cues index into; `firstCue` the plan's first.
    public init?(text: String, firstCue: RevealCue, parts: [Bool]) {
        let tokens = RevealTiming.tokenize(text)
        guard !tokens.isEmpty else { return nil }
        let named = tokens.firstIndex { $0.word != nil && $0.offset == firstCue.offset }
        startOffset = named.map { tokens[$0].offset }
        if let end = tokens[(named ?? 0)...].firstIndex(where: { $0.sentenceEnd }) {
            endOffset = tokens[end].offset
            endSeconds = RevealTiming.seconds(before: end + 1, in: tokens)
        } else {
            endOffset = text.utf16.count
            endSeconds = RevealTiming.seconds(before: tokens.count, in: tokens)
        }
        self.parts = parts
        words = tokens.indices.compactMap { i in
            tokens[i].word == nil ? nil : RevealCue(offset: tokens[i].offset, seconds: RevealTiming.seconds(before: i, in: tokens))
        }
    }

    /// The estimated time of the last word starting at or before `offset`.
    func estimate(at offset: Int) -> Double? {
        words.last { ($0.offset ?? .max) <= offset }?.seconds
    }
}

/// Everything the overlay needs for one answer: the marks and drawings in order, when to reveal
/// them, and the capture they were mapped from.
public struct PointingPlan: Equatable, Sendable {
    public let items: [OverlayItem]
    public let cues: [RevealCue]
    public let pacing: PointingSequence.Pacing
    /// The captured display; the overlay finds it again by this ID, never by its index.
    public let displayID: UInt32?
    public let screenFrame: CGRect
    /// On-screen windows at capture time, front to back (for erasing when the target's window
    /// moves, closes or is covered).
    public let windows: [WindowInfo]
    /// A spoken picture's pacing (D-106); nil for anything else.
    public let fit: PictureFit?
    /// Edits of the drawing already up (chilly-whiteboard), in order.
    public let edits: [DrawingEdit]
    /// The beats form (chilly-whiteboard): the answer's sentences and the one that owns each item
    /// (nil: before any). Nil when every tag came at the end: the old anchor-word pacing.
    public let sentences: [String]?
    public let owners: [Int?]?
    /// The display's points per pixel of the screenshot (for edits given in pixels).
    public let pointsPerPixel: CGSize
    /// The text the cues' offsets index (the answer as spoken, or as shown when not spoken).
    public let cueText: String
    /// The voice began on the answer's first sentence before the answer (and these marks) arrived
    /// (D-164): the overlay replays what was already heard, mapped into `cueText`.
    public var spokenFirst = false

    /// The pointer marks (rings and regions), in order.
    public var marks: [PointingMark] { items.compactMap(\.mark) }
    /// The answer draws: everything it shows stays up together (`PointingSequence.accumulate`).
    public var draws: Bool { items.contains { $0.sketch != nil } }
    /// It draws a picture (a path, polyline or oval): drawn part after part, and kept up
    /// (`PointingSequence.drawing`).
    public var isDrawing: Bool { items.contains { $0.sketch?.isDrawing == true } }

    /// Nil when no target gets a mark. `text` is the answer as shown; with `speaking`, the
    /// cues are offsets into the text the synthesizer speaks (`SpeechText.plain`).
    public init?(targets: [PointingTarget], text: String, speaking: Bool, pixelSize: CGSize,
                 screenFrame: CGRect, displayID: UInt32?, windows: [WindowInfo] = []) {
        var items: [OverlayItem] = [], ats: [Int?] = []
        for t in PointingTags.capped(targets) where t.shape.edit == nil {
            guard let item = PointMapping.item(for: t, pixelSize: pixelSize, screenFrame: screenFrame) else { continue }
            items.append(item)
            ats.append(t.at)
        }
        let edits = targets.compactMap(\.shape.edit)
        guard !items.isEmpty || !edits.isEmpty else { return nil }
        self.items = items
        self.edits = edits
        self.pointsPerPixel = pixelSize.width > 0 && pixelSize.height > 0
            ? CGSize(width: screenFrame.width / pixelSize.width, height: screenFrame.height / pixelSize.height) : CGSize(width: 1, height: 1)
        if !ats.isEmpty, ats.allSatisfy({ $0 != nil }) {
            let owned = MarkOwners.of(text: text, ats: ats.map { $0! })
            sentences = owned.lines
            owners = owned.owners
        } else {
            sentences = nil
            owners = nil
        }
        self.cueText = speaking ? SpeechText.plain(text) : text
        self.cues = RevealTiming.cues(labels: items.map(\.label), in: cueText)
        self.pacing = speaking ? .speech : .text
        self.displayID = displayID
        self.screenFrame = screenFrame
        self.windows = windows
        let picture = items.contains { $0.sketch?.isDrawing == true }
        self.fit = speaking && picture && owners == nil
            ? PictureFit(text: SpeechText.plain(text), firstCue: cues[0], parts: items.map { $0.sketch != nil })
            : nil
    }

    /// A beats-form answer's marks on their sentences (`OverlayBeats`); nil for the old form.
    public func beats(reduceMotion: Bool, now: Double) -> OverlayBeats? {
        guard let sentences, let owners else { return nil }
        let naturals = items.map { item -> Double in
            switch item {
            case let .mark(m): return MarkTimeline.restTime(kind: m.kind, step: .reveal, reduceMotion: reduceMotion)
            case let .sketch(s): return SketchTimeline.restTime(s, reduceMotion: reduceMotion)
            }
        }
        return OverlayBeats(texts: sentences, owners: owners, naturals: naturals,
                            clock: pacing == .speech ? .voice : .estimate, now: now)
    }

    /// The answer edits or adds to the drawing already up instead of replacing it.
    public var extendsDrawing: Bool { !edits.isEmpty }

    public func sequence(reduceMotion: Bool, now: Double) -> PointingSequence {
        let rest = items.map { item -> Double in
            switch item {
            case let .mark(m): return MarkTimeline.restTime(kind: m.kind, step: .reveal, reduceMotion: reduceMotion)
            case let .sketch(s): return SketchTimeline.restTime(s, reduceMotion: reduceMotion)
            }
        }
        // Under Reduce Motion parts fade in rather than draw, so there's nothing to pace.
        return PointingSequence(cues: cues, restTimes: rest, pacing: pacing, now: now, accumulate: draws,
                                drawing: isDrawing, fit: reduceMotion ? nil : fit)
    }
}
