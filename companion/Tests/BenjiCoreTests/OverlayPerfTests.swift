import XCTest
@testable import BenjiCore

/// The overlay's window-list work, once per plan and off the main thread, and spoken pictures
/// fitted to their sentence (D-106).
final class OverlayPerfTests: XCTestCase {
    private let pixel = CGSize(width: 1000, height: 500)
    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 500)

    private func t(_ shape: PointingShape, _ label: String) -> PointingTarget {
        PointingTarget(shape: shape, label: label)
    }

    // MARK: one watch per plan

    private let own = WindowInfo(id: 1, ownerPID: 99, frame: CGRect(x: 0, y: 0, width: 1000, height: 500))
    private let editor = WindowInfo(id: 10, ownerPID: 5, frame: CGRect(x: 0, y: 0, width: 600, height: 500))
    private let browser = WindowInfo(id: 20, ownerPID: 6, frame: CGRect(x: 600, y: 0, width: 400, height: 500))

    private let onEditor = [CGRect(x: 100, y: 100, width: 40, height: 40), CGRect(x: 300, y: 300, width: 40, height: 40),
                            CGRect(x: 400, y: 50, width: 20, height: 20)]
    private let onBrowser = CGRect(x: 700, y: 200, width: 50, height: 50)
    private let offScreen = CGRect(x: 2000, y: 2000, width: 10, height: 10)

    func testAPlansTargetsShareOneWatchPerWindow() {
        let areas = onEditor + [onBrowser, offScreen]
        let captured = [own, editor, browser]
        let plan = WindowTracking.PlanWatch(areas: areas, in: captured, excludingPID: 99)
        XCTAssertEqual(plan.windows.map(\.id), [10, 20], "three targets on the editor, one on the browser")
        XCTAssertEqual(plan.targets.map { $0.map(\.item) }, [[0, 1, 2], [3]])
        for (i, area) in areas.enumerated() {
            XCTAssertEqual(plan.watch(for: i), WindowTracking.watch(area: area, in: captured, excludingPID: 99),
                           "item \(i): the same watch the overlay built at each reveal")
        }
        XCTAssertNil(plan.watch(for: 4))
        XCTAssertTrue(WindowTracking.PlanWatch(areas: [offScreen], in: captured, excludingPID: 99).isEmpty)
    }

    func testPlanChangesMatchTheWindowByWindowRule() {
        let areas = onEditor + [onBrowser]
        let alreadyInFront = WindowInfo(id: 30, ownerPID: 7, frame: CGRect(x: 280, y: 280, width: 30, height: 30))
        let captured = [own, alreadyInFront, editor, browser]
        let plan = WindowTracking.PlanWatch(areas: areas, in: captured, excludingPID: 99)
        let popover = WindowInfo(id: 40, ownerPID: 8, frame: CGRect(x: 90, y: 90, width: 30, height: 30))
        let ownPanel = WindowInfo(id: 2, ownerPID: 99, frame: CGRect(x: 0, y: 0, width: 1000, height: 500))
        let clear = WindowInfo(id: 41, ownerPID: 8, alpha: 0, frame: CGRect(x: 0, y: 0, width: 1000, height: 500))
        let nudged = WindowInfo(id: 10, ownerPID: 5, frame: editor.frame.offsetBy(dx: 0.5, dy: 0))
        let moved = WindowInfo(id: 10, ownerPID: 5, frame: editor.frame.offsetBy(dx: 30, dy: 0))
        let resized = WindowInfo(id: 20, ownerPID: 6, frame: CGRect(x: 600, y: 0, width: 300, height: 500))
        let lists: [[WindowInfo]] = [
            captured, [], [editor], [browser], [popover, editor, browser], [ownPanel, clear, editor, browser],
            [alreadyInFront, editor, browser], [nudged, browser], [moved, browser], [editor, resized],
            [popover, moved, resized], [browser, editor], [editor, browser, popover],
        ]
        for (n, list) in lists.enumerated() {
            let changes = plan.changes(now: list, excludingPID: 99)
            for i in areas.indices {
                let one = WindowTracking.change(for: plan.watch(for: i)!, now: list, excludingPID: 99)
                XCTAssertEqual(changes[i] ?? WindowTracking.Change.none, one, "list \(n), item \(i)")
            }
        }
        // A popover over one target covers that one only, though the others share its window.
        XCTAssertEqual(plan.changes(now: [popover, editor, browser], excludingPID: 99), [0: .covered])
        XCTAssertEqual(plan.changes(now: [browser], excludingPID: 99), [0: .closed, 1: .closed, 2: .closed])
    }

    // MARK: reads off the main thread

    /// A window list source that counts its reads and notes which queue each ran on.
    private final class Source: @unchecked Sendable {
        let lock = NSLock()
        var list: [WindowInfo]
        private(set) var reads = 0
        private(set) var queues: [String] = []
        init(_ list: [WindowInfo]) { self.list = list }
        func read() -> [WindowInfo] {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            queues.append(String(cString: __dispatch_queue_get_label(nil)))
            return list
        }
        func set(_ l: [WindowInfo]) { lock.lock(); list = l; lock.unlock() }
    }

    private let work = DispatchQueue(label: "test.work")
    private let deliver = DispatchQueue(label: "test.deliver")

    private func poller(_ source: Source) -> WindowPoller {
        WindowPoller(source: { source.read() }, work: work, deliver: deliver, excludingPID: 99)
    }

    /// Lets every read and delivery that's been started finish.
    private func drain() {
        work.sync {}
        deliver.sync {}
    }

    private func pictureAreas(_ n: Int) -> [CGRect] {
        (0..<n).map { CGRect(x: 50 + 30 * $0, y: 200, width: 20, height: 20) }
    }

    func testOneReadPerPlanBeforeItsFirstRevealWhateverItsParts() {
        let source = Source([own, editor, browser])
        let p = poller(source)
        let plan = WindowTracking.PlanWatch(areas: pictureAreas(12), in: [own, editor, browser], excludingPID: 99)
        deliver.sync {
            p.begin(plan)
            for i in 0..<12 { XCTAssertEqual(p.change(for: i), .none) }   // every reveal asks
        }
        XCTAssertEqual(source.reads, 1, "one read for a 12-part picture, not one per part")
        XCTAssertEqual(source.queues, ["test.deliver"], "taken where the plan begins, before the first reveal")

        let nothingUnder = WindowTracking.PlanWatch(areas: [offScreen], in: [own, editor], excludingPID: 99)
        deliver.sync { p.begin(nothingUnder); p.poll() }
        drain()
        XCTAssertEqual(source.reads, 1, "no read when no target has a window under it")
    }

    func testThePollReadsOffTheDeliverQueueAndHandsBackOnlyAChange() {
        let source = Source([own, editor, browser])
        let p = poller(source)
        var delivered: [[Int: WindowTracking.Change]] = []
        var deliveredOn: [String] = []
        p.onChange = { delivered.append($0); deliveredOn.append(String(cString: __dispatch_queue_get_label(nil))) }
        deliver.sync { p.begin(WindowTracking.PlanWatch(areas: onEditor + [onBrowser], in: [own, editor, browser], excludingPID: 99)) }

        for _ in 0..<3 { deliver.sync { p.poll() }; drain() }
        XCTAssertEqual(source.reads, 4)
        XCTAssertEqual(Array(source.queues.dropFirst()), ["test.work", "test.work", "test.work"])
        XCTAssertTrue(delivered.isEmpty, "nothing changed: nothing handed back")

        source.set([own, WindowInfo(id: 10, ownerPID: 5, frame: editor.frame.offsetBy(dx: 40, dy: 0)), browser])
        deliver.sync { p.poll() }; drain()
        XCTAssertEqual(delivered, [[0: .moved, 1: .moved, 2: .moved]])
        XCTAssertEqual(deliveredOn, ["test.deliver"])
        deliver.sync { XCTAssertEqual(p.change(for: 1), .moved); XCTAssertEqual(p.change(for: 3), .none) }

        deliver.sync { p.poll() }; drain()
        XCTAssertEqual(delivered.count, 1, "the same change isn't handed back twice")
        source.set([own, editor, browser])
        deliver.sync { p.poll() }; drain()
        XCTAssertEqual(delivered.last, [:], "moved back: the change is withdrawn")
    }

    func testAResultForAReplacedOrEndedPlanIsDropped() {
        let source = Source([own, editor, browser])
        let p = poller(source)
        var delivered = 0
        p.onChange = { _ in delivered += 1 }
        let plan = WindowTracking.PlanWatch(areas: onEditor, in: [own, editor, browser], excludingPID: 99)
        deliver.sync { p.begin(plan) }
        source.set([own, browser])                       // the editor closes

        work.suspend()
        deliver.sync { p.poll() }                        // its read is held up
        deliver.sync { p.begin(WindowTracking.PlanWatch(areas: [onBrowser], in: [own, editor, browser], excludingPID: 99)) }
        work.resume()
        drain()
        XCTAssertEqual(delivered, 0, "the editor's closing belonged to the replaced plan")
        deliver.sync { XCTAssertEqual(p.changed, [:]) }

        work.suspend()
        deliver.sync { p.begin(plan) }                    // this one sees the editor closed at once
        deliver.sync { XCTAssertEqual(p.change(for: 0), .closed) }
        deliver.sync { p.poll() }
        deliver.sync { p.end() }
        work.resume()
        drain()
        deliver.sync { XCTAssertNil(p.plan); XCTAssertEqual(p.changed, [:]) }
        XCTAssertEqual(delivered, 0, "nothing comes back after the plan ended")
    }

    func testAPollStillOutIsNotStackedUp() {
        let source = Source([own, editor])
        let p = poller(source)
        deliver.sync { p.begin(WindowTracking.PlanWatch(areas: onEditor, in: [own, editor], excludingPID: 99)) }
        work.suspend()
        deliver.sync { for _ in 0..<5 { p.poll() } }
        work.resume()
        drain()
        XCTAssertEqual(source.reads, 2, "the begin read and one poll")
        deliver.sync { p.poll() }; drain()
        XCTAssertEqual(source.reads, 3, "the next poll reads again once the last came back")
    }

    // MARK: pictures fitted to speech

    private func run(_ seq: inout PointingSequence, until end: Double = 400,
                     at times: [Double: (inout PointingSequence) -> Void] = [:]) -> [(Double, PointingSequence.Action)] {
        var out: [(Double, PointingSequence.Action)] = []
        var events = times.sorted { $0.key < $1.key }
        while true {
            let next = seq.deadline()
            if let e = events.first, next.map({ e.key <= $0 }) ?? true {
                events.removeFirst()
                e.value(&seq)
                for a in seq.advance(to: e.key) { out.append((e.key, a)) }
                continue
            }
            guard let d = next, d < end else { break }
            for a in seq.advance(to: d) { out.append((d, a)) }
        }
        return out
    }

    private func reveals(_ a: [(Double, PointingSequence.Action)]) -> [(Double, Int)] {
        a.compactMap { if case let .reveal(i) = $0.1 { return ($0.0, i) } else { return nil } }
    }

    /// 12 parts: a body, a fin, two wings, a tailplane, a cockpit, five windows and a stripe.
    private var airplaneTargets: [PointingTarget] {
        let outlines: [([Int], String)] = [
            ([100, 262, 400, 258, 446, 268, 466, 282, 446, 295, 400, 302, 120, 302, 104, 290], "body"),
            ([112, 262, 88, 192, 116, 192, 170, 262], "tail fin"),
            ([250, 262, 222, 212, 246, 212, 312, 262], "far wing"),
            ([240, 292, 190, 372, 224, 372, 318, 292], "wing"),
            ([114, 288, 88, 316, 108, 316, 152, 290], "tailplane"),
            ([416, 268, 440, 268, 452, 279, 420, 279], "cockpit"),
        ]
        var out: [PointingTarget] = outlines.map { t(.shape($0.0), $0.1) }
        for k in 0..<5 {
            let x = 290 + 20 * k
            out.append(t(.oval(x1: x, y1: 270, x2: x + 10, y2: 280), "window"))
        }
        out.append(t(.line([200, 290, 380, 290]), "stripe"))
        return out
    }

    private func airplane(_ text: String, speaking: Bool = true) -> PointingPlan {
        PointingPlan(targets: airplaneTargets, text: text, speaking: speaking, pixelSize: pixel, screenFrame: frame, displayID: 1)!
    }

    /// What a sentence-at-a-time voice reports: its words spread over `duration`, from `start`.
    private func kokoro(_ seq: inout PointingSequence, text: String, start: Double, duration: Double) {
        seq.speechDidStart(at: start)
        let m = SpeechFollow.milestones(sentence: text, in: text, from: 0, duration: duration)!.milestones
        for w in m { seq.speechWillReach(offset: w.offset, at: start + w.delay) }
    }

    private func naturalTime(_ plan: PointingPlan) -> Double {
        let rest = plan.items.map { SketchTimeline.drawDuration($0.sketch!) }
        return rest.reduce(0, +) + Double(rest.count - 1) * PointingSequence.penLift
    }

    func testFitIsTheSentenceThatNamesThePicture() {
        let unnamed = PictureFit(text: "An airliner. It flies.", firstCue: RevealCue(offset: 11, seconds: 1.3), parts: [true])!
        XCTAssertNil(unnamed.startOffset, "no word names it: from the start of speech")
        XCTAssertEqual(unnamed.endOffset, 11, "to the end of the first sentence")
        let named = PictureFit(text: "Sure. Here's the body of a plane. More.", firstCue: RevealCue(offset: 17, seconds: 1), parts: [true])!
        XCTAssertEqual(named.startOffset, 17)
        XCTAssertEqual(named.endOffset, 32)
        XCTAssertEqual(named.endSeconds, RevealTiming.seconds(before: 9, in: RevealTiming.tokenize("Sure. Here's the body of a plane. More.")))
        let noStop = PictureFit(text: "A plane", firstCue: RevealCue(offset: nil, seconds: 0), parts: [true])!
        XCTAssertEqual(noStop.endOffset, 7)

        XCTAssertNotNil(airplane("An airliner.").fit)
        XCTAssertNil(airplane("An airliner.", speaking: false).fit, "read, not spoken: today's timing")
        XCTAssertNil(airplane("An airliner.").sequence(reduceMotion: true, now: 0).fit, "Reduce Motion fades parts in")
        let ring = PointingPlan(targets: [t(.point(x: 10, y: 10), "Save"), t(.circle(x1: 100, y1: 100, x2: 200, y2: 140), "Total")],
                                text: "Press Save, then check the Total.", speaking: true, pixelSize: pixel, screenFrame: frame, displayID: 1)!
        XCTAssertNil(ring.fit, "marks on things keep today's timing")
    }

    func testUnfittedPicturesKeepTodaysTimingExactly() {
        let plan = airplane("An airliner, nose to the right.", speaking: false)
        var seq = plan.sequence(reduceMotion: false, now: 0)
        let actions = run(&seq)
        let r = reveals(actions)
        XCTAssertEqual(r.count, 12)
        for (k, (time, i)) in r.enumerated() where k > 0 {
            XCTAssertEqual(time - r[k - 1].0, SketchTimeline.drawDuration(plan.items[i - 1].sketch!) + PointingSequence.penLift,
                           accuracy: 1e-9, "part \(i) at the pen's pace")
            XCTAssertEqual(seq.pace(i), 1)
        }
        XCTAssertEqual(seq.durations, seq.restTimes)
        var direct = PointingSequence(cues: plan.cues, restTimes: seq.restTimes, pacing: .text, now: 0, drawing: true)
        XCTAssertEqual(run(&direct).map(\.0), actions.map(\.0), "the same moments as a sequence built without a fit")
    }

    func testAShortSentenceHurriesThePictureWithinLimits() {
        let text = "Here's an airliner, nose to the right."   // a sentence of about two seconds
        let plan = airplane(text)
        var seq = plan.sequence(reduceMotion: false, now: 0)
        kokoro(&seq, text: text, start: 0.5, duration: 2)
        let actions = run(&seq, at: [2.5: { $0.speechDidEnd(at: 2.5) }])
        let r = reveals(actions)
        XCTAssertEqual(r.map(\.1), Array(0..<12), "every part, in order")
        XCTAssertEqual(r[0].0, 0.5, "no word names it: the first part comes as the sentence starts")
        for i in 0..<12 {
            let rest = seq.restTimes[i]
            XCTAssertGreaterThanOrEqual(seq.pace(i), PictureFit.fastest - 1e-12)
            XCTAssertLessThanOrEqual(seq.pace(i), PictureFit.slowest + 1e-12)
            XCTAssertGreaterThanOrEqual(seq.durations[i], min(rest, PictureFit.partFloor) - 1e-12, "the 0.25 s floor")
        }
        let done = r[11].0 + seq.durations[11]
        // Two seconds of speech can't hold twelve parts: all at the fastest pace, small ones at the floor.
        let fastest = seq.restTimes.reduce(0) { $0 + max($1 * PictureFit.fastest, min($1, PictureFit.partFloor)) }
            + 11 * PointingSequence.penLift
        XCTAssertEqual(done - 0.5, fastest, accuracy: 1e-9)
        XCTAssertLessThan(done - 0.5, naturalTime(plan) - 1, "quicker than the pen alone")
        let erase = actions.first { if case .erase = $0.1 { return true } else { return false } }!
        XCTAssertEqual(erase.0, done + PointingSequence.drawingHold, accuracy: 1e-9, "still two minutes up")
    }

    func testAPictureThatFitsEndsWithItsSentence() {
        // A long sentence: the picture is paced to finish as it does.
        let text = "Here's a little airliner flying along with its nose to the right, the wings swept back, a row of windows and a stripe."
        let plan = airplane(text)
        let natural = naturalTime(plan)
        let end = 0.5 + natural * 1.2                    // the voice takes 1.2× the pen's time
        var seq = plan.sequence(reduceMotion: false, now: 0)
        kokoro(&seq, text: text, start: 0.5, duration: end - 0.5)
        let r = reveals(run(&seq, at: [end: { $0.speechDidEnd(at: end) }]))
        XCTAssertEqual(r.count, 12)
        let done = r[11].0 + seq.durations[11]
        XCTAssertEqual(done, end, accuracy: 0.05, "the last part comes to rest as the sentence ends")
        XCTAssertGreaterThan(seq.pace(0), 1)
    }

    func testALongSentenceStretchesThePictureOnlySoFar() {
        let text = "Here's an airliner. " + String(repeating: "It has a long body and wide wings to carry it far. ", count: 3)
        let small = PointingPlan(targets: [t(.oval(x1: 100, y1: 100, x2: 160, y2: 140), "airliner"),
                                           t(.line([100, 150, 200, 150]), "runway")],
                                 text: text, speaking: true, pixelSize: pixel, screenFrame: frame, displayID: 1)!
        var seq = small.sequence(reduceMotion: false, now: 0)
        // The first sentence is the one that names it, spoken over 6 s.
        let first = "Here's an airliner."
        seq.speechDidStart(at: 0)
        for w in SpeechFollow.milestones(sentence: first, in: text, from: 0, duration: 6)!.milestones {
            seq.speechWillReach(offset: w.offset, at: w.delay)
        }
        let r = reveals(run(&seq, until: 30))
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(seq.pace(0), PictureFit.slowest, accuracy: 1e-12, "stretched no further than 1.4×")
        XCTAssertEqual(seq.pace(1), PictureFit.slowest, accuracy: 1e-12)
        XCTAssertLessThan(r[1].0 + seq.durations[1], 6, "so it ends before the sentence rather than crawl")
    }

    func testSpeechEndingEarlyFinishesTheRestQuicklyInOrder() {
        let text = "Here's an airliner, nose to the right, with a long body, swept wings and five windows."
        let plan = airplane(text)
        var seq = plan.sequence(reduceMotion: false, now: 0)
        seq.speechDidStart(at: 0)                        // a voice with no word reports
        let actions = run(&seq, at: [1.0: { $0.speechDidEnd(at: 1.0) }])
        let r = reveals(actions)
        XCTAssertEqual(r.map(\.1), Array(0..<12), "nothing dropped")
        for (time, i) in r where time > 1.0 {
            XCTAssertEqual(seq.durations[i], max(seq.restTimes[i] * PictureFit.fastest, min(seq.restTimes[i], PictureFit.partFloor)),
                           accuracy: 1e-12, "part \(i), after speech ended, at the fastest pace")
        }
        XCTAssertGreaterThan(r.filter { $0.0 > 1.0 }.count, 3)
    }

    func testTheNextTurnHurriesTheRestButKeepsThePictureUp() {
        let text = "Here's a little airliner flying along with its nose to the right, the wings swept back, a row of windows and a stripe."
        let plan = airplane(text)
        var seq = plan.sequence(reduceMotion: false, now: 0)
        kokoro(&seq, text: text, start: 0, duration: 12)
        let actions = run(&seq, at: [2.0: { $0.hurry() }])
        let r = reveals(actions)
        XCTAssertEqual(r.map(\.1), Array(0..<12), "whole, in order")
        let after = r.filter { $0.0 > 2.0 }
        XCTAssertFalse(after.isEmpty)
        for (_, i) in after {
            XCTAssertEqual(seq.durations[i], max(seq.restTimes[i] * PictureFit.fastest, min(seq.restTimes[i], PictureFit.partFloor)),
                           accuracy: 1e-12)
        }
        let done = r[11].0 + seq.durations[11]
        let erases = actions.filter { if case .erase = $0.1 { return true } else { return false } }
        XCTAssertEqual(erases.count, 12)
        XCTAssertEqual(erases[0].0, done + PointingSequence.drawingHold, accuracy: 1e-9, "D-97's two minutes, unchanged")

        var unhurried = airplane(text, speaking: false).sequence(reduceMotion: false, now: 0)
        var hurried = airplane(text, speaking: false).sequence(reduceMotion: false, now: 0)
        hurried.hurry()
        XCTAssertEqual(run(&hurried).map(\.0), run(&unhurried).map(\.0), "a picture that isn't spoken ignores it")
    }

    func testAVoiceThatNeverStartsFallsBackToTodaysTextTiming() {
        let plan = airplane("An airliner.")
        var seq = plan.sequence(reduceMotion: false, now: 0)
        let r = reveals(run(&seq))
        XCTAssertEqual(r.first?.0, PointingSequence.speechStartGrace)
        XCTAssertEqual(seq.durations, seq.restTimes, "after the grace it's read, at the pen's pace")
    }

    func testTheVoicesPaceMovesTheFittedEnd() {
        let text = "Here's a little airliner flying along with its nose to the right."
        var seq = airplane(text).sequence(reduceMotion: false, now: 0)
        seq.speechDidStart(at: 0)
        let estimate = seq.fit!.endSeconds
        XCTAssertEqual(seq.fittedEnd()!, estimate, accuracy: 1e-12, "the estimate until the voice is heard")
        let tokens = RevealTiming.tokenize(text)
        let nose = tokens.firstIndex { $0.word == "nose" }!
        let noseAt = RevealTiming.seconds(before: nose, in: tokens)
        seq.speechDidReach(offset: tokens[nose].offset, at: noseAt * 1.5)   // a slower voice
        XCTAssertEqual(seq.fittedEnd()!, estimate * 1.5, accuracy: 1e-9)
        seq.speechDidReach(offset: text.utf16.count + 5, at: 3)            // already past it
        XCTAssertEqual(seq.fittedEnd()!, 3)
        seq.speechDidEnd(at: 2.5)
        XCTAssertEqual(seq.fittedEnd()!, 2.5)
    }
}
