import XCTest
@testable import BenjiCore

/// The pointing protocol. selftest.py runs the same cases against benji/pointing.py.
final class PointingTests: XCTestCase {
    private func point(_ x: Int, _ y: Int, _ label: String = "") -> PointingTarget {
        PointingTarget(shape: .point(x: x, y: y), label: label)
    }
    private func box(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int, _ label: String = "") -> PointingTarget {
        PointingTarget(shape: .box(x1: x1, y1: y1, x2: x2, y2: y2), label: label)
    }

    // MARK: parsing

    func testBoxTag() {
        let r = PointingTags.parse("Type it in the search field. [BOX:100,40,500,80:Search field]")
        XCTAssertEqual(r.text, "Type it in the search field.")
        XCTAssertEqual(r.targets, [box(100, 40, 500, 80, "Search field")])
    }

    func testOrderedTargets() {
        let r = PointingTags.parse("Tick Sync files, then Include photos.\n[POINT:412,300:Sync files] [BOX:400,330,700,350:Include photos]")
        XCTAssertEqual(r.text, "Tick Sync files, then Include photos.")
        XCTAssertEqual(r.targets, [point(412, 300, "Sync files"), box(400, 330, 700, 350, "Include photos")])
    }

    func testAtMostThreeTargetsAndAllTagsStripped() {
        let r = PointingTags.parse("Steps. [POINT:1,1:a][POINT:2,2:b] [POINT:3,3:c] [POINT:4,4:d]")
        XCTAssertEqual(r.text, "Steps.")
        XCTAssertEqual(r.targets, [point(1, 1, "a"), point(2, 2, "b"), point(3, 3, "c")])
    }

    func testLenientForms() {
        XCTAssertEqual(PointingTags.parse("x [box: 1, 2, 3, 4 : Field ]").targets, [box(1, 2, 3, 4, "Field")])
        XCTAssertEqual(PointingTags.parse("x [POINT:10.5,20.4:a]").targets, [point(11, 20, "a")])
        XCTAssertEqual(PointingTags.parse("x [POINT:1,2:Settings: General]").targets, [point(1, 2, "Settings: General")])
        XCTAssertEqual(PointingTags.parse("x [BOX:1,2,3,4]").targets, [box(1, 2, 3, 4)])
    }

    func testMalformedTagsLeaveTextAlone() {
        for text in ["Here. [BOX:1,2,3:x]", "Here. [POINT:a,b:x]", "Here. [POINT:1,2,3:x]",
                     "Here. [ARROW:1,2:x]", "Here. [POINT:1e3,2:x]", "Here. [POINT:,2:x]",
                     "[POINT:1,2:x] then more text", "No tags at all."] {
            let r = PointingTags.parse(text)
            XCTAssertEqual(r.text, text, text)
            XCTAssertEqual(r.targets, [], text)
        }
    }

    func testOnlyTheTrailingRunCounts() {
        let r = PointingTags.parse("See [Help]. [POINT:x:y] [POINT:5,6:Help]")
        XCTAssertEqual(r.text, "See [Help]. [POINT:x:y]")
        XCTAssertEqual(r.targets, [point(5, 6, "Help")])
    }

    func testLegacyParseTakesFirstTargetAndBoxCentre() {
        XCTAssertEqual(PointingTag.parse("x [BOX:100,40,500,80:Field] [POINT:1,2:b]").target,
                       PointTarget(x: 300, y: 60, label: "Field"))
    }

    // MARK: marks

    // A 1512 × 982 pt display sent at 1:1, so pixels equal points (y flipped).
    private let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let oneToOne = CGSize(width: 1512, height: 982)

    private func mark(_ t: PointingTarget, _ size: CGSize? = nil) -> PointingMark? {
        PointMapping.mark(for: t, pixelSize: size ?? oneToOne, screenFrame: frame)
    }

    func testPointGetsRing() {
        XCTAssertEqual(mark(point(100, 100, "a")), .ring(center: CGPoint(x: 100, y: 882), label: "a"))
    }

    func testSmallBoxGetsRingAtCentre() {
        XCTAssertEqual(mark(box(100, 100, 140, 130)), .ring(center: CGPoint(x: 120, y: 867), label: ""))
        XCTAssertEqual(mark(box(100, 100, 144, 144)), .ring(center: CGPoint(x: 122, y: 860), label: ""),
                       "exactly 44 × 44 is still a ring")
    }

