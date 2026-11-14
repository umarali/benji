import XCTest
@testable import BenjiCore

/// Acting on the screen (D-123): the step's wire form, the card's words, the mapping to the
/// display, the refusals, the one-approval-one-step gate, the take-over watch and settling.
final class ScreenActionTests: XCTestCase {
    private func step(_ json: String) -> ScreenStep? {
        let o = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        return ScreenStep.decode(o)
    }

    // MARK: the step

    /// Lines as benji/tools.py `screen_step` writes them (selftest.py checks that side).
    func testDecodesWhatTheEngineSends() {
        XCTAssertEqual(step(#"{"kind":"click","x":412,"y":300,"button":"left","count":1,"label":"Save button"}"#),
                       .click(x: 412, y: 300, button: .left, count: 1, label: "Save button"))
        XCTAssertEqual(step(#"{"kind":"click","x":1,"y":2,"button":"right","count":2,"label":"a"}"#),
                       .click(x: 1, y: 2, button: .right, count: 2, label: "a"))
        XCTAssertEqual(step(#"{"kind":"scroll","x":600,"y":400,"direction":"down","amount":3,"label":""}"#),
                       .scroll(x: 600, y: 400, direction: .down, amount: 3, label: ""))
        XCTAssertEqual(step(#"{"kind":"type_text","text":"Hello, café"}"#), .typeText("Hello, café"))
        XCTAssertEqual(step(#"{"kind":"press_key","key":"l","modifiers":["cmd","shift"]}"#),
                       .pressKey(key: "l", modifiers: [.cmd, .shift]))
        XCTAssertEqual(step(#"{"kind":"press_key","key":"return","modifiers":[]}"#), .pressKey(key: "return", modifiers: []))
    }

    func testRefusesMalformedSteps() {
        for bad in [
            #"{"kind":"click","x":1,"y":2,"label":""}"#, #"{"kind":"click","x":1,"y":2}"#,
            #"{"kind":"click","x":-1,"y":2,"label":"a"}"#, #"{"kind":"click","x":1.5,"y":2,"label":"a"}"#,
            #"{"kind":"click","x":"1","y":2,"label":"a"}"#, #"{"kind":"click","x":1,"y":2,"label":"a","count":3}"#,
            #"{"kind":"click","x":1,"y":2,"label":"a","button":"middle"}"#,
            #"{"kind":"scroll","x":1,"y":2,"direction":"down","amount":11}"#,
            #"{"kind":"scroll","x":1,"y":2,"direction":"down","amount":0}"#,
            #"{"kind":"scroll","x":1,"y":2,"direction":"sideways","amount":3}"#,
            #"{"kind":"scroll","x":1,"y":2,"direction":"down"}"#,
            #"{"kind":"type_text","text":"a\nb"}"#, #"{"kind":"type_text","text":"a\tb"}"#, #"{"kind":"type_text","text":""}"#,
            #"{"kind":"press_key","key":"hyper","modifiers":[]}"#, #"{"kind":"press_key","key":"a","modifiers":["fn"]}"#,
            #"{"kind":"press_key","key":"a","modifiers":"cmd"}"#, #"{"kind":"drag","x":1,"y":2}"#, #"{}"#,
        ] {
            XCTAssertNil(step(bad), bad)
        }
        XCTAssertNil(ScreenStep.decode(["kind": "type_text", "text": String(repeating: "x", count: 501)]))
        XCTAssertNotNil(ScreenStep.decode(["kind": "type_text", "text": String(repeating: "x", count: 500)]))
    }

    // MARK: a drag

    private let drag = ScreenStep.drag(x: 100, y: 200, toX: 900, toY: 700, label: "report.pdf to the Trash")
    private let finder = ScreenTarget(pid: 42, bundleID: "com.apple.finder", appName: "Finder")
    private let dock = ScreenTarget(pid: 43, bundleID: "com.apple.dock", appName: "Dock")

    func testADragDecodesAndWritesTheEnginesForm() throws {
        XCTAssertEqual(step(#"{"kind":"drag","x":100,"y":200,"to_x":900,"to_y":700,"label":"report.pdf to the Trash"}"#), drag)
        let round = try XCTUnwrap(ScreenStep.decode(drag.object))
        XCTAssertEqual(round, drag)
        XCTAssertEqual(Set(drag.object.keys), ["kind", "x", "y", "to_x", "to_y", "label"], "the keys benji/tools.py writes")
        XCTAssertEqual(drag.point?.x, 100)
        XCTAssertEqual(drag.endPoint?.y, 700)
        XCTAssertFalse(drag.usesKeyboard)
        XCTAssertNil(ScreenStep.click(x: 1, y: 1, button: .left, count: 1, label: "a").endPoint)
    }

    func testAMalformedDragIsRefused() {
        for bad in [
            #"{"kind":"drag","x":1,"y":2,"to_x":3,"label":"a"}"#, #"{"kind":"drag","x":1,"y":2,"to_y":3,"label":"a"}"#,
            #"{"kind":"drag","to_x":3,"to_y":4,"label":"a"}"#, #"{"kind":"drag","x":1,"y":2,"to_x":3,"to_y":4}"#,
            #"{"kind":"drag","x":1,"y":2,"to_x":3,"to_y":4,"label":"  "}"#,
            #"{"kind":"drag","x":-1,"y":2,"to_x":3,"to_y":4,"label":"a"}"#,
            #"{"kind":"drag","x":1,"y":2,"to_x":-3,"to_y":4,"label":"a"}"#,
            #"{"kind":"drag","x":1,"y":2,"to_x":3.5,"to_y":4,"label":"a"}"#,
            #"{"kind":"drag","x":1,"y":2,"to_x":"3","to_y":4,"label":"a"}"#,
            #"{"kind":"drag","x":5,"y":5,"to_x":5,"to_y":5,"label":"not a drag"}"#,
        ] {
            XCTAssertNil(step(bad), bad)
        }
    }

    func testTheCardAndTheLinesSayWhatADragMoves() {
        XCTAssertEqual(ScreenStepCard.action(drag, app: "Finder"), "drag in Finder")
        XCTAssertEqual(ScreenStepCard.action(drag, app: "Finder", endApp: "Finder"), "drag in Finder")
        XCTAssertEqual(ScreenStepCard.action(drag, app: "Finder", endApp: "Dock"), "drag from Finder to Dock")
        XCTAssertEqual(ScreenStepCard.action(drag, app: nil), "drag on the screen")
        XCTAssertEqual(ScreenStepCard.target(drag),
                       "report.pdf to the Trash. This may move or delete something; then Benji looks at the screen again")
        XCTAssertEqual(ScreenStepCard.acting(drag, app: "Finder"), "Dragging report.pdf to the Trash in Finder")
        XCTAssertEqual(ScreenStepCard.done(drag, app: "Finder"), "Dragged report.pdf to the Trash in Finder.")
        XCTAssertEqual(ScreenStepCard.done(drag, app: "Finder", endApp: "Dock"), "Dragged report.pdf to the Trash from Finder to Dock.")
    }

    private func dragRefusal(start: ScreenTarget?, end: ScreenTarget?, approved: Int32? = 42, approvedEnd: Int32? = nil) -> ScreenRefusal? {
        ScreenActionPolicy.refusal(for: drag, target: start, accessibility: true, secureInput: false, ownPID: 99,
                                   approvedPID: approved, endTarget: end, approvedEndPID: approvedEnd)
    }

    func testADragIsRefusedAtEitherEnd() {
        let own = ScreenTarget(pid: 99, bundleID: "com.emerssive.heybenji.app", appName: "Benji")
        let vault = ScreenTarget(pid: 42, bundleID: CaptureExclusions.passwordManagers.first!, appName: "Vault")
        let secure = ScreenTarget(pid: 42, bundleID: "com.apple.Safari", appName: "Safari", roles: ["AXSecureTextField"])
        XCTAssertNil(dragRefusal(start: finder, end: finder), "both ends in the app on the card")
        XCTAssertEqual(dragRefusal(start: own, end: finder), .benjiWindow)
        XCTAssertEqual(dragRefusal(start: finder, end: own), .benjiWindow)
        XCTAssertEqual(dragRefusal(start: vault, end: finder), .passwordManager)
        XCTAssertEqual(dragRefusal(start: finder, end: vault), .passwordManager)
        XCTAssertEqual(dragRefusal(start: secure, end: finder), .secureField)
        XCTAssertEqual(dragRefusal(start: finder, end: secure), .secureField)
        XCTAssertEqual(dragRefusal(start: finder, end: nil), .nothingThere)
        XCTAssertEqual(dragRefusal(start: nil, end: finder), .nothingThere)
    }

    func testEachEndOfADragMustBeTheAppTheCardNamed() {
        XCTAssertEqual(dragRefusal(start: dock, end: finder), .appChanged, "the start moved to another app")
        XCTAssertEqual(dragRefusal(start: finder, end: dock), .appChanged, "the card named one app, the end is in another")
        XCTAssertNil(dragRefusal(start: finder, end: dock, approvedEnd: 43), "the card named both")
        XCTAssertEqual(dragRefusal(start: finder, end: finder, approvedEnd: 43), .appChanged, "the end changed since the card")
        XCTAssertNil(dragRefusal(start: finder, end: dock, approved: nil), "no app was found for the card")
    }

    func testAClickIgnoresTheDragsEnd() {
        let click = ScreenStep.click(x: 1, y: 1, button: .left, count: 1, label: "a")
        XCTAssertNil(ScreenActionPolicy.refusal(for: click, target: finder, accessibility: true, secureInput: false, ownPID: 99,
                                                approvedPID: 42, endTarget: nil))
    }

    func testTheGateCarriesBothAppsOfADrag() {
        var gate = ScreenStepGate()
        gate.approve(drag, appPID: 42, endAppPID: 43)
        let approval = gate.take(drag)
        XCTAssertEqual(approval?.appPID, 42)
        XCTAssertEqual(approval?.endAppPID, 43)
        XCTAssertNil(gate.take(drag), "one approval, one step")
    }

    private let from = CGPoint(x: 100, y: 200), to = CGPoint(x: 400, y: 600)

    func testTheDragPathPressesMovesAndLetsGoInOrder() {
        let events = DragPath.events(from: from, to: to)
        XCTAssertEqual(events.first, .move(from))
        XCTAssertEqual(events[1], .down(from))
        XCTAssertEqual(events.last, .up(to))
        XCTAssertEqual(events.filter { if case .down = $0 { return true } else { return false } }.count, 1)
        XCTAssertEqual(events.filter { if case .up = $0 { return true } else { return false } }.count, 1, "one release")
        XCTAssertEqual(Array(events[2..<(2 + DragPath.holdEvents)]), Array(repeating: .dragged(from), count: DragPath.holdEvents),
                       "held still after the press")
        XCTAssertEqual(events[events.count - 2], .dragged(to), "held over the target before letting go")
        for pair in zip(events, events.dropFirst()) {
            XCTAssertLessThanOrEqual(hypot(pair.1.point.x - pair.0.point.x, pair.1.point.y - pair.0.point.y), DragPath.spacing + 0.5,
                                     "no jumps along the path")
        }
    }

    func testAVeryLongDragIsCappedAndAShortOneStillMoves() {
        let long = DragPath.events(from: .zero, to: CGPoint(x: 6000, y: 3000))
        XCTAssertLessThanOrEqual(long.count, DragPath.maxSegments + 2 * DragPath.holdEvents + 3)
        XCTAssertEqual(long.last, .up(CGPoint(x: 6000, y: 3000)))
        let short = DragPath.events(from: .zero, to: CGPoint(x: 1, y: 0))
        XCTAssertEqual(short.filter { $0 == .dragged(CGPoint(x: 0.5, y: 0)) }.count, 1, "at least two steps")
    }

    /// Replays a whole drag through the watch, as the actuator posts it, with `input` after event `at`.
    private func replay(_ input: TakeOverWatch.Input? = nil, at: Int = 0, synthetic: Bool = false) -> TakeOverWatch {
        var watch = TakeOverWatch(pointer: CGPoint(x: 5, y: 5))
        watch.benjiActs()
        for (i, event) in DragPath.events(from: from, to: to).enumerated() {
            watch.benjiPosts(event)
            watch.observe(.pointerMoved(event.point), synthetic: true)
            if i == at, let input { watch.observe(input, synthetic: synthetic) }
        }
        return watch
    }

    func testBenjisOwnDragIsNotATakeOver() {
        XCTAssertFalse(replay().tookOver, "marked events are Benji's")
        // A monitor that loses the marker sees each event exactly where Benji put it.
        var watch = TakeOverWatch(pointer: CGPoint(x: 5, y: 5))
        watch.benjiActs()
        for event in DragPath.events(from: from, to: to) {
            watch.benjiPosts(event)
            switch event {
            case .down: watch.observe(.mouseDown(event.point))
            default: watch.observe(.pointerMoved(event.point))
            }
        }
        XCTAssertFalse(watch.tookOver)
    }

    func testAnUnmarkedEventLateOnThePathIsNotATakeOver() {
        var watch = TakeOverWatch(pointer: from)
        watch.benjiActs()
        let events = DragPath.events(from: from, to: to)
        for event in events[0..<(events.count / 2)] { watch.benjiPosts(event) }
        watch.observe(.pointerMoved(events[events.count / 2 - 3].point))
        XCTAssertFalse(watch.tookOver)
    }

    func testAUsersSmallMoveMidDragIsATakeOver() {
        let mid = DragPath.events(from: from, to: to).count / 2
        let p = DragPath.events(from: from, to: to)[mid].point
        // Less than a click's tolerance: Benji's next event rewrites the pointer, so moves don't add up.
        XCTAssertTrue(replay(.pointerMoved(CGPoint(x: p.x + 3, y: p.y - 2)), at: mid).tookOver)
    }

    func testAnyOtherInputOfTheUsersMidDragIsATakeOver() {
        let mid = DragPath.events(from: from, to: to).count / 2
        let p = DragPath.events(from: from, to: to)[mid].point
        XCTAssertTrue(replay(.mouseDown(p), at: mid).tookOver, "a real press at the very spot")
        XCTAssertTrue(replay(.scroll(p), at: mid).tookOver)
        XCTAssertTrue(replay(.keyDown(KeyCodes.escape), at: mid).tookOver)
        XCTAssertTrue(replay(.keyDown(0), at: mid).tookOver)
        XCTAssertTrue(replay(.modifiersChanged, at: mid).tookOver)
    }

    func testBenjisOwnPressDuringTheHoldIsNotATakeOverIfItsMarkerIsLost() {
        var watch = TakeOverWatch(pointer: from)
        watch.benjiActs()
        let events = DragPath.events(from: from, to: to)
        for event in events[0..<(2 + DragPath.holdEvents)] { watch.benjiPosts(event) }
        watch.observe(.mouseDown(from))
        XCTAssertFalse(watch.tookOver, "the press arrives late, while the pointer is still where it was pressed")
    }

    func testAfterTheReleaseTheUsualToleranceIsBack() {
        var watch = replay()
        XCTAssertFalse(watch.tookOver)
        watch.observe(.pointerMoved(CGPoint(x: to.x + 3, y: to.y)))
        XCTAssertFalse(watch.tookOver, "the drag is over: small moves are tolerated again")
        watch.observe(.pointerMoved(CGPoint(x: to.x + 30, y: to.y)))
        XCTAssertTrue(watch.tookOver, "and a real move still stops the settling")
    }

    func testLettingGoGoesBackToTheStartAndReleasesOnce() {
        let user = CGPoint(x: 700, y: 50)
        let events = DragPath.letGo(start: from, pointer: user)
        XCTAssertEqual(events, [.dragged(from), .up(from), .move(user)],
                       "released where it began, so nothing lands on what the pointer was crossing")
    }

    func testTheStoppedLineSaysTheDragWasLetGo() {
        XCTAssertEqual(ScreenActionPolicy.tookOverLine + ScreenActionPolicy.dragLetGo,
                       "Stopped: you took over, so Benji let go where the drag began.")
    }

    func testModifiersAreOrderedAndDeduplicated() {
        XCTAssertEqual(step(#"{"kind":"press_key","key":"z","modifiers":["shift","cmd","shift"]}"#),
                       .pressKey(key: "z", modifiers: [.cmd, .shift]))
        XCTAssertEqual(step(#"{"kind":"press_key","key":"tab"}"#), .pressKey(key: "tab", modifiers: []))
    }

    func testWireFormRoundTrips() {
        let steps: [ScreenStep] = [.click(x: 1, y: 2, button: .right, count: 2, label: "Row"),
                                   .scroll(x: 3, y: 4, direction: .left, amount: 10, label: "the list"),
                                   .typeText("hi"), .pressKey(key: "page_down", modifiers: [.option])]
        for s in steps { XCTAssertEqual(ScreenStep.decode(s.object), s) }
    }

    /// The same cases as selftest.py's `key_may_commit` check.
    func testKeysThatMaySendOrDeleteAreFlagged() {
        for s: ScreenStep in [.pressKey(key: "return", modifiers: []), .pressKey(key: "enter", modifiers: [.shift]),
                              .pressKey(key: "q", modifiers: [.cmd]), .pressKey(key: "w", modifiers: [.cmd]),
                              .pressKey(key: "delete", modifiers: [.cmd])] {
            XCTAssertTrue(s.mayCommit, "\(s)")
        }
        for s: ScreenStep in [.pressKey(key: "tab", modifiers: []), .pressKey(key: "page_down", modifiers: []),
                              .pressKey(key: "delete", modifiers: []), .pressKey(key: "l", modifiers: [.cmd]),
                              .typeText("x"), .click(x: 1, y: 1, button: .left, count: 1, label: "Send")] {
            XCTAssertFalse(s.mayCommit, "\(s)")
        }
    }

    func testEveryKeyNameHasACode() {
        let named: [String] = ["return", "enter", "tab", "space", "delete", "forward_delete", "escape", "up", "down",
                               "left", "right", "home", "end", "page_up", "page_down", "minus", "equal", "comma",
                               "period", "slash", "semicolon", "quote", "left_bracket", "right_bracket", "backslash", "grave"]
        let letters: [String] = "abcdefghijklmnopqrstuvwxyz".map { String($0) }
        let digits: [String] = (0...9).map { String($0) }
        let functions: [String] = (1...12).map { "f\($0)" }
        let names = named + letters + digits + functions
        XCTAssertEqual(Set(names).count, 74)
        XCTAssertEqual(KeyCodes.table.count, 74, "the same names as benji/tools.py KEYS, no more")
        for n in names { XCTAssertNotNil(KeyCodes.code(for: n), n) }
        XCTAssertEqual(KeyCodes.code(for: "return"), 36)
        XCTAssertEqual(KeyCodes.code(for: "escape"), KeyCodes.escape)
        XCTAssertEqual(KeyCodes.flags([.cmd, .shift]), 0x0012_0000)
        XCTAssertEqual(KeyCodes.flags([]), 0)
    }

    // MARK: the card

    func testCardNamesTheActionTheAppAndTheTarget() {
        let click = ScreenStep.click(x: 412, y: 300, button: .left, count: 1, label: "Save button")
        XCTAssertEqual(ScreenStepCard.action(click, app: "TextEdit"), "click in TextEdit")
        XCTAssertEqual(ScreenStepCard.action(click, app: nil), "click on the screen")
        XCTAssertEqual(ScreenStepCard.target(click), "Save button; then Benji looks at the screen again")
        XCTAssertEqual(ScreenStepCard.action(.click(x: 1, y: 1, button: .left, count: 2, label: "a"), app: "Finder"),
                       "double-click in Finder")
        XCTAssertEqual(ScreenStepCard.action(.click(x: 1, y: 1, button: .right, count: 1, label: "a"), app: "Finder"),
                       "right-click in Finder")
        let scroll = ScreenStep.scroll(x: 1, y: 1, direction: .down, amount: 5, label: "the page")
        XCTAssertEqual(ScreenStepCard.action(scroll, app: "Safari"), "scroll down in Safari")
        XCTAssertEqual(ScreenStepCard.target(scroll), "the page, about half a screen; then Benji looks at the screen again")
        XCTAssertEqual(ScreenStepCard.action(.typeText("hi"), app: "Notes"), "type in Notes")
        XCTAssertEqual(ScreenStepCard.target(.typeText("hi")),
                       "“hi” into the field that has the keyboard; then Benji looks at the screen again")
        let send = ScreenStep.pressKey(key: "return", modifiers: [.cmd])
        XCTAssertEqual(ScreenStepCard.action(send, app: "Mail"), "press a key in Mail")
        XCTAssertEqual(ScreenStepCard.target(send),
                       "⌘Return. This may send, submit, delete or close something; then Benji looks at the screen again")
    }

    func testKeysReadAsMenusShowThem() {
        XCTAssertEqual(ScreenStepCard.keys("l", [.cmd, .shift]), "⇧⌘L")
        XCTAssertEqual(ScreenStepCard.keys("page_down", []), "Page Down")
        XCTAssertEqual(ScreenStepCard.keys("tab", [.control, .option]), "⌃⌥Tab")
    }

    func testLongTypedTextIsShortenedOnTheCard() {
        let target = ScreenStepCard.target(.typeText(String(repeating: "a", count: 300)))
        XCTAssertTrue(target.hasPrefix("“" + String(repeating: "a", count: 119) + "…”"))
    }

    func testDoneLineForTheModel() {
        XCTAssertEqual(ScreenStepCard.done(.click(x: 1, y: 1, button: .left, count: 1, label: "Save button"), app: "TextEdit"),
                       "Clicked Save button in TextEdit.")
        XCTAssertEqual(ScreenStepCard.done(.click(x: 1, y: 1, button: .left, count: 2, label: "notes.md"), app: nil),
                       "Double-clicked notes.md.")
        XCTAssertEqual(ScreenStepCard.done(.scroll(x: 1, y: 1, direction: .up, amount: 1, label: ""), app: "Safari"),
                       "Scrolled up a few lines in Safari.")
        XCTAssertEqual(ScreenStepCard.done(.typeText("hey"), app: "Notes"), "Typed 3 characters in Notes.")
        XCTAssertEqual(ScreenStepCard.done(.pressKey(key: "tab", modifiers: []), app: nil), "Pressed Tab.")
    }

    // MARK: where it acts

    func testPixelsMapOntoTheDisplay() {
        // A 1512×982-point display shown in a 1330×864 screenshot, and an external one to its right.
        let size = CGSize(width: 1330, height: 864)
        let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let p = ScreenActionGeometry.appKitPoint(x: 665, y: 432, pixelSize: size, screenFrame: builtIn)!
        XCTAssertEqual(p.x, 756, accuracy: 0.01)
        XCTAssertEqual(p.y, 491, accuracy: 0.01)
        let corner = ScreenActionGeometry.appKitPoint(x: 1330, y: 864, pixelSize: size, screenFrame: builtIn)!
        XCTAssertEqual(corner, CGPoint(x: 1511, y: 1), "the far edge stays on this display")
        XCTAssertEqual(ScreenActionGeometry.appKitPoint(x: 0, y: 0, pixelSize: size, screenFrame: builtIn),
                       CGPoint(x: 0, y: 982))
        XCTAssertNil(ScreenActionGeometry.appKitPoint(x: 1331, y: 10, pixelSize: size, screenFrame: builtIn))
        let external = CGRect(x: 1512, y: -98, width: 1920, height: 1080)
        let q = ScreenActionGeometry.appKitPoint(x: 960, y: 540, pixelSize: CGSize(width: 1920, height: 1080),
                                                 screenFrame: external)!
        XCTAssertEqual(q, CGPoint(x: 2472, y: 442))
        XCTAssertEqual(ScreenActionGeometry.globalPoint(q, primaryMaxY: 982), CGPoint(x: 2472, y: 540))
        XCTAssertEqual(ScreenActionGeometry.globalPoint(CGPoint(x: 10, y: 982), primaryMaxY: 982), CGPoint(x: 10, y: 0))
    }

    func testAppKitPointsMapBackToPixels() {
        let size = CGSize(width: 1330, height: 864), frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let p = ScreenActionGeometry.appKitPoint(x: 400, y: 300, pixelSize: size, screenFrame: frame)!
        let back = ScreenActionGeometry.pixel(for: p, pixelSize: size, screenFrame: frame)!
        XCTAssertEqual(back.x, 400)
        XCTAssertEqual(back.y, 300)
        XCTAssertNil(ScreenActionGeometry.pixel(for: CGPoint(x: 2000, y: 10), pixelSize: size, screenFrame: frame))
    }

    func testTheCardNamesTheAppWhoseWindowWasUnderThePoint() {
        let windows = [WindowInfo(id: 1, ownerPID: 99, frame: CGRect(x: 0, y: 600, width: 400, height: 400)),   // Benji's panel
                       WindowInfo(id: 2, ownerPID: 7, alpha: 0, frame: CGRect(x: 0, y: 0, width: 800, height: 800)),
                       WindowInfo(id: 3, ownerPID: 42, frame: CGRect(x: 0, y: 0, width: 1000, height: 1000)),
                       WindowInfo(id: 4, ownerPID: 50, frame: CGRect(x: 0, y: 0, width: 1500, height: 1000))]
        XCTAssertEqual(ScreenActionGeometry.windowOwner(at: CGPoint(x: 100, y: 700), windows: windows, excludingPID: 99), 42)
        XCTAssertEqual(ScreenActionGeometry.windowOwner(at: CGPoint(x: 1200, y: 10), windows: windows, excludingPID: 99), 50)
        XCTAssertNil(ScreenActionGeometry.windowOwner(at: CGPoint(x: 1600, y: 10), windows: windows, excludingPID: 99))
    }

    func testAClickThroughOverlayIsNotTheAppThatGetsTheClick() {
        let p = CGPoint(x: 100, y: 100)
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let panel = WindowInfo(id: 1, ownerPID: 99, layer: 25, frame: frame)
        let overlay = WindowInfo(id: 2, ownerPID: 7, layer: 1000, frame: frame)
        let safari = WindowInfo(id: 3, ownerPID: 42, frame: frame)
        let desktop = WindowInfo(id: 4, ownerPID: 50, layer: -2147483603, frame: frame)

        XCTAssertEqual(ScreenActionGeometry.windowOwner(at: p, windows: [overlay, desktop], excludingPID: 99, hit: 50), 50,
                       "the overlay lets the click through to the desktop, so the card names the desktop's app")
        XCTAssertEqual(ScreenActionGeometry.windowOwner(at: p, windows: [overlay, desktop], excludingPID: 99, hit: 7), 7,
                       "the overlay does take the click")
        XCTAssertEqual(ScreenActionGeometry.windowOwner(at: p, windows: [overlay, safari, desktop], excludingPID: 99, hit: 50), 7,
                       "a normal window was in front of the desktop in the picture: the desktop isn't adopted, so the step is refused")
        XCTAssertEqual(ScreenActionGeometry.windowOwner(at: p, windows: [overlay, safari, desktop], excludingPID: 99, hit: 42), 42,
                       "the overlay lets the click through to the normal window under it")
        XCTAssertEqual(ScreenActionGeometry.windowOwner(at: p, windows: [overlay, desktop], excludingPID: 99, hit: 60), 7,
                       "what's there now wasn't at that point in the picture at all")
        XCTAssertEqual(ScreenActionGeometry.windowOwner(at: p, windows: [panel, overlay, desktop], excludingPID: 99, hit: 99), 7,
                       "Benji's own panel covering the point says nothing about what's under it")
        XCTAssertEqual(ScreenActionGeometry.windowOwner(at: p, windows: [overlay, desktop], excludingPID: 99), 7,
                       "no hit test: the front window, as before")
    }

    func testScrollIsARunOfSmallWheelEvents() {
        let display = CGSize(width: 1512, height: 982)
        let down = ScreenActionGeometry.scrollDeltas(direction: .down, amount: 5, displaySize: display)
        XCTAssertEqual(down.reduce(0) { $0 + Int($1.vertical) }, -442)   // 982 × 0.09 × 5, rounded
        XCTAssertTrue(down.allSatisfy { $0.horizontal == 0 && -$0.vertical <= ScreenActionGeometry.scrollStep && $0.vertical < 0 })
        let up = ScreenActionGeometry.scrollDeltas(direction: .up, amount: 1, displaySize: display)
        XCTAssertEqual(up.map(\.vertical), [40, 40, 8])
        let right = ScreenActionGeometry.scrollDeltas(direction: .right, amount: 10, displaySize: display)
        XCTAssertEqual(right.reduce(0) { $0 + Int($1.horizontal) }, -1361)
        XCTAssertTrue(ScreenActionGeometry.scrollDeltas(direction: .left, amount: 2, displaySize: display)
            .allSatisfy { $0.horizontal > 0 && $0.vertical == 0 })
        XCTAssertEqual(ScreenActionGeometry.scrollDeltas(direction: .down, amount: 99, displaySize: display).count,
                       ScreenActionGeometry.scrollDeltas(direction: .down, amount: 10, displaySize: display).count)
    }

    // MARK: refusals

    private let own: Int32 = 99
    private let click = ScreenStep.click(x: 1, y: 1, button: .left, count: 1, label: "Save")
    private func refusal(_ target: ScreenTarget?, accessibility: Bool = true, secureInput: Bool = false,
                         approved: Int32? = 42) -> ScreenRefusal? {
        ScreenActionPolicy.refusal(for: click, target: target, accessibility: accessibility, secureInput: secureInput,
                                   ownPID: own, approvedPID: approved)
    }

    func testRefusals() {
        let app = ScreenTarget(pid: 42, bundleID: "com.apple.TextEdit", appName: "TextEdit", roles: ["AXButton"])
        XCTAssertNil(refusal(app))
        XCTAssertNil(refusal(app, approved: nil), "no app was found for the card: any app but Benji")
        XCTAssertEqual(refusal(app, accessibility: false), .noAccessibility)
        XCTAssertEqual(refusal(app, secureInput: true), .secureInput)
        XCTAssertEqual(refusal(nil), .nothingThere)
        XCTAssertEqual(refusal(ScreenTarget(pid: own, bundleID: "com.emerssive.heybenji.app", appName: "Benji")), .benjiWindow)
        XCTAssertEqual(refusal(ScreenTarget(pid: 42, bundleID: "com.1password.1password", appName: "1Password")), .passwordManager)
        XCTAssertEqual(refusal(ScreenTarget(pid: 42, bundleID: "com.apple.Safari", appName: "Safari",
                                            roles: ["AXTextField"], subrole: "AXSecureTextField")), .secureField)
        XCTAssertEqual(refusal(ScreenTarget(pid: 42, bundleID: nil, appName: nil, roles: ["AXSecureTextField"])), .secureField)
        XCTAssertEqual(refusal(ScreenTarget(pid: 43, bundleID: "com.apple.Notes", appName: "Notes")), .appChanged)
        XCTAssertEqual(ScreenActionPolicy.precheck(accessibility: true, secureInput: false), nil)
        XCTAssertEqual(ScreenActionPolicy.precheck(accessibility: true, secureInput: true), .secureInput)
        for why: ScreenRefusal in [.noAccessibility, .secureInput, .benjiWindow, .passwordManager, .secureField, .appChanged,
                                   .nothingThere, .outsideScreenshot, .noScreenshot, .notApproved, .unreadable] {
            XCTAssertFalse(why.text.isEmpty)
        }
        XCTAssertEqual(ScreenActionPolicy.tookOverLine, "Stopped: you took over")
    }

    // MARK: how it acts

    func testAPlainClickOnAControlIsAPress() {
        let button = ScreenTarget(pid: 1, bundleID: nil, appName: nil, roles: ["AXButton"], actions: [["AXPress"]])
        XCTAssertEqual(ClickMethod.choose(for: click, target: button), .press(level: 0))
        let label = ScreenTarget(pid: 1, bundleID: nil, appName: nil, roles: ["AXStaticText", "AXButton"],
                                 actions: [[], ["AXPress", "AXShowMenu"]])
        XCTAssertEqual(ClickMethod.choose(for: click, target: label), .press(level: 1))
        let link = ScreenTarget(pid: 1, bundleID: nil, appName: nil, roles: ["AXStaticText", "AXGroup", "AXLink"],
                                actions: [[], [], ["AXPress"]])
        XCTAssertEqual(ClickMethod.choose(for: click, target: link), .press(level: 2))
        let deep = ScreenTarget(pid: 1, bundleID: nil, appName: nil, roles: ["AXStaticText", "AXGroup", "AXGroup", "AXLink"],
                                actions: [[], [], [], ["AXPress"]])
        XCTAssertEqual(ClickMethod.choose(for: click, target: deep), .events)
        let field = ScreenTarget(pid: 1, bundleID: nil, appName: nil, roles: ["AXTextField"], actions: [["AXConfirm"]])
        XCTAssertEqual(ClickMethod.choose(for: click, target: field), .events)
        let noPress = ScreenTarget(pid: 1, bundleID: nil, appName: nil, roles: ["AXButton"], actions: [[]])
        XCTAssertEqual(ClickMethod.choose(for: click, target: noPress), .events)
        XCTAssertEqual(ClickMethod.choose(for: .click(x: 1, y: 1, button: .left, count: 2, label: "a"), target: button), .events)
        XCTAssertEqual(ClickMethod.choose(for: .click(x: 1, y: 1, button: .right, count: 1, label: "a"), target: button), .events)
    }

    func testTypingInsertsInANativeFieldAndTypesInAWebPage() {
        let native = ScreenTarget(pid: 1, bundleID: nil, appName: nil, roles: ["AXTextField"], canInsertText: true)
        XCTAssertEqual(TypingMethod.choose(target: native), .insert)
        XCTAssertEqual(TypingMethod.choose(target: ScreenTarget(pid: 1, bundleID: nil, appName: nil, roles: ["AXTextArea"],
                                                                inWebArea: true, canInsertText: true)), .keys)
        XCTAssertEqual(TypingMethod.choose(target: ScreenTarget(pid: 1, bundleID: nil, appName: nil, roles: ["AXTextField"])),
                       .keys)
        XCTAssertEqual(TypingMethod.choose(target: ScreenTarget(pid: 1, bundleID: nil, appName: nil, roles: ["AXGroup"],
                                                                canInsertText: true)), .keys)
    }

    func testTypedTextIsChunkedWithoutSplittingACharacter() {
        let text = String(repeating: "ab", count: 15) + "👍🏽" + "é"
        let chunks = TypingMethod.chunks(text)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= TypingMethod.chunk })
        XCTAssertTrue(chunks.contains { $0.contains("👍🏽") })
        XCTAssertEqual(TypingMethod.chunks(""), [])
    }

    // MARK: one approval, one step

    func testTheGateLetsOnlyTheApprovedStepThroughOnce() {
        var gate = ScreenStepGate()
        XCTAssertNil(gate.take(click), "nothing approved")
        gate.approve(click, appPID: 42)
        XCTAssertEqual(gate.take(click)?.appPID, 42)
        XCTAssertNil(gate.take(click), "used up")
        gate.approve(click, appPID: 42)
        XCTAssertNil(gate.take(.click(x: 2, y: 1, button: .left, count: 1, label: "Save")), "another point")
        XCTAssertNil(gate.take(click), "a mismatch uses the approval up too")
        gate.approve(click, appPID: nil)
        gate.clear()
        XCTAssertNil(gate.take(click))
    }

    // MARK: the user taking over

    func testSmallJitterIsNotATakeOverButAMoveIs() {
        var w = TakeOverWatch(pointer: CGPoint(x: 100, y: 100))
        XCTAssertFalse(w.observe(.pointerMoved(CGPoint(x: 103, y: 104))))
        XCTAssertTrue(w.observe(.pointerMoved(CGPoint(x: 120, y: 100))))
        XCTAssertTrue(w.observe(.pointerMoved(CGPoint(x: 100, y: 100))), "it stays taken over")
    }

    func testBenjisOwnEventsAreNotATakeOver() {
        var w = TakeOverWatch(pointer: CGPoint(x: 100, y: 100))
        XCTAssertFalse(w.observe(.mouseDown(CGPoint(x: 900, y: 500)), synthetic: true))
        XCTAssertFalse(w.observe(.keyDown(KeyCodes.escape), synthetic: true), "Benji pressing Esc itself")
        w.benjiMovedPointer(to: CGPoint(x: 900, y: 500))
        w.benjiActs()
        XCTAssertFalse(w.observe(.pointerMoved(CGPoint(x: 900, y: 500))), "the pointer is where Benji put it")
        XCTAssertFalse(w.observe(.mouseDown(CGPoint(x: 901, y: 499))), "Benji's click, marker lost")
        XCTAssertFalse(w.observe(.scroll(CGPoint(x: 900, y: 500))))
        XCTAssertTrue(w.observe(.mouseDown(CGPoint(x: 300, y: 300))), "a click somewhere else is the user's")
    }

    func testTheUsersClicksKeysAndEscStopIt() {
        var click = TakeOverWatch(pointer: .zero)
        XCTAssertTrue(click.observe(.mouseDown(.zero)), "not acting: any click is the user's")
        var scroll = TakeOverWatch(pointer: .zero)
        XCTAssertTrue(scroll.observe(.scroll(.zero)))
        var key = TakeOverWatch(pointer: .zero)
        key.benjiActs(keys: [36])
        XCTAssertFalse(key.observe(.keyDown(36)), "the key Benji is pressing")
        XCTAssertTrue(key.observe(.keyDown(0)), "another key")
        var esc = TakeOverWatch(pointer: .zero)
        esc.benjiActs(keys: [KeyCodes.escape])
        XCTAssertTrue(esc.observe(.keyDown(KeyCodes.escape)), "the user's Esc, even while Benji presses Esc")
        var mods = TakeOverWatch(pointer: .zero)
        XCTAssertTrue(mods.observe(.modifiersChanged), "the talk key, or any modifier")
        var ownMods = TakeOverWatch(pointer: .zero)
        ownMods.benjiActs(keys: [37], modifiers: true)
        XCTAssertFalse(ownMods.observe(.modifiersChanged))
        ownMods.benjiDone()
        XCTAssertTrue(ownMods.observe(.keyDown(37)), "after Benji is done, its key is the user's")
    }

    // MARK: settling

    func testSamplesMatchDespiteACaretButNotALoadingPage() {
        let a = [UInt8](repeating: 120, count: 1000)
        var caret = a
        for i in 0..<5 { caret[i] = 255 }
        XCTAssertTrue(ScreenSettle.same(a, caret))
        var loading = a
        for i in 0..<6 { loading[i] = 0 }
        XCTAssertFalse(ScreenSettle.same(a, loading))
        var faint = a
        for i in 0..<500 { faint[i] = 140 }
        XCTAssertTrue(ScreenSettle.same(a, faint), "a small shift in brightness isn't movement")
        XCTAssertFalse(ScreenSettle.same(a, Array(a.prefix(999))), "different sizes")
        XCTAssertFalse(ScreenSettle.same([], []))
        XCTAssertTrue(ScreenSettle.ready(elapsed: 0.5, lastTwoSame: true))
        XCTAssertFalse(ScreenSettle.ready(elapsed: 0.5, lastTwoSame: false))
        XCTAssertTrue(ScreenSettle.ready(elapsed: ScreenSettle.longest, lastTwoSame: false))
    }

    func testTheSwitchIsOnUnlessTurnedOff() {
        XCTAssertTrue(ScreenActions.isOn(nil))
        XCTAssertTrue(ScreenActions.isOn(true))
        XCTAssertFalse(ScreenActions.isOn(false))
        XCTAssertTrue(ScreenActions.isOn("NO"), "only a real boolean turns it off")
    }

    // MARK: the panel's activity line

    func testStepsOnTheScreenAreAnActivityThatChangesSomething() {
        XCTAssertEqual(TurnActivity(kind: "screen", name: nil), .actedOnScreen)
        XCTAssertTrue(TurnActivity.actedOnScreen.changesSomething, "no Retry: it could act twice")
        XCTAssertEqual(ActivityLine.text([.lookedAtScreen, .actedOnScreen]), "Looked at your screen · Took a step on your screen")
        XCTAssertEqual(ActivityLine.text([.actedOnScreen, .actedOnScreen, .actedOnScreen]), "Took 3 steps on your screen")
    }
}

/// The screen-step lines of the `benji --serve` protocol (D-123), as benji/serve.py writes and reads them.
final class ScreenActionProtocolTests: XCTestCase {
    private func text(_ r: ServeRequest) -> String { String(decoding: r.line(), as: UTF8.self) }

    func testSendSaysTheAppCanActOnlyWithAScreenshot() {
        XCTAssertEqual(text(.send(id: "t1", text: "scroll down", imagePath: "/tmp/s.jpg", allowPointing: true, screenActions: true)),
                       #"{"allow_pointing":true,"id":"t1","image":"/tmp/s.jpg","screen_actions":true,"text":"scroll down","type":"send"}"# + "\n")
        XCTAssertEqual(text(.send(id: "t2", text: "x", imagePath: nil, allowPointing: true, screenActions: true)),
                       #"{"allow_pointing":true,"id":"t2","text":"x","type":"send"}"# + "\n")
        XCTAssertEqual(text(.send(id: "t3", text: "x", imagePath: "/tmp/s.jpg", allowPointing: false, screenActions: true)),
                       #"{"id":"t3","image":"/tmp/s.jpg","text":"x","type":"send"}"# + "\n")
    }

    func testScreenResultLines() {
        XCTAssertEqual(text(.screenResult(id: "t1", request: "s1", result: ScreenStepResult(
            status: .done, text: "Clicked Save button in TextEdit.", imagePath: "/tmp/after.jpg"))),
            #"{"id":"t1","image":"/tmp/after.jpg","request":"s1","status":"done","text":"Clicked Save button in TextEdit.","type":"screen_result"}"# + "\n")
        XCTAssertEqual(text(.screenResult(id: "t1", request: "s2", result: .refused(.secureField))),
                       #"{"id":"t1","request":"s2","status":"refused","text":"That's a password field; Benji never clicks or types in one.","type":"screen_result"}"# + "\n")
        XCTAssertEqual(text(.screenResult(id: "t1", request: "s3", result: ScreenStepResult(status: .stopped, text: "Stopped: you took over"))),
                       #"{"id":"t1","request":"s3","status":"stopped","text":"Stopped: you took over","type":"screen_result"}"# + "\n")
    }

    /// The lines selftest.py's serve checks see the engine write.
    func testDecodesScreenEvents() {
        let save = ScreenStep.click(x: 412, y: 300, button: .left, count: 1, label: "Save button")
        XCTAssertEqual(ServeEvent.decode(#"{"type":"approval","id":"s1","request":"a1","action":"click on the screen","target":"Save button at 412,300","screen":{"kind":"click","x":412,"y":300,"button":"left","count":1,"label":"Save button"}}"#),
                       .screenApproval(id: "s1", request: "a1", action: "click on the screen", target: "Save button at 412,300", step: save))
        XCTAssertEqual(ServeEvent.decode(#"{"type":"approval","id":"s1","request":"a1","action":"click on the screen","target":"x","screen":{"kind":"click"}}"#),
                       .approval(id: "s1", request: "a1", action: "click on the screen", target: "x"),
                       "a step this build can't read: the plain card, worded by the engine")
        XCTAssertEqual(ServeEvent.decode(#"{"type":"screen_action","id":"s1","request":"s1","step":{"kind":"click","x":412,"y":300,"button":"left","count":1,"label":"Save button"}}"#),
                       .screenAction(id: "s1", request: "s1", step: save))
        XCTAssertEqual(ServeEvent.decode(#"{"type":"screen_action","id":"s1","request":"s2","step":{"kind":"teleport"}}"#),
                       .screenAction(id: "s1", request: "s2", step: nil), "still answered: refused")
        XCTAssertEqual(ServeEvent.decode(#"{"type":"activity","id":"s1","kind":"screen"}"#),
                       .activity(id: "s1", kind: "screen", name: nil))
    }
}
