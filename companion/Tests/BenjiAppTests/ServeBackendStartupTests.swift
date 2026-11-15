import XCTest
@testable import BenjiApp
import BenjiCore

/// The real `ServeBackend` against a stand-in engine: a small Python `benji` package in a temp folder
/// that answers `hello` with `ready` (jobs and schedules on), answers every `send` with `accepted`
/// and `done` (or exits with code 3 for the text "crash"), and appends every line it reads to
/// `received.jsonl`. Checks what each engine process was told when it starts at awkward moments.
final class ServeBackendStartupTests: XCTestCase {
    private var dir: URL!
    private var backend: ServeBackend!
    private var finished: [Int: Int32] = [:]
    private var savedWorkdir: String?

    private static let fakeEngine = """
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
            say({"type": "ready", "protocol": 1, "version": "test", "provider": "fake", "model": "fake",
                 "destination": "local", "jobs": True, "schedules": True})
        elif t == "send":
            if m["text"] == "crash":
                os._exit(3)
            say({"type": "accepted", "id": m["id"]})
            say({"type": "done", "id": m["id"], "status": "ok"})
        elif t == "shutdown":
            break
    """

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("benji-serve-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("benji")
        try! FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try! Data().write(to: package.appendingPathComponent("__init__.py"))
        try! Data(Self.fakeEngine.utf8).write(to: package.appendingPathComponent("__main__.py"))
        // The app's audit and engine logs go to the temp folder, never a real working folder.
        savedWorkdir = ProcessInfo.processInfo.environment["BENJI_WORKDIR"]
        setenv("BENJI_WORKDIR", dir.appendingPathComponent("work").path, 1)
        finished = [:]
        backend = ServeBackend(assistantDir: dir.path)
        backend.onFinished = { [weak self] run, code in self?.finished[run] = code }
    }

    override func tearDown() {
        backend.shutdown()
        backend = nil
        if let savedWorkdir { setenv("BENJI_WORKDIR", savedWorkdir, 1) } else { unsetenv("BENJI_WORKDIR") }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: helpers

    private func send(_ run: Int, _ task: String, memory: ConversationMemory = ConversationMemory()) {
        backend.start(run: run, task: task, imagePath: nil, memory: memory, allowPointing: false,
                      spoken: false, screen: nil)
    }

    private func waitForFinish(_ run: Int, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(20)
        while finished[run] == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertNotNil(finished[run], "run \(run) never finished", file: file, line: line)
    }

    /// Every line the stand-in engines read, in order, across processes.
    private func received() -> [[String: Any]] {
        let text = (try? String(contentsOf: dir.appendingPathComponent("received.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    /// What the newest engine process read: the lines after the last `hello`.
    private func receivedByLatestEngine() -> [[String: Any]] {
        let all = received()
        guard let last = all.lastIndex(where: { $0["type"] as? String == "hello" }) else { return [] }
        return Array(all[(last + 1)...])
    }

    private func types(_ lines: [[String: Any]]) -> [String] { lines.compactMap { $0["type"] as? String } }

    private func memory(_ pairs: [(String, String)]) -> ConversationMemory {
        var m = ConversationMemory()
        for (user, assistant) in pairs { m.record(user: user, assistant: assistant) }
        return m
    }

    // MARK: the conversation reaches every engine process

    func testAnEngineRestartedByPrewarmAfterACrashIsGivenTheConversation() {
        send(1, "first")
        waitForFinish(1)
        send(2, "crash", memory: memory([("first", "one")]))
        waitForFinish(2)
        XCTAssertEqual(finished[2], 3)
        backend.prewarm()       // the talk key relaunches the engine before the message is sent
        send(3, "third", memory: memory([("first", "one")]))
        waitForFinish(3)
        let latest = receivedByLatestEngine()
        let kinds = types(latest)
        XCTAssertEqual(kinds.filter { $0 == "restore" }.count, 1, "\(kinds)")
        XCTAssertLessThan(kinds.firstIndex(of: "restore") ?? .max, kinds.firstIndex(of: "send") ?? -1, "\(kinds)")
        let restored = latest.first { $0["type"] as? String == "restore" }?["exchanges"] as? [[String: String]]
        XCTAssertEqual(restored ?? [], [["user": "first", "assistant": "one"]])
    }

    func testAReopenedConversationIsRestoredIntoAnEngineThePrewarmStarted() {
        backend.reset()         // a saved conversation reopened while no engine runs
        backend.prewarm()
        send(1, "more", memory: memory([("earlier", "answer")]))
        waitForFinish(1)
        let kinds = types(receivedByLatestEngine())
        XCTAssertEqual(kinds.filter { $0 == "restore" }.count, 1, "\(kinds)")
        XCTAssertLessThan(kinds.firstIndex(of: "restore") ?? .max, kinds.firstIndex(of: "send") ?? -1, "\(kinds)")
    }

    func testAConversationReopenedInARunningEngineIsRestored() {
        send(1, "first")
        waitForFinish(1)
        backend.reset()
        send(2, "more", memory: memory([("earlier", "answer")]))
        waitForFinish(2)
        let kinds = types(receivedByLatestEngine()).filter { ["send", "reset", "restore"].contains($0) }
        XCTAssertEqual(kinds, ["send", "reset", "restore", "send"])
    }

    func testANormalSecondMessageInALiveEngineRestoresNothing() {
        backend.prewarm()
        send(1, "first")
        waitForFinish(1)
        send(2, "second", memory: memory([("first", "one")]))
        waitForFinish(2)
        let kinds = types(received())
        XCTAssertFalse(kinds.contains("restore"), "\(kinds)")
        XCTAssertEqual(kinds.filter { $0 == "hello" }.count, 1, "\(kinds)")
    }

    // MARK: capabilities from `ready`

    func testTheFirstMessageAfterAColdStartOffersSchedulesWhenTheEngineRunsThem() {
        send(1, "remind me every morning")
        waitForFinish(1)
        let sent = received().first { $0["type"] as? String == "send" }
        XCTAssertEqual(sent?["jobs"] as? Bool, true)
        XCTAssertEqual(sent?["schedules"] as? Bool, true)
    }
}
