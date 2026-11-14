import XCTest
@testable import BenjiCore

/// D-98: the heard mark, the activity line, Retry for cut-off turns, the thinking dots, the
/// read-aloud rule and the meter's smoothing.
final class ActivityLineTests: XCTestCase {
    func testWordingAndOrder() {
        XCTAssertNil(ActivityLine.text([]))
        XCTAssertEqual(ActivityLine.text([.lookedAtScreen]), "Looked at your screen")
        XCTAssertEqual(ActivityLine.text([.lookedAtScreen, .ranCommand, .savedFile(name: "notes.md"), .drewOnScreen]),
                       "Looked at your screen · Ran a command · Saved notes.md · Drew on your screen")
        XCTAssertEqual(ActivityLine.text([.lookedOnline, .readFile, .lookedThroughFiles, .ranAutomation,
                                          .ranShortcut, .remembered]),
                       "Looked online · Read a file · Looked through your files · Ran an automation · "
                       + "Ran a Shortcut · Remembered something")
    }

    func testRepeatsAreCountedInFirstSeenOrder() {
        XCTAssertEqual(ActivityLine.text([.ranCommand, .readFile, .ranCommand, .ranCommand, .readFile]),
                       "Ran 3 commands · Read 2 files")
        XCTAssertEqual(ActivityLine.text([.ranShortcut, .ranShortcut, .ranAutomation, .ranAutomation, .lookedOnline,
                                          .lookedOnline]),
                       "Ran 2 Shortcuts · Ran 2 automations · Looked online")
    }

    func testSavedFilesNameAtMostTwo() {
        XCTAssertEqual(ActivityLine.text([.savedFile(name: "a.md"), .savedFile(name: "b.md")]), "Saved a.md and b.md")
        XCTAssertEqual(ActivityLine.text([.savedFile(name: "a.md"), .savedFile(name: "a.md")]), "Saved a.md")
        XCTAssertEqual(ActivityLine.text([.savedFile(name: "a"), .savedFile(name: "b"), .savedFile(name: "c")]),
                       "Saved 3 files")
        XCTAssertEqual(ActivityLine.text([.savedFile(name: nil)]), "Saved a file")
        XCTAssertEqual(ActivityLine.text([.savedFile(name: "a"), .savedFile(name: nil)]), "Saved 2 files")
    }

    func testApprovalsSayWhatWasAskedAndTheOutcome() {
        XCTAssertEqual(ActivityLine.text([.asked(action: "overwrite existing file", outcome: .allowed),
                                          .savedFile(name: "keep.txt")]),
                       "Asked to overwrite existing file, you allowed it · Saved keep.txt")
        XCTAssertEqual(ActivityLine.text([.asked(action: "run the Shortcut 'Tidy'", outcome: .declined)]),
                       "Asked to run the Shortcut 'Tidy', you said no")
        XCTAssertEqual(ActivityLine.text([.asked(action: "x", outcome: .noAnswer), .asked(action: "x", outcome: .stopped)]),
                       "Asked to x, no answer, so no · Asked to x, stopped")
        XCTAssertEqual(ActivityLine.text([.asked(action: " ", outcome: .allowed)]), "Asked first, you allowed it")
    }

    func testEngineKinds() {
        XCTAssertEqual(TurnActivity(kind: "command", name: nil), .ranCommand)
        XCTAssertEqual(TurnActivity(kind: "file_saved", name: "plan.md"), .savedFile(name: "plan.md"))
        // A path that slipped through becomes its file name; an empty one is just "a file".
        XCTAssertEqual(TurnActivity(kind: "file_saved", name: "/Users/me/secret/plan.md"), .savedFile(name: "plan.md"))
        XCTAssertEqual(TurnActivity(kind: "file_saved", name: ""), .savedFile(name: nil))
        XCTAssertEqual(TurnActivity(kind: "web", name: nil), .lookedOnline)
        XCTAssertNil(TurnActivity(kind: "teleported", name: nil))
    }
}

