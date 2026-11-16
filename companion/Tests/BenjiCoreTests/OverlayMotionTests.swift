import XCTest
@testable import BenjiCore

/// Overlay.md: layers per variant, the reveal/glide/erase timeline, the reveal sequence with and
/// without speech, window tracking, announcements and the plan the app gets from an answer.
final class OverlayMotionTests: XCTestCase {

    // MARK: layers

    func testDefaultLayersMatchTheAnatomy() {
        let ring = MarkLayers.of(.ring, .standard)
        XCTAssertEqual(ring.innerKeyline, MarkBand(9, 10))
        XCTAssertEqual(ring.mint, MarkBand(10, 13))
        XCTAssertEqual(ring.outerKeyline, MarkBand(13, 14))
        XCTAssertEqual(ring.halo, MarkBand(14, 20))
        XCTAssertEqual(ring.keyline, .black60)
        let region = MarkLayers.of(.region, .standard)
        XCTAssertEqual(region.innerKeyline, MarkBand(3, 4))
        XCTAssertEqual(region.mint, MarkBand(4, 6))
        XCTAssertEqual(region.outerKeyline, MarkBand(6, 7))
        XCTAssertEqual(region.halo, MarkBand(7, 13))
        XCTAssertEqual(MarkLayers.cornerRadius(atOutset: region.mint.outer), 10)   // radius-field
        XCTAssertEqual(MarkLayers.cornerRadius(atOutset: region.halo!.outer), 17)
    }

    func testIncreaseContrastThickensInwardWithOpaqueKeylines() {
        let ring = MarkLayers.of(.ring, OverlayAppearance(increaseContrast: true))
        XCTAssertEqual(ring.mint, MarkBand(9, 13))              // 4 pt, outer edge unchanged
        XCTAssertEqual(ring.innerKeyline, MarkBand(7.5, 9))     // flush, 1.5 pt
        XCTAssertEqual(ring.outerKeyline, MarkBand(13, 14.5))
        XCTAssertEqual(ring.keyline, .black)
        XCTAssertNotNil(ring.halo)
        XCTAssertEqual(ring.labelBackground, .opaqueBordered)
        XCTAssertEqual(MarkLayers.of(.region, OverlayAppearance(increaseContrast: true)).mint, MarkBand(3, 6))
    }

    func testReduceTransparencyDropsTheHaloAndUsesNotchRaisedKeylines() {
        let ring = MarkLayers.of(.ring, OverlayAppearance(reduceTransparency: true))
        XCTAssertNil(ring.halo)
        XCTAssertEqual(ring.keyline, .notchRaised)
        XCTAssertEqual(ring.outerKeyline, MarkBand(13, 15))
        XCTAssertEqual(ring.keepOut, 15)
        XCTAssertEqual(ring.labelBackground, .opaque)
        XCTAssertEqual(OverlayLayout.keepOut(for: .ring(center: .zero, label: ""),
                                             appearance: OverlayAppearance(reduceTransparency: true)).width, 30)
    }

    func testDifferentiateWithoutColorChangesNothing() {
        let a = OverlayAppearance(differentiateWithoutColor: true)
        XCTAssertEqual(MarkLayers.of(.ring, a), MarkLayers.of(.ring, .standard))
        XCTAssertEqual(MarkLayers.of(.region, a), MarkLayers.of(.region, .standard))
    }

    // MARK: timeline

    func testCurvesAndSpringFractions() {
        XCTAssertEqual(TimingCurve.easeInOut.value(at: 0.5), 0.5, accuracy: 0.001)
        XCTAssertEqual(TimingCurve.easeOut.value(at: 1), 1, accuracy: 0.0001)
        XCTAssertGreaterThan(TimingCurve.easeOut.value(at: 0.3), 0.3)
        // The 65% point of a critically damped token is 0.353 × d (Motion.md).
        XCTAssertEqual(MotionTokens.content.time(toReach: 0.65), MotionTokens.content.contentFadeInDelay, accuracy: 0.002)
    }

