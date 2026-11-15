import XCTest
@testable import BenjiCore

/// Cut-offs: what had been said when the user cut in, the reply the conversation keeps,
/// the panel line, and the engine request.
final class SpokenProgressTests: XCTestCase {
    let text = "Planes fly because the wings push air down. The engines push them forward."

    func testKokorosSentenceMilestonesSayWhatWasHeard() {
        var p = SpokenProgress()
        let first = SpeechFollow.milestones(sentence: "Planes fly because the wings push air down.", in: text,
                                            from: 0, duration: 2.0)!
        p.sentenceStarted(at: 100, milestones: first.milestones)
        XCTAssertEqual(p.heard(text, at: 99), "")
        XCTAssertEqual(p.heard(text, at: 100), "Planes")
        let midway = p.heard(text, at: 101)
        XCTAssertTrue(midway.hasPrefix("Planes fly because"), midway)
        XCTAssertFalse(midway.contains("down"), midway)
        XCTAssertEqual(p.heard(text, at: 102), "Planes fly because the wings push air down.")
        let second = SpeechFollow.milestones(sentence: "The engines push them forward.", in: text,
                                             from: first.end, duration: 1.5)!
        p.sentenceStarted(at: 102, milestones: second.milestones)
        XCTAssertEqual(p.heard(text, at: 102), "Planes fly because the wings push air down. The")
        XCTAssertEqual(p.heard(text, at: 110), text)
    }

    func testTheAppleVoicesWordCallbacksToo() {
        var p = SpokenProgress()
        p.reached(offset: 0, at: 1)
        p.reached(offset: 7, at: 1.3)   // "fly"
        XCTAssertEqual(p.heard(text, at: 1.31), "Planes fly")
        p.reset()
        XCTAssertEqual(p.heard(text, at: 5), "")
    }

    func testAnOffsetPastTheTextKeepsItAll() {
        var p = SpokenProgress()
        p.reached(offset: 500, at: 0)
        XCTAssertEqual(p.heard("Short.", at: 1), "Short.")
    }
}

final class CutOffReplyTests: XCTestCase {
    let full = "Planes fly because the **wings** push air down. The engines push them forward."

    func testWhatWasHeardIsKeptAndMarked() {
        let r = CutOffReply.reply(heard: "Planes fly because the wings", full: full)
        XCTAssertEqual(r, "Planes fly because the wings … \(CutOffReply.marker)")
        XCTAssertTrue(CutOffReply.isCutOff(r))
    }

    func testNothingHeardSaysSo() {
        XCTAssertEqual(CutOffReply.reply(heard: "  ", full: full), CutOffReply.unheard)
        XCTAssertTrue(CutOffReply.isCutOff(CutOffReply.unheard))
    }

    func testAnAnswerHeardToTheEndStaysWhole() {
        let all = "Planes fly because the wings push air down. The engines push them forward."
        XCTAssertEqual(CutOffReply.reply(heard: all, full: full), full)
        XCTAssertFalse(CutOffReply.isCutOff(full))
    }

    func testWhileTheAnswerIsStillBeingWrittenTheRestIsAlwaysUnsaid() {
        XCTAssertEqual(CutOffReply.reply(heard: "Planes fly.", full: nil), "Planes fly. … \(CutOffReply.marker)")
    }

    func testThePanelShowsWhatWasSaidWithADash() {
        XCTAssertEqual(CutOffReply.shown(heard: "Planes fly because "), "Planes fly because —")
        XCTAssertNil(CutOffReply.shown(heard: ""))
    }

    func testTheMarksStartAsThePromptSays() {
        // benji/prompts.py CUT_OFF_MARK; selftest checks the same from the engine's side.
        XCTAssertTrue(CutOffReply.marker.hasPrefix("[cut off"))
        XCTAssertTrue(CutOffReply.unheard.hasPrefix("[cut off"))
        XCTAssertTrue(CutOffReply.marker.hasSuffix("]"))
    }
}

final class CutOffMemoryTests: XCTestCase {
    func testTheLastAnswerIsReplacedAndTheRestKept() {
        var m = ConversationMemory()
        m.record(user: "hi", assistant: "Hello.")
        m.record(user: "how do planes fly?", assistant: "Long answer.")
        m.cutOffLast(reply: "Long … \(CutOffReply.marker)")
        XCTAssertEqual(m.exchanges.map(\.assistant), ["Hello.", "Long … \(CutOffReply.marker)"])
        XCTAssertEqual(m.exchanges.last?.user, "how do planes fly?")
    }

    func testNothingToCutIsANoOp() {
        var m = ConversationMemory()
        m.cutOffLast(reply: "x")
        XCTAssertTrue(m.isEmpty)
        m.record(user: "a", assistant: "b")
        m.cutOffLast(reply: "   ")
        XCTAssertEqual(m.exchanges.last?.assistant, "b")
    }
}

final class CutOffStateTests: XCTestCase {
    func testThePanelLineShowsWhatWasSaidAndANoteFollows() {
        var s = CompanionState()
        reduce(&s, .submitText("how do planes fly?"))
        reduce(&s, .assistantAnswer("Planes fly because the wings push air down. The engines push."))
        let id = s.lines.last!.id
        reduce(&s, .answerCutOff(shown: "Planes fly because —"))
        XCTAssertEqual(s.lines.map(\.role), [.user, .assistant, .system])
        XCTAssertEqual(s.lines[1].text, "Planes fly because —")
        XCTAssertEqual(s.lines[1].id, id)
        XCTAssertEqual(s.lines[2].text, CutOffReply.notice)
    }

    func testAnEarlierAnswerIsNeverRewritten() {
        var s = CompanionState()
        reduce(&s, .submitText("one"))
        reduce(&s, .assistantAnswer("First."))
        reduce(&s, .submitText("two"))
        reduce(&s, .answerCutOff(shown: "Fi —"))
        XCTAssertEqual(s.lines.filter { $0.role == .assistant }.map(\.text), ["First."])
        XCTAssertEqual(s.lines.last?.text, CutOffReply.notice)
    }

    func testTheServeRequestNamesTheTurnAndTheReply() {
        let line = String(decoding: ServeRequest.cutOff(id: "t3", reply: "Planes … [cut off]").line(), as: UTF8.self)
        XCTAssertEqual(line, #"{"id":"t3","reply":"Planes … [cut off]","type":"cut_off"}"# + "\n")
    }
}