final class TurnTrailTests: XCTestCase {
    /// A typed message that went to the engine.
    private func sent(_ text: String = "tidy my desktop") -> CompanionState {
        var s = CompanionState()
        reduce(&s, .submitText(text))
        reduce(&s, .turnSent)
        return s
    }

    func testAnsweredTurnIsHeardAndTellsWhatHappened() {
        var s = CompanionState()
        reduce(&s, .submitText("what's here?"))
        reduce(&s, .engineAccepted)
        XCTAssertFalse(s.turns[0].heard, "only a message that was sent can be heard")
        reduce(&s, .turnSent)
        reduce(&s, .engineAccepted)
        XCTAssertTrue(s.turns[0].heard)
        reduce(&s, .screenAttached(id: "a", summary: "Screen attached"))
        reduce(&s, .screenAttached(id: "b", summary: "Screen attached"))
        reduce(&s, .activity(.lookedThroughFiles))
        reduce(&s, .assistantAnswer("Two files."))
        XCTAssertNil(s.turns[0].activityLine, "the line waits for the turn to finish")
        reduce(&s, .backendFinished(0))
        XCTAssertFalse(s.turns[0].cutOff)
        XCTAssertEqual(s.turns[0].activityLine, "Looked at your screen · Looked through your files")
        XCTAssertNil(s.retryableTurn)
    }

    func testDrawingIsOneActivity() {
        var s = sent()
        reduce(&s, .assistantAnswer("There."))
        reduce(&s, .activity(.drewOnScreen))
        reduce(&s, .activity(.drewOnScreen))
        reduce(&s, .backendFinished(0))
        XCTAssertEqual(s.turns[0].activityLine, "Drew on your screen")
    }

    func testEndingWithoutAnAnswerIsCutOff() {
        var crashed = sent()
        reduce(&crashed, .backendError("Benji's backend (the engine) stopped unexpectedly (exit code 1)."))
        reduce(&crashed, .backendFinished(1))
        XCTAssertTrue(crashed.turns[0].cutOff)
        XCTAssertNotNil(crashed.retryableTurn)

        var stopped = sent()
        reduce(&stopped, .cancel)
        XCTAssertTrue(stopped.turns[0].cutOff)
        XCTAssertEqual(stopped.phase, .idle)
    }

    func testAMessageThatNeverLeftIsNotCutOff() {
        // Screen Ask: Cancel on the card (or its timeout) before anything was sent.
        var s = CompanionState()
        reduce(&s, .submitText("look at this"))
        reduce(&s, .cancel)
        XCTAssertTrue(s.turns[0].finished)
        XCTAssertFalse(s.turns[0].cutOff)
        XCTAssertNil(s.retryableTurn)
    }

    func testApprovalOutcomesFoldIntoTheActivityLine() {
        var s = sent()
        reduce(&s, .approvalRequested(ApprovalRequest(id: "1", action: "overwrite existing file", target: "/x/keep.txt")))
        reduce(&s, .approvalResolved(true))
        reduce(&s, .activity(.savedFile(name: "keep.txt")))
        reduce(&s, .approvalRequested(ApprovalRequest(id: "2", action: "run a potentially destructive shell command",
                                                      target: "rm -rf build")))
        reduce(&s, .approvalTimedOut)
        reduce(&s, .assistantAnswer("Saved it; left the build folder alone."))
        reduce(&s, .backendFinished(0))
        // The outcome lines are still recorded...
        XCTAssertEqual(s.lines.filter { $0.role == .system }.count, 2)
        // ...but told once, by the activity line, never with the target.
        let rows = PanelTranscript.rows(s.lines, turns: s.turns)
        XCTAssertEqual(rows.map(\.line.role), [.user, .assistant])
        XCTAssertEqual(rows[1].footer?.activity,
                       "Asked to overwrite existing file, you allowed it · Saved keep.txt · "
                       + "Asked to run a potentially destructive shell command, no answer, so no")
        XCTAssertFalse(rows[1].footer?.activity?.contains("rm -rf") ?? true)
        // Without the turns (older callers) the rows are as before.
        XCTAssertEqual(PanelTranscript.rows(s.lines).map(\.line.role), [.user, .system, .system, .assistant])
    }

