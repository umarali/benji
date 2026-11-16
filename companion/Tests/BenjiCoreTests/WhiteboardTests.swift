import XCTest
@testable import BenjiCore

/// The screen as Benji's whiteboard. The shared cases in
/// Tests/whiteboard-cases.json are also run by selftest.py against benji/pointing.py and
/// benji/cards.py: both sides read tags between sentences, edits and card lines the same way.
final class WhiteboardTests: XCTestCase {
    static func file() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("whiteboard-cases.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func editObject(_ e: DrawingEdit) -> [String: Any] {
        ["part": e.part, "op": e.op.rawValue, "args": e.numbers, "text": e.text]
    }

    static func same(_ a: Any?, _ b: Any?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        let x = try? JSONSerialization.data(withJSONObject: ["v": a], options: [.sortedKeys])
        let y = try? JSONSerialization.data(withJSONObject: ["v": b], options: [.sortedKeys])
        return x != nil && x == y
    }

    // MARK: shared grammar

    func testSharedEditCases() throws {
        let cases = try XCTUnwrap(try Self.file()["edits"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 20)
        for c in cases {
            let tag = try XCTUnwrap(c["tag"] as? String)
            let got = DrawingEdit.parse(Substring(tag)).map(Self.editObject)
            let want = c["edit"] is NSNull ? nil : c["edit"]
            XCTAssertTrue(Self.same(got, want), "\(tag): \(String(describing: got)) vs \(String(describing: want))")
        }
    }

    func testSharedSplitCases() throws {
        let cases = try XCTUnwrap(try Self.file()["splits"] as? [[String: Any]])
        for c in cases {
            let text = try XCTUnwrap(c["text"] as? String)
            let (shown, targets) = PointingTags.split(text)
            XCTAssertEqual(shown, c["shown"] as? String, text)
            let marks = targets.filter { $0.shape.edit == nil }, edits = targets.compactMap { t in t.shape.edit.map { (t, $0) } }
            let wantMarks = try XCTUnwrap(c["targets"] as? [[String: Any]])
            let wantEdits = try XCTUnwrap(c["edits"] as? [[String: Any]])
            XCTAssertEqual(marks.count, wantMarks.count, text)
            XCTAssertEqual(edits.count, wantEdits.count, text)
            let beats = (wantMarks + wantEdits).contains { ($0["at"] as? Int ?? 0) < shown.unicodeScalars.count }
            for (t, w) in zip(marks, wantMarks) {
                XCTAssertEqual(t.label, w["label"] as? String, text)
                XCTAssertEqual(t.at, beats ? w["at"] as? Int : nil, text)
                XCTAssertNotNil(ServeEvent.target(["kind": w["kind"]!, "coords": w["coords"]!]).map { $0.shape == t.shape }, text)
                XCTAssertEqual(ServeEvent.target(["kind": w["kind"]!, "coords": w["coords"]!])?.shape, t.shape, text)
            }
            for ((t, e), w) in zip(edits, wantEdits) {
                var o = Self.editObject(e)
                o["at"] = w["at"]
                XCTAssertTrue(Self.same(o, w), text)
                XCTAssertEqual(t.at, beats ? w["at"] as? Int : nil, text)
            }
        }
    }

    func testTagsOnlyAtTheEndSplitExactlyAsParse() {
        for text in ["Here it is.\n[BOX:10,20,110,60:Field]\n[POINT:300,400:Save]", "No tags.", "Hi [x:1]",
                     "An airliner.\n[SHAPE:10,10,200,10,200,60:body] [OVAL:20,20,30,30:window]"] {
            let a = PointingTags.split(text), b = PointingTags.parse(text)
            XCTAssertEqual(a.text, b.text, text)
            XCTAssertEqual(a.targets, b.targets, text)
            XCTAssertTrue(a.targets.allSatisfy { $0.at == nil })
        }
    }

    func testSharedCardLineCases() throws {
        let cases = try XCTUnwrap(try Self.file()["cardlines"] as? [[String: Any]])
        for c in cases {
            let line = try XCTUnwrap(c["line"] as? String)
            let (spoken, script) = CardScript.whole(line, at: 0)
            XCTAssertEqual(spoken, c["spoken"] as? String, line)
            let kinds = try XCTUnwrap(c["kinds"] as? [String])
            _ = script
            // The card line the line holds, read whole or later in the line.
            let read = ExplainCardGrammar.inlineSplit(line)?.card ?? ExplainCardGrammar.line(line)
            var kind: String?
            if case let .card(l) = read {
                switch l {
                case .open: kind = "card"
                case .item: kind = "item"
                case .takeaway: kind = "takeaway"
                case .chips: kind = "chips"
                }
            }
            XCTAssertEqual(kind.map { [$0] } ?? [], kinds, line)
        }
    }

    func testTheLiveLeakIsNeverSpoken() {
        // "Takeaway:" is never read aloud, and the takeaway shows once, on the card.
        let reply = "card: {\"title\":\"Pythagoras\"}\nThe legs are a and b.\nitem: {\"label\":\"Legs\"}\nThe long side is c. Takeaway: a² + b² = c².\n"
        let (spoken, script) = CardScript.whole(reply, at: 0)
        XCTAssertFalse(spoken.lowercased().contains("takeaway"))
        XCTAssertEqual(script.draft?.takeaway, "a² + b² = c².")
        XCTAssertFalse(SpeechText.plain("Done. [TEXT:10,20:large:a² + b² = c²]\nNext.").contains("TEXT"))
        XCTAssertEqual(SpeechText.plain("The legs.\n[LINE:1,1,1,90:a]\nThe long side."), "The legs.\nThe long side.")
    }

    // MARK: TEXT

    func testTextTagMapsToWordsInTheHand() {
        XCTAssertEqual(TextSize.split("large:a² + b² = c²").0, .large)
        XCTAssertEqual(TextSize.split("large:a² + b² = c²").1, "a² + b² = c²")
        XCTAssertEqual(TextSize.split("c").0, .medium)
        XCTAssertEqual(TextSize.split("ratio: 3:4").1, "ratio: 3:4")
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let (_, targets) = PointingTags.split("A label. [TEXT:100,200:small:c]")
        let item = PointMapping.item(for: targets[0], pixelSize: CGSize(width: 2000, height: 1600), screenFrame: screen)
        XCTAssertEqual(item, .sketch(.text(at: CGPoint(x: 50, y: 700), text: "c", size: .small)))
        XCTAssertNil(PointMapping.item(for: PointingTarget(shape: .text(x: 1, y: 1), label: String(repeating: "x", count: 81)),
                                       pixelSize: screen.size, screenFrame: screen))
        XCTAssertNil(PointMapping.item(for: PointingTarget(shape: .text(x: 1, y: 1), label: "large:"), pixelSize: screen.size,
                                       screenFrame: screen))
        XCTAssertTrue(PointingShape.text(x: 1, y: 1).isDrawing)
        XCTAssertTrue(Sketch.text(at: .zero, text: "c", size: .large).isDrawing)
        XCTAssertGreaterThan(SketchTimeline.drawDuration(.text(at: .zero, text: "a² + b² = c²", size: .large)),
                             SketchTimeline.drawDuration(.text(at: .zero, text: "c", size: .large)))
        XCTAssertEqual(PointingAnnouncement.text(for: .text(at: .zero, text: "c", size: .large)), "Written on screen: c.")
    }

    func testTextFrameStaysOnScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let f = SketchLayout.textFrame(size: CGSize(width: 200, height: 40), at: CGPoint(x: 100, y: 300), bounds: bounds)
        XCTAssertEqual(f, CGRect(x: 100, y: 280, width: 200, height: 40))
        let edge = SketchLayout.textFrame(size: CGSize(width: 200, height: 40), at: CGPoint(x: 790, y: 2), bounds: bounds)
        XCTAssertTrue(bounds.insetBy(dx: OverlayLayout.safeInset, dy: OverlayLayout.safeInset).contains(edge))
    }

