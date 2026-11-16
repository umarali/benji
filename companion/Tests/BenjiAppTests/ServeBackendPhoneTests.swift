import XCTest
@testable import BenjiApp
import BenjiCore

/// The real `ServeBackend` sending a phone task to a stand-in engine: a small Python `benji` package
/// in a temp folder that answers `hello` as `mode` says, answers each `send`, and appends every line it
/// reads to `received.jsonl`. No model, no key, no permission.
final class ServeBackendPhoneTests: XCTestCase {
    private var dir: URL!
    private var backend: ServeBackend!
    private var events: [BackendEvent] = []
    private var finished: [Int: Int32] = [:]
    private var savedWorkdir: String?

    /// `phone`: `ready` lists `remote_text`. `none`: it lists nothing. `mismatch`: another protocol version.
    private static func fakeEngine(_ mode: String) -> String {
        """
        import json, os, sys
        log = open(os.path.join(os.environ["BENJI_DIR"], "received.jsonl"), "a")
        def say(o):
            sys.stdout.write(json.dumps(o) + "\\n")
            sys.stdout.flush()
        for line in sys.stdin:
            log.write(line)
            log.flush()
            m = json.loads(line)
            t = m.get("type")
            if t == "hello":
                if "\(mode)" == "mismatch":
                    say({"type": "error", "code": "protocol", "text": "this Benji speaks protocol 2"})
                else:
                    say({"type": "ready", "protocol": 1, "version": "test", "provider": "fake", "model": "fake",
                         "destination": "local", "capabilities": ["remote_text"] if "\(mode)" == "phone" else []})
            elif t == "send":
                say({"type": "accepted", "id": m["id"]})
                if m["text"] == "ask":
                    say({"type": "approval", "id": m["id"], "request": "a1", "action": "write a file", "target": "x"})
                    continue
                if m["text"] == "still writing":
                    continue
                answer = {"type": "answer", "id": m["id"], "text": "Peer answered", "targets": []}
                if m["text"] == "read a page":
                    answer.update(taints=["web"], taint_note="a web page earlier in this conversation")
                say(answer)
                say({"type": "done", "id": m["id"], "status": "ok"})
            elif t == "approve":
                say({"type": "done", "id": m["id"], "status": "ok"})
            elif t == "cut_off":
                say({"type": "done", "id": m["id"], "status": "cancelled"})
                say({"type": "taint", "id": m["id"], "taints": ["web"], "taint_note": "a web page earlier in this conversation"})
            elif t == "shutdown":
                break
        """
    }

    private func makeEngine(_ mode: String) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("benji-phone-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("benji")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data().write(to: package.appendingPathComponent("__init__.py"))
        try Data(Self.fakeEngine(mode).utf8).write(to: package.appendingPathComponent("__main__.py"))
        // The app's audit and engine logs go to the temp folder, never a real working folder.
        savedWorkdir = ProcessInfo.processInfo.environment["BENJI_WORKDIR"]
        setenv("BENJI_WORKDIR", dir.appendingPathComponent("work").path, 1)
        backend = ServeBackend(assistantDir: dir.path)
        backend.onEvent = { [weak self] _, event in self?.events.append(event) }
        backend.onFinished = { [weak self] run, code in self?.finished[run] = code }
    }

