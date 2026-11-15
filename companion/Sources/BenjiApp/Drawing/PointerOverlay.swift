import AppKit
import Carbon.HIToolbox
import BenjiCore
import os
import SwiftUI

/// What the synthesizer reports while speaking an answer (offsets are UTF-16, in the spoken text).
enum SpeechProgress {
    case started
    case reached(offset: Int)
    /// A voice that reports a sentence at a time (Kokoro): when each of its words will be heard.
    case willReach([SpeechMilestone])
    case ended
}

/// Shows where things are on screen: up to three marks in order, one at a time,
/// each a ring or a region with a short label, revealed as the speech reaches its words (or at
/// once for a text-only answer), then gone. An answer that draws (circles, arrows, underlines,
/// highlights, dashed groups, notes, callouts) keeps everything it shows up together, each
/// drawn with the pen as its words come, and erases it all at once. A picture (paths, lines,
/// shapes, ovals) is drawn part after part and stays up through the next turn until the next
/// answer's marks replace it, it's erased, or two minutes pass. One click-through window
/// over the captured display; it never takes focus or swallows input, belongs to this app (so
/// the next screenshot leaves it out) and asks to be left out of other apps' captures.
///
/// Erased early on: Escape (observed, never consumed), a click on the target, a scroll over
/// its window, the window moving, closing or being covered, a Space change, an app switch,
/// a display change, sleep, screen lock, secure input, and the screenshot shortcuts.
final class PointerOverlay {
    /// Benji's own windows (the notch object, panels), kept clear of labels. Read at each reveal.
    var avoid: () -> [CGRect] = { [] }
    /// Each mark's keep-out as it's revealed, so the open panel can collapse to peek when it
    /// covers the target.
    var onReveal: ((CGRect) -> Void)?

    private var window: NSPanel?
    private let state = OverlayState()
    private var plan: PointingPlan?
    private var screen: NSScreen?
    private var sequence: PointingSequence?
    /// A beats-form answer's marks, each drawn on its sentence; used instead
    /// of `sequence` when the plan has owners.
    private var beats: OverlayBeats?
    /// The drawing up, part by part (p1 first): what the model is told it drew, what edits change.
    private(set) var drawing = DrawingParts()
    /// Where the plan being drawn starts among the drawing's parts (it added to one already up).
    private var base = 0
    private var extended = false
    /// The board behind a drawing that landed on busy space (AppKit global points), and its
    /// panel, which takes the drags (the overlay itself is click-through).
    private var boardPanel: BoardPanel?
    /// What the voice has said of this answer, kept for a plan shown a moment after it started.
    private var heardText = ""
    private var heardMarks: [SpokenProgress.Mark] = []
    /// When the voice last started and ended (the replay of an answer spoken first).
    private var speechStartedAt: Double?
    private var speechEndedAt: Double?
    private var holdTimer: Timer?
    /// The plan's targets against their windows, and the item whose window the poll watches
    /// (the latest revealed, until it's erased).
    private var targets: WindowTracking.PlanWatch?
    private var watched: Int?
    private var watch: WindowTracking.Watch? { watched.flatMap { targets?.watch(for: $0) } }
    /// The window list is read once per plan, then off the main thread.
    private let windowQueue = DispatchQueue(label: "com.benji.overlay.windows", qos: .userInitiated)
    private lazy var windows: WindowPoller = {
        let poller = WindowPoller(source: { [height = primaryHeight] in WindowList.current(primaryHeight: height.withLock { $0 }) },
                                  work: windowQueue, deliver: .main, excludingPID: Self.ownPID)
        poller.onChange = { [weak self] changed in
            guard let self, let i = self.watched, changed[i] != nil else { return }
            self.dismiss()
        }
        return poller
    }()
    /// The primary display's height, read on the main thread for the background reads (a
    /// display change erases everything anyway).
    private let primaryHeight = OSAllocatedUnfairLock<CGFloat>(initialState: 0)
    private var nextID = 0

    private var sequenceTimer: Timer?
    private var animationTimer: Timer?
    private var orderOutTimer: Timer?
    private var pollTimer: Timer?
    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// The "Show drawings in screenshots" setting (off by default); read for each drawing. While a
    /// picture is up it shows unless the user turned the setting off, so the model sees its own
    /// drawing in the next screenshot.
    private var shownInCaptures: Bool {
        let raw = UserDefaults.standard.object(forKey: DrawingCapture.defaultsKey)
        return drawing.isDrawing ? DrawingCapture.shownWhileDrawing(from: raw) : DrawingCapture.shown(from: raw)
    }