    // MARK: beats on the overlay

    func testBeatsFormOwnsEachMarkByTheSentenceBeforeIt() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let reply = "The two short sides meet at a right angle.\n[LINE:400,200,400,500:a] [LINE:400,500,800,500:b]\nThe long side is c.\n[LINE:400,200,800,500:c]\n[TEXT:560,300:large:a² + b² = c²]\nThat is all."
        let (text, targets) = PointingTags.split(reply)
        let plan = PointingPlan(targets: targets, text: text, speaking: true, pixelSize: screen.size, screenFrame: screen, displayID: nil)!
        XCTAssertEqual(plan.sentences, ["The two short sides meet at a right angle.", "The long side is c.", "That is all."])
        XCTAssertEqual(plan.owners, [0, 0, 1, 1])
        XCTAssertNil(plan.fit, "the beats form doesn't fit the picture to one sentence")
        XCTAssertNotNil(plan.beats(reduceMotion: false, now: 0))
        // Tags only at the end, the other form an answer may take, keep the anchor-word pacing.
        let old = PointingTags.split("An L. [LINE:400,200,400,500:a] [LINE:400,500,800,500:b]")
        let oldPlan = PointingPlan(targets: old.targets, text: old.text, speaking: true, pixelSize: screen.size,
                                   screenFrame: screen, displayID: nil)!
        XCTAssertNil(oldPlan.owners)
        XCTAssertNil(oldPlan.beats(reduceMotion: false, now: 0))
        XCTAssertNotNil(oldPlan.fit)
    }

    func testAMarkBeforeAnySentenceHasNoOwner() {
        let owned = MarkOwners.of(text: "Look here. Then there.", ats: [0, 10, 22])
        XCTAssertEqual(owned.lines, ["Look here.", "Then there."])
        XCTAssertEqual(owned.owners, [nil, 0, 1])
        let unended = MarkOwners.of(text: "A sentence that never ends", ats: [5, 26])
        XCTAssertEqual(unended.owners, [0, 0])
    }

    /// A simulated voice: each sentence's parts are drawn while that sentence is heard, never before.
    func testEachPartIsDrawnWhileItsSentenceIsHeard() {
        let texts = ["The two short sides meet at a right angle.", "The long side is c.", "That is all."]
        var b = OverlayBeats(texts: texts, owners: [0, 0, 1, 1], naturals: [0.4, 0.4, 0.5, 0.6], clock: .voice, now: 0)
        let spoken = texts.joined(separator: " ")
        let starts = [1.0, 4.0, 6.5], ends = [3.9, 6.4, 7.5]
        var marks: [SpokenProgress.Mark] = []
        for (i, t) in texts.enumerated() {
            let offset = (spoken as NSString).range(of: t).location
            marks.append(.init(at: starts[i], offset: offset))
        }
        var releasedAt: [Int: Double] = [:]
        var t = 0.0
        while t < 9 {
            if t >= 1.0 && marks.contains(where: { $0.at <= t }) {
                b.heard(spoken: spoken, marks: marks.filter { $0.at <= t && $0.at > t - 0.01 - 1e-9 })
            }
            for i in b.advance(now: t) { releasedAt[i] = t }
            t += 0.01
        }
        XCTAssertTrue(b.isDone)
        XCTAssertGreaterThanOrEqual(releasedAt[0]!, starts[0])
        XCTAssertLessThan(releasedAt[1]!, ends[0])
        XCTAssertGreaterThanOrEqual(releasedAt[2]!, starts[1] - 0.02)
        XCTAssertLessThan(b.track.released[3].end, ends[1] + 0.05)
        XCTAssertNil(releasedAt.values.first { $0 < 1.0 }, "nothing before the voice starts")
    }

    func testWithNoVoiceTheEstimateTimesThem() {
        var b = OverlayBeats(texts: ["One two three four.", "Five six."], owners: [0, 1], naturals: [0.3, 0.3], clock: .estimate, now: 0)
        let first = b.advance(now: 0.2)
        XCTAssertEqual(first, [0])
        XCTAssertEqual(b.advance(now: 0.3), [])
        XCTAssertNotNil(b.nextDue(now: 0.3))
        _ = b.advance(now: 10)
        XCTAssertTrue(b.isDone)
        var hurried = OverlayBeats(texts: ["A.", "B."], owners: [0, 1], naturals: [0.3, 0.3], clock: .voice, now: 0)
        hurried.hurry(now: 1)
        XCTAssertTrue(hurried.isDone)
        XCTAssertEqual(hurried.pace(1), BeatPlanner.rush, accuracy: 1e-9)
    }

    // MARK: edits by part id

    func parts() -> DrawingParts {
        var d = DrawingParts()
        d.append([.sketch(.polyline(points: [CGPoint(x: 100, y: 500), CGPoint(x: 100, y: 200)], closed: false, label: "a")),
                  .sketch(.polyline(points: [CGPoint(x: 100, y: 200), CGPoint(x: 400, y: 200)], closed: false, label: "b")),
                  .sketch(.polyline(points: [CGPoint(x: 100, y: 500), CGPoint(x: 400, y: 200)], closed: false, label: "hypotenuse")),
                  .sketch(.text(at: CGPoint(x: 260, y: 380), text: "c", size: .large))])
        return d
    }

    func testMakeTheHypotenuseLongerChangesOnePart() {
        var d = parts()
        let before = d.parts
        let changes = d.apply(DrawingEdit.parse("EDIT:p3:scale 1.5")!, pointsPerPixel: CGSize(width: 0.5, height: 0.5))
        XCTAssertEqual(changes.count, 1)
        guard case .moved(index: 2, _) = changes[0] else { return XCTFail("\(changes)") }
        XCTAssertEqual(Array(d.parts[0...1]), Array(before[0...1]))
        XCTAssertEqual(d.parts[3], before[3])
        guard case let .sketch(.polyline(p, _, _)) = d.parts[2].item else { return XCTFail() }
        XCTAssertEqual(hypot(p[1].x - p[0].x, p[1].y - p[0].y), 1.5 * hypot(300, 300), accuracy: 1e-6)
        XCTAssertEqual((p[0].x + p[1].x) / 2, 250, accuracy: 1e-9, "scaled about its centre")
    }

    func testMoveIsInScreenshotPixelsWithYDown() {
        var d = parts()
        _ = d.apply(DrawingEdit.parse("EDIT:p4:move 20,10")!, pointsPerPixel: CGSize(width: 0.5, height: 0.5))
        XCTAssertEqual(d.parts[3].item, .sketch(.text(at: CGPoint(x: 270, y: 375), text: "c", size: .large)))
    }

    func testRelabelRecolorEraseAndAll() {
        var d = parts()
        XCTAssertEqual(d.apply(DrawingEdit.parse("EDIT:p4:relabel a² + b² = c²")!, pointsPerPixel: CGSize(width: 1, height: 1)),
                       [.relabeled(index: 3)])
        XCTAssertEqual(d.parts[3].item, .sketch(.text(at: CGPoint(x: 260, y: 380), text: "a² + b² = c²", size: .large)))
        XCTAssertEqual(d.apply(DrawingEdit.parse("EDIT:p1:recolor red")!, pointsPerPixel: CGSize(width: 1, height: 1)),
                       [.recolored(index: 0)])
        XCTAssertEqual(d.parts[0].color, .red)
        XCTAssertEqual(d.apply(DrawingEdit.parse("EDIT:p2:erase")!, pointsPerPixel: CGSize(width: 1, height: 1)), [.erased(index: 1)])
        XCTAssertEqual(d.live.map(\.id), ["p1", "p3", "p4"], "ids stay with their parts")
        XCTAssertEqual(d.apply(DrawingEdit.parse("EDIT:p2:erase")!, pointsPerPixel: CGSize(width: 1, height: 1)), [])
        XCTAssertEqual(d.apply(DrawingEdit.parse("EDIT:p9:erase")!, pointsPerPixel: CGSize(width: 1, height: 1)), [])
        XCTAssertEqual(d.apply(DrawingEdit.parse("EDIT:all:keep")!, pointsPerPixel: CGSize(width: 1, height: 1)), [])
        XCTAssertEqual(d.apply(DrawingEdit.parse("EDIT:all:erase")!, pointsPerPixel: CGSize(width: 1, height: 1)).count, 3)
        XCTAssertTrue(d.live.isEmpty)
        XCTAssertFalse(d.isDrawing)
    }

    func testAnEditAnswerExtendsTheDrawing() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let (text, targets) = PointingTags.split("Longer now. [EDIT:p3:scale 1.4]")
        let plan = PointingPlan(targets: targets, text: text, speaking: false, pixelSize: screen.size, screenFrame: screen, displayID: nil)
        XCTAssertNotNil(plan, "edits alone make a plan")
        XCTAssertTrue(plan!.extendsDrawing)
        XCTAssertTrue(plan!.items.isEmpty)
        XCTAssertEqual(plan!.edits, [DrawingEdit(part: "p3", op: .scale, numbers: [1.4])])
        let fresh = PointingTags.split("A new one. [OVAL:10,10,90,90:face]")
        XCTAssertFalse(PointingPlan(targets: fresh.targets, text: fresh.text, speaking: false, pixelSize: screen.size,
                                    screenFrame: screen, displayID: nil)!.extendsDrawing)
    }

    // MARK: what Benji has on the screen

    func testCanvasMapsPartsIntoTheScreenshotsPixels() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let parts = CanvasSnapshot.parts(parts(), drawnOn: screen, screenFrame: screen, pixelSize: CGSize(width: 2000, height: 1600))
        XCTAssertEqual(parts.map(\.id), ["p1", "p2", "p3", "p4"])
        XCTAssertEqual(parts.map(\.kind), ["line", "line", "line", "text"])
        XCTAssertEqual(parts[0].box, .init(x1: 200, y1: 600, x2: 200, y2: 1200))
        XCTAssertEqual(parts[3].label, "c")
        let elsewhere = CanvasSnapshot.parts(self.parts(), drawnOn: CGRect(x: 1000, y: 0, width: 1920, height: 1080),
                                             screenFrame: screen, pixelSize: screen.size)
        XCTAssertTrue(elsewhere.allSatisfy { $0.box == nil }, "a drawing on another display has no box here")
        var c = CanvasSnapshot()
        XCTAssertTrue(c.isEmpty)
        c.parts = parts
        c.board = .init(x1: 1, y1: 2, x2: 3, y2: 4)
        c.figureTitle = "A jet engine"
        c.figureParts = ["fan"]
        let o = c.object
        XCTAssertEqual((o["parts"] as? [[String: Any]])?.first?["box"] as? [Int], [200, 600, 200, 1200])
        XCTAssertEqual(o["board"] as? [Int], [1, 2, 3, 4])
        XCTAssertEqual((o["figure"] as? [String: Any])?["title"] as? String, "A jet engine")
        XCTAssertNil(o["card"])
    }

    func testSendCarriesTheCanvasAndOlderSendsAreUnchanged() throws {
        var c = CanvasSnapshot()
        c.parts = [.init(id: "p1", kind: "oval", label: "face", box: .init(x1: 1, y1: 2, x2: 3, y2: 4))]
        let line = String(decoding: ServeRequest.send(id: "t1", text: "hi", imagePath: nil, allowPointing: false, canvas: c).line(),
                          as: UTF8.self)
        XCTAssertTrue(line.contains(#""canvas":{"parts":[{"box":[1,2,3,4],"id":"p1","kind":"oval","label":"face"}]}"#), line)
        let bare = String(decoding: ServeRequest.send(id: "t1", text: "hi", imagePath: nil, allowPointing: false).line(), as: UTF8.self)
        XCTAssertEqual(bare, #"{"id":"t1","text":"hi","type":"send"}"# + "\n")
        let empty = String(decoding: ServeRequest.send(id: "t1", text: "hi", imagePath: nil, allowPointing: false,
                                                       canvas: CanvasSnapshot()).line(), as: UTF8.self)
        XCTAssertEqual(empty, bare)
    }

    func testAnswerDecodesPlacesAndEdits() {
        let json = #"{"type":"answer","id":"t1","text":"One.\nTwo.","targets":[{"kind":"line","coords":[1,2,3,4],"label":"a","at":5},{"kind":"text","coords":[5,6],"label":"large:c","at":9}],"edits":[{"part":"p2","op":"move","args":[10,-20],"text":"","at":9},{"part":"p1","op":"recolor","args":[],"text":"red","at":9},{"part":"p1","op":"spin","args":[],"text":""}]}"#
        guard case let .answer(_, text, targets, _)? = ServeEvent.decode(json) else { return XCTFail() }
        XCTAssertEqual(text, "One.\nTwo.")
        XCTAssertEqual(targets.map(\.at), [5, 9, 9, 9])
        XCTAssertEqual(targets[1].shape, .text(x: 5, y: 6))
        XCTAssertEqual(targets[2].shape.edit, DrawingEdit(part: "p2", op: .move, numbers: [10, -20]))
        XCTAssertEqual(targets[3].shape.edit, DrawingEdit(part: "p1", op: .recolor, text: "red"))
        let old = #"{"type":"answer","id":"t1","text":"Here.","targets":[{"kind":"point","coords":[1,2],"label":"x"}]}"#
        guard case let .answer(_, _, oldTargets, _)? = ServeEvent.decode(old) else { return XCTFail() }
        XCTAssertEqual(oldTargets, [PointingTarget(shape: .point(x: 1, y: 2), label: "x")])
    }

    // MARK: the board

    func testACalmDrawingGetsNoBoardABusyOneMovesOntoOne() {
        // Busy on the left half, calm on the right.
        let cols = 24, rows = 15
        let density = (0..<(cols * rows)).map { i in (i % cols) < cols / 2 ? 0.2 : 0.0 }
        let map = BusyMap(cols: cols, rows: rows, density: density)
        let visible = CGRect(x: 0, y: 0, width: 1536, height: 960)
        XCTAssertNil(DrawingBoard.place(drawing: CGRect(x: 1000, y: 300, width: 300, height: 200), visible: visible, busy: map,
                                        prefer: CGPoint(x: 768, y: 60)))
        XCTAssertNil(DrawingBoard.place(drawing: CGRect(x: 100, y: 300, width: 300, height: 200), visible: visible, busy: nil,
                                        prefer: CGPoint(x: 768, y: 60)))
        let busy = CGRect(x: 100, y: 300, width: 300, height: 200)
        let placed = try! XCTUnwrap(DrawingBoard.place(drawing: busy, visible: visible, busy: map, prefer: CGPoint(x: 768, y: 60)))
        XCTAssertLessThan(map.coverage(of: placed.frame), ExplainCardPlacement.busySpace, "the board sits on calm space")
        XCTAssertEqual(placed.frame.width, busy.width + 2 * DrawingBoard.padding)
        let moved = busy.offsetBy(dx: placed.offset.dx, dy: placed.offset.dy)
        XCTAssertTrue(placed.frame.contains(moved), "every part lands on the board")
        XCTAssertEqual(moved.midX, placed.frame.midX, accuracy: 1e-9)
    }

    func testDrawingsShowInCapturesUnlessTurnedOff() {
        XCTAssertTrue(DrawingCapture.shownWhileDrawing(from: nil))
        XCTAssertTrue(DrawingCapture.shownWhileDrawing(from: true))
        XCTAssertFalse(DrawingCapture.shownWhileDrawing(from: false))
        XCTAssertFalse(DrawingCapture.shown(from: nil), "marks on things keep the old default")
    }

    func testShiftAndExtentFollowTheBoard() {
        var d = parts()
        let before = d.extent!
        d.shift(by: CGVector(dx: 10, dy: -20))
        XCTAssertEqual(d.extent!, before.offsetBy(dx: 10, dy: -20))
        XCTAssertTrue(d.isDrawing)
    }
}
