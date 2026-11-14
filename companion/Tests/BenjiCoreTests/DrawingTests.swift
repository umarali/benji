import XCTest
@testable import BenjiCore

/// Benji's pen marks: the plan, the reveal sequence when an answer draws, the stroke geometry
/// and timing, and following a voice that reports a sentence at a time.
final class DrawingTests: XCTestCase {
    private let pixel = CGSize(width: 1000, height: 500)
    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 500)

    private func t(_ shape: PointingShape, _ label: String) -> PointingTarget {
        PointingTarget(shape: shape, label: label)
    }

    private func run(_ seq: inout PointingSequence, until end: Double = 200) -> [(Double, PointingSequence.Action)] {
        var out: [(Double, PointingSequence.Action)] = []
        while let d = seq.deadline(), d < end {
            for a in seq.advance(to: d) { out.append((d, a)) }
        }
        return out
    }

    // MARK: plan and sequence

    func testDrawingPlanAccumulates() {
        let text = "Circle the Total, then follow the arrow to Pay."
        let plan = PointingPlan(targets: [t(.circle(x1: 100, y1: 100, x2: 200, y2: 140), "Total"),
                                          t(.arrow(x1: 300, y1: 300, x2: 600, y2: 200), "Pay")],
                                text: text, speaking: false, pixelSize: pixel, screenFrame: frame, displayID: 1)!
        XCTAssertTrue(plan.draws)
        XCTAssertEqual(plan.marks, [])
        XCTAssertEqual(plan.items.count, 2)
        var seq = plan.sequence(reduceMotion: false, now: 0)
        XCTAssertTrue(seq.accumulate)
        let actions = run(&seq)
        XCTAssertEqual(actions.map(\.1), [.reveal(0), .reveal(1), .erase(0), .erase(1)],
                       "both stay up together and go together")
        let secondReveal = actions[1].0
        let rest = SketchTimeline.restTime(plan.items[1].sketch!, reduceMotion: false)
        XCTAssertEqual(actions[2].0, secondReveal + rest + MotionTiming.markLifetime, accuracy: 1e-9,
                       "lifetime counts from the last one to come to rest")
        XCTAssertTrue(seq.isFinished)
    }

    func testPointerOnlyPlanStillReplaces() {
        let plan = PointingPlan(targets: [t(.point(x: 10, y: 10), "a"), t(.point(x: 900, y: 400), "b")],
                                text: "a then b", speaking: false, pixelSize: pixel, screenFrame: frame, displayID: 1)!
        XCTAssertFalse(plan.draws)
        var seq = plan.sequence(reduceMotion: false, now: 0)
        XCTAssertEqual(run(&seq).map(\.1), [.reveal(0), .reveal(1), .erase(1)])
    }

    func testMixedPlanKeepsOrderAndCuesEveryItem() {
        let text = "Press Save, then type in the Name field."
        let plan = PointingPlan(targets: [t(.point(x: 10, y: 10), "Save"), t(.underline(x1: 100, y1: 300, x2: 400, y2: 300), "Name")],
                                text: text, speaking: false, pixelSize: pixel, screenFrame: frame, displayID: 1)!
        XCTAssertEqual(plan.items.map(\.label), ["Save", "Name"])
        XCTAssertEqual(plan.cues.map(\.offset), [6, 29])
        XCTAssertTrue(plan.draws)
    }

    func testFutureWordTimesPaceTheReveal() {
        // A voice that reports each sentence: the second mark's word is heard 1.5 s in.
        let text = "Here is the Total. Now look at Pay."
        let plan = PointingPlan(targets: [t(.circle(x1: 100, y1: 100, x2: 200, y2: 140), "Total"),
                                          t(.circle(x1: 300, y1: 100, x2: 400, y2: 140), "Pay")],
                                text: text, speaking: true, pixelSize: pixel, screenFrame: frame, displayID: nil)!
        var seq = plan.sequence(reduceMotion: false, now: 0)
        seq.speechDidStart(at: 1)
        seq.speechWillReach(offset: 12, at: 1.4)       // "Total"
        seq.speechWillReach(offset: 31, at: 4.0)       // "Pay"
        XCTAssertEqual(seq.deadline(), 1.4)
        XCTAssertEqual(seq.advance(to: 1.4), [.reveal(0)])
        XCTAssertEqual(seq.deadline(), 4.0)
        seq.speechWillReach(offset: 31, at: 3.0)       // an earlier report wins
        XCTAssertEqual(seq.deadline(), 3.0)
    }

    // MARK: geometry

    func testSketchConversionPutsRectsRight() {
        let flip: (CGPoint) -> CGPoint = { CGPoint(x: $0.x, y: 500 - $0.y) }
        XCTAssertEqual(Sketch.circle(rect: CGRect(x: 10, y: 20, width: 30, height: 40), label: "c").converted(flip),
                       .circle(rect: CGRect(x: 10, y: 440, width: 30, height: 40), label: "c"))
        XCTAssertEqual(Sketch.arrow(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 3, y: 4), label: "").converted(flip),
                       .arrow(from: CGPoint(x: 1, y: 498), to: CGPoint(x: 3, y: 496), label: ""))
    }

    func testStrokesAreDeterministicAndNearTheirShape() {
        let style = PenStyle.of(.standard)
        let r = CGRect(x: 100, y: 100, width: 200, height: 60)
        let circle = Sketch.circle(rect: r, label: "c")
        let a = PenGeometry.strokes(for: circle, seed: 7, style: style)
        XCTAssertEqual(a, PenGeometry.strokes(for: circle, seed: 7, style: style), "same seed, same ink")
        XCTAssertNotEqual(a, PenGeometry.strokes(for: circle, seed: 8, style: style))
        XCTAssertEqual(a.count, 1)
        let loose = circle.bounds.insetBy(dx: -0.01, dy: -0.01)
        let tight = r.insetBy(dx: 1, dy: 1)
        for p in a[0].points {
            XCTAssertTrue(loose.contains(p), "\(p) strays too far")
            XCTAssertFalse(tight.contains(p), "\(p) cuts into the thing it circles")
        }

        let from = CGPoint(x: 100, y: 400), to = CGPoint(x: 500, y: 200)
        let arrow = PenGeometry.strokes(for: .arrow(from: from, to: to, label: ""), seed: 3, style: style)
        XCTAssertEqual(arrow.count, 3, "shaft and two barbs")
        XCTAssertEqual(arrow[0].points.first!.x, from.x, accuracy: 0.01)
        XCTAssertEqual(arrow[0].points.last!.x, to.x, accuracy: 0.01, "the wobble is pinned at the tip")
        XCTAssertEqual(arrow[0].points.last!.y, to.y, accuracy: 0.01)
        XCTAssertEqual(arrow[1].points.first, to)
        XCTAssertEqual(arrow[2].points.first, to)

        XCTAssertEqual(PenGeometry.strokes(for: .note(at: .zero, text: "x"), seed: 1, style: style), [])
        let hl = PenGeometry.strokes(for: .highlight(rect: r, label: ""), seed: 1, style: style)
        XCTAssertEqual(hl.first?.widths.first, r.height + 2, "the marker covers the box")
    }

    func testTaperLandsLightPressesThenLifts() {
        XCTAssertEqual(PenGeometry.pressure(at: 0), 0.55, accuracy: 1e-9)
        XCTAssertEqual(PenGeometry.pressure(at: 0.5), 1, accuracy: 1e-9)
        XCTAssertLessThan(PenGeometry.pressure(at: 1), 0.75)
        XCTAssertGreaterThan(PenGeometry.pressure(at: 1), 0.5)
    }

    func testRevealDrawsStrokesInTurn() {
        let s1 = PenStroke(points: [.zero, CGPoint(x: 100, y: 0)], widths: [2, 2])
        let s2 = PenStroke(points: [.zero, CGPoint(x: 0, y: 100)], widths: [2, 2])
        XCTAssertEqual(PenGeometry.revealed([s1, s2], progress: 0), [])
        let half = PenGeometry.revealed([s1, s2], progress: 0.25)
        XCTAssertEqual(half.count, 1)
        XCTAssertEqual(half[0].length, 50, accuracy: 1e-9)
        let most = PenGeometry.revealed([s1, s2], progress: 0.75)
        XCTAssertEqual(most.map(\.length), [100, 50])
        XCTAssertEqual(PenGeometry.revealed([s1, s2], progress: 1), [s1, s2])
    }

    func testOutlineIsClosedAroundTheInk() {
        let s = PenStroke(points: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 100, y: 0)], widths: [4, 4, 4])
        let o = s.outline(grow: 1)
        XCTAssertEqual(o.count, 3 + 5 + 3 + 5)
        XCTAssertEqual(o.map(\.y).max()!, 3, accuracy: 1e-9)
        XCTAssertEqual(o.map(\.y).min()!, -3, accuracy: 1e-9)
        XCTAssertGreaterThan(o.map(\.x).max()!, 100, "the end cap goes past the tip")
        XCTAssertLessThan(o.map(\.x).min()!, 0, "the start cap goes behind the start")
    }

    // MARK: timing

    func testPenSpeedWithLimits() {
        XCTAssertEqual(SketchTimeline.drawDuration(.underline(from: .zero, to: CGPoint(x: 20, y: 0), label: "")), SketchTimeline.shortest)
        XCTAssertEqual(SketchTimeline.drawDuration(.underline(from: .zero, to: CGPoint(x: 650, y: 0), label: "")), 1, accuracy: 1e-9)
        XCTAssertEqual(SketchTimeline.drawDuration(.path(points: [.zero, CGPoint(x: 900, y: 0), CGPoint(x: 900, y: 900)], label: "")),
                       SketchTimeline.longest)
        XCTAssertEqual(SketchTimeline.restTime(.note(at: .zero, text: "Hi"), reduceMotion: true), MotionTokens.reduceDuration)
    }

    func testPhaseDrawsThenRestsAndReduceMotionOnlyFades() {
        let s = Sketch.underline(from: .zero, to: CGPoint(x: 650, y: 0), label: "")
        XCTAssertEqual(SketchTimeline.phase(s, reduceMotion: false, at: 0).draw, 0)
        XCTAssertEqual(SketchTimeline.phase(s, reduceMotion: false, at: 0.5).draw, 0.5, accuracy: 0.01)
        XCTAssertEqual(SketchTimeline.phase(s, reduceMotion: false, at: 2).draw, 1)
        let rm = SketchTimeline.phase(s, reduceMotion: true, at: 0.1)
        XCTAssertEqual(rm.draw, 1, "no pen movement under Reduce Motion")
        XCTAssertGreaterThan(rm.opacity, 0)
        XCTAssertLessThan(rm.opacity, 1)
    }

    func testNoteSitsBesideItsPointAndOnScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let size = CGSize(width: 120, height: 24)
        XCTAssertEqual(SketchLayout.noteFrame(size: size, at: CGPoint(x: 100, y: 300), bounds: bounds),
                       CGRect(x: 110, y: 288, width: 120, height: 24))
        XCTAssertEqual(SketchLayout.noteFrame(size: size, at: CGPoint(x: 950, y: 300), bounds: bounds).maxX, 940,
                       "no room on the right: it goes to the left")
        XCTAssertEqual(SketchLayout.noteFrame(size: size, at: CGPoint(x: 100, y: 2), bounds: bounds).minY, 12)
    }

    func testDrawingAnnouncements() {
        XCTAssertEqual(PointingAnnouncement.text(for: .circle(rect: .zero, label: "Total")), "Circling Total.")
        XCTAssertEqual(PointingAnnouncement.text(for: .arrow(from: .zero, to: .zero, label: "Pay")), "Arrow to Pay.")
        XCTAssertEqual(PointingAnnouncement.text(for: .highlight(rect: .zero, label: "")), "Highlighting something on screen.")
        XCTAssertEqual(PointingAnnouncement.text(for: .note(at: .zero, text: "Click here!")), "Note on screen: Click here!")
    }

    // MARK: following Kokoro

    func testKokoroAudioCarriesItsSentence() {
        let pcm = Data([0x00, 0x00])
        XCTAssertEqual(KokoroEvent.decode(#"{"type":"audio","id":"1","seq":0,"text":"Hi there.","pcm16":"\#(pcm.base64EncodedString())"}"#),
                       .audio(id: "1", seq: 0, text: "Hi there.", pcm16: pcm))
    }

    func testSentenceWordsSpreadOverItsAudio() {
        let text = "Open Settings. Then press the Save button."
        guard let first = SpeechFollow.milestones(sentence: "Open Settings.", in: text, from: 0, duration: 1) else {
            return XCTFail("first sentence not found")
        }
        XCTAssertEqual(first.milestones.map(\.offset), [0, 5])
        XCTAssertEqual(first.milestones[0].delay, 0)
        XCTAssertEqual(first.end, 13)
        guard let second = SpeechFollow.milestones(sentence: "Then press the Save button.", in: text, from: first.end, duration: 2) else {
            return XCTFail("second sentence not found")
        }
        XCTAssertEqual(second.milestones.map(\.offset), [15, 20, 26, 30, 35])
        let save = second.milestones[3]
        // "Then press the" is 3 of 8 syllables: 1 + 1 + 1 + 1 + 2, and 2 for the sentence end.
        XCTAssertEqual(save.delay, 2 * 3.0 / 8.0, accuracy: 1e-9)
        XCTAssertNil(SpeechFollow.milestones(sentence: "Something else.", in: text, from: 0, duration: 1))
        XCTAssertNil(SpeechFollow.milestones(sentence: "Open Settings.", in: text, from: 13, duration: 1),
                     "never looks back before the last sentence")
    }
}
