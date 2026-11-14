import XCTest
@testable import BenjiCore

final class OpenListeningTests: XCTestCase {
    func testOpeningStartsListeningWithNoKey() {
        var o = OpenListening()
        XCTAssertEqual(o.update(panelOpen: true, conversationOn: false, canListen: true), .start)
    }

    func testClosingStopsListening() {
        var o = OpenListening()
        _ = o.update(panelOpen: true, conversationOn: false, canListen: true)
        XCTAssertEqual(o.update(panelOpen: false, conversationOn: true, canListen: true), .stop(.panelClosed))
        // Closing again, or closing with nothing on, does nothing.
        XCTAssertNil(o.update(panelOpen: false, conversationOn: true, canListen: true))
    }

    func testBenjiCollapsingForADrawingKeepsListening() {
        var o = OpenListening()
        _ = o.update(panelOpen: true, conversationOn: false, canListen: true)
        XCTAssertNil(o.update(panelOpen: false, conversationOn: true, canListen: true, keepListening: true))
        XCTAssertFalse(o.panelOpen)
    }

    func testNeverAsksForPermissionsOrUsesTheCloud() {
        var o = OpenListening()
        // canListen is false without on-device recognition or without both permissions granted.
        XCTAssertNil(o.update(panelOpen: true, conversationOn: false, canListen: false))
    }

    func testSettingOffNeverOpensTheMic() {
        var o = OpenListening(enabled: false)
        XCTAssertNil(o.update(panelOpen: true, conversationOn: false, canListen: true))
        // A conversation the user started by hand still ends when the panel closes.
        XCTAssertEqual(o.update(panelOpen: false, conversationOn: true, canListen: true), .stop(.panelClosed))
    }

    func testAlreadyListeningDoesNotStartTwice() {
        var o = OpenListening()
        XCTAssertNil(o.update(panelOpen: true, conversationOn: true, canListen: true))
    }

    func testEndingWhileOpenHoldsListeningOffUntilReopened() {
        for reason: HandsFreeEndReason in [.stopPhrase, .timeout, .escape, .user, .locked, .sleep, .micUnavailable] {
            var o = OpenListening()
            _ = o.update(panelOpen: true, conversationOn: false, canListen: true)
            o.conversationEnded(reason)
            XCTAssertNil(o.update(panelOpen: true, conversationOn: false, canListen: true), "\(reason)")
            _ = o.update(panelOpen: false, conversationOn: false, canListen: true)
            XCTAssertEqual(o.update(panelOpen: true, conversationOn: false, canListen: true), .start, "\(reason)")
        }
    }

    func testUserStartClearsTheHold() {
        var o = OpenListening()
        _ = o.update(panelOpen: true, conversationOn: false, canListen: true)
        o.conversationEnded(.stopPhrase)
        o.userStarted()
        XCTAssertEqual(o.update(panelOpen: true, conversationOn: false, canListen: true), .start)
    }

    func testEndingWhileClosedDoesNotHold() {
        var o = OpenListening()
        o.conversationEnded(.timeout)
        XCTAssertEqual(o.update(panelOpen: true, conversationOn: false, canListen: true), .start)
    }

    func testTurningTheSettingOffStopsAndOnStarts() {
        var o = OpenListening()
        _ = o.update(panelOpen: true, conversationOn: false, canListen: true)
        XCTAssertEqual(o.setEnabled(false, conversationOn: true, canListen: true), .stop(.user))
        XCTAssertNil(o.setEnabled(false, conversationOn: false, canListen: true))
        XCTAssertEqual(o.setEnabled(true, conversationOn: false, canListen: true), .start)
    }

    func testTurningTheSettingOnWhileClosedWaitsForTheNextOpen() {
        var o = OpenListening(enabled: false)
        XCTAssertNil(o.setEnabled(true, conversationOn: false, canListen: true))
        XCTAssertEqual(o.update(panelOpen: true, conversationOn: false, canListen: true), .start)
    }

    func testCancelKeepsListeningOnlyWhileOpenWithTheSettingOn() {
        var o = OpenListening()
        XCTAssertFalse(o.keepsListeningOnCancel)
        _ = o.update(panelOpen: true, conversationOn: false, canListen: true)
        XCTAssertTrue(o.keepsListeningOnCancel)
        _ = o.setEnabled(false, conversationOn: true, canListen: true)
        XCTAssertFalse(o.keepsListeningOnCancel)
    }

    func testStoredSetting() {
        XCTAssertTrue(OpenListening.enabled(from: nil))
        XCTAssertTrue(OpenListening.enabled(from: "maybe"))
        XCTAssertFalse(OpenListening.enabled(from: false))
        XCTAssertFalse(OpenListening.enabled(from: NSNumber(value: 0)))
        XCTAssertFalse(OpenListening.enabled(from: "off"))
        XCTAssertTrue(OpenListening.enabled(from: true))
    }