    func testSizeRuleUsesPointsNotPixels() {
        // Sent at 2× (Retina, no downscale): an 88 px box is 44 pt.
        let retina = CGSize(width: 3024, height: 1964)
        XCTAssertEqual(mark(box(200, 200, 288, 288), retina), .ring(center: CGPoint(x: 122, y: 860), label: ""))
        XCTAssertEqual(mark(box(200, 200, 290, 288), retina),
                       .region(rect: CGRect(x: 100, y: 838, width: 45, height: 44), label: ""))
    }

    func testMediumBoxGetsRegion() {
        let region = PointingMark.region(rect: CGRect(x: 100, y: 842, width: 200, height: 40), label: "Field")
        XCTAssertEqual(mark(box(100, 100, 300, 140, "Field")), region)
        XCTAssertEqual(mark(box(300, 140, 100, 100, "Field")), region, "corners in either order")
    }

    func testHugeBoxGetsNoMark() {
        XCTAssertNil(mark(box(0, 0, 1000, 600)), "more than a third of the display's area")
        XCTAssertNil(mark(box(0, 100, 1300, 200)), "wider than 80% of the display")
        XCTAssertNil(mark(box(100, 0, 200, 900)), "taller than 80% of the display")
        XCTAssertNotNil(mark(box(0, 0, 800, 600)), "just under a third")
    }

    func testOutsideTheImageIsRejected() {
        XCTAssertNil(mark(point(-1, 5)))
        XCTAssertNil(mark(point(1513, 5)))
        XCTAssertNil(mark(box(100, 100, 1600, 200)), "one corner outside")
    }

    func testMarksKeepOrderAndSkipRejected() {
        let marks = PointMapping.marks(for: [point(9999, 1), point(10, 10, "b"), box(100, 100, 300, 140, "c")],
                                       pixelSize: oneToOne, screenFrame: frame)
        XCTAssertEqual(marks.count, 2)
        XCTAssertEqual(marks.first, .ring(center: CGPoint(x: 10, y: 972), label: "b"))
    }

    // MARK: drawing (the same cases run in selftest.py)

    private func t(_ shape: PointingShape, _ label: String = "") -> PointingTarget {
        PointingTarget(shape: shape, label: label)
    }

    func testDrawingTagsParse() {
        let r = PointingTags.parse("Look here. [CIRCLE:100,40,500,80:Search field] [ARROW:10,10,90,90:Save] [NOTE:200,200:Click: here]")
        XCTAssertEqual(r.text, "Look here.")
        XCTAssertEqual(r.targets, [t(.circle(x1: 100, y1: 40, x2: 500, y2: 80), "Search field"),
                                   t(.arrow(x1: 10, y1: 10, x2: 90, y2: 90), "Save"),
                                   t(.note(x: 200, y: 200), "Click: here")])
        XCTAssertEqual(PointingTags.parse("x [UNDERLINE:1,2,3,4:u] [HIGHLIGHT:5,6,7,8:h]").targets,
                       [t(.underline(x1: 1, y1: 2, x2: 3, y2: 4), "u"), t(.highlight(x1: 5, y1: 6, x2: 7, y2: 8), "h")])
        XCTAssertEqual(PointingTags.parse("x [PATH:1,2,3,4,5,6:wave]").targets, [t(.path([1, 2, 3, 4, 5, 6]), "wave")])
        XCTAssertEqual(PointingTags.parse("x [path: 1, 2 , 3,4]").targets, [t(.path([1, 2, 3, 4]))])
    }

    func testAtMostSixMarksAndThreePointers() {
        let r = PointingTags.parse("Do it. [POINT:1,1:a] [CIRCLE:1,1,9,9:b] [POINT:2,2:c] [POINT:3,3:d] [POINT:4,4:e] "
                                   + "[ARROW:1,1,50,50:f] [UNDERLINE:1,1,40,1:g] [HIGHLIGHT:1,1,40,20:h]")
        XCTAssertEqual(r.text, "Do it.")
        XCTAssertEqual(r.targets.map(\.label), ["a", "b", "c", "d", "f", "g"])
    }

    func testMalformedDrawingTagsLeaveTextAlone() {
        for text in ["Here. [PATH:1,2,3:x]", "Here. [PATH:1,2:x]", "Here. [NOTE:1,2,3:x]",
                     "Here. [CIRCLE:1,2,3:x]", "Here. [SCRIBBLE:1,2,3,4:x]", "Here. [HIGHLIGHT:1,2,3,4,5,6:x]"] {
            let r = PointingTags.parse(text)
            XCTAssertEqual(r.text, text, text)
            XCTAssertEqual(r.targets, [], text)
        }
    }

    private func item(_ target: PointingTarget, _ size: CGSize? = nil) -> OverlayItem? {
        PointMapping.item(for: target, pixelSize: size ?? oneToOne, screenFrame: frame)
    }

