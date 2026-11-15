import XCTest
@testable import BenjiCore

/// Simple screen steps. The shared cases in Tests/screen-class-cases.json are also run by
/// selftest.py against benji/screen_class.py: both sides give every step the same class.
final class ScreenStepClassTests: XCTestCase {
    struct Shared {
        let name: String
        let step: ScreenStep
        let intent: ScreenStepIntent?
        let askEveryStep: Bool
        let askedForText: Bool
        let unaskedSoFar: Int
        let element: ScreenElement?
        let sameApp: Bool
        let plan: ScreenStepClass
        let final: ScreenStepClass
    }

    static func file() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("screen-class-cases.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func cases() throws -> [Shared] {
        let raw = try XCTUnwrap(try file()["cases"] as? [[String: Any]])
        return try raw.map { c in
            let stepObject = try XCTUnwrap(c["step"] as? [String: Any])
            let element = (c["element"] as? [String: Any]).map {
                ScreenElement(role: $0["role"] as? String ?? "", subrole: $0["subrole"] as? String,
                              title: $0["title"] as? String ?? "", description: $0["description"] as? String ?? "",
                              inSheet: $0["in_sheet"] as? Bool ?? false, inWebArea: $0["in_web_area"] as? Bool)
            }
            return Shared(name: c["name"] as? String ?? "?",
                          step: try XCTUnwrap(ScreenStep.decode(stepObject), c["name"] as? String ?? "?"),
                          intent: ScreenStepIntent.decode(stepObject),
                          askEveryStep: c["ask_every_step"] as? Bool ?? false,
                          askedForText: c["asked_for_text"] as? Bool ?? false,
                          unaskedSoFar: c["unasked_so_far"] as? Int ?? 0,
                          element: element, sameApp: c["same_app"] as? Bool ?? true,
                          plan: try XCTUnwrap(ScreenStepClass(rawValue: c["plan"] as? String ?? "")),
                          final: try XCTUnwrap(ScreenStepClass(rawValue: c["final"] as? String ?? "")))
        }
    }

    func testSharedCasesGiveTheSameClassesAsPython() throws {
        let cases = try Self.cases()
        XCTAssertGreaterThanOrEqual(cases.count, 25)
        for c in cases {
            let (plan, _) = ScreenStepClassifier.plan(c.step, intent: c.intent, askEveryStep: c.askEveryStep,
                                                      askedForText: c.askedForText, unaskedSoFar: c.unaskedSoFar)
            XCTAssertEqual(plan, c.plan, c.name)
            let (final, why) = ScreenStepClassifier.final(c.step, planned: plan, element: c.element, sameApp: c.sameApp)
            XCTAssertEqual(final, c.final, c.name)
            if final == .asked, plan != .asked { XCTAssertFalse(why.isEmpty, "the card says why: \(c.name)") }
        }
        XCTAssertEqual(Set(cases.map(\.final)), [.free, .quiet, .asked])
        XCTAssertEqual(Set(cases.compactMap { $0.intent?.confidence }), Set(ScreenStepIntent.Confidence.allCases))
    }

    func testCommitWordsAreTheSharedList() throws {
        XCTAssertEqual(ScreenStepClassifier.commitWords.sorted(), try Self.file()["commit_words"] as? [String])
    }

    /// Steps that could commit something are asked: Space, keys on a button or in a dialog,
    /// buttons in a web page, and the sixth unasked step of a turn.
    func testTheReviewsScreenHolesAreAsked() {
        let high = ScreenStepIntent(intent: "x", confidence: .high)
        let space = ScreenStep.pressKey(key: "space", modifiers: [])
        XCTAssertEqual(ScreenStepClassifier.plan(space, intent: high, askEveryStep: false, askedForText: false).0, .asked)
        let send = ScreenElement(role: "AXButton", title: "Send", inWebArea: false)
        let letter = ScreenStep.pressKey(key: "j", modifiers: [])
        XCTAssertEqual(ScreenStepClassifier.final(letter, planned: .quiet, element: send, sameApp: true).0, .asked)
        let sheet = ScreenElement(role: "AXTextField", inSheet: true)
        let tab = ScreenStep.pressKey(key: "tab", modifiers: [])
        XCTAssertEqual(ScreenStepClassifier.final(tab, planned: .free, element: sheet, sameApp: true).0, .asked)
        XCTAssertEqual(ScreenStepClassifier.final(tab, planned: .free, element: nil, sameApp: true).0, .free)
        let readMore = ScreenStep.click(x: 1, y: 1, button: .left, count: 1, label: "Read more")
        let pagey = ScreenElement(role: "AXButton", title: "Read more", inWebArea: true)
        XCTAssertTrue(ScreenStepClassifier.final(readMore, planned: .quiet, element: pagey, sameApp: true).1.contains("web page"))
        let unknown = ScreenElement(role: "AXButton", title: "Read more")
        XCTAssertNil(unknown.inWebArea, "an older caller doesn't say: it may be in a page")
        XCTAssertTrue(ScreenStepClassifier.final(readMore, planned: .quiet, element: unknown, sameApp: true).1.contains("web page"))
        let scroll = ScreenStep.scroll(x: 1, y: 1, direction: .down, amount: 3, label: "")
        XCTAssertEqual(ScreenStepClassifier.plan(scroll, intent: high, askEveryStep: false, askedForText: false,
                                                 unaskedSoFar: ScreenStepClassifier.maxUnaskedSteps - 1).0, .free)
        XCTAssertEqual(ScreenStepClassifier.plan(scroll, intent: high, askEveryStep: false, askedForText: false,
                                                 unaskedSoFar: ScreenStepClassifier.maxUnaskedSteps).0, .asked)
        XCTAssertEqual(ScreenStepClassifier.maxUnaskedSteps, 5)
        XCTAssertFalse(ScreenStepClassifier.quietClickRoles.contains("AXButton"))
        XCTAssertTrue(ScreenStepClassifier.lookRoles.contains("AXButton"), "the app still finds the button to name it")
    }

