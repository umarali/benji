import XCTest
@testable import BenjiCore

/// Drive mode (D-170): the rules the app applies at the point, the hand-back of the screen to the
/// user, the card's words and the wire. The shared cases in Tests/drive-cases.json are also run by
/// selftest_drive.py against benji/drive.py: both sides give every text and step the same class.
final class DriveClassTests: XCTestCase {
    static func file() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("drive-cases.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// A step from a case's compact form: a click gets a point, a scroll a direction and amount.
    static func step(_ o: [String: Any]) throws -> ScreenStep {
        var full = o
        switch o["kind"] as? String {
        case "click": full["x"] = 10; full["y"] = 10; if full["label"] == nil { full["label"] = "x" }
        case "scroll": full["x"] = 10; full["y"] = 10; full["direction"] = "down"; full["amount"] = 3
        case "drag": full["x"] = 10; full["y"] = 10; full["to_x"] = 20; full["to_y"] = 20; if full["label"] == nil { full["label"] = "x" }
        default: break
        }
        return try XCTUnwrap(ScreenStep.decode(full), "\(o)")
    }

    static func element(_ raw: Any?) -> ScreenElement? {
        guard let o = raw as? [String: Any] else { return nil }
        return ScreenElement(role: o["role"] as? String ?? "", subrole: o["subrole"] as? String,
                             title: o["title"] as? String ?? "", description: o["description"] as? String ?? "",
                             inSheet: o["in_sheet"] as? Bool ?? false, inWebArea: o["in_web_area"] as? Bool,
                             hints: o["hints"] as? String ?? "")
    }

    func testOutboundWordsMatchPython() throws {
        let cases = try XCTUnwrap(Self.file()["outbound"] as? [[Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 25)
        for c in cases {
            XCTAssertEqual(DriveClassifier.outboundWord(c[0] as? String ?? ""), c[1] as? String, "\(c[0])")
        }
    }

    func testSkeletonsMatchPython() throws {
        for c in try XCTUnwrap(Self.file()["skeleton"] as? [[Any]]) {
            XCTAssertEqual(DriveClassifier.skeleton(c[0] as? String ?? ""), c[1] as? String, "\(c[0])")
        }
    }

    func testFieldKindsMatchPython() throws {
        for c in try XCTUnwrap(Self.file()["field"] as? [[Any]]) {
            let kind = DriveClassifier.fieldKind(Self.element(c[0]))
            XCTAssertEqual(kind.rawValue, c[1] as? String, "\(c[0])")
        }
    }

    func testCardNumbersMatchPython() throws {
        for c in try XCTUnwrap(Self.file()["card"] as? [[Any]]) {
            XCTAssertEqual(DriveClassifier.looksLikeCard(c[0] as? String ?? ""), c[1] as? Bool, "\(c[0])")
        }
    }

    func testPlansMatchPython() throws {
        let cases = try XCTUnwrap(Self.file()["plan"] as? [[Any]])
        for c in cases {
            let o = try XCTUnwrap(c[0] as? [String: Any])
            let (cls, why) = DriveClassifier.plan(try Self.step(o), intent: ScreenStepIntent.decode(o))
            XCTAssertEqual(cls.rawValue, c[1] as? String, "\(o)")
            if cls != .free, cls != .quiet { XCTAssertFalse(why.isEmpty, "a card or a refusal says why: \(o)") }
        }
    }

    func testFinalClassesMatchPythonAndNeverLowerThePlan() throws {
        let cases = try XCTUnwrap(Self.file()["final"] as? [[Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 45)
        for c in cases {
            let o = try XCTUnwrap(c[0] as? [String: Any])
            let planned = try XCTUnwrap(DriveClass(rawValue: c[1] as? String ?? ""))
            let (final, why) = DriveClassifier.final(try Self.step(o), planned: planned, element: Self.element(c[2]),
                                                     sameApp: c[3] as? Bool ?? true)
            XCTAssertEqual(final.rawValue, c[4] as? String, "\(o) on \(String(describing: c[2]))")
            XCTAssertGreaterThanOrEqual(final, planned, "the app only raises a class")
            if final > planned { XCTAssertFalse(why.isEmpty, "it says why: \(o)") }
        }
    }

    func testDragsOnAControlMatchPythonAndNeverLowerThePlan() throws {
        let cases = try XCTUnwrap(Self.file()["final_drag"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 19)
        for c in cases {
            let o = try XCTUnwrap(c["step"] as? [String: Any])
            let planned = try XCTUnwrap(DriveClass(rawValue: c["planned"] as? String ?? ""))
            let (final, why) = DriveClassifier.final(try Self.step(o), planned: planned, element: Self.element(c["element"] as Any?),
                                                     sameApp: c["same_app"] as? Bool ?? false,
                                                     endElement: Self.element(c["end"] as Any?),
                                                     sameControl: c["same_control"] as? Bool ?? false)
            XCTAssertEqual(final.rawValue, c["want"] as? String, "\(c["why"] ?? "")")
            XCTAssertGreaterThanOrEqual(final, planned, "the app only raises a class")
            if final > planned { XCTAssertFalse(why.isEmpty, "it says why: \(c["why"] ?? "")") }
        }
    }

    func testASliderIsNotQuietUnlessTheAppSaysItStaysOnTheControl() {
        let drag = ScreenStep.drag(x: 1, y: 1, toX: 2, toY: 2, label: "volume to half")
        let slider = ScreenElement(role: "AXSlider", title: "Volume", inWebArea: false)
        XCTAssertEqual(DriveClassifier.final(drag, planned: .quiet, element: slider, sameApp: true, endElement: slider).0, .asked)
        XCTAssertEqual(DriveClassifier.final(drag, planned: .quiet, element: slider, sameApp: true, endElement: slider, sameControl: true).0, .quiet)
    }

    func testAQuietDragLetsGoInsideTheSliderOrTheDividersSplitGroup() {
        XCTAssertEqual(DriveClassifier.dragBoundsLevel(roles: ["AXSlider", "AXGroup"]), 0)
        XCTAssertEqual(DriveClassifier.dragBoundsLevel(roles: ["AXValueIndicator", "AXSlider", "AXGroup"]), 1, "the knob belongs to its slider")
        XCTAssertEqual(DriveClassifier.dragBoundsLevel(roles: ["AXSplitter", "AXSplitGroup"]), 1)
        XCTAssertNil(DriveClassifier.dragBoundsLevel(roles: ["AXSplitter", "AXGroup"]), "a divider with no split group has no bounds")
        XCTAssertNil(DriveClassifier.dragBoundsLevel(roles: ["AXSplitter"]))
        XCTAssertNil(DriveClassifier.dragBoundsLevel(roles: ["AXStaticText", "AXGroup"]))
    }

    func testADragIsDeniedOverASecretFieldAtEitherEnd() {
        let drag = ScreenStep.drag(x: 1, y: 1, toX: 2, toY: 2, label: "the text into the box")
        let secret = ScreenElement(role: "AXTextField", title: "Password")
        let plain = ScreenElement(role: "AXStaticText", title: "report.pdf")
        XCTAssertEqual(DriveClassifier.final(drag, planned: .quiet, element: plain, sameApp: true, endElement: secret).0, .denied)
        XCTAssertEqual(DriveClassifier.final(drag, planned: .quiet, element: secret, sameApp: true, endElement: plain).0, .denied)
        XCTAssertEqual(DriveClassifier.final(drag, planned: .quiet, element: secret, sameApp: false, endElement: plain).0, .denied,
                       "another app doesn't get it out of the refusal")
        XCTAssertEqual(DriveClassifier.final(drag, planned: .quiet, element: plain, sameApp: true, endElement: plain).0, .asked)
        XCTAssertEqual(DriveClassifier.final(drag, planned: .quiet, element: plain, sameApp: true,
                                             endElement: ScreenElement(role: "AXStaticText", title: "password list.txt")).0, .asked,
                       "only a field is a secret field: a file can be called that")
    }

    func testTheOutboundListIsTheCommitListPlusTheDrivesOwn() {
        for w in ScreenStepClassifier.commitWords { XCTAssertNotNil(DriveClassifier.outboundWord(w), w) }
        for w in ["send", "buy", "pay", "delete", "post", "confirm", "submit"] { XCTAssertNotNil(DriveClassifier.outboundWord(w)) }
    }

    func testLookAlikesAndInvisibleCharactersDontHideAWord() {
        for sneaky in ["Sеnd", "S\u{200B}end", "S\u{00AD}end", "Sen\u{0301}d", "\u{202E}Send", "ｓｅｎｄ", "S e n d", "P.a.y"] {
            XCTAssertNotNil(DriveClassifier.outboundWord(sneaky), sneaky)
        }
        XCTAssertNil(DriveClassifier.outboundWord("Sandbox"))
    }

    // MARK: handing the screen back

    private func fresh() -> DriveHandBack { DriveHandBack(pointer: CGPoint(x: 100, y: 100)) }

    func testEscTypingClickAndScrollEndTheDriveAtOnce() {
        var w = fresh()
        XCTAssertEqual(w.observe(.keyDown(KeyCodes.escape), at: 1), .handBack(.escape))
        w = fresh()
        XCTAssertEqual(w.observe(.keyDown(0), at: 1), .handBack(.typing))
        w = fresh()
        XCTAssertEqual(w.observe(.mouseDown, at: 1), .handBack(.click))
        w = fresh()
        XCTAssertEqual(w.observe(.scroll, at: 1), .handBack(.scroll))
    }

    func testOnceHandedBackItStaysHandedBack() {
        var w = fresh()
        w.observe(.keyDown(0), at: 1)
        XCTAssertEqual(w.observe(.pointerMoved(CGPoint(x: 100, y: 100)), at: 2), .handBack(.typing))
        XCTAssertFalse(w.isPaused(at: 2))
    }

    func testBenjisOwnEventsNeverCount() {
        var w = fresh()
        XCTAssertEqual(w.observe(.keyDown(KeyCodes.escape), at: 1, synthetic: true), .none)
        XCTAssertEqual(w.observe(.mouseDown, at: 1, synthetic: true), .none)
        XCTAssertEqual(w.observe(.scroll, at: 1, synthetic: true), .none)
        XCTAssertNil(w.handedBack)
    }

    func testAPointerWhereItShouldBeIsNotTheUser() {
        var w = fresh()
        XCTAssertEqual(w.observe(.pointerMoved(CGPoint(x: 103, y: 102)), at: 1), .none, "within the tolerance")
        w.benjiMovedPointer(to: CGPoint(x: 500, y: 400))
        XCTAssertEqual(w.observe(.pointerMoved(CGPoint(x: 500, y: 400)), at: 2), .none, "where Benji put it")
    }

    func testASmallMoveOnlyPausesAndLiftsAfterTheMouseIsStill() {
        var w = fresh()
        XCTAssertEqual(w.observe(.pointerMoved(CGPoint(x: 130, y: 100)), at: 1), .paused)
        XCTAssertTrue(w.isPaused(at: 1.5))
        XCTAssertFalse(w.isPaused(at: 1 + DriveHandBack.resumeAfter + 0.01))
        XCTAssertNil(w.handedBack)
    }

    func testARunOfAtLeastThreeSecondsAndOneHundredFiftyPointsHandsBack() {
        var w = fresh()
        var outcome = DriveHandBack.Outcome.none
        var handedAt: Double?
        // 10 points every 0.1 s from 0.1 s: 3 s and 300 points in all.
        for i in 1...40 {
            let t = Double(i) * 0.1
            outcome = w.observe(.pointerMoved(CGPoint(x: 100 + Double(i) * 10, y: 100)), at: t)
            if case .handBack(.movement) = outcome, handedAt == nil { handedAt = t }
        }
        let at = try! XCTUnwrap(handedAt)
        XCTAssertGreaterThanOrEqual(at - 0.1, DriveHandBack.minRunSeconds - 0.0001, "never before three seconds of running")
        XCTAssertLessThan(at, 3.3)
    }

    func testALongRunThatDoesntGoFarEnoughOnlyPauses() {
        var w = fresh()
        // 4 seconds of tiny wiggles: 20 points in all.
        var last = DriveHandBack.Outcome.none
        for i in 1...40 {
            let x = i % 2 == 0 ? 100.0 : 110.0
            last = w.observe(.pointerMoved(CGPoint(x: x, y: 100)), at: Double(i) * 0.1)
        }
        // each wiggle is 10 points back and forth: 400 points in all, which does hand back
        XCTAssertEqual(last, .handBack(.movement))
        var slow = fresh()
        var outcome = DriveHandBack.Outcome.none
        for i in 1...40 {       // 4 s, 3 points a step: 120 points, under 150
            outcome = slow.observe(.pointerMoved(CGPoint(x: 100 + Double(i) * 3, y: 100)), at: Double(i) * 0.1)
        }
        XCTAssertEqual(outcome, .paused, "4 s and 120 points is still only a pause")
    }

    func testAFastMoveIsOnlyAPauseWhenItIsShort() {
        var w = fresh()
        XCTAssertEqual(w.observe(.pointerMoved(CGPoint(x: 400, y: 100)), at: 1), .paused)
        XCTAssertEqual(w.observe(.pointerMoved(CGPoint(x: 800, y: 100)), at: 1.2), .paused, "300+ points but not three seconds")
    }

    func testAGapStartsANewRun() {
        var w = fresh()
        for i in 1...20 { w.observe(.pointerMoved(CGPoint(x: 100 + Double(i) * 8, y: 100)), at: Double(i) * 0.1) }
        // a pause of a second (more than the gap), then movement again: the earlier 2 s don't count
        var outcome = DriveHandBack.Outcome.none
        for i in 1...20 { outcome = w.observe(.pointerMoved(CGPoint(x: 300 + Double(i) * 8, y: 100)), at: 4 + Double(i) * 0.1) }
        XCTAssertEqual(outcome, .paused, "two runs of two seconds are not one run of four")
    }

    // MARK: words and the wire

    func testTheCardNamesTheGoalAndSaysWhatItCovers() {
        let t = DriveCopy.cardTarget(goal: "fill in the form")
        XCTAssertTrue(t.hasPrefix("fill in the form\n"))
        for part in ["scroll, click, type and move sliders", "send, buy, pay, delete or post still asks", "never types a password", "Esc"] {
            XCTAssertTrue(t.contains(part), part)
        }
        XCTAssertEqual(DriveCopy.cardSeconds, 45)
        XCTAssertEqual(DriveCopy.expiryLine(), "No answer in 45 s means No.")
        XCTAssertFalse(t.lowercased().contains("always"), "there is no always approve")
    }

    func testTheBannerHasTheEscHint() {
        XCTAssertEqual(DriveCopy.activeLine(goal: "fill in the form"), "Driving · fill in the form · Esc stops")
        XCTAssertEqual(DriveCopy.activeLine(goal: " "), "Driving · Esc stops")
        XCTAssertTrue(DriveCopy.pausedLine(goal: "x").hasSuffix("Esc stops"))
    }

    func testTheHelloListsDriveOnlyWhenTheAppCanCarryItOut() {
        XCTAssertFalse(AppCapabilities.list(screenActions: true).contains("drive"), "not unless the app asks for it")
        XCTAssertTrue(AppCapabilities.list(screenActions: true, drive: true).contains("drive"))
        XCTAssertFalse(AppCapabilities.list(screenActions: false, drive: true).contains("drive"), "a drive needs the screen")
        XCTAssertEqual(AppCapabilities.list(screenActions: true, drive: true).filter { $0 == "drive" }.count, 1)
    }

    func testTheSwitchIsOnUnlessSetOff() {
        XCTAssertTrue(DriveCopy.isOn(nil))
        XCTAssertTrue(DriveCopy.isOn(true))
        XCTAssertFalse(DriveCopy.isOn(false))
    }

    func testTheWireForTheDrive() throws {
        func json(_ r: ServeRequest) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: r.line()) as? [String: Any])
        }
        let card = try json(.approve(id: "t1", request: "a1", approved: true, viaCard: true))
        XCTAssertEqual(card["via"] as? String, "card")
        XCTAssertEqual(card["decision"] as? String, "yes")
        XCTAssertNil(try json(.approve(id: "t1", request: "a1", approved: true))["via"], "a job row's answer isn't the card")
        let stop = try json(.driveStop(id: "t1", reason: "typing"))
        XCTAssertEqual(stop["type"] as? String, "drive_stop")
        XCTAssertEqual(stop["reason"] as? String, "typing")
        let withDrive = try json(.send(id: "t1", text: "x", imagePath: "/tmp/x.jpg", allowPointing: true, screenActions: true,
                                       screenSimpleSteps: true, drive: true))
        XCTAssertEqual(withDrive["drive"] as? Bool, true)
        for (label, req) in [
            ("no simple steps", ServeRequest.send(id: "t1", text: "x", imagePath: "/tmp/x.jpg", allowPointing: true,
                                                 screenActions: true, screenSimpleSteps: false, drive: true)),
            ("no screen actions", .send(id: "t1", text: "x", imagePath: "/tmp/x.jpg", allowPointing: true, screenActions: false,
                                        screenSimpleSteps: true, drive: true)),
            ("no image", .send(id: "t1", text: "x", imagePath: nil, allowPointing: true, screenActions: true,
                               screenSimpleSteps: true, drive: true)),
            ("not asked", .send(id: "t1", text: "x", imagePath: "/tmp/x.jpg", allowPointing: true, screenActions: true,
                                screenSimpleSteps: true, drive: false)),
        ] {
            XCTAssertNil(try json(req)["drive"], "no drive flag with \(label)")
        }
    }

    func testTheDriveEventsDecode() throws {
        let card = ServeEvent.decode(#"{"type":"approval","id":"t1","request":"a1","action":"take over your screen","target":"fill in","drive":{"goal":"fill in the form","seconds":45}}"#)
        XCTAssertEqual(card, .driveApproval(id: "t1", request: "a1", goal: "fill in the form", seconds: 45))
        let long = ServeEvent.decode(#"{"type":"approval","id":"t1","request":"a1","drive":{"goal":"g","seconds":9999}}"#)
        XCTAssertEqual(long, .driveApproval(id: "t1", request: "a1", goal: "g", seconds: 45), "the card never waits longer than 45 s")
        let plain = ServeEvent.decode(#"{"type":"approval","id":"t1","request":"a1","action":"x","target":"y","drive":{"goal":""}}"#)
        XCTAssertEqual(plain, .approval(id: "t1", request: "a1", action: "x", target: "y"), "an empty goal is a plain card")
        XCTAssertEqual(ServeEvent.decode(#"{"type":"drive","id":"t1","state":"active","goal":"g"}"#),
                       .drive(id: "t1", event: DriveEvent(state: .active, goal: "g")))
        XCTAssertEqual(ServeEvent.decode(#"{"type":"drive","id":"t1","state":"ended","goal":"g","reason":"typing","spoken":"s","written":"w","steps":4}"#),
                       .drive(id: "t1", event: DriveEvent(state: .ended, goal: "g", reason: "typing", spoken: "s", written: "w", steps: 4)))
        XCTAssertEqual(ServeEvent.decode(#"{"type":"drive","id":"t1","state":"nope"}"#), .unknown(type: "drive"))
        let act = ServeEvent.decode(#"{"type":"screen_action","id":"t1","request":"s1","mode":"quiet","drive":true,"step":{"kind":"scroll","x":1,"y":1,"direction":"down","amount":3,"label":""}}"#)
        guard case let .screenAction(_, _, step, mode, _, drive)? = act else { return XCTFail("\(String(describing: act))") }
        XCTAssertNotNil(step)
        XCTAssertEqual(mode, .quiet)
        XCTAssertTrue(drive)
        guard case let .screenAction(_, _, _, _, _, plainDrive)? = ServeEvent.decode(
            #"{"type":"screen_action","id":"t1","request":"s1","drive":"yes","step":{"kind":"press_key","key":"tab","modifiers":[]}}"#) else { return XCTFail() }
        XCTAssertFalse(plainDrive, "only JSON true marks a drive step")
    }
}