    /// The whole loop the user asked for: open, three turns with reading time between them,
    /// an approval in the middle, then the quiet spell; no key at any point.
    func testOpenPanelConversationWithReadingTimeAndAnApproval() {
        var open = OpenListening()
        // A saved five-minute choice (the default is two, D-134), so four minutes of reading fits.
        var s = HandsFreeSession(settings: HandsFreeSettings(idleTimeout: 300))
        XCTAssertEqual(open.update(panelOpen: true, conversationOn: s.isOn, canListen: true), .start)
        XCTAssertEqual(s.start(at: 0), [.openMic])

        var t: TimeInterval = 0
        for turn in 0..<3 {
            // The user talks, Benji works and speaks, then the user reads for four minutes.
            t += 5
            s.heardSpeech(at: t)
            s.utteranceEnding()
            XCTAssertEqual(s.utteranceFinished("Question number \(turn)", at: t), [.submit("Question number \(turn)")])
            XCTAssertEqual(s.update(HandsFreeSnapshot(phase: .thinking), at: t), [])
            if turn == 1 {
                // An approval: the mic stays shut however long it waits.
                XCTAssertEqual(s.update(HandsFreeSnapshot(phase: .awaitingApproval, approvalPending: true), at: t), [])
                for k in 1...100 { XCTAssertEqual(s.tick(at: t + Double(k)), []) }
                t += 100
                XCTAssertEqual(s.update(HandsFreeSnapshot(phase: .thinking), at: t), [])
            }
            XCTAssertEqual(s.update(HandsFreeSnapshot(phase: .speaking), at: t + 1), [])
            t += 20
            XCTAssertEqual(s.update(HandsFreeSnapshot(phase: .idle), at: t), [])
            XCTAssertEqual(s.tick(at: t + HandsFreeSettings.resumeDelay), [.openMic])
            t += HandsFreeSettings.resumeDelay
            XCTAssertEqual(s.tick(at: t + 240), [], "still listening after four minutes of reading")
            t += 240
        }
        // Then nothing at all: the quiet spell (five minutes here, a saved choice) ends it.
        let quietStart = t - 240
        XCTAssertEqual(s.tick(at: quietStart + 300), [.closeMic, .ended(.timeout)])
        open.conversationEnded(.timeout)
        XCTAssertNil(open.update(panelOpen: true, conversationOn: s.isOn, canListen: true), "stays off until reopened")
    }

    func testQuietSpellCanBeChangedMidConversation() {
        var s = HandsFreeSession(settings: HandsFreeSettings())
        _ = s.start(at: 0)
        s.settings = HandsFreeSettings(idleTimeout: 60)
        XCTAssertEqual(s.tick(at: 60), [.closeMic, .ended(.timeout)])
    }
}

final class PanelTranscriptTests: XCTestCase {
    func testOnlyTheConversationWithTheScreenAsAMark() {
        let lines = [
            TranscriptLine(role: .user, text: "Which button saves this?"),
            TranscriptLine(role: .attachment, text: "Screen attached · 1330×864 · sent to Anthropic", attachmentID: "a1"),
            TranscriptLine(role: .tool, text: "read_file notes.md"),
            TranscriptLine(role: .assistant, text: "The Save button."),
            TranscriptLine(role: .system, text: "Approved: Delete a file"),
            TranscriptLine(role: .error, text: "That didn't work."),
        ]
        let rows = PanelTranscript.rows(lines)
        XCTAssertEqual(rows.map(\.line.role), [.user, .assistant, .system, .error])
        XCTAssertEqual(rows[0].screen, PanelScreenMark(summary: "Screen attached · 1330×864 · sent to Anthropic",
                                                       attachmentID: "a1"))
        XCTAssertNil(rows[1].screen)
    }

    func testAMarkGoesOnTheLatestMessage() {
        let lines = [
            TranscriptLine(role: .user, text: "One"),
            TranscriptLine(role: .assistant, text: "Answer"),
            TranscriptLine(role: .user, text: "Two"),
            TranscriptLine(role: .attachment, text: "Screen attached", attachmentID: "b"),
        ]
        let rows = PanelTranscript.rows(lines)
        XCTAssertNil(rows[0].screen)
        XCTAssertEqual(rows[2].screen?.attachmentID, "b")
    }

