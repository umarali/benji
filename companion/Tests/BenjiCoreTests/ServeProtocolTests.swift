import XCTest
@testable import BenjiCore

/// The `benji --serve` protocol (D-72). Event lines are the proposal's example and lines the engine
/// sent in the live run of 2026-10-31.
final class ServeProtocolTests: XCTestCase {
    private func text(_ r: ServeRequest) -> String { String(decoding: r.line(), as: UTF8.self) }

    // MARK: requests

    func testRequestLines() {
        XCTAssertEqual(text(.hello), #"{"protocol":1,"type":"hello"}"# + "\n")
        XCTAssertEqual(text(.send(id: "t1", text: "tidy my Downloads", imagePath: nil, allowPointing: false)),
                       #"{"id":"t1","text":"tidy my Downloads","type":"send"}"# + "\n")
        XCTAssertEqual(text(.send(id: "t2", text: "where?", imagePath: "/tmp/s.png", allowPointing: true)),
                       #"{"allow_pointing":true,"id":"t2","image":"/tmp/s.png","text":"where?","type":"send"}"# + "\n")
        XCTAssertEqual(text(.approve(id: "t1", request: "a1", approved: true)),
                       #"{"decision":"yes","id":"t1","request":"a1","type":"approve"}"# + "\n")
        XCTAssertEqual(text(.approve(id: "t1", request: "a1", approved: false)),
                       #"{"decision":"no","id":"t1","request":"a1","type":"approve"}"# + "\n")
        XCTAssertEqual(text(.cancel(id: "t3")), #"{"id":"t3","type":"cancel"}"# + "\n")
        XCTAssertEqual(text(.reset), #"{"type":"reset"}"# + "\n")
        XCTAssertEqual(text(.shutdown), #"{"type":"shutdown"}"# + "\n")
    }

    /// The fields benji/prompts.py's TurnInfo.from_request reads: `spoken` (JSON true), and
    /// `screen` only with `allow_pointing`.
    func testSendCarriesSpokenAndScreen() {
        let geo = ScreenshotGeometry(width: 1330, height: 864,
                                     notch: .init(x1: 577, y1: 0, x2: 753, y2: 28),
                                     menuBarHeight: 33, builtIn: true, displayCount: 1)
        XCTAssertEqual(text(.send(id: "t1", text: "can you hear me?", imagePath: nil, allowPointing: false, spoken: true)),
                       #"{"id":"t1","spoken":true,"text":"can you hear me?","type":"send"}"# + "\n")
        XCTAssertEqual(text(.send(id: "t2", text: "circle the notch", imagePath: "/tmp/s.jpg", allowPointing: true,
                                  spoken: true, screen: geo)),
                       #"{"allow_pointing":true,"id":"t2","image":"/tmp/s.jpg","screen":{"display":"built-in","#
                       + #""displays":1,"height":864,"menu_bar":33,"notch":[577,0,753,28],"width":1330},"#
                       + #""spoken":true,"text":"circle the notch","type":"send"}"# + "\n")
        // No screenshot to draw on: the geometry stays home.
        XCTAssertEqual(text(.send(id: "t3", text: "hi", imagePath: nil, allowPointing: false, screen: geo)),
                       #"{"id":"t3","text":"hi","type":"send"}"# + "\n")
    }

    func testRestoreCarriesExchangesInOrder() {
        let line = text(.restore([.init(user: "my favourite colour is teal", assistant: "Noted."),
                                  .init(user: "and yours?", assistant: "I don't have one.")]))
        XCTAssertEqual(line, #"{"exchanges":[{"assistant":"Noted.","user":"my favourite colour is teal"},"#
                       + #"{"assistant":"I don't have one.","user":"and yours?"}],"type":"restore"}"# + "\n")
    }

    func testRequestTextIsEscapedOnOneLine() {
        let line = text(.send(id: "t1", text: "line one\nline \"two\"", imagePath: nil, allowPointing: false))
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(line.contains(#""text":"line one\nline \"two\"""#))
    }

    // MARK: events

    func testReady() {
        let e = ServeEvent.decode(#"{"type": "ready", "protocol": 1, "version": "0.1.0", "provider": "claude", "model": "claude-sonnet-4-5", "destination": "Anthropic", "approval_timeout": 90.0}"#)
        XCTAssertEqual(e, .ready(ServeReady(protocolVersion: 1, version: "0.1.0", provider: "claude",
                                            model: "claude-sonnet-4-5", destination: "Anthropic",
                                            approvalTimeout: 90)))
    }

    func testReadyNamesTheHostAndWhetherTheModelReadsImages() {
        // D-147: an open-model provider says which host gets the data and whether Screen can work
        let e = ServeEvent.decode(#"{"type":"ready","protocol":1,"version":"0.1.0","provider":"deepseek","model":"deepseek-v4-pro","destination":"DeepSeek","host":"api.deepseek.com","vision":false}"#)
        XCTAssertEqual(e, .ready(ServeReady(protocolVersion: 1, version: "0.1.0", provider: "deepseek",
                                            model: "deepseek-v4-pro", destination: "DeepSeek", approvalTimeout: nil,
                                            host: "api.deepseek.com", vision: false)))
        guard case let .ready(older)? = ServeEvent.decode(#"{"type":"ready","protocol":1,"version":"1","provider":"p","model":"m","destination":"d"}"#) else { return XCTFail() }
        XCTAssertNil(older.host)
        XCTAssertTrue(older.vision, "an engine that doesn't say could always read images")
    }

    func testTurnEvents() {
        XCTAssertEqual(ServeEvent.decode(#"{"type": "tool", "id": "t2", "name": "write_file", "detail": "serve-test.txt"}"#),
                       .tool(id: "t2", name: "write_file", detail: "serve-test.txt"))
        XCTAssertEqual(ServeEvent.decode(#"{"type":"approval","id":"t1","request":"a1","action":"move files","target":"~/Downloads/Archive"}"#),
                       .approval(id: "t1", request: "a1", action: "move files", target: "~/Downloads/Archive"))
        XCTAssertEqual(ServeEvent.decode(#"{"type":"approval_result","id":"t1","request":"a1","approved":true,"why":"yes"}"#),
                       .approvalResult(id: "t1", request: "a1", approved: true, why: "yes"))
        XCTAssertEqual(ServeEvent.decode(#"{"type":"approval_result","id":"t1","request":"a2","approved":false,"why":"timeout"}"#),
                       .approvalResult(id: "t1", request: "a2", approved: false, why: "timeout"))
        XCTAssertEqual(ServeEvent.decode(#"{"type": "answer", "id": "t1", "text": "2 + 2 equals 4.", "targets": []}"#),
                       .answer(id: "t1", text: "2 + 2 equals 4.", targets: []))
        XCTAssertEqual(ServeEvent.decode(#"{"type": "usage", "id": "t1", "calls": 1, "input_tokens": 2404, "output_tokens": 14, "cache_read_tokens": 0, "cache_write_tokens": 0}"#),
                       .usage(id: "t1", calls: 1, inputTokens: 2404, outputTokens: 14))
        XCTAssertEqual(ServeEvent.decode(#"{"type": "done", "id": "t3", "status": "cancelled"}"#),
                       .done(id: "t3", status: "cancelled"))
    }

    func testErrors() {
        XCTAssertEqual(ServeEvent.decode(#"{"type":"error","id":"t2","code":"busy","text":"a turn is running"}"#),
                       .error(id: "t2", code: "busy", text: "a turn is running"))
        XCTAssertEqual(ServeEvent.decode(#"{"type":"error","code":"protocol","text":"unsupported protocol 2"}"#),
                       .error(id: nil, code: "protocol", text: "unsupported protocol 2"))
    }

    func testAnswerTargets() {
        let line = #"{"type":"answer","id":"t1","text":"Fill in the name, then save.","targets":["#
            + #"{"kind":"box","coords":[280,118,780,190],"label":"Customer name"},"#
            + #"{"kind":"point","coords":[1069,702],"label":"Save invoice"}]}"#
        XCTAssertEqual(ServeEvent.decode(line), .answer(id: "t1", text: "Fill in the name, then save.", targets: [
            PointingTarget(shape: .box(x1: 280, y1: 118, x2: 780, y2: 190), label: "Customer name"),
            PointingTarget(shape: .point(x: 1069, y: 702), label: "Save invoice"),
        ]))
    }

    func testMalformedTargetsAreDroppedAndAtMostThreeKept() {
        let line = #"{"type":"answer","id":"t1","text":"x","targets":["#
            + #"{"kind":"point","coords":[1,2]},"#
            + #"{"kind":"box","coords":[1,2,3]},"#
            + #"{"kind":"ring","coords":[1,2]},"#
            + #"{"kind":"point","coords":["a",2]},"#
            + #"{"kind":"point","coords":[3,4],"label":"b"},"#
            + #"{"kind":"point","coords":[5,6]},"#
            + #"{"kind":"point","coords":[7,8]}]}"#
        guard case let .answer(_, _, targets) = ServeEvent.decode(line) else { return XCTFail("not an answer") }
        XCTAssertEqual(targets.map(\.shape), [.point(x: 1, y: 2), .point(x: 3, y: 4), .point(x: 5, y: 6)])
        XCTAssertEqual(targets[1].label, "b")
    }

    func testDrawingTargets() {
        let line = #"{"type":"answer","id":"t1","text":"x","targets":["#
            + #"{"kind":"circle","coords":[1,2,3,4],"label":"c"},"#
            + #"{"kind":"path","coords":[1,2,3,4,5,6]},"#
            + #"{"kind":"path","coords":[1,2,3]},"#
            + #"{"kind":"ARROW","coords":[1,2,3,4]},"#
            + #"{"kind":"scribble","coords":[1,2,3,4]},"#
            + #"{"kind":"note","coords":[7,8],"label":"Here"}]}"#
        guard case let .answer(_, _, targets) = ServeEvent.decode(line) else { return XCTFail("not an answer") }
        XCTAssertEqual(targets.map(\.shape), [.circle(x1: 1, y1: 2, x2: 3, y2: 4), .path([1, 2, 3, 4, 5, 6]), .note(x: 7, y: 8)])
        XCTAssertEqual(targets.last?.label, "Here")
    }

    func testNotEventsAndUnknownTypes() {
        XCTAssertNil(ServeEvent.decode("Benji 0.1.0 serving"))
        XCTAssertNil(ServeEvent.decode(""))
        XCTAssertNil(ServeEvent.decode(#"["type","ready"]"#))
        XCTAssertNil(ServeEvent.decode(#"{"type": 3}"#))
        XCTAssertEqual(ServeEvent.decode(#"{"type":"progress","id":"t1"}"#), .unknown(type: "progress"))
    }

    /// D-98: lines benji/serve.py sends (selftest checks the engine side).
    func testAcceptedAndActivity() {
        XCTAssertEqual(ServeEvent.decode(#"{"type": "accepted", "id": "t1"}"#), .accepted(id: "t1"))
        XCTAssertEqual(ServeEvent.decode(#"{"type": "activity", "id": "t1", "kind": "command"}"#),
                       .activity(id: "t1", kind: "command", name: nil))
        XCTAssertEqual(ServeEvent.decode(#"{"type": "activity", "id": "a1", "kind": "file_saved", "name": "keep.txt"}"#),
                       .activity(id: "a1", kind: "file_saved", name: "keep.txt"))
    }

    // MARK: approval timeout

    func testAppApprovalTimeoutStaysBelowPals() {
        XCTAssertEqual(ServeProtocol.approvalTimeout(engineTimeout: 90), 60)
        XCTAssertEqual(ServeProtocol.approvalTimeout(engineTimeout: nil), 60)
        XCTAssertEqual(ServeProtocol.approvalTimeout(engineTimeout: 30), 25)
        XCTAssertEqual(ServeProtocol.approvalTimeout(engineTimeout: 3), 1)
        XCTAssertEqual(ServeProtocol.approvalTimeout(engineTimeout: 0), 60)
        XCTAssertEqual(ServeProtocol.approvalTimeout(engineTimeout: .infinity), 60)
        for engine in stride(from: 6.0, through: 200, by: 7) {
            XCTAssertLessThan(ServeProtocol.approvalTimeout(engineTimeout: engine), engine)
        }
    }

    func testRingTargetOfABoxIsItsCentre() {
        XCTAssertEqual(PointingTarget(shape: .box(x1: 10, y1: 20, x2: 30, y2: 60), label: "a").ringTarget,
                       PointTarget(x: 20, y: 40, label: "a"))
        XCTAssertEqual(PointingTarget(shape: .point(x: 5, y: 6), label: "b").ringTarget,
                       PointTarget(x: 5, y: 6, label: "b"))
    }
}

final class ServeProtocolQuietTests: XCTestCase {
    private func text(_ r: ServeRequest) -> String { String(decoding: r.line(), as: UTF8.self) }

    func testHelloWithCapabilitiesIsTheOldHelloPlusAList() {
        XCTAssertEqual(text(.hello), #"{"protocol":1,"type":"hello"}"# + "\n", "the old shape is unchanged")
        XCTAssertEqual(text(.helloWith(capabilities: ["pointing", "jobs"])),
                       #"{"capabilities":["pointing","jobs"],"protocol":1,"type":"hello"}"# + "\n")
    }

    func testPrewarmIsOneSmallRequest() {
        XCTAssertEqual(text(.prewarm), #"{"type":"prewarm"}"# + "\n")
    }

    func testCapabilitiesListOnlyWhatTheAppCanCarryOut() {
        XCTAssertTrue(AppCapabilities.list(screenActions: true).contains("screen_actions"))
        XCTAssertFalse(AppCapabilities.list(screenActions: false).contains("screen_actions"))
        XCTAssertFalse(AppCapabilities.list(screenActions: true, jobs: false).contains("jobs"))
        XCTAssertFalse(AppCapabilities.list(screenActions: true, jobs: false, browser: true).contains("browser"), "browser reach is for jobs")
        // The names are the engine's (benji/serve.py APP_CAPS).
        XCTAssertTrue(Set(AppCapabilities.list(screenActions: true)).isSubset(of: ["pointing", "screen_actions", "cards", "figures", "jobs", "browser", "prewarm", "schedules", "drive", "browser_act", "browser_upload"]))
        XCTAssertTrue(AppCapabilities.list(screenActions: true).contains("schedules"))
        XCTAssertFalse(AppCapabilities.list(screenActions: true, jobs: false).contains("schedules"), "schedules are for jobs")
        XCTAssertFalse(AppCapabilities.list(screenActions: true, schedules: false).contains("schedules"))
    }

    func testReadyKeepsWorkingWithAndWithoutTheEnginesList() {
        let old = #"{"type":"ready","protocol":1,"version":"0.1","provider":"claude","model":"m","destination":"Anthropic"}"#
        guard case let .ready(a)? = ServeEvent.decode(old) else { return XCTFail() }
        XCTAssertEqual(a.capabilities, [])
        let new = #"{"type":"ready","protocol":1,"version":"0.1","provider":"claude","model":"m","destination":"Anthropic","capabilities":["prewarm","policy",7]}"#
        guard case let .ready(b)? = ServeEvent.decode(new) else { return XCTFail() }
        XCTAssertEqual(b.capabilities, ["prewarm", "policy"], "a name that isn't text is dropped")
    }

    func testAnErrorWithAReasonStillDecodes() {
        let line = #"{"type":"error","id":"t1","code":"provider","reason":"auth","text":"x.com didn't accept the API key (HTTP 401)."}"#
        guard case let .error(id, code, text)? = ServeEvent.decode(line) else { return XCTFail() }
        XCTAssertEqual(id, "t1"); XCTAssertEqual(code, "provider"); XCTAssertTrue(text.contains("401"))
    }
}
