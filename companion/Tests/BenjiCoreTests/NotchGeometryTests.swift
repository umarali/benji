import XCTest
@testable import BenjiCore

final class NotchGeometryTests: XCTestCase {
    // A 1512 × 982 pt notch laptop at the origin; a 185 × 32 notch centred at the top.
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let notch = CGRect(x: 663.5, y: 950, width: 185, height: 32)
    // An external display to the right, no notch.
    let external = CGRect(x: 1512, y: 0, width: 1920, height: 1080)

    func testClosedIsTheHardwareNotch() {
        let s = PanelGeometry.notchShape(.closed, notch: notch, screenFrame: laptop)
        XCTAssertEqual(s.frame, notch)
        XCTAssertEqual(s.bottomRadius, 10)
        XCTAssertEqual(s.shoulderRadius, 6)
        XCTAssertEqual(s.opacity, 1)
        XCTAssertEqual(s.shadowOpacity, 0)
    }

    func testScreenOnWidensTheClosedNotchOnly() {
        let on = PanelGeometry.notchShape(.closed, notch: notch, screenFrame: laptop, indicator: true)
        XCTAssertEqual(on.frame, notch.insetBy(dx: -PanelGeometry.indicatorWing, dy: 0))
        XCTAssertEqual(on.opacity, 1)
        let bare = PanelGeometry.notchShape(.closed, notch: nil, screenFrame: external, indicator: true)
        XCTAssertEqual(bare.opacity, 1, "visible even without a hardware notch, so the dot always shows")
        XCTAssertEqual(bare.frame.width, PanelGeometry.closedSize.width + 2 * PanelGeometry.indicatorWing)
        for size in [NotchSize.peek, .open] {
            XCTAssertEqual(PanelGeometry.notchShape(size, notch: notch, screenFrame: laptop, indicator: true),
                           PanelGeometry.notchShape(size, notch: notch, screenFrame: laptop))
        }
    }

    func testPeekAndOpenGrowFromTheNotch() {
        let peek = PanelGeometry.notchShape(.peek, notch: notch, screenFrame: laptop)
        XCTAssertEqual(peek.frame, CGRect(x: 576, y: 922, width: 360, height: 60))
        XCTAssertEqual(peek.bottomRadius, 18)
        XCTAssertEqual(peek.shadowOpacity, 0, "peek never has a shadow")
        XCTAssertEqual((peek.frame.width - notch.width) / 2, 87.5, "wing width from Motion.md")

        let open = PanelGeometry.notchShape(.open, notch: notch, screenFrame: laptop)
        XCTAssertEqual(open.frame, CGRect(x: 526, y: 602, width: 460, height: 380))
        XCTAssertEqual(open.bottomRadius, 26)
        XCTAssertEqual(open.shoulderRadius, 12)
        XCTAssertEqual(open.shadowOpacity, 1)
        XCTAssertEqual(open.outerFrame, CGRect(x: 514, y: 602, width: 484, height: 380))
        for s in [peek, open] {
            XCTAssertEqual(s.frame.maxY, laptop.maxY, "flush with the top")
            XCTAssertEqual(s.frame.midX, notch.midX, "centred on the notch")
        }
    }

    func testOffCentreNotchAndReportedTopAreSnapped() {
        // A notch reported 1 pt low and off centre: the closed shape still sits flush at the top,
        // and the bigger sizes centre on the notch, not the display.
        let odd = CGRect(x: 700, y: 949, width: 200, height: 32)
        let closed = PanelGeometry.notchShape(.closed, notch: odd, screenFrame: laptop)
        XCTAssertEqual(closed.frame, CGRect(x: 700, y: 950, width: 200, height: 32))
        XCTAssertEqual(PanelGeometry.notchShape(.peek, notch: odd, screenFrame: laptop).frame.midX, 800)
    }

    func testNeverNarrowerThanTheNotchOrWiderThanTheDisplay() {
        let wide = CGRect(x: 500, y: 950, width: 400, height: 32)
        XCTAssertEqual(PanelGeometry.notchShape(.peek, notch: wide, screenFrame: laptop).frame.width, 400)
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 200)
        let open = PanelGeometry.notchShape(.open, notch: nil, screenFrame: tiny)
        XCTAssertEqual(open.frame.size, CGSize(width: 300, height: 200))
    }

    func testDisplayWithoutNotch() {
        let closed = PanelGeometry.notchShape(.closed, notch: nil, screenFrame: external)
        XCTAssertEqual(closed.frame, CGRect(x: 2379.5, y: 1048, width: 185, height: 32))
        XCTAssertEqual(closed.opacity, 0, "closed is invisible without a hardware notch")
        let peek = PanelGeometry.notchShape(.peek, notch: nil, screenFrame: external)
        XCTAssertEqual(peek.frame, CGRect(x: 2292, y: 1020, width: 360, height: 60))
        XCTAssertEqual(peek.opacity, 1)
    }

    func testHotZoneIsNotchPlusEight() {
        let zone = PanelGeometry.hotZone(notch: notch, screenFrame: laptop)
        XCTAssertEqual(zone, CGRect(x: 655.5, y: 942, width: 201, height: 48))
        XCTAssertTrue(zone.contains(CGPoint(x: notch.midX, y: laptop.maxY)), "a pointer pinned to the top counts")
        XCTAssertTrue(zone.contains(CGPoint(x: notch.minX - 7, y: 960)))
        XCTAssertFalse(zone.contains(CGPoint(x: notch.minX - 9, y: 960)))
        XCTAssertFalse(zone.contains(CGPoint(x: notch.midX, y: 941)))
    }

    func testInterpolationIsOneShape() {
        let closed = PanelGeometry.notchShape(.closed, notch: notch, screenFrame: laptop)
        let open = PanelGeometry.notchShape(.open, notch: notch, screenFrame: laptop)
        XCTAssertEqual(closed.interpolated(to: open, 0), closed)
        XCTAssertEqual(closed.interpolated(to: open, 1), open)
        let mid = closed.interpolated(to: open, 0.5)
        XCTAssertEqual(mid.frame.maxY, laptop.maxY, "the top edge never moves")
        XCTAssertEqual(mid.frame.midX, notch.midX)
        XCTAssertEqual(mid.frame.size, CGSize(width: 322.5, height: 206))
        XCTAssertEqual(mid.bottomRadius, 18)
        XCTAssertEqual(mid.shadowOpacity, (206 - 60) / 320, accuracy: 1e-9)
    }
}

