import XCTest
@testable import BenjiCore

/// D-118 step 1: serve and streaming by default, what a streaming reply may show and say, the
/// sentences the voice starts on early, and the local latency record.
final class FastPathTests: XCTestCase {

    // MARK: defaults

    func testServeIsTheDefaultAndOneShotIsTheWayBack() {
        XCTAssertTrue(FastPath.usesServe(nil))
        XCTAssertTrue(FastPath.usesServe("serve"))       // set by hand before D-118: still serve
        XCTAssertTrue(FastPath.usesServe("anything"))
        XCTAssertFalse(FastPath.usesServe("oneshot"))
        XCTAssertFalse(FastPath.usesServe(" OneShot "))
    }

    func testStreamingIsOnUnlessTurnedOff() {
        XCTAssertTrue(FastPath.streams(nil))
        XCTAssertTrue(FastPath.streams(true))
        XCTAssertFalse(FastPath.streams(false))
        XCTAssertEqual(FastPath.engineStreamValue(nil), "1")
        XCTAssertEqual(FastPath.engineStreamValue(false), "0")
    }

    // MARK: protocol

    func testDeltaEventsDecode() {
        XCTAssertEqual(ServeEvent.decode(#"{"type":"delta","id":"t1","text":"Hel"}"#), .delta(id: "t1", text: "Hel"))
        XCTAssertEqual(ServeEvent.decode(#"{"type":"delta_reset","id":"t1"}"#), .deltaReset(id: "t1"))
    }

    // MARK: what may show

    func testVisibleStopsAtAFence() {
        XCTAssertEqual(StreamingReply.visible("A plane has wings.\n\n```figure\n{\"title\""), "A plane has wings.\n\n")
        XCTAssertEqual(StreamingReply.visible("Here it is.\n``"), "Here it is.\n")   // maybe a fence: held
        XCTAssertEqual(StreamingReply.visible("Use `ls` to list."), "Use `ls` to list.")
        XCTAssertEqual(StreamingReply.visible("Use `ls"), "Use `ls")
        XCTAssertEqual(StreamingReply.visible("No fence at all"), "No fence at all")
    }

    // MARK: sentences

    /// Feeds `pieces` as a stream would arrive, returning every sentence handed out.
    private func stream(_ pieces: [String], finish final: String? = nil) -> (said: [String], rest: String?) {
        var s = SentenceStream()
        var text = ""
        var said: [String] = []
        for p in pieces {
            text += p
            said += s.feed(StreamingReply.visible(text))
        }
        let rest = final.flatMap { s.finish($0) }
        return (said, rest)
    }

    func testSentencesComeOutAsSoonAsTheyAreComplete() {
        var s = SentenceStream()
        XCTAssertEqual(s.feed("Sure"), [])
        XCTAssertEqual(s.feed("Sure."), [])                 // can't tell yet: maybe "Sure.com"
        XCTAssertEqual(s.feed("Sure. It"), ["Sure."])
        XCTAssertEqual(s.feed("Sure. It is 4 pm"), [])
        XCTAssertEqual(s.feed("Sure. It is 4 pm in Lahore! And"), ["It is 4 pm in Lahore!"])
        XCTAssertEqual(s.finish("Sure. It is 4 pm in Lahore! And that's it."), "And that's it.")
    }

    func testAbbreviationsInitialsAndListNumbersDoNotEndASentence() {
        let r = stream(["Use e.g. a ", "file. J. Smith ", "said so. ", "Steps:\n1. Open it.\n2. Save it.\n"])
        XCTAssertEqual(r.said, ["Use e.g. a file.", "J. Smith said so.", "Steps:", "1. Open it.", "2. Save it."])
    }

    func testLineBreaksEndASentence() {
        XCTAssertEqual(stream(["One line\nTwo"]).said, ["One line"])
    }

    func testClosingQuotesGoWithTheSentence() {
        XCTAssertEqual(stream(["He said \"stop.\" Then"]).said, ["He said \"stop.\""])
    }

    func testFinishSaysOnlyWhatIsLeft() {
        let r = stream(["First one. Second"], finish: "First one. Second one.")
        XCTAssertEqual(r.said, ["First one."])
        XCTAssertEqual(r.rest, "Second one.")
    }

    func testFinishWithNothingLeftIsNil() {
        let r = stream(["All said. "], finish: "All said.")
        XCTAssertEqual(r.said, ["All said."])
        XCTAssertNil(r.rest)
    }

    func testFigureBlockIsNeverSaid() {
        let r = stream(["A plane flies on its wings. ", "```figure\n{\"title\":\"Plane. Wings. \"}"],
                       finish: "A plane flies on its wings.")
        XCTAssertEqual(r.said, ["A plane flies on its wings."])
        XCTAssertNil(r.rest)
    }

    func testALineEndingBeforeAFigureIsNotSaidAgain() {
        // The user's live round (D-164): "Here's a kettle." ends at a line break, the figure block
        // follows, and the finished answer is trimmed: the last word used to be said again.
        let r = stream(["Here's a kettle.\n", "```figure\n{\"title\":\"A kettle\"}\n```"], finish: "Here's a kettle.")
        XCTAssertEqual(r.said, ["Here's a kettle."])
        XCTAssertNil(r.rest)
        let two = stream(["It boils water.\nThe lid lifts.\n", "```figure\n{}\n```"], finish: "It boils water.\nThe lid lifts.")
        XCTAssertEqual(two.said, ["It boils water.", "The lid lifts."])
        XCTAssertNil(two.rest)
        // Words after the block are still said, once.
        let after = stream(["Here's a kettle.\n", "```figure\n{}\n```\nTurn it with the mouse."],
                           finish: "Here's a kettle.\nTurn it with the mouse.")
        XCTAssertEqual(after.rest, "Turn it with the mouse.")
    }

    func testResetStartsANewSegmentAndKeepsWhatWasSaid() {
        var s = SentenceStream()
        XCTAssertEqual(s.feed("Let me check. "), ["Let me check."])
        s.reset()   // that text came before a tool call
        XCTAssertEqual(s.feed("You have two"), [])
        XCTAssertEqual(s.finish("You have two meetings."), "You have two meetings.")
        XCTAssertTrue(s.spokeAny)
    }

    func testAMismatchedFinishResumesAtAWordBoundary() {
        var s = SentenceStream()
        XCTAssertEqual(s.feed("Your build is green. "), ["Your build is green."])
        // Not expected from the engine, but never repeat a word or cut one in half.
        XCTAssertEqual(s.finish("Your build is great now."), "great now.")   // "Your build is" was said
    }

    // MARK: latency

    func testLatencyStagesInOrderAndOnlyThoseThatHappened() {
        var l = TurnLatency()
        l.mark(.keyUp, at: 10.0)
        l.mark(.transcript, at: 10.3)
        l.mark(.sent, at: 10.31)
        l.mark(.firstText, at: 11.0)
        l.mark(.firstText, at: 12.0)            // the first time wins
        l.mark(.firstSentence, at: 11.2)
        l.mark(.firstAudio, at: 11.5)
        l.mark(.answer, at: 12.5)
        l.mark(.finished, at: 12.6)
        let names = l.stages.map(\.0)
        XCTAssertEqual(names, ["release_to_transcript_ms", "transcript_to_sent_ms", "sent_to_first_text_ms",
                               "first_text_to_first_sentence_ms", "first_sentence_to_first_audio_ms",
                               "sent_to_first_audio_ms", "sent_to_answer_ms", "release_to_first_audio_ms",
                               "sent_to_finished_ms"])
        XCTAssertEqual(l.ms(.sent, .firstText), 690)
        XCTAssertEqual(l.ms(.keyUp, .firstAudio), 1500)
    }

    func testATypedTurnHasNoKeyStages() {
        var l = TurnLatency()
        l.mark(.sent, at: 1)
        l.mark(.answer, at: 2)
        XCTAssertEqual(l.stages.map(\.0), ["sent_to_answer_ms"])
    }

    func testLatencyLineHoldsNumbersAndSwitchesOnly() throws {
        var l = TurnLatency()
        l.spoken = true
        l.backend = "serve"
        l.streamed = true
        l.mark(.sent, at: 0)
        l.mark(.answer, at: 0.25)
        let line = l.jsonLine(at: Date(timeIntervalSince1970: 0))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["ts", "spoken", "screen", "backend", "streamed", "sent_to_answer_ms"])
        XCTAssertEqual(obj["sent_to_answer_ms"] as? Int, 250)
        XCTAssertEqual(obj["backend"] as? String, "serve")
        XCTAssertFalse(line.contains("\n"))
    }
}
