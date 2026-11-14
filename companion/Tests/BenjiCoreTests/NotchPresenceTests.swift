import XCTest
@testable import BenjiCore

final class NotchPresenceTests: XCTestCase {
    // MARK: size

    func testClosedWhenNothingHappens() {
        XCTAssertEqual(NotchPresence.targetSize(.init(phase: .idle)), .closed)
        XCTAssertEqual(NotchPresence.targetSize(.init(phase: .error, errorDismissed: true)), .closed)
    }

    func testPeekForEveryRealOngoingEvent() {
        for phase in [CompanionPhase.listening, .transcribing, .thinking, .speaking] {
            XCTAssertEqual(NotchPresence.targetSize(.init(phase: phase)), .peek, "\(phase)")
        }
        XCTAssertEqual(NotchPresence.targetSize(.init(phase: .idle, hovered: true)), .peek)
        XCTAssertEqual(NotchPresence.targetSize(.init(phase: .idle, doneHolding: true)), .peek)
        XCTAssertEqual(NotchPresence.targetSize(.init(phase: .error)), .peek, "an unseen error is held")
    }

    func testApprovalOpensTheNotchWithoutBeingAsked() {
        XCTAssertEqual(NotchPresence.targetSize(.init(phase: .awaitingApproval)), .open)
        XCTAssertEqual(NotchPresence.targetSize(.init(phase: .awaitingApproval, hovered: true)), .open)
        // Once answered, the engine resumes and the notch falls back to the peek.
        XCTAssertEqual(NotchPresence.targetSize(.init(phase: .thinking)), .peek)
        XCTAssertFalse(NotchPresence.mayCloseOnLeave(phase: .awaitingApproval, composerEmpty: true, panelFocused: false))
    }

    func testOpenOnlyWhenAsked() {
        for phase in [CompanionPhase.idle, .listening, .thinking, .awaitingApproval, .error] {
            XCTAssertEqual(NotchPresence.targetSize(.init(phase: phase, userOpened: true)), .open)
        }
    }

    func testLeavingClosesOnlyWhenNothingIsPending() {
        XCTAssertTrue(NotchPresence.mayCloseOnLeave(phase: .idle, composerEmpty: true, panelFocused: false))
        XCTAssertTrue(NotchPresence.mayCloseOnLeave(phase: .error, composerEmpty: true, panelFocused: false))
        XCTAssertFalse(NotchPresence.mayCloseOnLeave(phase: .thinking, composerEmpty: true, panelFocused: false))
        XCTAssertFalse(NotchPresence.mayCloseOnLeave(phase: .idle, composerEmpty: false, panelFocused: false))
        XCTAssertFalse(NotchPresence.mayCloseOnLeave(phase: .idle, composerEmpty: true, panelFocused: true))
    }

    func testDoneOnlyWhenATurnEndsWithAnAnswer() {
        XCTAssertTrue(NotchPresence.isDone(event: .backendFinished(0), before: .thinking, after: .idle))
        XCTAssertTrue(NotchPresence.isDone(event: .speakingFinished, before: .speaking, after: .idle))
        // A cancel leaves the phase idle before the engine exits: not Done.
        XCTAssertFalse(NotchPresence.isDone(event: .backendFinished(0), before: .idle, after: .idle))
        XCTAssertFalse(NotchPresence.isDone(event: .backendFinished(1), before: .error, after: .error))
        XCTAssertFalse(NotchPresence.isDone(event: .cancel, before: .thinking, after: .idle))
        // A voice turn: the engine exits while speaking; Done comes when speech ends.
        XCTAssertFalse(NotchPresence.isDone(event: .backendFinished(0), before: .speaking, after: .speaking))
    }

    func testDoneThroughTheReducer() {
        var s = CompanionState()
        reduce(&s, .submitText("tidy my desktop"))
        reduce(&s, .assistantAnswer("Done. 12 files moved."))
        let before = s.phase
        reduce(&s, .backendFinished(0))
        XCTAssertTrue(NotchPresence.isDone(event: .backendFinished(0), before: before, after: s.phase))
    }

    func testDoneHoldForAllSet() {
        XCTAssertEqual(NotchPresence.doneHold, 1.5, accuracy: 1e-9)
    }

    func testSizesAreNested() {
        XCTAssertLessThan(NotchSize.closed, .peek)
        XCTAssertLessThan(NotchSize.peek, .open)
        XCTAssertEqual(NotchSize.allCases.max(), .open)
    }

    // MARK: morph plan