    func testRingRevealTimesMatchTheSpec() {
        XCTAssertEqual(MarkTimeline.pulseStart(kind: .ring, step: .reveal), 0.284, accuracy: 0.002)
        XCTAssertEqual(MarkTimeline.restTime(kind: .ring, step: .reveal, reduceMotion: false), 0.875, accuracy: 0.005)
        XCTAssertEqual(MarkTimeline.restTime(kind: .region, step: .reveal, reduceMotion: false), 1.18, accuracy: 0.01)
        let start = MarkTimeline.phase(kind: .ring, step: .reveal, reduceMotion: false, at: 0)
        XCTAssertEqual(start.draw, 0)
        XCTAssertEqual(start.label, 0)
        XCTAssertNil(start.pulse)
        let mid = MarkTimeline.phase(kind: .ring, step: .reveal, reduceMotion: false, at: 0.1)
        XCTAssertGreaterThan(mid.draw, 0.2)
        XCTAssertLessThan(mid.draw, 1)
        XCTAssertGreaterThan(mid.label, 0)   // label from 85 ms
        XCTAssertNotNil(MarkTimeline.phase(kind: .ring, step: .reveal, reduceMotion: false, at: 0.4).pulse)
    }

    func testOnePulseThenStill() {
        let rest = MarkTimeline.restTime(kind: .ring, step: .reveal, reduceMotion: false)
        let atRest = MarkTimeline.phase(kind: .ring, step: .reveal, reduceMotion: false, at: rest)
        XCTAssertNil(atRest.pulse)
        XCTAssertEqual(atRest.draw, 1)
        XCTAssertEqual(atRest.label, 1, accuracy: 0.0001)
        // Long after: identical, so nothing needs to be redrawn.
        XCTAssertEqual(MarkTimeline.phase(kind: .ring, step: .reveal, reduceMotion: false, at: 30), atRest)
        // The pulse appears in exactly one window of time.
        let times = stride(from: 0.0, through: 10, by: 0.01)
        let pulsing = times.filter { MarkTimeline.phase(kind: .ring, step: .reveal, reduceMotion: false, at: $0).pulse != nil }
        XCTAssertEqual(pulsing.first!, 0.29, accuracy: 0.011)
        XCTAssertLessThan(pulsing.last!, rest)
        XCTAssertEqual(pulsing.count, Int(((pulsing.last! - pulsing.first!) / 0.01).rounded()) + 1)
    }

    func testReduceMotionFadesEverythingAtOnce() {
        let mid = MarkTimeline.phase(kind: .region, step: .reveal, reduceMotion: true, at: 0.1)
        XCTAssertEqual(mid.draw, 1)
        XCTAssertNil(mid.pulse)
        XCTAssertEqual(mid.opacity, 0.5, accuracy: 0.01)
        XCTAssertEqual(mid.label, 1)
        XCTAssertEqual(MarkTimeline.restTime(kind: .region, step: .reveal, reduceMotion: true), 0.2)
        XCTAssertEqual(MarkTimeline.replacedOpacity(at: 0.1, reduceMotion: true), 0.5, accuracy: 0.01)
        for t in stride(from: 0.0, through: 1, by: 0.05) {
            XCTAssertNil(MarkTimeline.phase(kind: .ring, step: .reveal, reduceMotion: true, at: t).pulse)
        }
    }

