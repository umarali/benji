import XCTest
@testable import BenjiCore

/// Explanation cards: the card block, its layout from a measured style, where the card
/// goes on a busy or calm screen, and the reveal.
final class ExplainCardTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static func reply(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent("tools/card-render/replies/\(name).txt"), encoding: .utf8)
    }

    /// Half the font size per character, words wrapped at the width: close enough to a real font
    /// to test the layout without AppKit.
    struct FixedMeasure: ExplainTextMeasuring {
        func lineHeight(_ style: ExplainTextStyle) -> CGFloat { (style.size * 1.25).rounded() }
        func size(_ text: String, _ style: ExplainTextStyle, width: CGFloat) -> CGSize {
            let advance = style.size * 0.5
            var lines = 1, line: CGFloat = 0, widest: CGFloat = 0
            for word in text.split(separator: " ") {
                let w = CGFloat(word.count) * advance
                let next = line == 0 ? w : line + advance + w
                if next > width && line > 0 { widest = max(widest, line); lines += 1; line = w } else { line = next }
            }
            widest = max(widest, line)
            return CGSize(width: min(widest, width), height: CGFloat(lines) * lineHeight(style))
        }
    }

    func card(_ json: String) -> ExplainCard? { ExplainCardGrammar.card(json: json) }

    // MARK: the block

    func testThreeStatesBlockParses() throws {
        let (text, card) = ExplainCardGrammar.parse(try Self.reply("states"))
        XCTAssertEqual(text, "Benji is always in exactly one of three states: it listens, it thinks, then it speaks.")
        let c = try XCTUnwrap(card)
        XCTAssertEqual(c.title, "Benji's three states")
        XCTAssertEqual(c.heading, "One state at a time")
        XCTAssertEqual(c.layout, .flow)
        XCTAssertEqual(c.items.map(\.label), ["Listening", "Thinking", "Speaking"])
        XCTAssertEqual(c.items.map(\.icon), ["ear", "sparkles", "waveform"])
        XCTAssertEqual(c.chips.count, 3)
    }

    func testCompareAndStepsBlocksParse() throws {
        let compare = try XCTUnwrap(ExplainCardGrammar.parse(try Self.reply("compare")).card)
        XCTAssertEqual(compare.layout, .compare)
        XCTAssertEqual(compare.items.map(\.points.count), [3, 3])
        XCTAssertEqual(compare.takeaway, "Use iCloud unless the notes are private.")
        let steps = try XCTUnwrap(ExplainCardGrammar.parse(try Self.reply("steps")).card)
        XCTAssertEqual(steps.layout, .steps)
        XCTAssertEqual(steps.items.count, 5)
        XCTAssertNil(steps.items[0].icon)
    }

    /// The prompt's own example (benji/prompts.py CARD_EXAMPLE) reads as the card it shows, each
    /// part on the sentence before it (the card's lines go between the sentences).
    func testPromptExampleParses() throws {
        let prompts = try String(contentsOf: Self.root.deletingLastPathComponent().appendingPathComponent("benji/prompts.py"),
                                 encoding: .utf8)
        let start = try XCTUnwrap(prompts.range(of: "CARD_EXAMPLE = \"\"\""))
        let end = try XCTUnwrap(prompts.range(of: "\"\"\"", range: start.upperBound..<prompts.endIndex))
        let (text, script) = CardScript.whole(String(prompts[start.upperBound..<end.lowerBound]), at: 0)
        let c = try XCTUnwrap(script.draft?.card)
        XCTAssertEqual(c.layout, .flow)
        XCTAssertEqual(c.items.count, 4)
        XCTAssertEqual(c.chips.count, 2)
        XCTAssertEqual(script.owners, [0, 1, 2, 3])
        XCTAssertFalse(text.contains("{"))
    }

    func testNoBlockOrBrokenBlockLeavesTextAlone() {
        let plain = "Just words, no card."
        XCTAssertNil(ExplainCardGrammar.parse(plain).card)
        XCTAssertEqual(ExplainCardGrammar.parse(plain).text, plain)
        let broken = "Words.\n```card\n{\"items\": [\n```"
        XCTAssertNil(ExplainCardGrammar.parse(broken).card)
        XCTAssertEqual(ExplainCardGrammar.parse(broken).text, broken)
        XCTAssertNil(card("{\"items\": []}"))
        XCTAssertNil(card("{\"title\": \"x\"}"))
        XCTAssertNil(card("[1, 2]"))
        XCTAssertNil(card("{\"items\": [{\"note\": \"no label\"}, 3, null]}"))
    }

    func testFigureBlocksAreLeftForTheFigureParser() {
        let figure = "A lamp.\n```json\n{\"title\":\"Lamp\",\"parts\":[{\"name\":\"a\",\"kind\":\"box\",\"size\":[1,1,1]}],\"items\":[\"x\"]}\n```"
        XCTAssertNil(ExplainCardGrammar.parse(figure).card)
        let marked = "A lamp.\n```figure\n{\"title\":\"Lamp\",\"items\":[\"a\",\"b\"]}\n```"
        XCTAssertNil(ExplainCardGrammar.parse(marked).card)
    }

    func testJSONBlockCountsOnlyAtTheEnd() {
        let body = "{\"layout\":\"list\",\"items\":[\"One\",\"Two\"]}"
        XCTAssertNotNil(ExplainCardGrammar.parse("Words.\n```json\n\(body)\n```").card)
        XCTAssertNotNil(ExplainCardGrammar.parse("Words.\n```json\n\(body)\n```\n[POINT:10,20:Save]").card,
                        "pointing tags after the block still leave it at the end")
        XCTAssertNil(ExplainCardGrammar.parse("Words.\n```json\n\(body)\n```\nMore words after.").card)
        XCTAssertNotNil(ExplainCardGrammar.parse("Words.\n```card\n\(body)\n```\nMore words after.").card)
    }

    func testTextAroundTheBlockIsJoinedAndTagsKept() {
        let r = ExplainCardGrammar.parse("Before.\n\n```card\n{\"items\":[\"A\",\"B\"]}\n```\n[POINT:10,20:Save]")
        XCTAssertEqual(r.text, "Before.\n[POINT:10,20:Save]")
        XCTAssertEqual(ExplainCardGrammar.parse("```card\n{\"items\":[\"A\"]}\n```").text, "")
    }

    func testTheLastOfTwoCardsWins() {
        let r = ExplainCardGrammar.parse("```card\n{\"items\":[\"A\"]}\n```\nThen.\n```card\n{\"items\":[\"B\"]}\n```")
        XCTAssertEqual(r.card?.items.map(\.label), ["B"])
        XCTAssertTrue(r.text.contains("```card"), "only the card shown is taken out")
    }

    func testLayoutAliasesAndInference() {
        XCTAssertEqual(card("{\"layout\":\" Process \",\"items\":[\"a\",\"b\"]}")?.layout, .steps)
        XCTAssertEqual(card("{\"layout\":\"vs\",\"items\":[\"a\",\"b\"]}")?.layout, .compare)
        XCTAssertEqual(card("{\"layout\":\"states\",\"items\":[\"a\",\"b\"]}")?.layout, .flow)
        // No or unknown layout: columns of points compare, anything else lists.
        XCTAssertEqual(card("{\"items\":[{\"label\":\"A\",\"points\":[\"x\"]},{\"label\":\"B\",\"points\":[\"y\"]}]}")?.layout, .compare)
        XCTAssertEqual(card("{\"layout\":\"spiral\",\"items\":[\"a\",\"b\",\"c\"]}")?.layout, .list)
    }

    func testItemCountsFitTheLayout() {
        let six = (1...6).map { "\"s\($0)\"" }.joined(separator: ",")
        let flow = card("{\"layout\":\"flow\",\"items\":[\(six)]}")
        XCTAssertEqual(flow?.layout, .steps, "a flow too long for one row becomes steps")
        XCTAssertEqual(flow?.items.count, 6)
        let nine = (1...9).map { "\"s\($0)\"" }.joined(separator: ",")
        XCTAssertEqual(card("{\"layout\":\"steps\",\"items\":[\(nine)]}")?.items.count, 7)
        XCTAssertEqual(card("{\"layout\":\"list\",\"items\":[\(nine)]}")?.items.count, 6)
        XCTAssertEqual(card("{\"layout\":\"compare\",\"items\":[\"a\",\"b\",\"c\",\"d\"]}")?.items.count, 3)
        XCTAssertEqual(card("{\"layout\":\"compare\",\"items\":[\"only\"]}")?.layout, .list)
        XCTAssertEqual(card("{\"layout\":\"flow\",\"items\":[\"only\"]}")?.layout, .list)
    }

    func testTextIsCollapsedAndClippedAtAWord() throws {
        let c = try XCTUnwrap(card("""
            {"title":"  A   title\\nwith breaks ","items":[{"label":"Supercalifragilistic expialidocious word here","note":"n"}]}
            """))
        XCTAssertEqual(c.title, "A title with breaks")
        XCTAssertLessThanOrEqual(c.items[0].label.count, ExplainCardGrammar.maxLabel)
        XCTAssertTrue(c.items[0].label.hasSuffix("…"))
        XCTAssertEqual(ExplainCardGrammar.clip("one two three four", 12), "one two…")
    }

    func testTitleFallsBackToHeading() {
        XCTAssertEqual(card("{\"heading\":\"How it works\",\"items\":[\"a\"]}")?.title, "How it works")
        XCTAssertEqual(card("{\"items\":[\"a\"]}")?.title, "Benji")
    }

    func testIconsAreSymbolNamesOnly() {
        XCTAssertEqual(ExplainCardGrammar.icon(.string(" Arrow.Right.Circle ")), "arrow.right.circle")
        for bad in ["", "../etc", "a b", ".dot", "dot.", "emoji🙂", String(repeating: "a", count: 49)] {
            XCTAssertNil(ExplainCardGrammar.icon(.string(bad)), bad)
        }
        XCTAssertNil(ExplainCardGrammar.icon(.number(3)))
    }

    func testChipsAreDistinctShortAndAtMostThree() throws {
        let long = String(repeating: "x", count: 49)
        let c = try XCTUnwrap(card("""
            {"items":["a"],"chips":["Why?","why?","  Can I   stop it? ","\(long)",3,"Next one","Fourth"]}
            """))
        XCTAssertEqual(c.chips, ["Why?", "Can I stop it?", "Next one"])
    }

    func testPointsAreCappedAtFour() throws {
        let c = try XCTUnwrap(card("{\"layout\":\"compare\",\"items\":[{\"label\":\"A\",\"points\":[\"1\",\"2\",\"\",\"3\",\"4\",\"5\"]},\"B\"]}"))
        XCTAssertEqual(c.items[0].points, ["1", "2", "3", "4"])
    }

    func testOversizeBlockIsRefused() {
        let big = "{\"items\":[\"" + String(repeating: "a", count: 9000) + "\"]}"
        XCTAssertNil(card(big))
    }

    func testSpokenSummaryReadsInOrder() throws {
        let c = try XCTUnwrap(ExplainCardGrammar.parse(try Self.reply("steps")).card)
        XCTAssertTrue(c.spokenSummary.hasPrefix("A pull request. From your branch to main. 1. Branch: make a branch off main"))
    }

    // MARK: layout

    func layout(_ name: String) throws -> ExplainCardLayout {
        let c = try XCTUnwrap(ExplainCardGrammar.parse(try Self.reply(name)).card)
        return ExplainCardLayout.make(c, measure: FixedMeasure())
    }

    /// Nothing on the card overlaps anything else, and all of it sits on the board.
    func assertTidy(_ l: ExplainCardLayout, file: StaticString = #filePath, line: UInt = #line) {
        var rects: [CGRect] = []
        if let h = l.heading { rects.append(h.frame) }
        for n in l.nodes {
            if let b = n.badge { rects.append(b) }
            if let i = n.icon, n.box == nil { rects.append(i) }
            rects += n.texts.map(\.frame)
        }
        if let t = l.takeaway { rects.append(t.frame) }
        for r in rects {
            XCTAssertTrue(l.board.insetBy(dx: 8, dy: 8).contains(r), "\(r) off the board \(l.board)", file: file, line: line)
        }
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] where a.intersects(b) {
                XCTFail("\(a) overlaps \(b)", file: file, line: line)
            }
        }
        for (i, a) in l.chips.enumerated() {
            XCTAssertGreaterThanOrEqual(a.frame.minY, l.card.maxY + ExplainCardMetrics.chipsBelow - 0.5, file: file, line: line)
            XCTAssertLessThanOrEqual(a.frame.maxX, max(l.card.width, ExplainCardMetrics.chipRow) + 0.5, file: file, line: line)
            XCTAssertLessThanOrEqual(a.frame.maxX, l.size.width + 0.5, file: file, line: line)
            for b in l.chips[(i + 1)...] { XCTAssertFalse(a.frame.intersects(b.frame), file: file, line: line) }
        }
    }

    func testFlowLaysItemsLeftToRightWithArrowsBetween() throws {
        let l = try layout("states")
        assertTidy(l)
        let boxes = l.nodes.compactMap(\.box)
        XCTAssertEqual(boxes.count, 3)
        XCTAssertEqual(Set(boxes.map(\.height)).count, 1, "every box as tall as the tallest")
        XCTAssertEqual(Set(boxes.map(\.minY)).count, 1)
        XCTAssertTrue(zip(boxes, boxes.dropFirst()).allSatisfy { $0.maxX < $1.minX })
        XCTAssertEqual(l.arrows.count, 2)
        for (i, a) in l.arrows.enumerated() {
            XCTAssertGreaterThan(a.first!.x, boxes[i].maxX)
            XCTAssertLessThan(a.last!.x, boxes[i + 1].minX)
            XCTAssertEqual(a.first!.y, boxes[i].midY)
        }
        for n in l.nodes {
            let box = try XCTUnwrap(n.box)
            XCTAssertTrue(box.contains(try XCTUnwrap(n.icon)))
            for t in n.texts { XCTAssertTrue(box.contains(t.frame), "\(t.text) inside its box") }
        }
        XCTAssertEqual(l.chips.count, 3)
    }

    func testStepsAreNumberedDownALine() throws {
        let l = try layout("steps")
        assertTidy(l)
        XCTAssertEqual(l.nodes.compactMap(\.number), [1, 2, 3, 4, 5])
        let badges = l.nodes.compactMap(\.badge)
        XCTAssertEqual(Set(badges.map(\.minX)).count, 1)
        XCTAssertTrue(zip(badges, badges.dropFirst()).allSatisfy { $0.maxY < $1.minY })
        XCTAssertEqual(l.arrows.count, 4)
        XCTAssertTrue(l.arrows.allSatisfy { $0.first!.x == $0.last!.x && $0.first!.y < $0.last!.y }, "arrows run down")
        XCTAssertLessThan(l.size.width, 560, "five steps stay narrow")
    }

    func testCompareColumnsSideBySideWithADivider() throws {
        let l = try layout("compare")
        assertTidy(l)
        XCTAssertEqual(l.dividers.count, 1)
        let x = l.dividers[0][0].x
        XCTAssertTrue(l.nodes[0].texts.allSatisfy { $0.frame.maxX < x })
        XCTAssertTrue(l.nodes[1].texts.allSatisfy { $0.frame.minX > x })
        XCTAssertEqual(l.nodes[0].bullets.count, 3)
        XCTAssertNotNil(l.takeaway)
        XCTAssertGreaterThan(l.takeaway!.frame.minY, l.nodes.flatMap(\.texts).map(\.frame.maxY).max()!)
    }

    func testListRowsStackWithIconsOrDashes() throws {
        let withIcons = ExplainCardLayout.make(card("{\"layout\":\"list\",\"items\":[{\"label\":\"A\",\"icon\":\"star\"},{\"label\":\"B\",\"note\":\"bee\"}]}")!,
                                               measure: FixedMeasure())
        assertTidy(withIcons)
        XCTAssertEqual(withIcons.nodes.compactMap(\.icon).count, 2, "every row keeps the icon column")
        XCTAssertEqual(withIcons.nodes[0].iconName, "star")
        XCTAssertNil(withIcons.nodes[1].iconName, "a row without an icon gets a plain tile")
        let dashes = ExplainCardLayout.make(card("{\"layout\":\"list\",\"items\":[\"A\",\"B\",\"C\"]}")!, measure: FixedMeasure())
        assertTidy(dashes)
        XCTAssertEqual(dashes.nodes.map(\.bullets.count), [1, 1, 1])
    }

    func testCardWidthIsClampedAndLongWordsWrap() throws {
        let tiny = ExplainCardLayout.make(card("{\"layout\":\"list\",\"items\":[\"A\"]}")!, measure: FixedMeasure())
        XCTAssertGreaterThanOrEqual(tiny.card.width, ExplainCardMetrics.minWidth)
        let five = ExplainCardLayout.make(card("""
            {"layout":"flow","heading":"A heading long enough to want the whole width of the card and then some more words",
             "items":[{"label":"One two three","note":"a note that is long enough to wrap over more than three lines in a box"},"B","C","D","E"]}
            """)!, measure: FixedMeasure())
        XCTAssertLessThanOrEqual(five.card.width, ExplainCardMetrics.maxWidth)
        assertTidy(five)
        let note = five.nodes[0].texts[1]
        XCTAssertLessThanOrEqual(note.frame.height, FixedMeasure().lineHeight(.note) * 3 + 1, "notes stop at three lines")
    }

    func testChipsWrapUnderANarrowCard() throws {
        let l = ExplainCardLayout.make(card("""
            {"layout":"list","items":["A"],"chips":["A fairly long first question?","Another long one here?","Third question?"]}
            """)!, measure: FixedMeasure())
        assertTidy(l)
        XCTAssertGreaterThan(Set(l.chips.map(\.frame.minY)).count, 1, "chips wrap to a second row")
        XCTAssertEqual(l.size.height, l.chips.last!.frame.maxY)
    }

    func testTitleBarAndCloseSitAboveTheBoard() throws {
        let l = try layout("states")
        XCTAssertEqual(l.titleBar.height, ExplainCardMetrics.titleBar)
        XCTAssertTrue(l.titleBar.contains(l.close))
        XCTAssertFalse(l.title.frame.intersects(l.close))
        XCTAssertEqual(l.board.minY, l.titleBar.maxY)
    }

    // MARK: busy map and placement

    /// A 1512×982 display, 64-point tiles; `busy` marks tiles (col, row) as busy.
    func map(busy: (Int, Int) -> Bool) -> BusyMap {
        let cols = 24, rows = 16
        var d: [Double] = []
        for r in 0..<rows { for c in 0..<cols { d.append(busy(c, r) ? 0.2 : 0) } }
        return BusyMap(cols: cols, rows: rows, density: d)
    }

    let visible = CGRect(x: 0, y: 33, width: 1512, height: 885)
    let panel = CGRect(x: 556, y: 0, width: 400, height: 182)
    var prefer: CGPoint { CGPoint(x: panel.midX, y: panel.maxY + 16) }

    func testCalmScreenPutsTheCardJustUnderThePanel() {
        let r = ExplainCardPlacement.place(size: CGSize(width: 600, height: 300), visible: visible, prefer: prefer,
                                           avoid: [panel], busy: map { _, _ in false })
        XCTAssertFalse(r.frame.intersects(panel))
        XCTAssertEqual(r.frame.midX, panel.midX, accuracy: 16)
        XCTAssertLessThan(r.frame.minY - panel.maxY, 48)
        XCTAssertFalse(r.overBusySpace)
    }

    func testCardGoesToCalmSpaceBesideAPageOfText() {
        // A page of text down the left two thirds; the right third is wallpaper.
        let m = map { c, _ in c < 16 }
        let r = ExplainCardPlacement.place(size: CGSize(width: 440, height: 360), visible: visible, prefer: prefer,
                                           avoid: [panel], busy: m)
        XCTAssertGreaterThanOrEqual(r.frame.minX, 16 * 64 - 1)
        XCTAssertEqual(r.busyCover, 0, accuracy: 0.001)
        XCTAssertTrue(visible.contains(r.frame))
    }

    func testAllBusyStillPlacesAnOpaqueCardInView() {
        let r = ExplainCardPlacement.place(size: CGSize(width: 600, height: 300), visible: visible, prefer: prefer,
                                           avoid: [panel], busy: map { _, _ in true })
        XCTAssertTrue(r.overBusySpace)
        XCTAssertTrue(visible.insetBy(dx: ExplainCardPlacement.margin, dy: ExplainCardPlacement.margin).contains(r.frame))
        XCTAssertFalse(r.frame.intersects(panel))
    }

    func testAvoidsWhatTheReplyPointsAt() {
        let target = CGRect(x: 500, y: 200, width: 500, height: 200)
        let r = ExplainCardPlacement.place(size: CGSize(width: 500, height: 260), visible: visible, prefer: prefer,
                                           avoid: [panel, target], busy: nil)
        XCTAssertFalse(r.frame.intersects(target))
        XCTAssertFalse(r.frame.intersects(panel))
    }

    func testTooBigForTheScreenIsPinnedToTheCorner() {
        let r = ExplainCardPlacement.place(size: CGSize(width: 2000, height: 300), visible: visible, prefer: prefer)
        XCTAssertEqual(r.frame.origin, CGPoint(x: visible.minX + 16, y: visible.minY + 16))
    }

    func testCoverageIsAreaWeighted() {
        let m = BusyMap(cols: 2, rows: 1, tile: 64, density: [0.5, 0])
        XCTAssertEqual(m.coverage(of: CGRect(x: 32, y: 0, width: 64, height: 64)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(m.coverage(of: CGRect(x: 200, y: 0, width: 64, height: 64)), 0)
        XCTAssertTrue(m.isBusy(col: 0, row: 0))
        XCTAssertFalse(m.isBusy(col: 5, row: 0))
    }

    func testMeasureFindsTextAndIgnoresGradients() throws {
        // 256×128 px of a 128-point-wide display: two tiles of 128 px across, one down.
        let w = 256, h = 128
        var luma = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                if x < 128 {
                    luma[y * w + x] = UInt8(60 + x / 2)                               // a soft gradient
                } else {
                    luma[y * w + x] = (y % 12 < 7 && (x / 3) % 2 == 0) ? 20 : 235     // lines of "letters"
                }
            }
        }
        let m = try XCTUnwrap(BusyMap.measure(luma: luma, width: w, height: h, pointsWide: 128))
        XCTAssertEqual(m.cols, 2)
        XCTAssertEqual(m.rows, 1)
        XCTAssertFalse(m.isBusy(col: 0, row: 0))
        XCTAssertTrue(m.isBusy(col: 1, row: 0))
        XCTAssertNil(BusyMap.measure(luma: [], width: 0, height: 0, pointsWide: 10))
    }

    // MARK: reveal

    func testRevealGoesInOrderAndChipsComeLast() {
        let r = ExplainCardReveal(items: 3, hasTakeaway: true)
        XCTAssertEqual(r.card(at: 0), 0)
        XCTAssertEqual(r.item(0, at: r.itemStart(0) - 0.01), 0)
        XCTAssertEqual(r.item(2, at: r.itemStart(2) + ExplainCardReveal.fade), 1)
        XCTAssertGreaterThan(r.arrow(0, at: r.itemStart(1)), 0, "the arrow is drawing when the next item lands")
        XCTAssertEqual(r.arrow(0, at: r.itemStart(0) + 0.05), 0)
        XCTAssertEqual(r.chips(at: r.chipsAt - 0.01), 0)
        XCTAssertEqual(r.chips(at: r.duration), 1)
        XCTAssertGreaterThan(r.chipsAt, r.itemStart(2) + ExplainCardReveal.fade)
        XCTAssertLessThan(r.duration, 2.5)
    }

    func testReduceMotionShowsEverythingAtOnce() {
        let r = ExplainCardReveal(items: 5, hasTakeaway: false, reduceMotion: true)
        XCTAssertEqual(r.duration, 0)
        XCTAssertEqual(r.item(4, at: 0), 1)
        XCTAssertEqual(r.chips(at: 0), 1)
        XCTAssertEqual(r.arrow(3, at: 0), 1)
    }
}

