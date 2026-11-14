import XCTest
@testable import BenjiCore

/// Overlay.md: keep-out, label placement order and sliding, and the estimated reveal times.
final class OverlayLayoutTests: XCTestCase {
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)   // below the menu bar
    let label = CGSize(width: 100, height: 22)

    func testKeepOutIsTheHaloEdge() {
        XCTAssertEqual(OverlayLayout.keepOut(for: .ring(center: CGPoint(x: 100, y: 100), label: "")),
                       CGRect(x: 80, y: 80, width: 40, height: 40))
        XCTAssertEqual(OverlayLayout.keepOut(for: .region(rect: CGRect(x: 10, y: 20, width: 100, height: 50), label: "")),
                       CGRect(x: -3, y: 7, width: 126, height: 76))
    }

    func testLabelGoesBelowCentredWhenItFits() {
        let mark = PointingMark.ring(center: CGPoint(x: 700, y: 500), label: "Save")
        XCTAssertEqual(OverlayLayout.labelFrame(size: label, for: mark, visibleFrame: visible),
                       CGRect(x: 650, y: 500 - 20 - 8 - 22, width: 100, height: 22))
    }

    func testNearTheBottomTheLabelGoesAbove() {
        let mark = PointingMark.ring(center: CGPoint(x: 700, y: 40), label: "Dock icon")
        XCTAssertEqual(OverlayLayout.labelFrame(size: label, for: mark, visibleFrame: visible)?.minY, 40 + 20 + 8)
    }

    func testNearALeftEdgeTheLabelSlidesButStillSpansTheCentre() {
        let mark = PointingMark.ring(center: CGPoint(x: 40, y: 500), label: "x")
        let r = OverlayLayout.labelFrame(size: label, for: mark, visibleFrame: visible)
        XCTAssertEqual(r?.minX, 12)
        XCTAssertEqual(r?.maxY, 500 - 28)
    }

    func testTooFarIntoACornerToSpanTheCentreFallsToTheSide() {
        // The centre is inside the 12 pt inset, so below/above can't span it; trailing can.
        let mark = PointingMark.ring(center: CGPoint(x: 6, y: 500), label: "x")
        let r = OverlayLayout.labelFrame(size: label, for: mark, visibleFrame: visible)
        XCTAssertEqual(r, CGRect(x: 6 + 20 + 8, y: 489, width: 100, height: 22))
    }

    func testAPanelInTheWayPushesTheLabelToTheNextSide() {
        let mark = PointingMark.ring(center: CGPoint(x: 700, y: 500), label: "x")
        let panel = CGRect(x: 600, y: 420, width: 200, height: 40)   // just below the mark
        XCTAssertEqual(OverlayLayout.labelFrame(size: label, for: mark, visibleFrame: visible, avoid: [panel])?.minY, 528)
    }

    func testNoSideFitsMeansNoLabel() {
        let tiny = CGRect(x: 0, y: 0, width: 80, height: 80)
        XCTAssertNil(OverlayLayout.labelFrame(size: label, for: .ring(center: CGPoint(x: 40, y: 40), label: "x"),
                                              visibleFrame: tiny))
    }

    func testLabelNeverCoversARegion() {
        let mark = PointingMark.region(rect: CGRect(x: 300, y: 300, width: 400, height: 200), label: "Form")
        let r = OverlayLayout.labelFrame(size: label, for: mark, visibleFrame: visible)!
        XCTAssertFalse(r.intersects(OverlayLayout.keepOut(for: mark)))
        XCTAssertEqual(r.maxY, 300 - 13 - 8)
    }

    func testWideLabelsAreCappedAt240() {
        let r = OverlayLayout.labelFrame(size: CGSize(width: 500, height: 22),
                                         for: .ring(center: CGPoint(x: 700, y: 500), label: "x"), visibleFrame: visible)
        XCTAssertEqual(r?.width, 240)
    }

    // MARK: reveal timing

    func testSyllables() {
        XCTAssertEqual(RevealTiming.syllables("Save"), 1)
        XCTAssertEqual(RevealTiming.syllables("invoice"), 2)
        XCTAssertEqual(RevealTiming.syllables("customer"), 3)
        XCTAssertEqual(RevealTiming.syllables("the"), 1)
        XCTAssertEqual(RevealTiming.syllables("42"), 0)
    }

    func testAnchorsAtTheLabelsFirstWord() {
        // "Fill in the" = 3 syllables -> 0.667 s; then "Customer name field, then click" ...
        let text = "Fill in the Customer name field, then click Save invoice."
        let t = RevealTiming.anchors(labels: ["Customer name", "Save invoice"], in: text)
        XCTAssertEqual(t[0], 3 / 4.5, accuracy: 0.001)
        // + customer 3, name 1, field 1, comma 1, then 1, click 1 = 11 syllables
        XCTAssertEqual(t[1], 11 / 4.5, accuracy: 0.001)
    }

    func testMissingLabelUsesTheFirstSentenceEndThenAMinimumStep() {
        let t = RevealTiming.anchors(labels: ["Gear", "Wheel"], in: "Open settings. Then look around.")
        XCTAssertEqual(t[0], (4 + 2) / 4.5, accuracy: 0.001)   // open 2, settings 2, sentence end 2
        XCTAssertEqual(t[1], t[0] + RevealTiming.minimumStep, accuracy: 0.001)
    }

    func testAnchorsAreOrderedAndSpaced() {
        // The second label's word comes earlier in the text than the first's: still in order.
        let t = RevealTiming.anchors(labels: ["Save", "Share"], in: "Share it, or Save it.")
        XCTAssertEqual(t.count, 2)
        XCTAssertGreaterThanOrEqual(t[1] - t[0], RevealTiming.minimumStep - 0.0001)
        XCTAssertEqual(RevealTiming.anchors(labels: ["x"], in: "x").first, 0)
    }
}