    /// The overlay's and board's window numbers while a picture is up and shown in captures:
    /// Benji's own screenshot keeps them in (ScreenCapturer).
    var windowsInCaptures: Set<Int> {
        guard drawing.isDrawing, shownInCaptures else { return [] }
        return Set([window?.windowNumber, boardPanel?.windowNumber].compactMap { $0 })
    }

    /// What is up for the model's next turn, in the pixels of a screenshot of `screenFrame` sent at
    /// `pixelSize` (nil: no screenshot this turn; parts then have no box).
    func canvas(screenFrame: CGRect?, pixelSize: CGSize?) -> (parts: [CanvasSnapshot.Part], board: ScreenshotGeometry.PixelRect?) {
        guard window != nil, let plan, !drawing.live.isEmpty else { return ([], nil) }
        let frame = screenFrame ?? .null, size = pixelSize ?? .zero
        let parts = CanvasSnapshot.parts(drawing, drawnOn: plan.screenFrame, screenFrame: frame, pixelSize: size)
        let board = state.board.flatMap { b in plan.screenFrame == frame ? CanvasSnapshot.pixels(b, screenFrame: frame, pixelSize: size) : nil }
        return (parts, board)
    }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }
    private static let ownPID = ProcessInfo.processInfo.processIdentifier

    /// `busy`: the turn's screenshot measured for busy space; a picture whose box lands on busy
    /// content goes on a board.
    func show(_ plan: PointingPlan, busy: ExplainBusyScreen? = nil) {
        // Edits (and new parts with them) go to the drawing already up on the same display, and so
        // do marks that only mark that picture up (a highlight on words Benji wrote).
        if window != nil, let up = self.plan, up.screenFrame == plan.screenFrame, !drawing.parts.isEmpty,
           plan.extendsDrawing || drawing.isMarkedUp(by: plan.items, offset: boardOffset) {
            return extend(with: plan)
        }
        removeNow()
        guard !plan.items.isEmpty, let screen = Self.screen(for: plan) else { return }   // display gone or changed: words only
        self.plan = plan
        self.screen = screen
        state.appearance = Self.currentAppearance()
        let now = Self.now
        drawing = DrawingParts()
        drawing.append(plan.items)
        base = 0
        extended = false
        if plan.isDrawing { placeBoard(on: screen, busy: busy, at: now) }
        startPacing(plan, now: now)
        makeWindow(on: screen)
        startWatching()
        // The target's window must still be where it was when the screenshot was taken: one
        // read now, before the first reveal; the 4 Hz poll keeps it current off the main thread.
        let height = NSScreen.screens.first?.frame.maxY ?? 0
        primaryHeight.withLock { $0 = height }
        let targets = WindowTracking.PlanWatch(areas: plan.items.map(Self.area), in: plan.windows, excludingPID: Self.ownPID)
        self.targets = targets
        windows.begin(targets)
        runSequence()
    }

    func speech(_ event: SpeechProgress) {
        if case .started = event { heardText = ""; heardMarks = []; speechStartedAt = Self.now; speechEndedAt = nil }
        if case .ended = event { speechEndedAt = Self.now }
        if beats != nil {
            if case .ended = event { beats?.speechEnded(at: Self.now) }
            return runSequence()
        }
        guard sequence != nil else { return }
        let t = Self.now
        switch event {
        case .started: sequence?.speechDidStart(at: t)
        // An answer spoken before its marks came is followed through `heard`, whose offsets are
        // mapped into the marks' text; these offsets are the voice's own.
        case let .reached(offset): if plan?.spokenFirst != true { sequence?.speechDidReach(offset: offset, at: t) }
        case let .willReach(words):
            if plan?.spokenFirst != true { for w in words { sequence?.speechWillReach(offset: w.offset, at: t + w.delay) } }
        case .ended: sequence?.speechDidEnd(at: t)
        }
        runSequence()
    }

    /// The voice's heard words, fed to the plain sequence of an answer that was spoken before
    /// its marks arrived, each offset mapped from what the voice says into the marks' text.
    private func feedSpokenFirst(spoken: String, marks: [SpokenProgress.Mark]) {
        guard let plan, plan.spokenFirst, sequence != nil else { return }
        for m in marks {
            guard let o = SpokenAlignment.offset(m.offset, in: spoken, to: plan.cueText) else { continue }
            sequence?.speechWillReach(offset: o, at: m.at)
        }
    }

    /// The app's clear, as a new turn starts (the user speaks or sends), on cancel and on a new
    /// conversation: marks go, but a picture stays up so the user can talk about it, until the
    /// next answer's marks replace it, it's dismissed, or its two minutes are up.
    func hide() {
        guard plan?.isDrawing != true, !drawing.isDrawing else {
            // A spoken picture still drawing finishes quickly, in order.
            sequence?.hurry()
            if beats != nil {
                beats?.hurry(now: Self.now)
                runSequence()
            }
            return
        }
        dismiss()
    }

    /// The voice's word marks for the answer it is saying (offsets into `spoken`), as the card
    /// stage gets them: the clock of a beats-form answer's marks.
    func heard(spoken: String, marks: [SpokenProgress.Mark]) {
        if !spoken.hasPrefix(heardText) { heardMarks = [] }
        heardText = spoken
        heardMarks += marks
        if beats == nil, sequence != nil, plan?.spokenFirst == true {
            feedSpokenFirst(spoken: spoken, marks: marks)
            return runSequence()
        }
        guard beats != nil else { return }
        beats?.heard(spoken: spoken, marks: marks)
        runSequence()
    }

    /// The pacing for `plan`'s items: on their sentences in the beats form, else the timed sequence.
    private func startPacing(_ plan: PointingPlan, now: Double) {
        if var b = plan.beats(reduceMotion: state.appearance.reduceMotion, now: now) {
            if !heardText.isEmpty { b.heard(spoken: heardText, marks: heardMarks) }
            beats = b
            sequence = nil
        } else {
            beats = nil
            sequence = plan.sequence(reduceMotion: state.appearance.reduceMotion, now: now)
            // Spoken first: the voice began before these marks came, so the sequence
            // learns when, and every word heard so far, before it paces anything.
            if plan.spokenFirst, let started = speechStartedAt {
                sequence?.speechDidStart(at: started)
                if !heardText.isEmpty { feedSpokenFirst(spoken: heardText, marks: heardMarks) }
                if let ended = speechEndedAt { sequence?.speechDidEnd(at: ended) }
            }
        }
    }

    /// An answer that edits the drawing up: its edits apply at once, animated, and its new parts
    /// join the drawing (on its board, if it has one), paced like any answer's.
    private func extend(with plan: PointingPlan) {
        let t = Self.now
        sequenceTimer?.invalidate()
        holdTimer?.invalidate()
        if sequence != nil || beats != nil { finishPending() }
        for edit in plan.edits {
            for change in drawing.apply(edit, pointsPerPixel: plan.pointsPerPixel) { show(change, at: t) }
        }
        var items = plan.items
        if let offset = boardOffset { items = items.map { $0.converted { CGPoint(x: $0.x + offset.dx, y: $0.y + offset.dy) } } }
        base = drawing.parts.count
        drawing.append(items)
        extended = true
        self.plan = plan
        startPacing(plan, now: t)
        if !items.isEmpty {
            let targets = WindowTracking.PlanWatch(areas: items.map(Self.area), in: plan.windows, excludingPID: Self.ownPID)
            self.targets = targets
            windows.begin(targets)
        }
        animate()
        runSequence()
    }

    /// Everything still to come of the plan up is drawn now (an edit arrived before it finished).
    private func finishPending() {
        let t = Self.now
        if var b = beats { b.hurry(now: t); beats = b }
        if beats != nil { runSequence() }
        if var seq = sequence {
            seq.hurry()
            sequence = seq
        }
        let count = (sequence?.cues.count ?? beats?.naturals.count) ?? 0
        let shownIndices = Set(state.sketches.map(\.index) + state.marks.map(\.index))
        for i in 0..<count where !shownIndices.contains(base + i) { reveal(i) }
        sequence = nil
        beats = nil
    }

    /// One edit's change, animated: a glide to where it now is, new words written in, a colour,
    /// or the pen running backwards.
    private func show(_ change: DrawingParts.Change, at t: Double) {
        switch change {
        case let .moved(i, transform):
            for k in state.sketches.indices where state.sketches[k].index == i && state.sketches[k].end == nil {
                guard let sketch = drawing.parts[i].item.sketch else { continue }
                state.sketches[k].sketch = sketch
                state.sketches[k].noteFrame = noteFrame(for: sketch)
                state.sketches[k].tweenFrom = transform.inverted()
                state.sketches[k].tweenStart = t
            }
            moveMarks(i)
        case let .relabeled(i):
            for k in state.sketches.indices where state.sketches[k].index == i && state.sketches[k].end == nil {
                guard let sketch = drawing.parts[i].item.sketch else { continue }
                state.sketches[k].sketch = sketch
                state.sketches[k].noteFrame = noteFrame(for: sketch)
                if case .text = sketch { state.sketches[k].start = t }       // the new words are written in
                if case .note = sketch { state.sketches[k].start = t }
                if case .callout = sketch { state.sketches[k].start = t }
            }
        case let .recolored(i):
            for k in state.sketches.indices where state.sketches[k].index == i { state.sketches[k].color = drawing.parts[i].color }
        case let .erased(i):
            for k in state.sketches.indices where state.sketches[k].index == i && state.sketches[k].end == nil {
                state.sketches[k].unwriteStart = t
                state.sketches[k].end = t + state.sketches[k].unwriteDuration
            }
            for k in state.marks.indices where state.marks[k].index == i && state.marks[k].end == nil { state.marks[k].end = t }
        }
    }

    private func moveMarks(_ i: Int) {
        guard case let .mark(m)? = Optional(drawing.parts[i].item), let screen else { return }
        for k in state.marks.indices where state.marks[k].index == i && state.marks[k].end == nil {
            state.marks[k].mark = OverlayLayout.snapped(m, scale: screen.backingScaleFactor)
        }
    }

    // MARK: the board

    /// How far the drawing moved onto its board (global points), while it has one.
    private var boardOffset: CGVector?

    private func placeBoard(on screen: NSScreen, busy: ExplainBusyScreen?, at t: Double) {
        guard let busy, busy.screen.frame == screen.frame, let extent = drawing.extent else { return }
        let f = screen.frame, v = screen.visibleFrame
        func local(_ r: CGRect) -> CGRect { CGRect(x: r.minX - f.minX, y: f.maxY - r.maxY, width: r.width, height: r.height) }
        let keepOut = avoid().filter { $0.intersects(f) }.map(local)
        let vis = local(v)
        let prefer = keepOut.first.map { CGPoint(x: $0.midX, y: $0.maxY + ExplainCardPlacement.margin) }
            ?? CGPoint(x: vis.midX, y: vis.minY + 40)
        guard let placed = DrawingBoard.place(drawing: local(extent), visible: vis, busy: busy.map, prefer: prefer,
                                              avoid: keepOut) else { return }
        let offset = CGVector(dx: placed.offset.dx, dy: -placed.offset.dy)     // y up in AppKit
        drawing.shift(by: offset)
        boardOffset = offset
        let board = CGRect(x: f.minX + placed.frame.minX, y: f.maxY - placed.frame.maxY,
                           width: placed.frame.width, height: placed.frame.height)
        state.board = board
        state.boardStart = t
        let panel = BoardPanel(frame: board)
        panel.onDrag = { [weak self] d in self?.dragBoard(by: d) }
        panel.sharingType = shownInCaptures ? .readOnly : .none
        panel.orderFrontRegardless()
        boardPanel = panel
    }

    /// The board was dragged: it and every part on it move together.
    private func dragBoard(by d: CGVector) {
        guard let board = state.board else { return }
        let t = CGAffineTransform(translationX: d.dx, y: d.dy)
        state.board = board.offsetBy(dx: d.dx, dy: d.dy)
        boardPanel?.setFrame(state.board!, display: false)
        drawing.shift(by: d)
        boardOffset = boardOffset.map { CGVector(dx: $0.dx + d.dx, dy: $0.dy + d.dy) }
        for k in state.sketches.indices {
            state.sketches[k].sketch = state.sketches[k].sketch.converted { $0.applying(t) }
            state.sketches[k].noteFrame = state.sketches[k].noteFrame?.offsetBy(dx: d.dx, dy: -d.dy)
        }
        holdTimer?.invalidate()
        scheduleHold(from: Self.now)
    }

    /// Every erase: what's up fades out (`motion-fade`), what's pending is dropped.
    func dismiss() {
        guard window != nil else { return }
        sequence = nil
        beats = nil
        holdTimer?.invalidate()
        sequenceTimer?.invalidate()
        stopWatching()
        let t = Self.now
        for i in state.marks.indices where state.marks[i].end == nil {
            state.marks[i].end = t
            state.marks[i].replaced = false
        }
        for i in state.sketches.indices where state.sketches[i].end == nil {
            state.sketches[i].end = t
        }
        animate()
        orderOutAfterFade()
    }

    // MARK: sequence

    private func runSequence() {
        if beats != nil { return runBeats() }
        guard var seq = sequence else { return }
        let actions = seq.advance(to: Self.now)
        sequence = seq
        for action in actions {
            guard sequence != nil else { return }   // a reveal found the target's window changed
            switch action {
            case let .reveal(i): reveal(i)
            case let .erase(i):
                // A drawing that grew over several answers goes all at once.
                if extended { return dismiss() }
                erase(base + i)
            }
        }
        sequenceTimer?.invalidate()
        guard let seq = sequence else { return }
        if seq.isFinished {
            sequence = nil
            stopWatching()
            orderOutAfterFade()
        } else if let due = seq.deadline() {
            sequenceTimer = Self.timer(after: due - Self.now) { [weak self] in self?.runSequence() }
        }
    }

    /// The beats form: release what is due, then wake at the next part (or poll while the voice
    /// hasn't reached its sentence); once all is drawn, a picture is held and marks fade on their timer.
    private func runBeats() {
        guard var b = beats else { return }
        let t = Self.now
        let released = b.advance(now: t)
        beats = b
        for i in released {
            guard beats != nil else { return }
            reveal(i)
        }
        sequenceTimer?.invalidate()
        guard let b = beats else { return }
        if b.isDone {
            beats = nil
            scheduleHold(from: t)
        } else {
            let due = b.nextDue(now: t).map { $0 - t } ?? 0.25
            sequenceTimer = Self.timer(after: min(max(due, 0.01), 0.25)) { [weak self] in self?.runSequence() }
        }
    }

    /// After the last part: a picture stays `drawingHold`, marks `markLifetime`.
    private func scheduleHold(from t: Double) {
        holdTimer?.invalidate()
        let rest = state.sketches.map { $0.start + SketchTimeline.restTime($0.sketch, reduceMotion: state.appearance.reduceMotion) * $0.pace }.max() ?? t
        let hold = drawing.isDrawing ? PointingSequence.drawingHold : MotionTiming.markLifetime
        holdTimer = Self.timer(after: max(rest, t) + hold - Self.now) { [weak self] in self?.dismiss() }
    }

    private func noteFrame(for sketch: Sketch) -> CGRect? {
        guard let screen else { return nil }
        let f = screen.frame, v = screen.visibleFrame
        let local = CGRect(x: v.minX - f.minX, y: f.maxY - v.maxY, width: v.width, height: v.height)
        switch sketch {
        case let .note(p, text):
            return SketchLayout.noteFrame(size: OverlayNoteMetrics.size(text), at: CGPoint(x: p.x - f.minX, y: f.maxY - p.y), bounds: local)
        case let .callout(p, text):
            return SketchLayout.calloutFrame(size: OverlayNoteMetrics.calloutSize(text),
                                             at: CGPoint(x: p.x - f.minX, y: f.maxY - p.y), bounds: local)
        case let .text(p, text, size):
            return SketchLayout.textFrame(size: OverlayHandwriting.size(text, size), at: CGPoint(x: p.x - f.minX, y: f.maxY - p.y),
                                          bounds: local)
        default:
            return nil
        }
    }

    private static func area(_ item: OverlayItem) -> CGRect {
        switch item {
        case let .mark(m): return OverlayLayout.hitArea(for: m)
        case let .sketch(s): return s.hitArea
        }
    }

    /// Reveals the plan's item `index` (its part `base + index` of the drawing).
    private func reveal(_ index: Int) {
        guard let plan, let screen, drawing.parts.indices.contains(base + index) else { return }
        let item = drawing.parts[base + index].item
        // The target's window must still be where it was when the screenshot was taken, as of
        // the latest read (at most a poll old).
        watched = index
        if windows.change(for: index) != .none {
            dismiss()
            return
        }
        let pace = beats?.pace(index) ?? sequence?.pace(index) ?? 1
        switch item {
        case let .mark(m): revealMark(m, index: base + index, on: screen, plan: plan)
        case let .sketch(s): revealSketch(s, index: base + index, on: screen, pace: pace)
        }
    }

    /// A pen mark joins whatever is already up.
    private func revealSketch(_ sketch: Sketch, index: Int, on screen: NSScreen, pace: Double) {
        let t = Self.now
        var noteFrame: CGRect?
        let f = screen.frame, v = screen.visibleFrame
        let local = CGRect(x: v.minX - f.minX, y: f.maxY - v.maxY, width: v.width, height: v.height)
        switch sketch {
        case let .note(p, text):
            noteFrame = SketchLayout.noteFrame(size: OverlayNoteMetrics.size(text),
                                               at: CGPoint(x: p.x - f.minX, y: f.maxY - p.y), bounds: local)
        case let .callout(p, text):
            noteFrame = SketchLayout.calloutFrame(size: OverlayNoteMetrics.calloutSize(text),
                                                  at: CGPoint(x: p.x - f.minX, y: f.maxY - p.y), bounds: local)
        case let .text(p, text, size):
            noteFrame = SketchLayout.textFrame(size: OverlayHandwriting.size(text, size),
                                               at: CGPoint(x: p.x - f.minX, y: f.maxY - p.y), bounds: local)
        default:
            break
        }
        nextID += 1
        state.sketches.append(ShownSketch(id: nextID, index: index, sketch: sketch,
                                          seed: PenRandom.seed(index: index, sketch: sketch),
                                          noteFrame: noteFrame, start: t, pace: pace))
        animate()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: PointingAnnouncement.text(for: sketch),
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        onReveal?(sketch.hitArea)
    }

    private func revealMark(_ planned: PointingMark, index: Int, on screen: NSScreen, plan: PointingPlan) {
        let appearance = state.appearance
        let mark = OverlayLayout.snapped(planned, scale: screen.backingScaleFactor)
        // In an answer that draws, everything stays up together: nothing glides or is replaced.
        let accumulate = plan.draws

        let t = Self.now
        var marks = state.marks.filter { m in m.end.map { t - $0 < 1 } ?? true }
        let previous = marks.last(where: { $0.end == nil })
        let step = accumulate ? .reveal
            : OverlayLayout.step(from: previous?.mark, to: mark, reduceMotion: appearance.reduceMotion)
        var avoid = self.avoid()
        if let notch = Self.notchRect(on: screen) { avoid.append(notch) }
        let labelFrame = mark.label.isEmpty ? nil
            : OverlayLayout.labelFrame(size: OverlayLabelMetrics.size(mark.label), for: mark,
                                       visibleFrame: screen.visibleFrame, avoid: avoid, appearance: appearance)
        nextID += 1
        var shown = ShownMark(id: nextID, index: index, mark: mark, labelFrame: labelFrame, step: step, start: t)
        if case .glide = step, let i = marks.lastIndex(where: { $0.end == nil }) {
            // The same ring moves on: its old label fades where it was.
            let old = marks.remove(at: i)
            shown.previousLabel = old.mark.label
            shown.previousLabelFrame = old.labelFrame
        } else if !accumulate {
            for i in marks.indices where marks[i].end == nil {
                marks[i].end = t
                marks[i].replaced = true
            }
        }
        marks.append(shown)
        state.marks = marks
        animate()

        let announcement = PointingAnnouncement.text(label: mark.label, step: (plan.marks.firstIndex(of: planned) ?? 0) + 1,
                                                     of: plan.marks.count)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: announcement,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        onReveal?(OverlayLayout.keepOut(for: mark, appearance: appearance))
    }

    private func erase(_ index: Int) {
        let t = Self.now
        for i in state.marks.indices where state.marks[i].index == index && state.marks[i].end == nil {
            state.marks[i].end = t
        }
        for i in state.sketches.indices where state.sketches[i].index == index && state.sketches[i].end == nil {
            state.sketches[i].end = t
        }
        watched = nil
        animate()
    }

    /// Redraw continuously only until every mark is at rest or gone; then stop.
    private func animate() {
        animationTimer?.invalidate()
        let t = Self.now, rm = state.appearance.reduceMotion
        let settles = state.marks.map { m in
            m.end.map { $0 + MarkTimeline.fadeOutDuration(reduceMotion: rm) }
                ?? m.start + MarkTimeline.restTime(kind: m.mark.kind, step: m.step, reduceMotion: rm)
        } + state.sketches.map { s in
            max(s.end.map { $0 + MotionTokens.fadeDuration } ?? s.start + SketchTimeline.restTime(s.sketch, reduceMotion: rm) * s.pace,
                s.tweenStart.map { $0 + ShownSketch.tween } ?? 0)
        } + (state.board != nil ? [state.boardStart + MotionTokens.fadeDuration] : [])
        let moving = settles.contains { $0 > t }
        if state.animating != moving { state.animating = moving }
        guard moving, let last = settles.max() else { return }
        animationTimer = Self.timer(after: last - t + 0.02) { [weak self] in self?.animate() }
    }

    private func orderOutAfterFade() {
        orderOutTimer?.invalidate()
        orderOutTimer = Self.timer(after: MotionTokens.reduceDuration + 0.05) { [weak self] in self?.removeNow() }
    }

    /// Gone at once, with nothing scheduled.
    private func removeNow() {
        [sequenceTimer, animationTimer, orderOutTimer, holdTimer].forEach { $0?.invalidate() }
        stopWatching()
        sequence = nil
        beats = nil
        drawing = DrawingParts()
        base = 0
        extended = false
        boardOffset = nil
        state.board = nil
        boardPanel?.orderOut(nil)
        boardPanel = nil
        plan = nil
        targets = nil
        watched = nil
        state.marks = []
        state.sketches = []
        state.animating = false
        window?.orderOut(nil)
        window = nil
    }

    // MARK: window

    private func makeWindow(on screen: NSScreen) {
        let panel = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true                  // click-through: everything reaches the app below
        panel.animationBehavior = .none
        // Above the menu bar and the Dock, below Benji's notch panel (mainMenu + 3), so a mark
        // never draws over the panel.
        panel.level = Self.level
        // Hidden from other apps' captures, "where macOS allows" (unverified for ScreenCaptureKit),
        // unless the user chose to show drawings in screenshots. Benji's own captures leave
        // its windows out either way.
        panel.sharingType = shownInCaptures ? .readOnly : .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isExcludedFromWindowsMenu = true
        let host = NSHostingView(rootView: OverlayHost(state: state, screenFrame: screen.frame))
        host.setAccessibilityElement(false)
        panel.contentView = host
        panel.setAccessibilityElement(false)
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        window = panel
    }

    /// The captured display, found again by its ID (never its index); nil if it's gone or its
    /// frame changed since the capture.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)

    private static func screen(for plan: PointingPlan) -> NSScreen? {
        NSScreen.screens.first { s in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            return (plan.displayID == nil || id == plan.displayID) && s.frame == plan.screenFrame
        }
    }

    private static func notchRect(on screen: NSScreen) -> CGRect? {
        OverlayLayout.notchRect(screenFrame: screen.frame,
                                topLeftArea: screen.auxiliaryTopLeftArea, topRightArea: screen.auxiliaryTopRightArea)
    }

    private static func currentAppearance() -> OverlayAppearance {
        let w = NSWorkspace.shared
        return OverlayAppearance(reduceMotion: w.accessibilityDisplayShouldReduceMotion,
                                 increaseContrast: w.accessibilityDisplayShouldIncreaseContrast,
                                 reduceTransparency: w.accessibilityDisplayShouldReduceTransparency,
                                 differentiateWithoutColor: w.accessibilityDisplayShouldDifferentiateWithoutColor)
    }

    // MARK: erase triggers (only while a mark is up or pending)

    private func startWatching() {
        stopWatching()
        // Escape and the screenshot shortcuts, elsewhere (needs Accessibility, which the talk
        // key already has; without it this sees nothing) and in Benji's own panel. Observed,
        // never consumed.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard let self else { return }
            let screenshot = Self.isScreenshotShortcut(e)
                && DrawingCapture.clearsOnScreenshot(shown: self.shownInCaptures)
            if Self.isEscape(e) || screenshot { self.dismiss() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if Self.isEscape(e) { self?.dismiss() }
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            guard let self else { return }
            let p = NSEvent.mouseLocation
            let areas = self.state.marks.filter { $0.end == nil }.map { OverlayLayout.hitArea(for: $0.mark) }
                + self.state.sketches.filter { $0.end == nil }.map(\.sketch.hitArea)
            if areas.contains(where: { $0.contains(p) }) { self.dismiss() }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] _ in
            guard let self, self.state.marks.contains(where: { $0.end == nil })
                    || self.state.sketches.contains(where: { $0.end == nil }) else { return }
            let area = self.watch?.window.frame ?? self.screen?.frame ?? .zero
            if area.contains(NSEvent.mouseLocation) { self.dismiss() }
        }) { monitors.append(m) }

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observe(ws, name) { [weak self] _ in self?.dismiss() }
        }
        observe(ws, NSWorkspace.didActivateApplicationNotification) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let self, let pid = app?.processIdentifier, pid != Self.ownPID,
                  pid != self.watch?.window.ownerPID else { return }
            self.dismiss()
        }
        observe(ws, NSWorkspace.didLaunchApplicationNotification) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let self, app?.bundleIdentifier == "com.apple.screenshot.launcher",
                  DrawingCapture.clearsOnScreenshot(shown: self.shownInCaptures) else { return }
            self.dismiss()   // best effort
        }
        observe(ws, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] _ in
            self?.state.appearance = Self.currentAppearance()
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in self?.dismiss() }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { [weak self] _ in
            self?.dismiss()
        }

        // 4 Hz while a mark is up: secure input anywhere, and the target's window (read off the
        // main thread; a change comes back through `windows.onChange`).
        pollTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            if IsSecureEventInputEnabled() { return self.dismiss() }
            self.windows.poll()
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    private func stopWatching() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach { center, token in center.removeObserver(token) }
        observers = []
        pollTimer?.invalidate()
        pollTimer = nil
        windows.end()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ block: @escaping (Notification) -> Void) {
        observers.append((center, center.addObserver(forName: name, object: nil, queue: .main, using: block)))
    }

    private static func isEscape(_ e: NSEvent) -> Bool { e.keyCode == UInt16(kVK_Escape) }

    /// ⇧⌘3, ⇧⌘4 and ⇧⌘5 at their default bindings (remapped shortcuts aren't seen).
    private static func isScreenshotShortcut(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains([.command, .shift]) else { return false }
        return [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5].map(UInt16.init).contains(e.keyCode)
    }

    private static func timer(after seconds: Double, _ action: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: max(seconds, 0), repeats: false) { _ in action() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

/// The on-screen windows, front to back, from the window list (bounds only; no permission needed).
/// Safe off the main thread: the primary display's height is read by the caller.
enum WindowList {
    static func current() -> [WindowInfo] {
        current(primaryHeight: NSScreen.screens.first?.frame.maxY ?? 0)
    }

    static func current(primaryHeight: CGFloat) -> [WindowInfo] {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return WindowTracking.windows(from: raw, primaryHeight: primaryHeight)
    }
}

/// Never key, never main: the overlay can't take focus or activate Benji.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayState: ObservableObject {
    @Published var marks: [ShownMark] = []
    @Published var sketches: [ShownSketch] = []
    @Published var board: CGRect?
    var boardStart = 0.0
    @Published var appearance = OverlayAppearance.standard
    /// True only while something moves; at rest the frame is drawn once and nothing is scheduled.
    @Published var animating = false
}