    func testGlideStepsAndLabels() {
        let a = PointingMark.ring(center: CGPoint(x: 100, y: 100), label: "Sync files")
        let near = PointingMark.ring(center: CGPoint(x: 172, y: 100), label: "Include photos")
        let far = PointingMark.ring(center: CGPoint(x: 400, y: 100), label: "x")
        let region = PointingMark.region(rect: CGRect(x: 120, y: 80, width: 100, height: 60), label: "x")
        XCTAssertEqual(OverlayLayout.step(from: a, to: near, reduceMotion: false), .glide(from: CGPoint(x: 100, y: 100)))
        XCTAssertEqual(OverlayLayout.step(from: a, to: near, reduceMotion: true), .reveal)
        XCTAssertEqual(OverlayLayout.step(from: a, to: far, reduceMotion: false), .reveal)
        XCTAssertEqual(OverlayLayout.step(from: a, to: region, reduceMotion: false), .reveal)
        XCTAssertEqual(OverlayLayout.step(from: nil, to: a, reduceMotion: false), .reveal)

        let g = MarkStep.glide(from: .zero)
        let early = MarkTimeline.phase(kind: .ring, step: g, reduceMotion: false, at: 0.05)
        XCTAssertEqual(early.draw, 1)                  // already drawn: it moves, it doesn't redraw
        XCTAssertLessThan(early.previousLabel, 1)      // old label fades out at once
        XCTAssertEqual(early.label, 0)
        let t65 = MotionTokens.follow.time(toReach: 0.65)
        XCTAssertEqual(MarkTimeline.phase(kind: .ring, step: g, reduceMotion: false, at: t65).label, 0, accuracy: 0.001)
        XCTAssertGreaterThan(MarkTimeline.phase(kind: .ring, step: g, reduceMotion: false, at: t65 + 0.05).label, 0)
        XCTAssertNotNil(MarkTimeline.phase(kind: .ring, step: g, reduceMotion: false,
                                           at: MotionTokens.follow.settleTime + 0.05).pulse)   // pulses on arrival
    }

    // MARK: sequence

    func cues(_ s: [Double], _ o: [Int?]) -> [RevealCue] { zip(o, s).map { RevealCue(offset: $0, seconds: $1) } }

    func testTextPacingRevealsAtOnceThenAtEstimatedGaps() {
        var seq = PointingSequence(cues: cues([0.7, 2.5], [10, 40]), restTimes: [1, 1], pacing: .text, now: 100)
        XCTAssertEqual(seq.advance(to: 100), [.reveal(0)])
        XCTAssertEqual(seq.deadline()!, 101.8, accuracy: 0.0001)
        XCTAssertEqual(seq.advance(to: 101.8), [.reveal(1)])
        XCTAssertEqual(seq.deadline()!, 101.8 + 1 + 8, accuracy: 0.0001)   // 8 s after rest
        XCTAssertEqual(seq.advance(to: 200), [.erase(1)])
        XCTAssertTrue(seq.isFinished)
        XCTAssertNil(seq.deadline())
    }

    func testSpeechRevealsAtTheWordAndHoldsUntilAfterSpeech() {
        var seq = PointingSequence(cues: cues([0.7, 2.5], [10, 40]), restTimes: [1, 1], pacing: .speech, now: 0)
        XCTAssertEqual(seq.advance(to: 1.9), [])         // waiting for speech
        seq.speechDidStart(at: 0.5)
        seq.speechDidReach(offset: 4, at: 0.6)
        XCTAssertEqual(seq.advance(to: 0.6), [])
        seq.speechDidReach(offset: 10, at: 1.0)
        XCTAssertEqual(seq.advance(to: 1.0), [.reveal(0)])
        seq.speechDidReach(offset: 40, at: 1.5)          // too soon after the first: waits for minimumStep
        XCTAssertEqual(seq.advance(to: 1.5), [])
        XCTAssertEqual(seq.advance(to: 2.2), [.reveal(1)])
        XCTAssertEqual(seq.advance(to: 30), [])          // still speaking (up to the 60 s cap)
        seq.speechDidEnd(at: 30)
        XCTAssertEqual(seq.deadline()!, 33, accuracy: 0.0001)   // 3 s after speech, later than rest + 8
        XCTAssertEqual(seq.advance(to: 33), [.erase(1)])
        XCTAssertTrue(seq.isFinished)
    }

    func testSpeechEndingRevealsTheRestInTurn() {
        var seq = PointingSequence(cues: cues([0.5, 1, 2], [5, 20, 30]), restTimes: [1, 1, 1], pacing: .speech, now: 0)
        seq.speechDidReach(offset: 5, at: 0.2)
        XCTAssertEqual(seq.advance(to: 0.2), [.reveal(0)])
        seq.speechDidEnd(at: 0.4)
        XCTAssertEqual(seq.advance(to: 1.4), [.reveal(1)])
        XCTAssertEqual(seq.advance(to: 2.6), [.reveal(2)])
    }