    func testStoppingDuringAnApprovalIsToldAsStopped() {
        var s = sent()
        reduce(&s, .approvalRequested(ApprovalRequest(id: "1", action: "overwrite existing file", target: "x")))
        reduce(&s, .cancel)
        XCTAssertEqual(s.turns[0].activities, [.asked(action: "overwrite existing file", outcome: .stopped)])
        XCTAssertTrue(s.turns[0].cutOff)
        let rows = PanelTranscript.rows(s.lines, turns: s.turns)
        XCTAssertEqual(rows.map(\.line.role), [.user])
        XCTAssertEqual(rows[0].footer, PanelTurnFooter(activity: "Asked to overwrite existing file, stopped",
                                                        cutOff: true, canRetry: true))
    }

    func testRetryStartsTheSameMessageAgainFromTheTop() {
        var s = sent("where's the save button?")
        let userID = s.turns[0].userLineID
        reduce(&s, .screenAttached(id: "old", summary: "Screen attached"))
        reduce(&s, .engineAccepted)
        reduce(&s, .backendError("timed out"))
        reduce(&s, .backendFinished(1))
        XCTAssertEqual(s.phase, .error)

        reduce(&s, .retry)
        XCTAssertEqual(s.phase, .thinking)
        XCTAssertNil(s.lastError)
        // The failed attempt (its old screen mark and error) is gone; the message stays.
        XCTAssertEqual(s.lines.map(\.id), [userID])
        XCTAssertEqual(s.turns.count, 1)
        XCTAssertEqual(s.turns[0].userLineID, userID)
        XCTAssertFalse(s.turns[0].heard)
        XCTAssertFalse(s.turns[0].sent)
        XCTAssertTrue(s.turns[0].activities.isEmpty)
        XCTAssertNil(PanelTranscript.rows(s.lines, turns: s.turns)[0].screen)

        reduce(&s, .turnSent)
        reduce(&s, .assistantAnswer("Top right."))
        reduce(&s, .backendFinished(0))
        XCTAssertFalse(s.turns[0].cutOff)
        XCTAssertNil(s.retryableTurn)
    }

    func testARetryCancelledBeforeSendingStaysRetryable() {
        var s = sent()
        reduce(&s, .cancel)
        reduce(&s, .retry)        // Screen Ask asks again...
        reduce(&s, .cancel)       // ...and the user cancels the card
        XCTAssertTrue(s.turns[0].cutOff)
        XCTAssertNotNil(s.retryableTurn)
    }

    func testRetryIsOnlyForTheLastTurnAndNeverWhileBusy() {
        var s = sent("first")
        reduce(&s, .cancel)
        reduce(&s, .submitText("second"))
        reduce(&s, .retry)        // busy with the second
        XCTAssertEqual(s.lines.map(\.text), ["first", "second"])
        reduce(&s, .turnSent)
        reduce(&s, .assistantAnswer("Done."))
        reduce(&s, .backendFinished(0))
        XCTAssertNil(s.retryableTurn, "the cut-off turn isn't the last one any more")
        reduce(&s, .retry)
        XCTAssertEqual(s.lines.map(\.text), ["first", "second", "Done."])
        let rows = PanelTranscript.rows(s.lines, turns: s.turns)
        XCTAssertEqual(rows[0].footer, PanelTurnFooter(activity: nil, cutOff: true, canRetry: false))
    }

    func testSpokenTurnsRetrySpoken() {
        var s = CompanionState()
        reduce(&s, .transcribed("what's the weather"))
        reduce(&s, .turnSent)
        reduce(&s, .backendFinished(1))
        XCTAssertEqual(s.retryableTurn?.spoken, true)
    }

