import XCTest
@testable import BenjiCore

/// Marks that land on Benji's own picture add to it instead of replacing it: after three Urdu
/// lines written with TEXT, "highlight them" keeps the lines under the highlights.
final class DrawingMarkUpTests: XCTestCase {
    private func lines() -> DrawingParts {
        var d = DrawingParts()
        d.append([100.0, 140.0, 180.0].map { y in
            .sketch(.text(at: CGPoint(x: 100, y: y), text: "بارش کے بعد مٹی کی خوشبو", size: .medium))
        })
        return d
    }

    private func highlight(_ r: CGRect) -> OverlayItem { .sketch(.highlight(rect: r, label: "")) }

    func testHighlightsOnTheWrittenLinesKeepThem() {
        let d = lines()
        let marks = d.parts.map { highlight($0.item.bounds.insetBy(dx: -2, dy: -2)) }
        XCTAssertTrue(d.isMarkedUp(by: marks))
        XCTAssertTrue(d.isMarkedUp(by: [.mark(.ring(center: CGPoint(x: d.parts[1].item.bounds.midX, y: d.parts[1].item.bounds.midY), label: "middle"))]))
    }

    func testMarksElsewhereOrANewPictureStillReplaceIt() {
        let d = lines()
        let on = highlight(d.parts[0].item.bounds)
        XCTAssertFalse(d.isMarkedUp(by: [highlight(CGRect(x: 900, y: 600, width: 80, height: 20))]))   // elsewhere
        XCTAssertFalse(d.isMarkedUp(by: [on, highlight(CGRect(x: 900, y: 600, width: 80, height: 20))]))   // one elsewhere
        XCTAssertFalse(d.isMarkedUp(by: [on, .sketch(.text(at: CGPoint(x: 100, y: 220), text: "new", size: .small))]))   // draws
        XCTAssertFalse(d.isMarkedUp(by: []))
    }

    func testOnlyAPictureIsKept() {
        // Highlights on highlights are ordinary pointing: the new ones replace the old.
        var marksOnly = DrawingParts()
        marksOnly.append([highlight(CGRect(x: 100, y: 100, width: 300, height: 30))])
        XCTAssertFalse(marksOnly.isMarkedUp(by: [highlight(CGRect(x: 100, y: 100, width: 300, height: 30))]))
        // An erased picture is not up.
        var d = lines()
        for p in ["p1", "p2", "p3"] { _ = d.apply(DrawingEdit.parse(Substring("EDIT:\(p):erase"))!, pointsPerPixel: CGSize(width: 1, height: 1)) }
        XCTAssertFalse(d.isMarkedUp(by: [highlight(CGRect(x: 100, y: 100, width: 300, height: 30))]))
    }

    func testABoardOffsetCountsToo() {
        let d = lines()
        let moved = d.parts[0].item.bounds.offsetBy(dx: -400, dy: 0)   // where the model saw it before the board move
        XCTAssertFalse(d.isMarkedUp(by: [highlight(moved)]))
        XCTAssertTrue(d.isMarkedUp(by: [highlight(moved)], offset: CGVector(dx: 400, dy: 0)))
    }
}