extension ExplainCardTests {
    func testPointedThingsBecomeRectsToAvoid() {
        XCTAssertEqual(ExplainCardPlacement.pixelBounds(of: .point(x: 100, y: 100)), CGRect(x: 40, y: 40, width: 120, height: 120))
        XCTAssertEqual(ExplainCardPlacement.pixelBounds(of: .arrow(x1: 300, y1: 50, x2: 100, y2: 150)),
                       CGRect(x: 76, y: 26, width: 248, height: 148))
        XCTAssertEqual(ExplainCardPlacement.pixelBounds(of: .shape([10, 10, 50, 90, 30, 40])), CGRect(x: -14, y: -14, width: 88, height: 128))
    }
}

extension ExplainCardTests {
    func testStepsLineUpUnderTheHeadingAndFlowsCentre() throws {
        let steps = try layout("steps")
        XCTAssertEqual(steps.nodes[0].badge!.minX, ExplainCardMetrics.pad)
        let flow = try layout("states")
        let boxes = flow.nodes.compactMap(\.box)
        XCTAssertEqual(boxes.first!.minX - flow.card.minX, flow.card.maxX - boxes.last!.maxX, accuracy: 1)
    }

    func testATakeawayOfAFullSentenceFits() throws {
        let line = "Pick iCloud if you use several Apple devices; a local folder with Time Machine if you want control."
        let c = try XCTUnwrap(card("{\"layout\":\"list\",\"items\":[\"A\"],\"takeaway\":\"\(line)\"}"))
        XCTAssertEqual(c.takeaway, line)
    }
}