    func testFooterSitsUnderTheTurnsLastRowAndHidesRetryWhileBusy() {
        var s = sent("one")
        reduce(&s, .backendError("The engine stopped."))
        reduce(&s, .backendFinished(1))
        var rows = PanelTranscript.rows(s.lines, turns: s.turns)
        XCTAssertEqual(rows.map(\.line.role), [.user, .error])
        XCTAssertNil(rows[0].footer)
        XCTAssertEqual(rows[1].footer?.cutOff, true)
        XCTAssertEqual(rows[1].footer?.canRetry, true)
        rows = PanelTranscript.rows(s.lines, turns: s.turns, busy: true)
        XCTAssertEqual(rows[1].footer?.canRetry, false)
    }

    func testHeardMarkOnTheMessage() {
        var s = sent()
        reduce(&s, .engineAccepted)
        let rows = PanelTranscript.rows(s.lines, turns: s.turns)
        XCTAssertTrue(rows[0].heard)
        XCTAssertNil(rows[0].footer, "nothing under a turn still running")
    }

    func testThinkingDotsOnlyWhileWaitingForTheAnswer() {
        var s = CompanionState()
        XCTAssertFalse(s.showsThinking)
        reduce(&s, .submitText("hi"))
        XCTAssertFalse(s.showsThinking, "not before it is sent (Screen Ask card, capture)")
        reduce(&s, .turnSent)
        XCTAssertTrue(s.showsThinking)
        reduce(&s, .approvalRequested(ApprovalRequest(id: "1", action: "a", target: "")))
        XCTAssertFalse(s.showsThinking, "the card is the sign of life")
        reduce(&s, .approvalResolved(false))
        XCTAssertTrue(s.showsThinking)
        reduce(&s, .assistantAnswer("Hello."))
        XCTAssertFalse(s.showsThinking)
    }

    func testNewConversationClearsTurns() {
        var s = sent()
        reduce(&s, .backendFinished(1))
        reduce(&s, .newConversation)
        XCTAssertTrue(s.turns.isEmpty)
        XCTAssertNil(s.retryableTurn)
    }

    func testANewMessageClosesAnUnfinishedOne() {
        // A capture that failed never started a run; the next message moves on without a Retry.
        var s = CompanionState()
        reduce(&s, .submitText("look"))
        reduce(&s, .backendError("Screen capture failed. Your message wasn't sent."))
        reduce(&s, .submitText("never mind"))
        XCTAssertEqual(s.turns.count, 2)
        XCTAssertTrue(s.turns[0].finished)
        XCTAssertFalse(s.turns[0].cutOff)
    }
}

final class PanelLiveTests: XCTestCase {
    func testReadAloud() {
        XCTAssertFalse(ReadAloud.isOn(nil), "off by default: Benji's old rule")
        XCTAssertTrue(ReadAloud.isOn(true))
        XCTAssertFalse(ReadAloud.isOn("yes"))
        XCTAssertTrue(ReadAloud.speaks(setting: false, spoken: true), "a spoken message is always answered aloud")
        XCTAssertFalse(ReadAloud.speaks(setting: false, spoken: false))
        XCTAssertTrue(ReadAloud.speaks(setting: true, spoken: false))
        XCTAssertTrue(ReadAloud.help(on: true).hasPrefix("Read answers aloud"))
        XCTAssertTrue(ReadAloud.help(on: false).hasPrefix("Read answers aloud"))
    }

    func testLevelRisesFastFallsSlowly() {
        var m = LevelSmoother()
        let step = 2048.0 / 48_000                    // one mic buffer
        let up = m.update(1, at: 0)
        XCTAssertGreaterThan(up, 0.3)
        var t = 0.0
        for _ in 0..<5 { t += step; _ = m.update(1, at: t) }
        XCTAssertGreaterThan(m.value, 0.99)
        t += step
        let down = m.update(0.01, at: t)
        XCTAssertGreaterThan(down, 0.6, "one buffer of quiet doesn't drop the bars")
        XCTAssertLessThan(down, 1)
        // Rising takes a bigger share of the gap per buffer than falling.
        var a = LevelSmoother(), b = LevelSmoother()
        _ = a.update(0.5, at: 0); _ = b.update(0.5, at: 0)
        for i in 1...20 { _ = a.update(0.5, at: Double(i) * step); _ = b.update(0.5, at: Double(i) * step) }
        let rise = a.update(1, at: 21 * step) - 0.5
        let fall = 0.5 - b.update(0.01, at: 21 * step)
        XCTAssertGreaterThan(rise / 0.5, fall / 0.49)
    }