    func testGrowingStartsAtOnceAndFadesInAt65Percent() {
        let p = NotchMorphPlan.plan(from: .closed, to: .peek, fromRest: true, reduceMotion: false)
        XCTAssertEqual(p.spring, MotionTokens.peek)
        XCTAssertEqual(p.shapeDelay, 0)
        XCTAssertEqual(p.fadeOut, [])
        XCTAssertEqual(p.fadeIn, [.wings, .line])
        XCTAssertEqual(p.fadeInDelay, 0.1059, accuracy: 1e-4, "106 ms into motion-peek")

        let o = NotchMorphPlan.plan(from: .peek, to: .open, fromRest: true, reduceMotion: false)
        XCTAssertEqual(o.spring, MotionTokens.open)
        XCTAssertEqual(o.fadeOut, [.line], "the line goes, the wings stay")
        XCTAssertEqual(o.fadeIn, [.panel])
        XCTAssertEqual(o.fadeInDelay, 0.1765, accuracy: 1e-4, "177 ms into motion-open")
        XCTAssertEqual(o.shapeDelay, 0)
    }

    func testShrinkingFadesOutFirstOnlyFromRest() {
        let p = NotchMorphPlan.plan(from: .open, to: .peek, fromRest: true, reduceMotion: false)
        XCTAssertEqual(p.spring, MotionTokens.open)
        XCTAssertEqual(p.shapeDelay, 0.1, accuracy: 1e-9)
        XCTAssertEqual(p.fadeOut, [.panel])
        XCTAssertEqual(p.fadeIn, [.line])
        XCTAssertEqual(p.fadeInDelay, 0.1 + 0.1765, accuracy: 1e-4)
        XCTAssertEqual(p.settleTime, 0.1 + MotionTokens.open.settleTime, accuracy: 1e-9)

        let retarget = NotchMorphPlan.plan(from: .peek, to: .closed, fromRest: false, reduceMotion: false)
        XCTAssertEqual(retarget.shapeDelay, 0, "a retarget mid-flight never waits")
        XCTAssertEqual(retarget.spring, MotionTokens.peek)
        XCTAssertEqual(retarget.fadeOut, [.wings, .line])
    }

    func testReduceMotionIsACrossfade() {
        let p = NotchMorphPlan.plan(from: .closed, to: .open, fromRest: true, reduceMotion: true)
        XCTAssertNil(p.spring)
        XCTAssertEqual(p.shapeDelay, 0)
        XCTAssertEqual(p.fadeInDelay, 0)
        XCTAssertEqual(p.settleTime, MotionTokens.reduceDuration)
    }

    // MARK: status

    func testStatusPerPhase() {
        var s = CompanionState()
        XCTAssertEqual(NotchStatusInfo.make(s).status, .ready)
        XCTAssertEqual(NotchStatusInfo.make(s).line, "Here if you need me.")
        XCTAssertEqual(NotchStatusInfo.make(s, doneHolding: true).status, .done)
        XCTAssertEqual(NotchStatusInfo.make(s, doneHolding: true).symbol, "checkmark")

        reduce(&s, .micStarted)
        var info = NotchStatusInfo.make(s)
        XCTAssertEqual(info.word, "Listening")
        XCTAssertEqual(info.line, "Go on.")
        XCTAssertEqual(info.tint, .listening)
        XCTAssertEqual(NotchStatusInfo.make(s, partial: " rename the screenshots ").line, "rename the screenshots")

        reduce(&s, .transcribingStarted)
        XCTAssertEqual(NotchStatusInfo.make(s).tint, .listeningDimmed)

        reduce(&s, .transcribed("rename the screenshots"))
        info = NotchStatusInfo.make(s)
        XCTAssertEqual(info.status, .working)
        XCTAssertEqual(info.line, "rename the screenshots", "before any step, the request")
        reduce(&s, .toolProgress(name: "list_dir", detail: "~/Desktop"))
        XCTAssertEqual(NotchStatusInfo.make(s).line, "list_dir ~/Desktop", "the current step")

        reduce(&s, .approvalRequested(ApprovalRequest(id: "1", action: "Move 12 files", target: "~/Archive")))
        info = NotchStatusInfo.make(s)
        XCTAssertEqual(info.status, .approval)
        XCTAssertEqual(info.line, "Move 12 files: ~/Archive")
        XCTAssertEqual(info.tint, .approval)

        reduce(&s, .approvalResolved(true))
        reduce(&s, .assistantAnswer("**Done.** 12 files moved.\nSecond line."))
        reduce(&s, .speakingStarted)
        info = NotchStatusInfo.make(s)
        XCTAssertEqual(info.status, .speaking)
        XCTAssertEqual(info.line, "Done. 12 files moved.", "first line, Markdown stripped")

        reduce(&s, .backendError("That didn't work: the file is locked.\nTraceback…"))
        info = NotchStatusInfo.make(s)
        XCTAssertEqual(info.status, .error)
        XCTAssertEqual(info.line, "That didn't work: the file is locked.")
    }

    func testLookingWhileAScreenshotIsAttached() {
        var s = CompanionState()
        reduce(&s, .submitText("what's this?"))
        reduce(&s, .screenAttached(id: "a", summary: "Screen attached"))
        XCTAssertEqual(NotchStatusInfo.make(s).status, .looking)
        XCTAssertEqual(NotchStatusInfo.make(s).tint, .looking)
        reduce(&s, .toolProgress(name: "read", detail: ""))
        XCTAssertEqual(NotchStatusInfo.make(s).status, .working)
    }