    func testListeningEndedIsAStatusNoteNotARow() {
        var s = CompanionState()
        let note = HandsFreeEndReason.timeout.notice
        let info = NotchStatusInfo.make(s, note: note)
        XCTAssertEqual(info.line, "Stopped listening after a quiet spell.")
        XCTAssertEqual(NotchStatusInfo.openLine(info, state: s), "Stopped listening after a quiet spell.")
        XCTAssertTrue(PanelTranscript.rows(s.lines).isEmpty)
        reduce(&s, .submitText("hi"))
        XCTAssertEqual(NotchStatusInfo.make(s, note: note).status, .working)
    }

    func testOpenLine() {
        var s = CompanionState()
        XCTAssertNil(NotchStatusInfo.openLine(.make(s), state: s), "nothing to say when simply ready")
        reduce(&s, .micStarted)
        XCTAssertEqual(NotchStatusInfo.openLine(.make(s, conversation: true), state: s), NotchStatusInfo.conversationListeningLine)
        reduce(&s, .transcribed("Move my screenshots"))
        XCTAssertNil(NotchStatusInfo.openLine(.make(s), state: s), "your message is already a row")
        reduce(&s, .toolProgress(name: "list_dir", detail: "~/Desktop"))
        XCTAssertEqual(NotchStatusInfo.openLine(.make(s), state: s), "list_dir ~/Desktop", "the step lives here, not in the transcript")
        reduce(&s, .assistantAnswer("Done."))
        reduce(&s, .speakingStarted)
        XCTAssertNil(NotchStatusInfo.openLine(.make(s), state: s), "the answer is already in the transcript")
        reduce(&s, .backendError("Broken"))
        XCTAssertNil(NotchStatusInfo.openLine(.make(s), state: s), "the error row says it")
    }

    func testPanelDoesNotCloseOnLeaveDuringAConversation() {
        XCTAssertTrue(NotchPresence.mayCloseOnLeave(phase: .idle, composerEmpty: true, panelFocused: false))
        XCTAssertFalse(NotchPresence.mayCloseOnLeave(phase: .idle, composerEmpty: true, panelFocused: false,
                                                     conversationOn: true))
    }
}

final class StatusWordSwapTests: XCTestCase {
    func testOneWordAtATime() {
        var w = StatusWordSwap("Done")
        XCTAssertEqual(w.request("Speaking", reduceMotion: false), .fadeOut)
        // While fading out, the label still draws only "Done", now hidden.
        XCTAssertEqual(w.shown, "Done")
        XCTAssertFalse(w.visible)
        w.fadedOut()
        XCTAssertEqual(w.shown, "Speaking")
        XCTAssertTrue(w.visible)
        XCTAssertNil(w.pending)
    }

    func testWordsArrivingMidSwapCoalesceToTheNewest() {
        var w = StatusWordSwap("Done")
        _ = w.request("Speaking", reduceMotion: false)
        XCTAssertEqual(w.request("Listening", reduceMotion: false), .none)
        XCTAssertEqual(w.shown, "Done")
        w.fadedOut()
        XCTAssertEqual(w.shown, "Listening")
    }

    func testReturningToTheShownWordCancelsTheSwap() {
        var w = StatusWordSwap("Working")
        _ = w.request("Speaking", reduceMotion: false)
        XCTAssertEqual(w.request("Working", reduceMotion: false), .show)
        XCTAssertTrue(w.visible)
        w.fadedOut()   // the fade's completion still arrives
        XCTAssertEqual(w.shown, "Working")
    }

    func testReduceMotionSwapsAtOnce() {
        var w = StatusWordSwap("Done")
        XCTAssertEqual(w.request("Speaking", reduceMotion: true), .show)
        XCTAssertEqual(w.shown, "Speaking")
        XCTAssertTrue(w.visible)
    }

    func testSameWordDoesNothing() {
        var w = StatusWordSwap("Ready")
        XCTAssertEqual(w.request("Ready", reduceMotion: false), .none)
        XCTAssertTrue(w.visible)
    }
}

final class QuietTimeoutTests: XCTestCase {
    /// D-134: with the defaults, two quiet minutes end listening, and it stays off while the panel is open.
    func testDefaultTwoMinutesEndsListeningAndItDoesNotComeBack() {
        var open = OpenListening()
        var s = HandsFreeSession(settings: HandsFreeSettings())
        XCTAssertEqual(open.update(panelOpen: true, conversationOn: false, canListen: true), .start)
        XCTAssertEqual(s.start(at: 0), [.openMic])
        XCTAssertEqual(s.tick(at: 119), [])
        XCTAssertEqual(s.tick(at: 120), [.closeMic, .ended(.timeout)])
        open.conversationEnded(.timeout)
        XCTAssertNil(open.update(panelOpen: true, conversationOn: s.isOn, canListen: true))
        XCTAssertEqual(s.tick(at: 500), [])
    }
}