final class MotionTokensTests: XCTestCase {
    func testSpringConstantsMatchTheTable() {
        // Motion.md: (k, c) per token.
        let table: [(SpringToken, Double, Double)] = [
            (MotionTokens.peek, 438.6, 41.89), (MotionTokens.open, 157.9, 25.13),
            (MotionTokens.content, 685.4, 52.36), (MotionTokens.follow, 322.3, 35.90),
        ]
        for (token, k, c) in table {
            XCTAssertEqual(token.stiffness, k, accuracy: 0.1)
            XCTAssertEqual(token.damping, c, accuracy: 0.01)
            XCTAssertEqual(token.dampingRatio, 1, "only motion-done may bounce")
        }
    }

    func testSettleTimes() {
        // Settled = within 0.5%; Motion.md lists ≈ 355, 590, 285 and 415 ms.
        for (token, ms) in [(MotionTokens.peek, 355.0), (MotionTokens.open, 590), (MotionTokens.content, 285), (MotionTokens.follow, 415)] {
            XCTAssertEqual(token.settleTime * 1000, ms, accuracy: 5)
            XCTAssertGreaterThanOrEqual(token.stepResponse(at: token.settleTime), 0.995)
            XCTAssertLessThan(token.stepResponse(at: token.settleTime - 0.01), 0.995)
        }
    }

    func testContentFadesInAtSixtyFivePercent() {
        XCTAssertEqual(MotionTokens.peek.contentFadeInDelay * 1000, 106, accuracy: 1)
        XCTAssertEqual(MotionTokens.open.contentFadeInDelay * 1000, 177, accuracy: 1)
        let p = MotionTokens.peek
        XCTAssertEqual(p.stepResponse(at: p.contentFadeInDelay), 0.65, accuracy: 0.005)
    }

    func testDoneIsOneNodOfFourteenPercent() {
        let d = MotionTokens.done
        XCTAssertEqual(d.dampingRatio, 0.7, accuracy: 1e-12)
        let samples = stride(from: 0.0, through: 0.6, by: 0.001).map {
            ($0, d.impulseResponse(at: $0, velocity: MotionTokens.doneStartVelocity))
        }
        let peak = samples.max { $0.1 < $1.1 }!
        XCTAssertEqual(peak.0, 0.080, accuracy: 0.002)
        XCTAssertEqual(peak.1, 0.14, accuracy: 0.002)
        let undershoot = samples.map(\.1).min()!
        XCTAssertGreaterThan(undershoot, -0.01, "undershoot under 1%")
        // "At rest by ≈ 450 ms": 0.51% of its size off there, invisible at 13 pt.
        XCTAssertLessThan(abs(d.impulseResponse(at: 0.45, velocity: MotionTokens.doneStartVelocity)), 0.006,
                          "at rest by about 450 ms")
    }

    func testFollowPeakSpeedForTheLongestGlide() {
        // Peak speed of a critically damped hop is D × ω / e: about 1,450 pt/s for 220 pt.
        let w = 2 * Double.pi / MotionTokens.follow.duration
        XCTAssertEqual(MotionTiming.followMaxHop * w / M_E, 1450, accuracy: 15)
    }

    func testMorphTokenLargestSizeWins() {
        XCTAssertEqual(MotionTokens.morph(from: .closed, to: .peek), MotionTokens.peek)
        XCTAssertEqual(MotionTokens.morph(from: .peek, to: .closed), MotionTokens.peek)
        XCTAssertEqual(MotionTokens.morph(from: .peek, to: .open), MotionTokens.open)
        XCTAssertEqual(MotionTokens.morph(from: .open, to: .closed), MotionTokens.open)
    }

    func testTimingConstants() {
        XCTAssertLessThanOrEqual(MotionTokens.fadeDuration, MotionTokens.peek.duration / 2, "fades finish inside the shortest morph")
        XCTAssertEqual(MotionTiming.doneHold(words: 0), 1.5)
        XCTAssertEqual(MotionTiming.doneHold(words: 6), 2.0)
        XCTAssertEqual(MotionTiming.doneHold(words: 40), 4.0)
        XCTAssertEqual(1 / (MotionTiming.shimmerSweep + MotionTiming.shimmerRest), 0.5, "0.5 Hz, far below 3 Hz")
        XCTAssertEqual(MotionTiming.hoverRest, 0.1)
        XCTAssertEqual(MotionTiming.closeGrace, 0.7)
    }
}
