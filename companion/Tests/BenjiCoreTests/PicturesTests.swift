import XCTest
@testable import BenjiCore

/// Pictures Benji draws from parts: smoothing that keeps corners, straight and closed
/// outlines, ovals, dashed groups, callouts, and a picture's reveal and hold.
final class PicturesTests: XCTestCase {
    private let pixel = CGSize(width: 1000, height: 500)
    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 500)
    private let style = PenStyle.of(.standard)

    private func t(_ shape: PointingShape, _ label: String) -> PointingTarget {
        PointingTarget(shape: shape, label: label)
    }

    private func pts(_ xy: [CGFloat]) -> [CGPoint] {
        stride(from: 0, to: xy.count - 1, by: 2).map { CGPoint(x: xy[$0], y: xy[$0 + 1]) }
    }

    /// Whether any two segments of the line cross, apart from neighbours sharing a point.
    private func selfIntersects(_ p: [CGPoint]) -> Bool {
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        let n = p.count - 1
        guard n > 2 else { return false }
        for i in 0..<n {
            for j in stride(from: i + 2, to: n, by: 1) {
                let a = p[i], b = p[i + 1], c = p[j], d = p[j + 1]
                let d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d)
                if ((d1 > 1e-9 && d2 < -1e-9) || (d1 < -1e-9 && d2 > 1e-9))
                    && ((d3 > 1e-9 && d4 < -1e-9) || (d3 < -1e-9 && d4 > 1e-9)) { return true }
            }
        }
        return false
    }

    private func distance(_ q: CGPoint, toPolyline p: [CGPoint]) -> CGFloat {
        zip(p, p.dropFirst()).map { a, b -> CGFloat in
            let dx = b.x - a.x, dy = b.y - a.y
            let l2 = dx * dx + dy * dy
            let f = l2 > 0 ? min(max(((q.x - a.x) * dx + (q.y - a.y) * dy) / l2, 0), 1) : 0
            return hypot(q.x - (a.x + f * dx), q.y - (a.y + f * dy))
        }.min() ?? .infinity
    }

    // MARK: smoothing keeps corners

    func testSharpCornersStaySharpWithoutLoops() {
        let cases: [(String, [CGPoint])] = [
            ("90°", pts([0, 0, 100, 0, 100, 100])),
            ("135°", pts([0, 0, 100, 0, 20, 80])),
            ("wing tip, about 160°", pts([0, 0, 120, 10, 0, 30])),
            ("zigzag", pts([0, 0, 40, 60, 80, 0, 120, 60, 160, 0])),
            ("a wing outline", pts([250, 290, 200, 370, 235, 370, 240, 300])),
        ]
        for (name, input) in cases {
            let out = PenGeometry.smooth(input)
            for corner in input {
                XCTAssertTrue(out.contains(corner), "\(name): passes through \(corner)")
            }
            XCTAssertLessThan(out.map { distance($0, toPolyline: input) }.max()!, 0.01,
                              "\(name): every turn here is a corner, so it stays on the straight segments")
            if !selfIntersects(input) {
                XCTAssertFalse(selfIntersects(out), "\(name): no loop added")
            }
        }
    }

    func testTheOldAirplaneGetsNoNewLoops() {
        // Smoothing every corner of a path like this one turns it into a scribble.
        let plane = pts([100, 280, 160, 262, 112, 192, 250, 262, 200, 372, 320, 292, 466, 282, 100, 300])
        let out = PenGeometry.smooth(plane)
        let at = plane.map { c in out.firstIndex(of: c)! }
        XCTAssertEqual(at, at.sorted(), "every point is on it, in order")
        for (a, b) in zip(at, at.dropFirst()) {
            XCTAssertFalse(selfIntersects(Array(out[a...b])), "no loop between \(out[a]) and \(out[b])")
        }
        XCTAssertLessThan(out.map { distance($0, toPolyline: plane) }.max()!, 8)
    }

    func testGentleBendsAreSmoothedWithoutLoops() {
        let smile = pts([206, 326, 246, 366, 290, 380, 334, 366, 374, 326])
        let out = PenGeometry.smooth(smile)
        for p in smile { XCTAssertTrue(out.contains(p), "every given point is on the curve") }
        XCTAssertFalse(selfIntersects(out))
        XCTAssertGreaterThan(out.map { distance($0, toPolyline: smile) }.max()!, 0.5, "it bends, not straight segments")
        XCTAssertLessThan(out.map { distance($0, toPolyline: smile) }.max()!, 8, "and stays close to its points")
        // Uneven spacing is where a plain Catmull–Rom loops; the centripetal one doesn't.
        let uneven = pts([0, 0, 200, 0, 204, 6, 206, 40])
        XCTAssertFalse(selfIntersects(PenGeometry.smooth(uneven)))
    }

    func testRepeatedPointsDontBreakSmoothing() {
        let out = PenGeometry.smooth(pts([0, 0, 0, 0, 50, 10, 50, 10, 100, 0]))
        XCTAssertEqual(out.first, CGPoint(x: 0, y: 0))
        XCTAssertEqual(out.last, CGPoint(x: 100, y: 0))
        XCTAssertFalse(out.contains { $0.x.isNaN || $0.y.isNaN })
    }

    // MARK: outlines, ovals, dashed groups

    func testPolylineKeepsCornersAndShapeCloses() {
        let tri = pts([100, 100, 200, 100, 150, 180])
        let open = PenGeometry.strokes(for: .polyline(points: tri, closed: false, label: ""), seed: 1, style: style)
        let closed = PenGeometry.strokes(for: .polyline(points: tri, closed: true, label: ""), seed: 1, style: style)
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(closed.count, 1)
        let c = closed[0]
        XCTAssertLessThan(hypot(c.points.first!.x - c.points.last!.x, c.points.first!.y - c.points.last!.y), 0.01,
                          "a shape ends where it started")
        for corner in tri {
            XCTAssertLessThan(c.points.map { hypot($0.x - corner.x, $0.y - corner.y) }.min()!, 1, "corner \(corner) kept")
        }
        XCTAssertEqual(c.length, 100 + 2 * hypot(50, 80), accuracy: 3)
        XCTAssertGreaterThanOrEqual(c.widths.min()!, style.width * 0.85 - 1e-9, "no thin gap where it closes")
    }

    func testOvalIsATrueEllipseThatCloses() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 80)
        let s = PenGeometry.strokes(for: .oval(rect: r, label: ""), seed: 7, style: style)
        XCTAssertEqual(s.count, 1)
        for p in s[0].points {
            let e = pow((p.x - r.midX) / (r.width / 2), 2) + pow((p.y - r.midY) / (r.height / 2), 2)
            XCTAssertEqual(sqrt(e), 1, accuracy: 0.02, "on the ellipse")
        }
        let angles = s[0].points.map { atan2(($0.y - r.midY) / 40, ($0.x - r.midX) / 100) }
        var swept: CGFloat = 0
        for (a, b) in zip(angles, angles.dropFirst()) {
            var d = b - a
            if d > .pi { d -= 2 * .pi }
            if d < -.pi { d += 2 * .pi }
            swept += d
        }
        XCTAssertGreaterThan(swept, 2 * .pi, "goes all the way round")
        XCTAssertLessThan(swept, 2 * .pi + 0.2, "and only a little past its start")
    }

    func testDashedGroupGoesRoundJustOutside() {
        let r = CGRect(x: 100, y: 100, width: 160, height: 400)
        let dashes = PenGeometry.strokes(for: .group(rect: r, label: ""), seed: 3, style: style)
        XCTAssertGreaterThan(dashes.count, 50)
        let outer = r.insetBy(dx: -PenGeometry.groupPad - 0.5, dy: -PenGeometry.groupPad - 0.5)
        for d in dashes {
            XCTAssertEqual(d.length, dashes[0].length, accuracy: 0.6, "even dashes")
            for p in d.points {
                XCTAssertTrue(outer.contains(p), "inside the padded box")
                XCTAssertFalse(r.insetBy(dx: 1, dy: 1).contains(p), "never over the region itself")
            }
        }
        XCTAssertEqual(Sketch.group(rect: r, label: "").bounds, r.insetBy(dx: -PenGeometry.groupPad, dy: -PenGeometry.groupPad))
    }

    // MARK: callouts

    func testCalloutSitsBesideItsTargetAndPointsAtIt() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let size = CGSize(width: 120, height: 30)
        let right = SketchLayout.calloutFrame(size: size, at: CGPoint(x: 300, y: 200), bounds: bounds)
        XCTAssertEqual(right, CGRect(x: 300 + SketchLayout.calloutGap, y: 185, width: 120, height: 30))
        let left = SketchLayout.calloutFrame(size: size, at: CGPoint(x: 950, y: 200), bounds: bounds)
        XCTAssertEqual(left.maxX, 950 - SketchLayout.calloutGap, "no room on the right: on the left")
        let (a, b) = PenGeometry.calloutPointer(from: right, to: CGPoint(x: 300, y: 200))!
        XCTAssertEqual(a.x, right.minX - 4, accuracy: 0.01)
        XCTAssertEqual(b.x, 302, accuracy: 0.01, "stops just short of the target")
        XCTAssertNil(PenGeometry.calloutPointer(from: right, to: CGPoint(x: right.minX - 5, y: 200)), "too close to point")
        XCTAssertEqual(PenGeometry.calloutStrokes(from: right, to: CGPoint(x: 300, y: 200), seed: 1, style: style).count, 3,
                       "a shaft and two barbs")
    }

    // MARK: a picture's reveal and hold

    private func run(_ seq: inout PointingSequence, until end: Double = 400) -> [(Double, PointingSequence.Action)] {
        var out: [(Double, PointingSequence.Action)] = []
        while let d = seq.deadline(), d < end {
            for a in seq.advance(to: d) { out.append((d, a)) }
        }
        return out
    }

    private func house(speaking: Bool) -> PointingPlan {
        PointingPlan(targets: [t(.shape([100, 200, 300, 200, 300, 400, 100, 400]), "walls"),
                               t(.shape([90, 205, 200, 100, 310, 205]), "roof"),
                               t(.oval(x1: 140, y1: 240, x2: 170, y2: 270), "window"),
                               t(.line([180, 400, 180, 330, 220, 330, 220, 400]), "door")],
                     text: "A small house.", speaking: speaking, pixelSize: pixel, screenFrame: frame, displayID: 1)!
    }

    func testAPictureIsDrawnPartAfterPartAndStaysUp() {
        let plan = house(speaking: false)
        XCTAssertTrue(plan.isDrawing)
        var seq = plan.sequence(reduceMotion: false, now: 0)
        XCTAssertTrue(seq.drawing)
        XCTAssertTrue(seq.accumulate)
        let actions = run(&seq)
        XCTAssertEqual(actions.map(\.1), [.reveal(0), .reveal(1), .reveal(2), .reveal(3), .erase(0), .erase(1), .erase(2), .erase(3)])
        for i in 1...3 {
            let previous = SketchTimeline.drawDuration(plan.items[i - 1].sketch!)
            XCTAssertEqual(actions[i].0 - actions[i - 1].0, previous + PointingSequence.penLift, accuracy: 1e-9,
                           "part \(i) starts as the pen finishes part \(i - 1)")
        }
        let lastRest = actions[3].0 + SketchTimeline.drawDuration(plan.items[3].sketch!)
        XCTAssertEqual(actions[4].0, lastRest + PointingSequence.drawingHold, accuracy: 1e-9, "up for two minutes")
    }

    func testAPictureOutlastsSpeech() {
        var seq = house(speaking: true).sequence(reduceMotion: false, now: 0)
        seq.speechDidStart(at: 0)
        seq.speechDidEnd(at: 1)
        let actions = run(&seq)
        XCTAssertEqual(actions.filter { if case .reveal = $0.1 { return true } else { return false } }.count, 4)
        XCTAssertGreaterThan(actions.first { if case .erase = $0.1 { return true } else { return false } }!.0, 100,
                             "speech ending doesn't take it down")
    }

    func testMarksOnThingsKeepTodaysTiming() {
        let plan = PointingPlan(targets: [t(.group(x1: 10, y1: 10, x2: 200, y2: 400), "Sidebar"),
                                          t(.callout(x: 205, y: 100), "Your folders")],
                                text: "Your folders are in the sidebar.", speaking: false, pixelSize: pixel, screenFrame: frame, displayID: 1)!
        XCTAssertTrue(plan.draws)
        XCTAssertFalse(plan.isDrawing)
        var seq = plan.sequence(reduceMotion: false, now: 0)
        XCTAssertFalse(seq.drawing)
        let actions = run(&seq)
        let rest = actions[1].0 + SketchTimeline.drawDuration(plan.items[1].sketch!)
        XCTAssertEqual(actions.last!.0, rest + MotionTiming.markLifetime, accuracy: 1e-9)
    }

    func testPartsDrawQuickerThanMarks() {
        let eye = Sketch.oval(rect: CGRect(x: 0, y: 0, width: 10, height: 10), label: "eye")
        XCTAssertEqual(SketchTimeline.drawDuration(eye), SketchTimeline.partShortest)
        let ring = Sketch.circle(rect: CGRect(x: 0, y: 0, width: 10, height: 10), label: "x")
        XCTAssertEqual(SketchTimeline.drawDuration(ring), SketchTimeline.shortest)
    }

    func testPictureAnnouncements() {
        XCTAssertEqual(PointingAnnouncement.text(for: .polyline(points: [.zero, CGPoint(x: 9, y: 9)], closed: true, label: "roof")),
                       "Drawing: roof.")
        XCTAssertEqual(PointingAnnouncement.text(for: .group(rect: .zero, label: "the sidebar")), "Marking the sidebar.")
        XCTAssertEqual(PointingAnnouncement.text(for: .callout(at: .zero, text: "Your folders")), "Label on screen: Your folders.")
    }
}