    func testEveryStateWordFitsTheWing() {
        // peek-status is 11 pt semibold; ~6.2 pt a character keeps 12 characters under 74 pt.
        let words = ["Ready", "Listening", "Transcribing", "Working", "Looking", "Approval", "Speaking", "Done", "Error"]
        for w in words { XCTAssertLessThanOrEqual(w.count, 12, w) }
    }

    // MARK: announcements

    func testAnnouncementsOnlyForRealStateChanges() {
        var s = CompanionState()
        reduce(&s, .micStarted)
        let listening = NotchStatusInfo.make(s)
        XCTAssertEqual(NotchStatusInfo.announcement(from: .ready, to: listening),
                       NotchAnnouncement(text: "Listening", highPriority: false))
        XCTAssertNil(NotchStatusInfo.announcement(from: .listening, to: listening), "no repeat")

        reduce(&s, .approvalRequested(ApprovalRequest(id: "1", action: "Move 12 files to Archive", target: "")))
        XCTAssertEqual(NotchStatusInfo.announcement(from: .working, to: NotchStatusInfo.make(s)),
                       NotchAnnouncement(text: "Benji needs approval: Move 12 files to Archive", highPriority: true))

        let done = NotchStatusInfo.make(CompanionState(), doneHolding: true)
        XCTAssertEqual(NotchStatusInfo.announcement(from: .working, to: done, answer: "Done. 12 files moved to Archive.")?.text,
                       "Done. 12 files moved to Archive.")
        XCTAssertEqual(NotchStatusInfo.announcement(from: .working, to: done)?.text, "All set.")

        reduce(&s, .backendError("Capture failed."))
        XCTAssertEqual(NotchStatusInfo.announcement(from: .approval, to: NotchStatusInfo.make(s))?.highPriority, true)
        XCTAssertNil(NotchStatusInfo.announcement(from: .ready, to: NotchStatusInfo.make(CompanionState(), doneHolding: false)))
    }

    // MARK: hover

    let zone = CGRect(x: 655, y: 942, width: 201, height: 48)

    func testRestingPointerOpensAfter100ms() {
        var h = HoverRestDetector()
        XCTAssertFalse(h.sample(CGPoint(x: 700, y: 960), at: 0, zone: zone))
        XCTAssertFalse(h.sample(CGPoint(x: 701, y: 960), at: 0.05, zone: zone))   // 20 pt/s
        XCTAssertFalse(h.check(at: 0.09))
        XCTAssertTrue(h.check(at: 0.10))
        XCTAssertFalse(h.check(at: 0.5), "fires once per visit")
    }

    func testFastPointerPassingThroughDoesNotOpen() {
        var h = HoverRestDetector()
        // 2000 pt/s across the menu bar.
        XCTAssertFalse(h.sample(CGPoint(x: 600, y: 965), at: 0, zone: zone))
        XCTAssertFalse(h.sample(CGPoint(x: 700, y: 965), at: 0.05, zone: zone))
        XCTAssertFalse(h.sample(CGPoint(x: 800, y: 965), at: 0.10, zone: zone))
        XCTAssertFalse(h.sample(CGPoint(x: 900, y: 965), at: 0.15, zone: zone))
        XCTAssertFalse(h.check(at: 1.0), "it left the zone")
    }

    func testPointerThatStopsInsideOpensFromItsLastMove() {
        var h = HoverRestDetector()
        _ = h.sample(CGPoint(x: 600, y: 965), at: 0, zone: zone)
        XCTAssertFalse(h.sample(CGPoint(x: 700, y: 965), at: 0.05, zone: zone), "arrived fast")
        XCTAssertFalse(h.check(at: 0.14))
        XCTAssertTrue(h.check(at: 0.15), "still for 100 ms since the last move")
    }

    func testLeavingAndReturningFiresAgain() {
        var h = HoverRestDetector()
        _ = h.sample(CGPoint(x: 700, y: 960), at: 0, zone: zone)
        XCTAssertTrue(h.check(at: 0.2))
        _ = h.sample(CGPoint(x: 700, y: 900), at: 1, zone: zone)
        _ = h.sample(CGPoint(x: 700, y: 960), at: 2, zone: zone)
        XCTAssertTrue(h.check(at: 2.2))
    }

    // MARK: hardware notch

    func testHardwareNotchFromTheMenuBarAreas() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let left = CGRect(x: 0, y: 950, width: 663, height: 32)
        let right = CGRect(x: 848, y: 950, width: 664, height: 32)
        XCTAssertEqual(PanelGeometry.hardwareNotch(screenFrame: screen, leftArea: left, rightArea: right, safeAreaTop: 32),
                       CGRect(x: 663, y: 950, width: 185, height: 32))
        XCTAssertNil(PanelGeometry.hardwareNotch(screenFrame: screen, leftArea: nil, rightArea: nil, safeAreaTop: 0))
        XCTAssertNil(PanelGeometry.hardwareNotch(screenFrame: screen, leftArea: left, rightArea: right, safeAreaTop: 0))
    }
}