    func testLevelZeroClearsAndInputIsClamped() {
        var m = LevelSmoother()
        _ = m.update(0.8, at: 0)
        XCTAssertEqual(m.update(0, at: 0.01), 0)
        XCTAssertEqual(m.value, 0)
        XCTAssertLessThanOrEqual(m.update(7, at: 1), 1)
        XCTAssertEqual(m.update(-1, at: 2), 0)
    }
}

/// (6) Retry never repeats a side effect: a cut-off turn that had already changed something
/// says so and offers no Retry; one that only looked or read can be retried.
final class RetrySideEffectTests: XCTestCase {
    private func cutOff(after activities: [TurnActivity]) -> CompanionState {
        var s = CompanionState()
        reduce(&s, .submitText("tidy my desktop"))
        reduce(&s, .turnSent)
        activities.forEach { reduce(&s, .activity($0)) }
        reduce(&s, .cancel)
        return s
    }

    func testChangesAreTheOnlyActivitiesThatBlockRetry() {
        for changing: TurnActivity in [.ranCommand, .savedFile(name: "a.md"), .ranAutomation, .ranShortcut, .remembered,
                                       .asked(action: "x", outcome: .allowed)] {
            XCTAssertTrue(changing.changesSomething, "\(changing)")
        }
        for looking: TurnActivity in [.lookedAtScreen, .readFile, .lookedThroughFiles, .lookedOnline, .drewOnScreen,
                                      .asked(action: "x", outcome: .declined), .asked(action: "x", outcome: .noAnswer),
                                      .asked(action: "x", outcome: .stopped)] {
            XCTAssertFalse(looking.changesSomething, "\(looking)")
        }
    }

    func testCutOffAfterACommandHasNoRetryAndSaysWhy() {
        var s = cutOff(after: [.lookedAtScreen, .ranCommand])
        XCTAssertTrue(s.turns[0].cutOff)
        XCTAssertNil(s.retryableTurn)
        let footer = PanelTranscript.rows(s.lines, turns: s.turns).last?.footer
        XCTAssertEqual(footer?.canRetry, false)
        XCTAssertEqual(footer?.cutOffText, TurnTrail.cutOffAfterChangeLine)
        // A Retry event (a stale button) does nothing.
        let before = s
        reduce(&s, .retry)
        XCTAssertEqual(s, before)
    }

    func testCutOffAfterOnlyLookingCanBeRetried() {
        let s = cutOff(after: [.lookedAtScreen, .readFile, .lookedOnline])
        XCTAssertNotNil(s.retryableTurn)
        let footer = PanelTranscript.rows(s.lines, turns: s.turns).last?.footer
        XCTAssertEqual(footer?.canRetry, true)
        XCTAssertEqual(footer?.cutOffText, TurnTrail.cutOffLine)
    }

    func testAnApprovedActionBlocksRetryEvenWithoutAnActivityEvent() {
        var s = CompanionState()
        reduce(&s, .submitText("delete the old build"))
        reduce(&s, .turnSent)
        reduce(&s, .approvalRequested(ApprovalRequest(id: "1", action: "run a potentially destructive shell command",
                                                      target: "rm -rf build")))
        reduce(&s, .approvalResolved(true))
        reduce(&s, .backendError("Benji's backend (the engine) stopped unexpectedly (exit code 1)."))
        reduce(&s, .backendFinished(1))
        XCTAssertNil(s.retryableTurn)
    }
}