    func testSpeechThatNeverStartsFallsBackToText() {
        var seq = PointingSequence(cues: cues([1, 3], [10, 40]), restTimes: [1, 1], pacing: .speech, now: 0)
        XCTAssertEqual(seq.deadline(), PointingSequence.speechStartGrace)
        XCTAssertEqual(seq.advance(to: 2), [.reveal(0)])
        XCTAssertEqual(seq.pacing, .text)
        XCTAssertEqual(seq.advance(to: 4), [.reveal(1)])
    }

    func testWithoutWordCallbacksALateEstimateStandsIn() {
        var seq = PointingSequence(cues: cues([2], [30]), restTimes: [1], pacing: .speech, now: 0)
        seq.speechDidStart(at: 1)
        XCTAssertEqual(seq.deadline()!, 1 + 2 * 1.5 + 1, accuracy: 0.0001)
    }

    func testAMarkCanExpireBeforeTheNextArrives() {
        var seq = PointingSequence(cues: cues([0, 20], [0, 99]), restTimes: [1, 1], pacing: .text, now: 0)
        XCTAssertEqual(seq.advance(to: 0), [.reveal(0)])
        XCTAssertEqual(seq.advance(to: 9), [.erase(0)])
        XCTAssertFalse(seq.isFinished)
        XCTAssertEqual(seq.advance(to: 20), [.reveal(1)])
    }

    // MARK: plan from an answer (both backends end here)