    /// Top-left display points (as benji/pointing.py gives them) to AppKit's flipped frame.
    private func tl(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: 982 - y - h, width: w, height: h)
    }
    private func tl(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: 982 - y) }

    func testCircleAndHighlightMapping() {
        XCTAssertEqual(item(t(.circle(x1: 100, y1: 100, x2: 300, y2: 140), "c")), .sketch(.circle(rect: tl(100, 100, 200, 40), label: "c")))
        XCTAssertEqual(item(t(.circle(x1: 100, y1: 100, x2: 110, y2: 104))), .sketch(.circle(rect: tl(93, 90, 24, 24), label: "")),
                       "a small loop grows to 24 pt around its centre")
        XCTAssertEqual(item(t(.circle(x1: 200, y1: 200, x2: 600, y2: 280)), CGSize(width: 3024, height: 1964)),
                       .sketch(.circle(rect: tl(100, 100, 200, 40), label: "")), "points, not pixels")
        XCTAssertNil(item(t(.circle(x1: 0, y1: 0, x2: 1000, y2: 600))), "more than a third of the display")
        XCTAssertNil(item(t(.highlight(x1: 100, y1: 100, x2: 300, y2: 104))), "thinner than 6 pt")
        XCTAssertEqual(item(t(.highlight(x1: 300, y1: 110, x2: 100, y2: 100), "h")), .sketch(.highlight(rect: tl(100, 100, 200, 10), label: "h")))
    }

    func testLineMapping() {
        XCTAssertNil(item(t(.arrow(x1: 10, y1: 10, x2: 20, y2: 20))), "arrow shorter than 24 pt")
        XCTAssertEqual(item(t(.arrow(x1: 100, y1: 100, x2: 400, y2: 500), "a")), .sketch(.arrow(from: tl(100, 100), to: tl(400, 500), label: "a")))
        XCTAssertNil(item(t(.arrow(x1: 0, y1: 0, x2: 1300, y2: 0))), "longer than 80% of the long side")
        XCTAssertNil(item(t(.arrow(x1: 100, y1: 100, x2: 1600, y2: 100))), "tip outside the image")
        XCTAssertNil(item(t(.underline(x1: 100, y1: 200, x2: 105, y2: 200))), "underline shorter than 8 pt")
        XCTAssertEqual(item(t(.underline(x1: 100, y1: 200, x2: 300, y2: 202))), .sketch(.underline(from: tl(100, 200), to: tl(300, 202), label: "")))
    }

    func testPathAndNoteMapping() {
        XCTAssertEqual(item(t(.path([100, 100, 150, 120, 200, 100]), "p")),
                       .sketch(.path(points: [tl(100, 100), tl(150, 120), tl(200, 100)], label: "p")))
        XCTAssertNil(item(t(.path(Array(repeating: [10, 10, 60, 60], count: 20).flatMap { $0 } + [10, 10]))), "41 points")
        XCTAssertNotNil(item(t(.path(Array(repeating: [10, 10, 60, 60], count: 20).flatMap { $0 }))), "40 points")
        XCTAssertNil(item(t(.path([0, 0, 1400, 900, 0, 900]))), "spans more than 80% of the width")
        XCTAssertNil(item(t(.path([100, 100, 103, 103]))), "shorter than 8 pt")
        XCTAssertEqual(item(t(.note(x: 50, y: 60), "Click here")), .sketch(.note(at: tl(50, 60), text: "Click here")))
        XCTAssertNil(item(t(.note(x: 50, y: 60), String(repeating: "a", count: 41))), "over 40 characters")
        XCTAssertNil(item(t(.note(x: 50, y: 60), "")), "no text")
        XCTAssertNotNil(item(t(.note(x: 50, y: 60), String(repeating: "é", count: 40))), "40 scalars")
    }

    // MARK: pictures (the same cases run in selftest.py)

    func testPictureTagsParse() {
        let r = PointingTags.parse("A house. [SHAPE:10,50,90,50,50,10:roof] [LINE:20,90,20,60,40,60,40,90:door] "
                                   + "[OVAL:60,60,70,70:knob] [GROUP:5,5,95,95:house] [CALLOUT:100,50:Front door]")
        XCTAssertEqual(r.text, "A house.")
        XCTAssertEqual(r.targets, [t(.shape([10, 50, 90, 50, 50, 10]), "roof"), t(.line([20, 90, 20, 60, 40, 60, 40, 90]), "door"),
                                   t(.oval(x1: 60, y1: 60, x2: 70, y2: 70), "knob"), t(.group(x1: 5, y1: 5, x2: 95, y2: 95), "house"),
                                   t(.callout(x: 100, y: 50), "Front door")])
        XCTAssertEqual(PointingTags.parse("x [line: 1, 2, 3, 4]").targets, [t(.line([1, 2, 3, 4]))])
        for text in ["Here. [SHAPE:1,2,3,4:x]", "Here. [LINE:1,2:x]", "Here. [LINE:1,2,3:x]", "Here. [OVAL:1,2:x]",
                     "Here. [GROUP:1,2,3,4,5,6:x]", "Here. [CALLOUT:1,2,3,4:x]"] {
            XCTAssertEqual(PointingTags.parse(text).text, text, text)
        }
    }

    func testAPictureMayUseTwentyTagsButStillThreePointers() {
        let parts = (1...24).map { "[OVAL:\($0),1,\($0 + 9),9:p\($0)]" }.joined(separator: " ")
        XCTAssertEqual(PointingTags.parse("Dots. " + parts).targets.count, 20)
        let mixed = PointingTags.parse("Look. [POINT:1,1:a] [POINT:2,2:b] [POINT:3,3:c] [POINT:4,4:d] [CIRCLE:1,1,9,9:e] "
                                       + "[ARROW:1,1,50,50:f] [NOTE:5,5:g] [LINE:1,1,40,1:h]")
        XCTAssertEqual(mixed.targets.map(\.label), ["a", "b", "c", "e", "f", "g", "h"], "no sixth-tag cap, still three pointers")
        let sketchy = PointingTags.parse("Look. " + (1...8).map { "[CIRCLE:\($0),1,\($0 + 9),9:c\($0)]" }.joined(separator: " "))
        XCTAssertEqual(sketchy.targets.count, 6, "marks on things without a picture keep the cap of six")
    }

    func testPictureMapping() {
        XCTAssertEqual(item(t(.line([100, 100, 150, 120, 200, 100]), "l")),
                       .sketch(.polyline(points: [tl(100, 100), tl(150, 120), tl(200, 100)], closed: false, label: "l")))
        XCTAssertEqual(item(t(.shape([100, 100, 200, 100, 150, 180]), "s")),
                       .sketch(.polyline(points: [tl(100, 100), tl(200, 100), tl(150, 180)], closed: true, label: "s")))
        XCTAssertNil(item(t(.shape([100, 100, 102, 100, 101, 102]))), "closed outline shorter than 8 pt")
        XCTAssertNil(item(t(.shape([0, 0, 1400, 0, 700, 900]))), "spans most of the display")
        XCTAssertEqual(item(t(.oval(x1: 300, y1: 140, x2: 100, y2: 100), "o")), .sketch(.oval(rect: tl(100, 100, 200, 40), label: "o")))
        XCTAssertEqual(item(t(.oval(x1: 100, y1: 100, x2: 102, y2: 140))), .sketch(.oval(rect: tl(98, 100, 6, 40), label: "")),
                       "a thin oval grows to 6 pt around its centre")
        XCTAssertNil(item(t(.oval(x1: 0, y1: 0, x2: 1000, y2: 600))))
        XCTAssertEqual(item(t(.group(x1: 10, y1: 40, x2: 300, y2: 960), "Sidebar")), .sketch(.group(rect: tl(10, 40, 290, 920), label: "Sidebar")),
                       "a full-height sidebar is fine")
        XCTAssertNil(item(t(.group(x1: 0, y1: 0, x2: 1000, y2: 800))), "over half the display")
        XCTAssertNil(item(t(.group(x1: 10, y1: 10, x2: 300, y2: 20))), "thinner than 12 pt")
        XCTAssertEqual(item(t(.callout(x: 50, y: 60), "Your folders")), .sketch(.callout(at: tl(50, 60), text: "Your folders")))
        XCTAssertNil(item(t(.callout(x: 50, y: 60), String(repeating: "a", count: 41))))
        XCTAssertNil(item(t(.callout(x: 50, y: 60), "")))
    }

    func testItemsKeepOrderAndSkipDropped() {
        let items = PointMapping.items(for: [t(.arrow(x1: 10, y1: 10, x2: 20, y2: 20)), t(.circle(x1: 100, y1: 100, x2: 300, y2: 140), "c"),
                                             point(10, 10, "b")], pixelSize: oneToOne, screenFrame: frame)
        XCTAssertEqual(items.map(\.label), ["c", "b"])
        XCTAssertEqual(items.last, .mark(.ring(center: tl(10, 10), label: "b")))
        XCTAssertEqual(PointMapping.marks(for: [t(.circle(x1: 100, y1: 100, x2: 300, y2: 140)), point(10, 10)],
                                          pixelSize: oneToOne, screenFrame: frame).count, 1, "marks are pointers only")
    }
}