private struct OverlayHost: View {
    @ObservedObject var state: OverlayState
    let screenFrame: CGRect

    var body: some View {
        if state.animating {
            TimelineView(.animation) { _ in frame }
        } else {
            frame
        }
    }

    private var frame: some View {
        OverlayFrame(marks: state.marks, sketches: state.sketches, screenFrame: screenFrame, appearance: state.appearance,
                     now: ProcessInfo.processInfo.systemUptime, backdrop: .live, board: state.board, boardStart: state.boardStart)
    }
}

/// The board's own window, under the overlay: it takes the drags that move the board and the
/// drawing on it (the overlay above it is click-through). It draws a whisper of fill only, so the
/// window server counts the area as its own; the overlay draws the board itself. Never key or main.
final class BoardPanel: NSPanel {
    var onDrag: ((CGVector) -> Void)?

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        level = NSWindow.Level(rawValue: PointerOverlay.level.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isExcludedFromWindowsMenu = true
        isMovable = false
        let view = BoardHitView(frame: CGRect(origin: .zero, size: frame.size))
        view.onDrag = { [weak self] d in self?.onDrag?(d) }
        contentView = view
        setAccessibilityElement(true)
        setAccessibilityLabel("Benji's board")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class BoardHitView: NSView {
    var onDrag: ((CGVector) -> Void)?
    private var last: NSPoint?

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.02).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: OverlayBoard.radius, yRadius: OverlayBoard.radius).fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { last = NSEvent.mouseLocation }
    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        if let last { onDrag?(CGVector(dx: p.x - last.x, dy: p.y - last.y)) }
        last = p
    }
    override func mouseUp(with event: NSEvent) { last = nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