    func testCommitWordsMatchTheirEndingsOnly() {
        XCTAssertEqual(ScreenStepClassifier.commitWord("Sending…"), "send")
        XCTAssertEqual(ScreenStepClassifier.commitWord("Payment details"), "pay")
        XCTAssertEqual(ScreenStepClassifier.commitWord("Check out now"), "check out")
        XCTAssertNil(ScreenStepClassifier.commitWord("Closet"))
        XCTAssertNil(ScreenStepClassifier.commitWord("Check the box"))
        XCTAssertNil(ScreenStepClassifier.commitWord("Postal code"))
    }

    func testTheAppNeverLowersTheEnginesClass() {
        let scroll = ScreenStep.scroll(x: 1, y: 1, direction: .down, amount: 3, label: "")
        XCTAssertEqual(ScreenStepClassifier.final(scroll, planned: .asked, element: nil, sameApp: true).0, .asked)
        XCTAssertEqual(ScreenStepClassifier.final(scroll, planned: .free, element: nil, sameApp: true).0, .free)
        XCTAssertEqual(max(ScreenStepClass.free, .quiet), .quiet)
        XCTAssertEqual(max(ScreenStepClass.asked, .quiet), .asked)
    }

    func testIntentAndConfidenceAreReadFromTheStep() {
        XCTAssertEqual(ScreenStepIntent.decode(["intent": " to read the rest ", "confidence": "high"]),
                       ScreenStepIntent(intent: "to read the rest", confidence: .high))
        XCTAssertEqual(ScreenStepIntent.decode(["confidence": "sure"]), nil, "an unknown confidence says nothing")
        XCTAssertEqual(ScreenStepIntent.decode(["intent": "x", "confidence": "sure"])?.confidence, nil)
        XCTAssertNil(ScreenStepIntent.decode(["kind": "scroll"]), "an older engine")
    }

    // MARK: the wire