    func testPlanKeepsEveryTargetInOrder() {
        let targets = [
            PointingTarget(shape: .point(x: 100, y: 100), label: "Sync files"),
            PointingTarget(shape: .box(x1: 200, y1: 200, x2: 600, y2: 400), label: "Photos list"),
            PointingTarget(shape: .box(x1: 700, y1: 100, x2: 720, y2: 120), label: "Done"),
        ]
        let text = "Tick Sync files, then check the Photos list, then press Done."
        let plan = PointingPlan(targets: targets, text: text, speaking: false,
                                pixelSize: CGSize(width: 1000, height: 500),
                                screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 500), displayID: 1)!
        XCTAssertEqual(plan.marks.map(\.kind), [.ring, .region, .ring])
        XCTAssertEqual(plan.marks.map(\.label), ["Sync files", "Photos list", "Done"])
        XCTAssertEqual(plan.cues.count, 3)
        XCTAssertEqual(plan.cues.map(\.offset), [5, 32, 56])
        XCTAssertEqual(plan.pacing, .text)
        var seq = plan.sequence(reduceMotion: false, now: 0)
        var revealed: [Int] = []
        var t = 0.0
        while let d = seq.deadline(), t < 100 {
            t = d
            for case let .reveal(i) in seq.advance(to: t) { revealed.append(i) }
        }
        XCTAssertEqual(revealed, [0, 1, 2])
        XCTAssertTrue(seq.isFinished)
    }

    /// A plain answer's tags parsed in the app (`BackendEvent.answer`) and the targets the engine
    /// parsed itself (`answer` with `targets`) end in the same plan.
    func testTagsParsedInTheAppAndByTheEngineGiveTheSamePlan() {
        let pixel = CGSize(width: 1000, height: 500), frame = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let tags = "Tick Sync files, then the Photos list, then Done. [POINT:100,100:Sync files] [BOX:200,200,600,400:Photos list] [POINT:710,110:Done]"
        let parsed = PointingTags.parse(tags)
        let inApp = PointingPlan(targets: parsed.targets, text: parsed.text, speaking: false,
                                 pixelSize: pixel, screenFrame: frame, displayID: 1)!

        let json = #"{"type":"answer","id":"t1","text":"Tick Sync files, then the Photos list, then Done.","targets":[{"kind":"point","coords":[100,100],"label":"Sync files"},{"kind":"box","coords":[200,200,600,400],"label":"Photos list"},{"kind":"point","coords":[710,110],"label":"Done"}]}"#
        guard case let .answer(_, text, targets, _)? = ServeEvent.decode(json) else { return XCTFail("not an answer") }
        let serve = PointingPlan(targets: targets, text: text, speaking: false, pixelSize: pixel, screenFrame: frame, displayID: 1)!

        XCTAssertEqual(inApp.marks.count, 3)
        XCTAssertEqual(inApp, serve)
        XCTAssertEqual(inApp.marks.map(\.kind), [.ring, .region, .ring])
    }

    func testSpokenPlanUsesOffsetsInTheSpokenText() {
        let plan = PointingPlan(targets: [PointingTarget(shape: .point(x: 1, y: 1), label: "Share")],
                                text: "It's the **Share** button.", speaking: true,
                                pixelSize: CGSize(width: 10, height: 10),
                                screenFrame: CGRect(x: 0, y: 0, width: 10, height: 10), displayID: nil)!
        XCTAssertEqual(plan.pacing, .speech)
        XCTAssertEqual(plan.cues.first?.offset, 9)   // "It's the Share button."
        XCTAssertNil(PointingPlan(targets: [], text: "x", speaking: false, pixelSize: CGSize(width: 1, height: 1),
                                  screenFrame: .zero, displayID: nil))
    }

    func testAnchorSkipsALeadingArticleAndCountsUTF16() {
        let c = RevealTiming.cues(labels: ["The Share button"], in: "Open the menu, then the 👍 Share button.")
        XCTAssertEqual(c.first?.offset, 27)   // the emoji is two UTF-16 units
    }

    // MARK: announcements

    func testAnnouncements() {
        XCTAssertEqual(PointingAnnouncement.text(label: "Share button", step: 1, of: 1), "Pointing at Share button.")
        XCTAssertEqual(PointingAnnouncement.text(label: "Include photos", step: 2, of: 2), "Step 2 of 2: Include photos.")
        XCTAssertEqual(PointingAnnouncement.text(label: "", step: 1, of: 1), "Pointing at something on screen.")
        XCTAssertEqual(PointingAnnouncement.text(label: "Done!", step: 1, of: 1), "Pointing at Done!")
    }

    // MARK: windows

    func testWindowListParsingFlipsToAppKit() {
        let list: [[String: Any]] = [[
            "kCGWindowNumber": 42, "kCGWindowOwnerPID": 7, "kCGWindowLayer": 0, "kCGWindowAlpha": 1,
            "kCGWindowBounds": ["X": 100, "Y": 50, "Width": 400, "Height": 300],
        ], ["kCGWindowNumber": 1]]
        let w = WindowTracking.windows(from: list, primaryHeight: 982)
        XCTAssertEqual(w, [WindowInfo(id: 42, ownerPID: 7, frame: CGRect(x: 100, y: 982 - 350, width: 400, height: 300))])
    }

    func testWatchDetectsMoveCloseAndNewCover() {
        let target = WindowInfo(id: 1, ownerPID: 10, frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        let glass = WindowInfo(id: 2, ownerPID: 11, layer: 25, frame: CGRect(x: 0, y: 0, width: 2000, height: 2000))
        let own = WindowInfo(id: 3, ownerPID: 99, frame: CGRect(x: 0, y: 0, width: 2000, height: 2000))
        let area = CGRect(x: 90, y: 90, width: 20, height: 20)
        let watch = WindowTracking.watch(area: area, in: [own, glass, target], excludingPID: 99)!
        XCTAssertEqual(watch.window.id, 2)   // the topmost window under the target, whoever owns it

        let w = WindowTracking.watch(area: area, in: [own, target], excludingPID: 99)!
        XCTAssertEqual(w.window.id, 1)
        XCTAssertEqual(WindowTracking.change(for: w, now: [own, target], excludingPID: 99), .none)
        XCTAssertEqual(WindowTracking.change(for: w, now: [], excludingPID: 99), .closed)
        let moved = WindowInfo(id: 1, ownerPID: 10, frame: CGRect(x: 40, y: 0, width: 500, height: 500))
        XCTAssertEqual(WindowTracking.change(for: w, now: [moved], excludingPID: 99), .moved)
        let menu = WindowInfo(id: 5, ownerPID: 12, layer: 101, frame: CGRect(x: 80, y: 80, width: 200, height: 200))
        XCTAssertEqual(WindowTracking.change(for: w, now: [menu, target], excludingPID: 99), .covered)
        let elsewhere = WindowInfo(id: 6, ownerPID: 12, frame: CGRect(x: 300, y: 300, width: 50, height: 50))
        XCTAssertEqual(WindowTracking.change(for: w, now: [elsewhere, target], excludingPID: 99), .none)

        // Something already in front at capture time (see-through) doesn't count as covering.
        let strip = glass.withID(7, frame: CGRect(x: 100, y: 95, width: 50, height: 5))   // overlaps, off-centre
        let w2 = WindowTracking.watch(area: area, in: [strip, target], excludingPID: 99)!
        XCTAssertEqual(w2.window.id, 1)
        XCTAssertEqual(w2.alreadyInFront, [7])
        XCTAssertEqual(WindowTracking.change(for: w2, now: [strip, target], excludingPID: 99), .none)
    }

    // MARK: layout helpers

    func testSnappingAndNotch() {
        let m = OverlayLayout.snapped(.ring(center: CGPoint(x: 10.3, y: 20.8), label: "x"), scale: 2)
        XCTAssertEqual(m, .ring(center: CGPoint(x: 10.5, y: 21), label: "x"))
        let notch = OverlayLayout.notchRect(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                            topLeftArea: CGRect(x: 0, y: 950, width: 661, height: 32),
                                            topRightArea: CGRect(x: 851, y: 950, width: 661, height: 32))
        XCTAssertEqual(notch, CGRect(x: 661, y: 950, width: 190, height: 32))
        XCTAssertNil(OverlayLayout.notchRect(screenFrame: .zero, topLeftArea: nil, topRightArea: nil))
        XCTAssertEqual(OverlayLayout.hitArea(for: .ring(center: .zero, label: "")).width, 26)
    }

    func testMenuBarAndDockTargetsGetALabelInsideTheSafeArea() {
        let visible = CGRect(x: 0, y: 64, width: 1512, height: 982 - 33 - 64)
        let size = CGSize(width: 60, height: 22)
        // Wi-Fi in the 33 pt menu bar: halo bottom at 946, safe area top at 937.
        let menu = OverlayLayout.labelFrame(size: size, for: .ring(center: CGPoint(x: 1323, y: 966), label: "Wi-Fi"),
                                            visibleFrame: visible)
        XCTAssertEqual(menu?.maxY, 937)
        // A Dock icon: halo top at 52, safe area bottom at 76.
        let dock = OverlayLayout.labelFrame(size: size, for: .ring(center: CGPoint(x: 700, y: 32), label: "Mail"),
                                            visibleFrame: visible)
        XCTAssertEqual(dock?.minY, 76)
        // Never closer than space-2, and never further than the extra 24 pt.
        XCTAssertNil(OverlayLayout.labelFrame(size: size, for: .ring(center: CGPoint(x: 700, y: 990), label: "x"),
                                              visibleFrame: visible))
    }

    func testMappingOnASecondDisplayLeftOfAndBelowThePrimary() {
        // A 1920×1080 display to the left of the primary, lower down; the image was downscaled.
        let frame = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let p = PointMapping.screenPoint(for: PointTarget(x: 640, y: 0, label: ""),
                                         pixelSize: CGSize(width: 1280, height: 720), screenFrame: frame)
        XCTAssertEqual(p, CGPoint(x: -960, y: 780))
    }
}

private extension WindowInfo {
    func withID(_ id: UInt32, frame: CGRect) -> WindowInfo {
        WindowInfo(id: id, ownerPID: ownerPID, layer: layer, alpha: alpha, frame: frame)
    }
}
