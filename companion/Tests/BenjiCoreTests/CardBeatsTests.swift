import XCTest
@testable import BenjiCore

/// Explanation cards drawn as Benji speaks: the card lines, which sentence owns
/// each part, the planner that spreads parts over their sentence, the sentences' clock (voice or
/// estimate), and a whole reply played against scripted voice milestones.
final class CardBeatsTests: XCTestCase {
    typealias Line = BeatPlanner.Line
    typealias Part = BeatPlanner.Part

    // MARK: the lines

    func testCardLinesReadAsBenjiCardsPyReadsThem() {
        XCTAssertEqual(ExplainCardGrammar.line(#"card: {"title":"Sending a letter","heading":"Four hands","layout":"Pipeline"}"#),
                       .card(.open(ExplainCardHeader(title: "Sending a letter", heading: "Four hands", layout: .flow))))
        XCTAssertEqual(ExplainCardGrammar.line(#"  item: {"label":"Post box","note":"you drop it in","icon":"envelope"}"#),
                       .card(.item(.init(label: "Post box", note: "you drop it in", icon: "envelope"))))
        XCTAssertEqual(ExplainCardGrammar.line("takeaway: The postcode does the work."), .card(.takeaway("The postcode does the work.")))
        XCTAssertEqual(ExplainCardGrammar.line(#"Takeaway: "Quoted.""#), .card(.takeaway("Quoted.")))
        XCTAssertEqual(ExplainCardGrammar.line(#"chips: ["Why postcodes?","Why postcodes?","How long?"]"#),
                       .card(.chips(["Why postcodes?", "How long?"])))
        XCTAssertEqual(ExplainCardGrammar.line(#"card: {"heading":"Only a heading"}"#),
                       .card(.open(ExplainCardHeader(title: "Only a heading", heading: "Only a heading", layout: nil))))
    }

    func testSentencesThatLookLikeCardLinesStaySentences() {
        XCTAssertEqual(ExplainCardGrammar.line("Item: one more thing before you go."), .text)
        XCTAssertEqual(ExplainCardGrammar.line("Chips are cheap."), .text)
        XCTAssertEqual(ExplainCardGrammar.line("chips: none today"), .text)
        XCTAssertEqual(ExplainCardGrammar.line("The card: it's in your wallet."), .text)
        XCTAssertEqual(ExplainCardGrammar.line("item: {broken"), .dropped)
        XCTAssertEqual(ExplainCardGrammar.line(#"item: {"note":"no label"}"#), .dropped)
        XCTAssertEqual(ExplainCardGrammar.line("takeaway:   "), .dropped)
    }

    func testTheEnginesEventsReadAsLines() throws {
        let item = try XCTUnwrap(ServeEvent.decode(#"{"type":"card_item","id":"t1","item":{"label":"Van","icon":"truck.box"},"at":32}"#))
        XCTAssertEqual(item, .cardLine(id: "t1", line: .item(.init(label: "Van", icon: "truck.box")), at: 32))
        XCTAssertEqual(ServeEvent.decode(#"{"type":"card","id":"t1","card":{"title":"Letter","layout":"steps"},"at":0}"#),
                       .cardLine(id: "t1", line: .open(ExplainCardHeader(title: "Letter", layout: .steps)), at: 0))
        XCTAssertEqual(ServeEvent.decode(#"{"type":"card_takeaway","id":"t1","text":"Done."}"#),
                       .cardLine(id: "t1", line: .takeaway("Done."), at: nil))
        XCTAssertEqual(ServeEvent.decode(#"{"type":"card_chips","id":"t1","chips":["Why?"],"at":3}"#),
                       .cardLine(id: "t1", line: .chips(["Why?"]), at: 3))
        XCTAssertEqual(ServeEvent.decode(#"{"type":"card_end","id":"t1"}"#), .cardEnd(id: "t1"))
        XCTAssertEqual(ServeEvent.decode(#"{"type":"card_item","id":"t1","item":{"note":"no label"}}"#), .unknown(type: "card_item"))
    }

    func testTheDraftKeepsItsDeclaredLayoutAsItGrows() {
        var draft = ExplainCardDraft(header: ExplainCardHeader(title: "States", layout: .flow))
        XCTAssertTrue(draft.add(.init(label: "One")))
        XCTAssertEqual(draft.card.layout, .flow, "a flow of one is still a flow while it grows")
        for n in 2...5 { XCTAssertTrue(draft.add(.init(label: "\(n)"))) }
        XCTAssertEqual(draft.card.layout, .flow)
        XCTAssertTrue(draft.add(.init(label: "6")))
        XCTAssertEqual(draft.card.layout, .steps, "a sixth part goes on as steps")
        XCTAssertTrue(draft.add(.init(label: "7")))
        XCTAssertFalse(draft.add(.init(label: "8")), "steps hold seven")
        var compare = ExplainCardDraft(header: ExplainCardHeader(title: "Pick", layout: .compare))
        for n in 1...3 { XCTAssertTrue(compare.add(.init(label: "\(n)"))) }
        XCTAssertFalse(compare.add(.init(label: "4")))
        XCTAssertEqual(ExplainCardDraft(header: ExplainCardHeader(title: "x")).layout, .list)
    }

    func testAnOpenCardWithNoPartsLaysOut() {
        for layout in ExplainCard.Layout.allCases {
            let empty = ExplainCard(title: "T", heading: "A heading", layout: layout, items: [])
            let l = ExplainCardLayout.make(empty, measure: ExplainCardTests.FixedMeasure())
            XCTAssertTrue(l.nodes.isEmpty && l.arrows.isEmpty && l.dividers.isEmpty)
            XCTAssertGreaterThan(l.card.height, l.titleBar.height)
            let one = ExplainCardLayout.make(ExplainCard(title: "T", heading: "A heading", layout: layout, items: [.init(label: "One")]),
                                             measure: ExplainCardTests.FixedMeasure())
            XCTAssertEqual(one.nodes.count, 1)
            XCTAssertEqual(one.heading?.frame.origin, l.heading?.frame.origin, "\(layout): the heading stays put as the body comes")
            XCTAssertGreaterThan(one.card.height, l.card.height, "\(layout): the body extends the card downward")
        }
    }

    // MARK: who owns a part

    /// Feeds the reply the way the engine sends it: spoken text as deltas, card lines as lines.
    func script(_ reply: [Any]) -> CardScript {
        var s = CardScript()
        var t = 0.0
        for piece in reply {
            t += 0.1
            if let text = piece as? String { s.delta(text, at: t) } else { _ = s.card(piece as! ExplainCardLine) }
        }
        return s
    }

    let open = ExplainCardLine.open(ExplainCardHeader(title: "Letter", layout: .flow))
    func item(_ label: String) -> ExplainCardLine { .item(.init(label: label)) }

    func testASentenceOwnsThePartsWrittenAfterItUntilTheNextOne() {
        var s = script([open, item("Early"), "You drop it in a box.\n", item("Box"), item("Slot"),
                        "A van takes it.\n", item("Van"), ExplainCardLine.takeaway("Postcodes win."), ExplainCardLine.chips(["Why?"])])
        XCTAssertEqual(s.owners, [nil, 0, 0, 1, 1])
        XCTAssertEqual(s.takeawayPart, 4)
        XCTAssertEqual(s.lines, ["You drop it in a box.", "A van takes it."])
        XCTAssertEqual(s.draft?.card.items.map(\.label), ["Early", "Box", "Slot", "Van"])
        XCTAssertEqual(s.draft?.chips, ["Why?"])
        s.finish(spoken: "You drop it in a box.\nA van takes it.\n", at: 1)
        XCTAssertTrue(s.ended)
        XCTAssertFalse(s.card(item("Late")), "nothing is added once the answer is in")
    }

    func testAPartOfASentenceStillBeingWrittenBelongsToIt() {
        // The engine may hold back a sentence's last space (pointing): the part still goes with it.
        let s = script([open, "You drop it in.", item("Box"), " A van", item("Van")])
        XCTAssertEqual(s.lines, ["You drop it in."])
        XCTAssertEqual(s.owners, [0, 1], "the van is in the sentence being written")
    }

    func testAResetTakesTheCardBack() {
        var s = script([open, "Let me look.\n", item("Box")])
        s.reset()
        XCTAssertNil(s.draft)
        XCTAssertTrue(s.owners.isEmpty && s.lines.isEmpty)
    }

    func testAFinishedAnswerWithItsLinesReadsAsIfItHadStreamed() {
        let answer = """
        card: {"title":"Letter","layout":"flow"}
        You drop it in.
        item: {"label":"Box"}
        A van takes it.
        item: {"label":"Van"}
        item: {broken
        chips: ["Why?"]
        """
        let (text, s) = CardScript.whole(answer, at: 5)
        XCTAssertEqual(text, "You drop it in.\nA van takes it.\n")
        XCTAssertEqual(s.owners, [0, 1])
        XCTAssertEqual(s.lines, ["You drop it in.", "A van takes it."])
        XCTAssertEqual(s.draft?.chips, ["Why?"])
        XCTAssertTrue(s.ended)
        let streamed = script([open, "You drop it in.\n", item("Box"), "A van takes it.\n", item("Van")])
        XCTAssertEqual(streamed.owners, s.owners)
    }

    func testLinesThatCameOnlyWithTheAnswerArePlacedByTheirPosition() {
        let spoken = "You drop it in.\nA van takes it.\n"
        let s = CardScript.replay(spoken: spoken, lines: [(open, 0), (item("Box"), 16), (item("Van"), 32), (.chips(["Why?"]), 32)], at: 2)
        XCTAssertEqual(s.owners, [0, 1])
        XCTAssertEqual(s.lines, ["You drop it in.", "A van takes it."])
        XCTAssertTrue(s.ended)
    }

    func testAnOlderFencedCardDrawsAtOnceAsBefore() {
        let card = ExplainCard(title: "States", layout: .flow, items: [.init(label: "A"), .init(label: "B")], takeaway: "T")
        let s = CardScript.fenced(card, spoken: "Two states. That's it.", at: 0)
        XCTAssertEqual(s.owners, [nil, nil, nil])
        XCTAssertEqual(s.lines.count, 2)
        var beat = CardBeat(clock: .estimate)
        beat.sync(s, now: 0)
        beat.advance(now: 0)
        XCTAssertEqual(beat.track.released.count, 1, "the first at once, the rest one after another at their own pace")
        var clock = 0.0
        while clock < 2 { clock += 0.01; beat.advance(now: clock) }
        XCTAssertTrue(beat.track.isDone)
        XCTAssertLessThan(beat.track.released.last!.end, 1.5, "all of it within a second or so, as the timer did")
    }

    // MARK: the planner

    func testPartsSpreadOverTheirSentenceWithALeadAndARestAtTheEnd() {
        let lines = [Line(start: 10, end: 13)]
        let slots = BeatPlanner.plan(lines: lines, parts: [Part(owner: 0, natural: 0.3)], released: [], now: 9).map { $0! }
        XCTAssertEqual(slots[0].at, 10 + BeatPlanner.lead, accuracy: 1e-9, "a small lead after the sentence starts")
        XCTAssertEqual(slots[0].draw, 0.3 * BeatPlanner.slowest, accuracy: 1e-9, "spare time is a rest, not a slow crawl")
        // Three parts in 1.2 s: spread to fill it.
        let three = BeatPlanner.plan(lines: [Line(start: 0, end: 1.5)], parts: Array(repeating: Part(owner: 0, natural: 0.3), count: 3),
                                     released: [], now: 0).map { $0! }
        let fit = (1.5 - BeatPlanner.tail - BeatPlanner.lead) / (0.9 + 2 * BeatPlanner.gap)
        for slot in three { XCTAssertEqual(slot.draw, 0.3 * fit, accuracy: 1e-9) }
        XCTAssertEqual(three[2].end, 1.5 - BeatPlanner.tail, accuracy: 1e-9, "the last part ends with the tail")
        XCTAssertEqual(three[1].at - three[0].end, BeatPlanner.gap * fit, accuracy: 1e-9)
    }

    func testFitIsClampedBetweenTheRushFloorAndTheSlowCeiling() {
        let many = Array(repeating: Part(owner: 0, natural: 0.3), count: 6)
        let tight = BeatPlanner.plan(lines: [Line(start: 0, end: 0.5)], parts: many, released: [], now: 0).map { $0! }
        XCTAssertEqual(tight[0].draw, 0.3 * BeatPlanner.rush, accuracy: 1e-9, "never faster than the rush floor")
        let roomy = BeatPlanner.plan(lines: [Line(start: 0, end: 30)], parts: many, released: [], now: 0).map { $0! }
        XCTAssertEqual(roomy[0].draw, 0.3 * BeatPlanner.slowest, accuracy: 1e-9, "never slower than the ceiling")
        XCTAssertEqual(roomy[1].at - roomy[0].end, BeatPlanner.gap * BeatPlanner.gapStretch, accuracy: 1e-9,
                       "the pauses inside the card stretch less than the parts")
        XCTAssertLessThan(roomy.last!.end, 30 - 20, "the spare time is a rest at the end of the sentence")
    }

    func testAnOpenSentenceStretchesLess() {
        let open = BeatPlanner.plan(lines: [Line(start: 0, end: 30, open: true)], parts: [Part(owner: 0, natural: 0.3)],
                                    released: [], now: 0).map { $0! }
        XCTAssertEqual(open[0].draw, 0.3 * BeatPlanner.openSlowest, accuracy: 1e-9)
    }

    func testPartsGoInStrictOrderAndOneWithoutItsSentenceHoldsTheRest() {
        let parts = [Part(owner: 0, natural: 0.3), Part(owner: 1, natural: 0.3), Part(owner: 2, natural: 0.3)]
        let lines = [Line(start: 0, end: 2), Line(start: nil, end: nil), Line(start: 4, end: 6)]
        let slots = BeatPlanner.plan(lines: lines, parts: parts, released: [], now: 0)
        XCTAssertNotNil(slots[0])
        XCTAssertNil(slots[1], "its sentence hasn't started")
        XCTAssertNil(slots[2], "held behind the part before it, though its own sentence is known")
        let none = BeatPlanner.plan(lines: [], parts: parts, released: [], now: 0)
        XCTAssertEqual(none.compactMap { $0 }.count, 0, "a part whose sentence isn't even written yet waits")
        // Strict order also across a sentence that starts late: the next never starts before the one before ends.
        let squeezed = BeatPlanner.plan(lines: [Line(start: 0, end: 0.6), Line(start: 0.2, end: 3)],
                                        parts: [Part(owner: 0, natural: 0.3), Part(owner: 0, natural: 0.3), Part(owner: 1, natural: 0.3)],
                                        released: [], now: 0).map { $0! }
        XCTAssertGreaterThanOrEqual(squeezed[2].at, squeezed[1].end - 1e-9)
    }

    func testPartsBeforeAnySentenceDrawAtOnce() {
        let slots = BeatPlanner.plan(lines: [Line(start: 50, end: 52)], parts: [Part(owner: nil, natural: 0.3), Part(owner: nil, natural: 0.3),
                                                                                Part(owner: 0, natural: 0.3)],
                                     released: [], now: 7).map { $0 }
        XCTAssertEqual(slots[0]?.at, 7)
        XCTAssertEqual(slots[0]?.draw, 0.3)
        XCTAssertEqual(slots[1]!.at, 7.3 + BeatPlanner.gap, accuracy: 1e-9)
        XCTAssertEqual(slots[2]!.at, 50 + BeatPlanner.lead, accuracy: 1e-9)
    }

    func testAVoiceAlreadyPastTheSentenceRushesItsParts() {
        let slots = BeatPlanner.plan(lines: [Line(start: 0, end: 2), Line(start: 2, end: 5)],
                                     parts: [Part(owner: 0, natural: 0.3), Part(owner: 0, natural: 0.3)], released: [], now: 3).map { $0! }
        XCTAssertEqual(slots[0].at, 3)
        XCTAssertEqual(slots[0].draw, 0.3 * BeatPlanner.rush, accuracy: 1e-9)
        XCTAssertEqual(slots[1].at, slots[0].end + BeatPlanner.gap * BeatPlanner.rush, accuracy: 1e-9)
    }

    func testReleasedPartsStayAndTheRestFollowThem() {
        var track = BeatTrack()
        for _ in 0..<3 { track.add(Part(owner: 0, natural: 0.3), now: 0) }
        let lines = [Line(start: 0, end: 3)]
        XCTAssertEqual(track.advance(lines, now: 0.2), 1)
        let first = track.released[0]
        XCTAssertEqual(track.advance(lines, now: 0.2), 0, "nothing new is due yet")
        let due = try! XCTUnwrap(track.nextDue(lines, now: 0.2))
        XCTAssertGreaterThan(due, first.end)
        XCTAssertEqual(track.advance(lines, now: due - 0.01), 0, "not before it is due")
        XCTAssertEqual(track.advance(lines, now: due), 1)
        XCTAssertEqual(track.released[1].at - first.end, BeatPlanner.gap * BeatPlanner.gapStretch, accuracy: 1e-9,
                       "the pause after a released part is kept")
        XCTAssertEqual(track.advance(lines, now: 10), 1)
        XCTAssertEqual(track.released[0], first, "a released part's slot is never moved")
        XCTAssertTrue(track.isDone)
    }

    func testCutOffDrawsEverythingLeftAtOnceAndAddsNothingLater() {
        var track = BeatTrack()
        track.add(Part(owner: 0, natural: 0.3), now: 0)
        track.add(Part(owner: 1, natural: 0.3), now: 0)
        let lines = [Line(start: 0, end: 2)]
        track.advance(lines, now: 0.2)
        track.hurry(now: 1)
        XCTAssertTrue(track.isDone, "the part waiting on a sentence never to be said is drawn now")
        XCTAssertEqual(track.released[1].at, max(1, track.released[0].end), accuracy: 1e-9)
        XCTAssertEqual(track.released[1].draw, 0.3 * BeatPlanner.rush, accuracy: 1e-9)
        track.add(Part(owner: 5, natural: 0.3), now: 2)
        XCTAssertTrue(track.isDone, "a part after the cut-off is drawn at once too, never left waiting")
    }

    // MARK: the sentences' clock

    func testWithoutAVoiceSentencesAreTimedByTheEstimate() {
        var lines = BeatLines(clock: .estimate)
        lines.sync(lines: ["You drop the letter in a post box.", "A van takes it."], ready: [1, 1.5], closed: false, at: 1.5)
        let t = lines.timings(now: 2)
        let first = BeatLines.seconds("You drop the letter in a post box.")
        XCTAssertEqual(first, 8.0 / 2.6, accuracy: 0.8, "about 2.6 words a second")
        XCTAssertEqual(t[0].start, 1)
        XCTAssertEqual(t[0].end!, 1 + first, accuracy: 1e-9)
        XCTAssertEqual(t[1].start!, 1 + first, accuracy: 1e-9, "the next starts when the one before has been said")
        XCTAssertTrue(t[1].open, "more parts may still come for the last sentence")
        XCTAssertFalse(t[0].open)
    }

    func testTheVoiceTimesEachSentenceFromItsWords() {
        var lines = BeatLines(clock: .voice)
        let a = "You drop it in.", b = "A van takes it away."
        lines.sync(lines: [a, b], ready: [0, 0], closed: true, at: 0)
        XCTAssertNil(lines.timings(now: 1)[0].start, "nothing said yet")
        let spoken = a + " " + b
        // Kokoro: a sentence's word marks arrive as it starts, some in the future.
        lines.heard(spoken: spoken, marks: [.init(at: 5, offset: 0), .init(at: 5.3, offset: 4), .init(at: 5.9, offset: 12)])
        var t = lines.timings(now: 5)
        XCTAssertEqual(t[0].start, 5)
        XCTAssertGreaterThan(t[0].end!, 5.9, "its end is estimated from its last word")
        XCTAssertNil(t[1].start)
        lines.heard(spoken: spoken, marks: [.init(at: 6.4, offset: 16)])
        t = lines.timings(now: 6.4)
        XCTAssertEqual(t[0].end, 6.4, "a sentence ends when the next one is heard")
        XCTAssertEqual(t[1].start, 6.4)
        lines.speechEnded(at: 7)
        t = lines.timings(now: 7)
        XCTAssertEqual(t[1].end, 7, "nothing is heard after the voice stops")
    }

    func testAVoiceThatStopsEarlyMakesTheRestPast() {
        var lines = BeatLines(clock: .voice)
        lines.sync(lines: ["One.", "Two.", "Three."], ready: [0, 0, 0], closed: true, at: 0)
        lines.speechEnded(at: 2)
        XCTAssertNil(lines.timings(now: 2)[0].start, "a stop before any word of this answer is the last answer's")
        lines.heard(spoken: "One. Two. Three.", marks: [.init(at: 3, offset: 0)])
        lines.speechEnded(at: 3.5)
        let t = lines.timings(now: 4)
        XCTAssertEqual(t[1].start, 3.5)
        XCTAssertEqual(t[2].end, 3.5)
    }

    func testANewAnswersVoiceDropsTheOldMarks() {
        var lines = BeatLines(clock: .voice)
        lines.heard(spoken: "Old answer.", marks: [.init(at: 1, offset: 0)])
        lines.heard(spoken: "New one.", marks: [])
        XCTAssertTrue(lines.marks.isEmpty)
        lines.heard(spoken: "New one. More.", marks: [.init(at: 2, offset: 0)])
        XCTAssertEqual(lines.marks.count, 1, "the same answer growing keeps its marks")
    }

    func testAVoiceThatNeverStartsFallsBackToTheEstimate() {
        var lines = BeatLines(clock: .voice)
        lines.sync(lines: ["One two three."], ready: [0], closed: true, at: 1)
        XCTAssertNil(lines.timings(now: 2)[0].start)
        let t = lines.timings(now: 1 + BeatLines.voiceGrace)
        XCTAssertEqual(t[0].start, 1 + BeatLines.voiceGrace)
    }

    func testTheVoiceFindsSentencesInTheWholeAnswerToo() {
        // Not streamed (a screenshot turn): the voice gets the whole answer as one text.
        var lines = BeatLines(clock: .voice)
        lines.sync(lines: ["First **thing**.", "Second."], ready: [0, 0], closed: true, at: 0)
        lines.heard(spoken: "First thing. Second.", marks: [.init(at: 1, offset: 0), .init(at: 1.4, offset: 6), .init(at: 2, offset: 13)])
        let t = lines.timings(now: 2)
        XCTAssertEqual(t[0].start, 1)
        XCTAssertEqual(t[0].end, 2)
        XCTAssertEqual(t[1].start, 2)
    }

    func testASentenceTheVoiceSaidDifferentlyDoesNotHoldUpTheRest() {
        var lines = BeatLines(clock: .voice)
        lines.sync(lines: ["One.", "Two 🙂 two.", "Three."], ready: [0, 0, 0], closed: true, at: 0)
        // The voice's own clean-up left the second sentence in a form not found word for word.
        lines.heard(spoken: "One. Two  two. Three.", marks: [.init(at: 1, offset: 0), .init(at: 1.5, offset: 5), .init(at: 2.5, offset: 15)])
        let t = lines.timings(now: 3)
        XCTAssertEqual(t[0].end, 2.5, "the first ends when the next sentence found is heard")
        XCTAssertEqual(t[1].start, 2.5)
        XCTAssertEqual(t[2].start, 2.5, "the one after it is still timed by its own words")
    }

    // MARK: a whole reply against a scripted voice

    /// The reply streams (card line, sentence, item, ...), then Kokoro-style milestones say when
    /// each sentence's words are heard. Each item must be drawn inside its own sentence: after it
    /// starts and before it ends; the first before the first sentence ends.
    func testEachItemIsDrawnWhileItsSentenceIsHeard() {
        let sentences = ["You drop the letter in a post box.", "At the sorting office a machine reads the postcode.",
                         "A van takes it out on the morning round.", "And it goes through your door."]
        let labels = ["Post box", "Sorting", "Van", "Door"]
        var script = CardScript()
        _ = script.card(open)
        var beat = CardBeat(clock: .voice)
        var t = 0.0
        beat.sync(script, now: t)
        // The model writes faster than the voice speaks: the whole reply is in by 1.2 s.
        for (s, label) in zip(sentences, labels) {
            t += 0.3
            script.delta(s + "\n", at: t)
            _ = script.card(item(label))
            beat.sync(script, now: t)
            beat.advance(now: t)
        }
        script.finish(spoken: sentences.map { $0 + "\n" }.joined(), at: t)
        beat.sync(script, now: t)
        XCTAssertEqual(beat.track.released.count, 0, "nothing is drawn before the voice says anything")

        // The voice: sentence k starts at starts[k]; its words are spread over its length.
        let spoken = sentences.joined(separator: " ")
        let starts = [1.5, 4.0, 7.2, 10.0], ends = [3.9, 7.1, 9.9, 12.0]
        var offset = 0
        var clock = 1.0
        var revealed: [Double] = []
        for k in sentences.indices {
            // Advance in 10 ms ticks up to this sentence's start, then report its milestones.
            while clock < starts[k] {
                clock += 0.01
                if beat.advance(now: clock) { revealed += beat.track.released[revealed.count...].map(\.at) }
            }
            let words = RevealTiming.tokenize(sentences[k]).filter { $0.word != nil }
            let marks = words.enumerated().map { i, w in
                SpokenProgress.Mark(at: starts[k] + (ends[k] - starts[k]) * Double(i) / Double(words.count), offset: offset + w.offset)
            }
            beat.lines.heard(spoken: spoken, marks: marks)
            offset += sentences[k].utf16.count + 1
        }
        while clock < 13 {
            clock += 0.01
            if beat.advance(now: clock) { revealed += beat.track.released[revealed.count...].map(\.at) }
        }
        XCTAssertEqual(revealed.count, 4)
        for k in sentences.indices {
            XCTAssertGreaterThanOrEqual(revealed[k], starts[k], "\(labels[k]) not before its sentence")
            XCTAssertLessThan(beat.track.released[k].end, ends[k], "\(labels[k]) drawn before its sentence ends")
        }
        XCTAssertLessThan(beat.track.released[0].end, ends[0], "the first part is up before the first sentence ends")
        XCTAssertNotNil(beat.chipsAt)
    }

    /// The same reply typed, read-aloud off: the estimate paces it like reading.
    func testWithoutAVoiceItemsFollowTheEstimate() {
        var script = CardScript()
        _ = script.card(open)
        let sentences = ["You drop the letter in a post box.", "A van takes it out on the morning round."]
        for (s, label) in zip(sentences, ["Box", "Van"]) {
            script.delta(s + "\n", at: 0)
            _ = script.card(item(label))
        }
        script.finish(spoken: sentences.map { $0 + "\n" }.joined(), at: 0)
        var beat = CardBeat(clock: .estimate)
        beat.sync(script, now: 0)
        var clock = 0.0
        while clock < 10 { clock += 0.01; beat.advance(now: clock) }
        let first = BeatLines.seconds(sentences[0])
        XCTAssertEqual(beat.track.released[0].at, BeatPlanner.lead, accuracy: 0.011)
        XCTAssertGreaterThanOrEqual(beat.track.released[1].at, first)
        XCTAssertLessThan(beat.track.released[1].end, first + BeatLines.seconds(sentences[1]))
    }

    /// Cut off in the second sentence: the rest is drawn at once and nothing waits on the voice.
    func testCutOffMidReplyFinishesTheCardAtOnce() {
        var script = CardScript()
        _ = script.card(open)
        for (s, label) in zip(["One two three four.", "Five six seven eight.", "Nine ten."], ["A", "B", "C"]) {
            script.delta(s + "\n", at: 0)
            _ = script.card(item(label))
        }
        var beat = CardBeat(clock: .voice)
        beat.sync(script, now: 0)
        beat.lines.heard(spoken: "One two three four. Five six seven eight. Nine ten.",
                         marks: [.init(at: 1, offset: 0), .init(at: 2, offset: 20)])
        beat.advance(now: 2.2)
        XCTAssertEqual(beat.track.released.count, 1)
        beat.cutOff(now: 2.5)
        XCTAssertTrue(beat.track.isDone)
        XCTAssertLessThan(beat.track.released.last!.end, 2.5 + 0.2)
        XCTAssertNotNil(beat.chipsAt, "the chips come once it is all drawn")
    }

    func testTheRevealDrawsEachItemOnItsSlot() {
        let slot = BeatPlanner.Slot(at: 5, draw: CardBeat.itemNatural)
        let r = ExplainCardReveal(beats: .init(opened: 4, items: [slot, nil], chips: nil), hasTakeaway: false)
        XCTAssertEqual(r.card(at: 4), 0)
        XCTAssertEqual(r.card(at: 4 + ExplainCardReveal.land), 1)
        XCTAssertEqual(r.item(0, at: 4.9), 0)
        XCTAssertEqual(r.item(0, at: 5 + CardBeat.itemNatural), 1)
        XCTAssertEqual(r.item(1, at: 100), 0, "not released: not drawn")
        XCTAssertEqual(r.arrow(0, at: 100), 0, "no arrow into a part not yet drawn")
        XCTAssertEqual(r.chips(at: 100), 0)
        let still = ExplainCardReveal(beats: .init(opened: 4, items: [slot]), hasTakeaway: false, reduceMotion: true)
        XCTAssertEqual(still.item(0, at: 4.9), 0, "Reduce Motion: still on its sentence")
        XCTAssertEqual(still.item(0, at: still.itemStart(0)), 1, "but without the fade")
    }
}