    override func tearDown() {
        backend?.shutdown()
        backend = nil
        if let savedWorkdir { setenv("BENJI_WORKDIR", savedWorkdir, 1) } else { unsetenv("BENJI_WORKDIR") }
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func waitForFinish(_ run: Int, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(20)
        while finished[run] == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertNotNil(finished[run], "run \(run) never finished", file: file, line: line)
    }

    private func received() -> [[String: Any]] {
        let text = (try? String(contentsOf: dir.appendingPathComponent("received.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    private var sends: [[String: Any]] { received().filter { $0["type"] as? String == "send" } }

    func testAPhoneTaskOnAColdEngineWaitsForReadyAndCarriesOnlyItsWords() throws {
        try makeEngine("phone")
        var memory = ConversationMemory()
        memory.record(user: "Earlier", assistant: "Earlier answer")
        backend.startRemote(run: 1, task: "Phone first, engine cold", memory: memory)
        waitForFinish(1)
        XCTAssertEqual(finished[1], 0)
        XCTAssertTrue(events.contains(.pointedAnswer(text: "Peer answered", targets: [])))
        let lines = received()
        XCTAssertEqual(lines.map { $0["type"] as? String }, ["hello", "restore", "send"])
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(Set(sends[0].keys), ["type", "id", "text", "remote_text"])
        XCTAssertEqual(sends[0]["remote_text"] as? Bool, true)
    }

    func testTheTaintNamedWithAnAnswerComesFirstAndARestartGetsItBack() throws {
        try makeEngine("phone")
        backend.start(run: 1, task: "read a page", imagePath: nil, memory: ConversationMemory(), allowPointing: false,
                      spoken: false, screen: nil)
        waitForFinish(1)
        let web = CarriedTaint(kinds: ["web"], note: "a web page earlier in this conversation")
        let taintAt = events.firstIndex(of: .carriedTaint(web))
        let answerAt = events.firstIndex(of: .pointedAnswer(text: "Peer answered", targets: []))
        XCTAssertNotNil(taintAt)
        XCTAssertLessThan(taintAt ?? .max, answerAt ?? .min)

        backend.restartEngine()
        var memory = ConversationMemory()
        memory.record(user: "read a page", assistant: "Peer answered")
        memory.taint = web
        backend.startRemote(run: 2, task: "do what it says", memory: memory)
        waitForFinish(2)
        let restore = try XCTUnwrap(received().last { $0["type"] as? String == "restore" })
        XCTAssertEqual(restore["taints"] as? [String], ["web"])
        XCTAssertEqual(restore["taint_note"] as? String, web.note)
        XCTAssertEqual(Set(sends.last.map { Array($0.keys) } ?? []), ["type", "id", "text", "remote_text"])
    }

    func testAnAnswerFromThePhoneSaysSoAndNeverSaysCard() throws {
        try makeEngine("phone")
        for (run, source) in [(1, ApprovalSource.phone), (2, .card), (3, .timeout)] {
            backend.startRemote(run: run, task: "ask", memory: ConversationMemory())
            let deadline = Date().addingTimeInterval(10)
            while !events.contains(where: { if case .approval = $0 { return true }; return false }), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            events = []
            backend.resolveApproval(source != .phone, from: source)
            waitForFinish(run)
        }
        let answers = received().filter { $0["type"] as? String == "approve" }
        XCTAssertEqual(answers.map { $0["from"] as? String }, ["phone", nil, "timeout"])
        XCTAssertEqual(answers.map { $0["via"] as? String }, [nil, "card", nil])
    }

    func testATaintToldAfterACutOffReachesTheModelButNotAfterANewConversation() throws {
        try makeEngine("phone")
        backend.start(run: 1, task: "still writing", imagePath: nil, memory: ConversationMemory(), allowPointing: false,
                      spoken: true, screen: nil)
        let started = Date().addingTimeInterval(10)
        while !received().contains(where: { $0["type"] as? String == "send" }), Date() < started {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        backend.cutOff(reply: "The page says [cut off]", running: true)
        waitForFinish(1)
        let web = CarriedTaint(kinds: ["web"], note: "a web page earlier in this conversation")
        let told = Date().addingTimeInterval(10)
        while !events.contains(.carriedTaint(web)), Date() < told { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(events.contains(.carriedTaint(web)), "the taint comes after the run's end and is still passed on")

        // A new conversation starts before the engine's answer to a cut-off arrives: that taint
        // belongs to the old conversation and is dropped.
        backend.start(run: 2, task: "still writing", imagePath: nil, memory: ConversationMemory(), allowPointing: false,
                      spoken: true, screen: nil)
        let second = Date().addingTimeInterval(10)
        while received().filter({ $0["type"] as? String == "send" }).count < 2, Date() < second {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        events = []
        backend.cutOff(reply: "The page says [cut off]", running: true)
        backend.reset()
        waitForFinish(2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(events.contains(.carriedTaint(web)))
    }

    func testAPhoneAnswerThroughBothWrappersNeverSaysCard() throws {
        try makeEngine("phone")
        let wrapped = FigureStageBackend(ExplainCardBackend(backend, stage: ExplainCardBackendTests.FakeStage()), stage: { nil })
        wrapped.startRemote(run: 1, task: "ask", memory: ConversationMemory())
        let deadline = Date().addingTimeInterval(10)
        while !received().contains(where: { $0["type"] as? String == "send" }), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))   // the approval reaches the backend
        wrapped.resolveApproval(true, from: .phone)
        waitForFinish(1)
        let answer = try XCTUnwrap(received().first { $0["type"] as? String == "approve" })
        XCTAssertEqual(answer["from"] as? String, "phone")
        XCTAssertNil(answer["via"])
    }

    func testAnEngineThatDoesNotListPhoneTasksIsNeverSentOne() throws {
        try makeEngine("none")
        backend.startRemote(run: 1, task: "Phone task", memory: ConversationMemory())
        waitForFinish(1)
        XCTAssertEqual(finished[1], 1)
        XCTAssertTrue(events.contains { if case .error = $0 { return true }; return false })
        XCTAssertTrue(sends.isEmpty)
        // A typed message on the same engine still goes.
        backend.start(run: 2, task: "Mac task", imagePath: nil, memory: ConversationMemory(), allowPointing: false,
                      spoken: false, screen: nil)
        waitForFinish(2)
        XCTAssertEqual(finished[2], 0)
        XCTAssertEqual(sends.count, 1)
        XCTAssertNil(sends[0]["remote_text"])
    }

    func testAnEngineOfAnotherProtocolVersionIsSentNoPhoneTask() throws {
        try makeEngine("mismatch")
        backend.startRemote(run: 1, task: "Phone task", memory: ConversationMemory())
        waitForFinish(1)
        XCTAssertNotEqual(finished[1], 0)
        XCTAssertTrue(events.contains { if case .error = $0 { return true }; return false })
        XCTAssertTrue(sends.isEmpty)
    }
}