    func testSendSaysSimpleStepsOnlyWithScreenActionsAndAnImage() throws {
        func object(_ r: ServeRequest) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: r.line()) as? [String: Any])
        }
        let on = try object(.send(id: "t1", text: "x", imagePath: "/s.png", allowPointing: true,
                                  screenActions: true, screenSimpleSteps: true))
        XCTAssertEqual(on["screen_simple_steps"] as? Bool, true)
        let noActions = try object(.send(id: "t1", text: "x", imagePath: "/s.png", allowPointing: true,
                                         screenActions: false, screenSimpleSteps: true))
        XCTAssertNil(noActions["screen_simple_steps"])
        let noImage = try object(.send(id: "t1", text: "x", imagePath: nil, allowPointing: true,
                                       screenActions: true, screenSimpleSteps: true))
        XCTAssertNil(noImage["screen_simple_steps"])
        let ask = try object(.send(id: "t1", text: "x", imagePath: "/s.png", allowPointing: true, screenActions: true))
        XCTAssertEqual(ask["screen_actions"] as? Bool, true)
        XCTAssertNil(ask["screen_simple_steps"], "Ask before every step: the field is left out, as an older app")
    }

    func testScreenActionCarriesItsModeAndIntent() {
        let line = #"{"type":"screen_action","id":"t1","request":"s1","mode":"free","step":{"kind":"scroll","x":600,"y":400,"direction":"down","amount":3,"label":"","intent":"to read the rest","confidence":"high"}}"#
        XCTAssertEqual(ServeEvent.decode(line), .screenAction(
            id: "t1", request: "s1", step: .scroll(x: 600, y: 400, direction: .down, amount: 3, label: ""),
            mode: .free, intent: ScreenStepIntent(intent: "to read the rest", confidence: .high)))
        let approved = #"{"type":"screen_action","id":"t1","request":"s2","step":{"kind":"press_key","key":"tab","modifiers":[]}}"#
        XCTAssertEqual(ServeEvent.decode(approved), .screenAction(id: "t1", request: "s2",
                                                                  step: .pressKey(key: "tab", modifiers: [])))
        let odd = #"{"type":"screen_action","id":"t1","request":"s3","mode":"whenever","step":{"kind":"press_key","key":"tab","modifiers":[]}}"#
        XCTAssertEqual(ServeEvent.decode(odd), .screenAction(id: "t1", request: "s3", step: nil),
                       "a mode this build doesn't know: the step is refused, never done unasked")
        let asked = #"{"type":"screen_action","id":"t1","request":"s4","mode":"asked","step":{"kind":"press_key","key":"tab","modifiers":[]}}"#
        XCTAssertEqual(ServeEvent.decode(asked), .screenAction(id: "t1", request: "s4", step: nil))
    }

    func testAnApprovalCarriesTheIntentForTheCard() {
        let line = #"{"type":"approval","id":"t1","request":"a1","action":"click on the screen","target":"Send at 1,2","screen":{"kind":"click","x":1,"y":2,"button":"left","count":1,"label":"Send","intent":"to send your reply to Sara","confidence":"high"}}"#
        XCTAssertEqual(ServeEvent.decode(line), .screenApproval(
            id: "t1", request: "a1", action: "click on the screen", target: "Send at 1,2",
            step: .click(x: 1, y: 2, button: .left, count: 1, label: "Send"),
            intent: ScreenStepIntent(intent: "to send your reply to Sara", confidence: .high)))
    }

    func testAskIsAResultStatus() throws {
        let line = ServeRequest.screenResult(id: "t1", request: "s1", result: .ask("it's in a dialog")).line()
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(o["status"] as? String, "ask")
        XCTAssertEqual(o["text"] as? String, "it's in a dialog")
    }

    // MARK: words

    func testTheCardReadsAsIntentNotCoordinates() {
        let send = ScreenStep.click(x: 1, y: 2, button: .left, count: 1, label: "Send")
        let intent = ScreenStepIntent(intent: "to send your reply to Sara", confidence: .high)
        XCTAssertEqual(ScreenStepCard.target(send, intent: intent),
                       "Send · to send your reply to Sara; then Benji looks at the screen again")
        XCTAssertEqual(ScreenStepCard.target(send, intent: intent, why: "it's in a dialog"),
                       "Send · to send your reply to Sara; then Benji looks at the screen again. Asked because it's in a dialog")
        XCTAssertEqual(ScreenStepCard.target(send, intent: nil), ScreenStepCard.target(send), "an older engine: as before")
    }

    func testActingWords() {
        XCTAssertEqual(ScreenStepCard.acting(.scroll(x: 1, y: 1, direction: .down, amount: 3, label: ""), app: "Safari"),
                       "Scrolling down in Safari")
        XCTAssertEqual(ScreenAutonomy.beatLabel(.click(x: 1, y: 1, button: .left, count: 1, label: "Settings")),
                       "Clicking Settings · Esc stops")
        XCTAssertEqual(ScreenAutonomy.actingLine(.pressKey(key: "l", modifiers: [.cmd]), app: "Safari"),
                       "Pressing ⌘L in Safari · Esc stops")
        XCTAssertEqual(ScreenAutonomy.actingLine(nil, app: nil), "Benji is acting · Esc stops")
        XCTAssertEqual(ScreenStepCard.acting(.typeText("hi"), app: "Notes"), "Typing in Notes")
    }

    func testTheSettingDefaultsToActingOnSimpleSteps() {
        XCTAssertTrue(ScreenAutonomy.actsOnSimpleSteps(nil))
        XCTAssertTrue(ScreenAutonomy.actsOnSimpleSteps(false))
        XCTAssertFalse(ScreenAutonomy.actsOnSimpleSteps(true), "screenActionsAsk YES: ask before every step")
        XCTAssertTrue(ScreenAutonomy.actsOnSimpleSteps("YES"), "only a real Bool turns it off")
        XCTAssertEqual(ScreenAutonomy.defaultsKey, "screenActionsAsk")
        XCTAssertTrue(SettingsSnapshot().screenSimpleSteps)
    }

    func testTheFrontAppAtCaptureLeavesBenjiOut() {
        let windows = [WindowInfo(id: 1, ownerPID: 7, layer: 0, frame: .zero), WindowInfo(id: 2, ownerPID: 9, layer: 25, frame: .zero),
                       WindowInfo(id: 3, ownerPID: 42, layer: 0, frame: .zero)]
        XCTAssertEqual(ScreenActionGeometry.frontApp(windows: windows, excludingPID: 7), 42)
        XCTAssertNil(ScreenActionGeometry.frontApp(windows: [], excludingPID: 7))
    }

    // MARK: the beat

    func testAQuietBeatIsLongerAndStoppedByTheUser() {
        var beat = StepBeat(mode: .quiet, pointer: CGPoint(x: 100, y: 100))
        XCTAssertEqual(beat.duration, 1.2)
        XCTAssertEqual(beat.decision(elapsed: 0.6), .wait, "a free step would act here; a quiet one waits")
        beat.observe(.pointerMoved(CGPoint(x: 103, y: 100)))
        XCTAssertEqual(beat.decision(elapsed: 0.8), .wait, "a tremble within the tolerance isn't a take-over")
        beat.observe(.pointerMoved(CGPoint(x: 140, y: 100)))
        XCTAssertEqual(beat.decision(elapsed: 0.9), .stop)
        XCTAssertEqual(beat.decision(elapsed: 5), .stop, "once stopped it never acts")
    }

    func testEscOrAKeyStopsTheBeatButBenjisOwnEventsDont() {
        var esc = StepBeat(mode: .quiet, pointer: .zero)
        esc.observe(.keyDown(KeyCodes.escape))
        XCTAssertEqual(esc.decision(elapsed: 2), .stop)
        var talkKey = StepBeat(mode: .quiet, pointer: .zero)
        talkKey.observe(.modifiersChanged)
        XCTAssertEqual(talkKey.decision(elapsed: 2), .stop, "a modifier talk key is the user too")
        var own = StepBeat(mode: .quiet, pointer: .zero)
        own.observe(.mouseDown(CGPoint(x: 500, y: 500)), synthetic: true)
        XCTAssertEqual(own.decision(elapsed: 1.2), .act)
    }

    func testAFreeOrApprovedStepKeepsTheShortRing() {
        XCTAssertEqual(StepBeat(mode: .free, pointer: .zero).decision(elapsed: 0.6), .act)
        XCTAssertEqual(StepBeat(mode: nil, pointer: .zero).duration, 0.6)
    }

    // MARK: the activity line

    func testThePeekAndPanelSayBenjiIsActing() {
        var s = CompanionState()
        reduce(&s, .submitText("what does the end say?"))
        reduce(&s, .toolProgress(name: "scroll", detail: ""))
        reduce(&s, .screenActing("Scrolling down in Safari · Esc stops"))
        let info = NotchStatusInfo.make(s)
        XCTAssertEqual(info.word, "Acting")
        XCTAssertEqual(info.line, "Scrolling down in Safari · Esc stops")
        XCTAssertEqual(NotchStatusInfo.openLine(info, state: s), "Scrolling down in Safari · Esc stops")
        reduce(&s, .screenActingEnded)
        XCTAssertNil(s.acting)
        XCTAssertEqual(NotchStatusInfo.make(s).word, "Working")
    }

    func testTheActingLineEndsWithTheTurn() {
        for end: CompanionEvent in [.assistantAnswer("Done."), .cancel, .backendError("x"), .backendFinished(0),
                                    .approvalRequested(ApprovalRequest(id: "a", action: "click", target: "Send"))] {
            var s = CompanionState()
            reduce(&s, .submitText("go"))
            reduce(&s, .screenActing("Clicking Settings · Esc stops"))
            XCTAssertNotNil(s.acting)
            reduce(&s, end)
            XCTAssertNil(s.acting, "\(end)")
        }
        var idle = CompanionState()
        reduce(&idle, .screenActing("late"))
        XCTAssertNil(idle.acting, "only while a turn runs")
    }

    func testADragIsAskedEvenIfTheEngineSaidOtherwise() {
        let drag = ScreenStep.drag(x: 1, y: 1, toX: 2, toY: 2, label: "the slider")
        let sure = ScreenStepIntent(intent: "x", confidence: .high)
        XCTAssertEqual(ScreenStepClassifier.plan(drag, intent: sure, askEveryStep: false, askedForText: false).0, .asked)
        for planned in [ScreenStepClass.free, .quiet] {
            let (final, why) = ScreenStepClassifier.final(drag, planned: planned, element: nil, sameApp: true)
            XCTAssertEqual(final, .asked)
            XCTAssertEqual(why, ScreenStepClassifier.dragWhy)
        }
        XCTAssertEqual(DriveClassifier.plan(drag, intent: sure).0, .quiet, "in a drive the app looks first; only a real slider or divider stays quiet")
    }
}
