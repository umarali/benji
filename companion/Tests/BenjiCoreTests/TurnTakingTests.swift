import XCTest
@testable import BenjiCore

/// Turn-taking that feels like talking to a person: a question ends a turn a little
/// sooner, an answer to Benji's own question gets time to think, and a press while Benji speaks
/// listens at once.
final class AdaptiveEndOfTurnTests: XCTestCase {
    func testAFinishedQuestionIsSentALittleSooner() {
        var e = UtteranceEndpointer(endSilence: 1.0)
        e.transcript("How do planes stay up?", at: 0)
        XCTAssertEqual(e.silenceNeeded, 0.75, accuracy: 1e-9)
        XCTAssertFalse(e.shouldEnd(at: 0.7))
        XCTAssertTrue(e.shouldEnd(at: 0.75))
    }

    func testAShortQuestionOrAShortSettingIsNotShortened() {
        var e = UtteranceEndpointer(endSilence: 1.0)
        e.transcript("Really?", at: 0)
        XCTAssertEqual(e.silenceNeeded, 1.0, accuracy: 1e-9)
        var quick = UtteranceEndpointer(endSilence: 0.5)
        quick.transcript("How do planes stay up?", at: 0)
        XCTAssertEqual(quick.silenceNeeded, 0.5, accuracy: 1e-9, "never longer than the setting")
        var slow = UtteranceEndpointer(endSilence: 0.7)
        slow.transcript("How do planes stay up?", at: 0)
        XCTAssertEqual(slow.silenceNeeded, HandsFreeSettings.questionSilenceFloor, accuracy: 1e-9)
    }

    func testAnsweringBenjisQuestionGetsTimeToThink() {
        var e = UtteranceEndpointer(endSilence: 1.0, patience: HandsFreeSettings.answerPatience)
        e.transcript("I think it's the wings", at: 0)
        XCTAssertEqual(e.silenceNeeded, 1.8, accuracy: 1e-9)
        e.transcript("I think it's the wings and", at: 0.5)
        XCTAssertEqual(e.silenceNeeded, 3.0, accuracy: 1e-9)
        var long = UtteranceEndpointer(endSilence: 2.0, patience: HandsFreeSettings.answerPatience)
        long.transcript("I think it's the wings and", at: 0)
        XCTAssertEqual(long.silenceNeeded, HandsFreeSettings.maximumSilence, accuracy: 1e-9)
        e.transcript("Is it the wings?", at: 1)
        XCTAssertEqual(e.silenceNeeded, 0.75, accuracy: 1e-9, "a question back still ends the turn")
    }

    func testPatienceFollowsAReplyThatAsked() {
        XCTAssertEqual(TurnPatience.after(reply: "Lift comes from the wings. What do you think pushes the plane forward?"),
                       HandsFreeSettings.answerPatience)
        XCTAssertEqual(TurnPatience.after(reply: "Lift comes from the wings."), 0)
        XCTAssertEqual(TurnPatience.after(reply: nil), 0)
        XCTAssertEqual(TurnPatience.after(reply: "Right? "), HandsFreeSettings.answerPatience)
    }
}

final class ListenNowTests: XCTestCase {
    func testAPressWhileBenjiSpeaksOpensTheMicWithoutTheResumeDelay() {
        var s = HandsFreeSession(settings: HandsFreeSettings())
        _ = s.update(HandsFreeSnapshot(phase: .speaking), at: 0)
        XCTAssertEqual(s.start(at: 0), [])
        // The press stopped the voice: the phase is idle and nothing is queued.
        XCTAssertEqual(s.listenNow(HandsFreeSnapshot(phase: .idle), at: 1), [.openMic])
        XCTAssertTrue(s.micOpen)
    }

    func testItForgetsAPendingEndAfterTheReply() {
        var s = HandsFreeSession(settings: HandsFreeSettings())
        _ = s.start(at: 0)
        XCTAssertEqual(s.utteranceFinished("open Mail, that's all", at: 1), [.submit("open Mail")])
        XCTAssertTrue(s.endAfterReply)
        _ = s.update(HandsFreeSnapshot(phase: .speaking), at: 2)
        XCTAssertEqual(s.listenNow(HandsFreeSnapshot(phase: .idle), at: 3), [.openMic])
        XCTAssertFalse(s.endAfterReply)
    }

    func testNothingOpensWhenTheMicMayNotListen() {
        var s = HandsFreeSession(settings: HandsFreeSettings())
        _ = s.start(at: 0)
        _ = s.utteranceFinished("delete it", at: 1)
        XCTAssertEqual(s.listenNow(HandsFreeSnapshot(phase: .awaitingApproval, approvalPending: true), at: 2), [])
        var off = HandsFreeSession(settings: HandsFreeSettings())
        XCTAssertEqual(off.listenNow(HandsFreeSnapshot(phase: .idle), at: 0), [])
    }
}
