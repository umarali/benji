import XCTest
@testable import BenjiApp
import BenjiCore

/// Phone control end to end on this Mac: the real `benji.remote` child process, real HTTP on
/// 127.0.0.1 with a port the system picks, and the app's pipe to it. The engine is a fake backend:
/// no model, no key, no permission.
final class RemoteControlIntegrationTests: XCTestCase {
    private var backend: FakeBackend!
    private var model: CompanionModel!
    private var control: RemoteControl!
    private var session: URLSession!

    override func setUp() {
        backend = FakeBackend()
        let defaults = UserDefaults(suiteName: "benji-phone-tests-\(UUID().uuidString)")!
        defaults.set(ScreenMode.off.rawValue, forKey: ScreenModeState.defaultsKey)
        model = CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: defaults))
        model.phoneAnswersApprovals = { true }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
        control = RemoteControl(model: model, assistantDir: root, port: 0)
        session = URLSession(configuration: .ephemeral)
    }

    override func tearDown() {
        control.stop()
        session.invalidateAndCancel()
        model.cancel()
    }

    private func until(_ predicate: () -> Bool) -> Bool {
        let limit = Date().addingTimeInterval(12)
        while !predicate() && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return predicate()
    }

    private func request(_ path: String, _ body: [String: Any]? = nil, key: String? = nil) throws -> (Int, [String: Any]) {
        var req = URLRequest(url: URL(string: control.address + path)!)
        req.setValue("Bearer " + (key ?? control.accessKey), forHTTPHeaderField: "Authorization")
        if let body {
            req.httpMethod = "POST"
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(control.address, forHTTPHeaderField: "Origin")
        }
        let done = expectation(description: "HTTP reply")
        var result: (Int, [String: Any])?
        var failure: Error?
        session.dataTask(with: req) { data, response, error in
            failure = error
            if let data, let response = response as? HTTPURLResponse {
                result = (response.statusCode, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 8)
        if let failure { throw failure }
        return try XCTUnwrap(result)
    }

    private var phoneTask: [String: Any]? { (try? request("/api/state").1["task"]) as? [String: Any] }

    private func receipt(_ id: String) -> [String: Any]? {
        (try? request("/api/receipt/\(id)").1["result"]) as? [String: Any]
    }

    private func startAndSend(_ id: String) throws {
        control.start()
        XCTAssertTrue(until { !control.accessKey.isEmpty }, control.status)
        XCTAssertTrue(until { (try? request("/api/state").1["connected"] as? Bool) == true })
        XCTAssertEqual(try request("/api/command", ["id": id, "op": "send", "text": "Write a note"]).0, 202)
        XCTAssertTrue(until { backend.remoteStarts == 1 })
    }

    func testAPhoneTaskThroughTheRealListenerWithAnApprovalFromThePhone() throws {
        try startAndSend("phone-integration-1")
        guard !control.accessKey.isEmpty else { return }
        XCTAssertEqual(try request("/api/state", key: "wrong").0, 401)
        XCTAssertEqual(try request("/api/command", ["id": "phone-integration-1", "op": "send", "text": "Write a note"]).0, 200)
        XCTAssertEqual(backend.remoteStarts, 1, "a retry with the same id starts nothing")
        backend.say(.approval(action: "write file", target: "outside/notes.txt"))
        let approval = try XCTUnwrap(model.state.pendingApproval?.id)
        XCTAssertTrue(until { (phoneTask?["approval"] as? [String: String])?["id"] == approval })
        let answer: [String: Any] = ["id": "phone-approval-1", "op": "approve", "task": "phone-integration-1",
                                     "request": approval, "approved": true]
        XCTAssertEqual(try request("/api/command", answer).0, 202)
        XCTAssertTrue(until { backend.approvals == [true] })
        XCTAssertEqual(try request("/api/command", answer).0, 200)
        XCTAssertEqual(backend.approvals, [true])
        backend.say(.answer("Note saved"))
        backend.finish()
        XCTAssertTrue(until { phoneTask?["status"] as? String == "Done" })

        // Off and on again: a Mac task that started meanwhile runs on, and the old key no longer works.
        model.composerText = "Local work"
        model.submit()
        let oldKey = control.accessKey
        control.stop()
        XCTAssertEqual(backend.cancels, 0)
        XCTAssertTrue(control.accessKey.isEmpty)
        model.cancel()
        control.address = "http://127.0.0.1:0"   // a fresh listener on a free port
        control.start()
        XCTAssertTrue(until { !control.accessKey.isEmpty }, control.status)
        XCTAssertNotEqual(control.accessKey, oldKey)
        XCTAssertEqual(try request("/api/state", key: oldKey).0, 401)
        XCTAssertEqual(try request("/api/state").0, 200)
    }

    func testWithPhoneApprovalsOffTheListenerPassesTheAnswerAndTheMacRefusesIt() throws {
        var on = false
        model.phoneAnswersApprovals = { on }
        try startAndSend("phone-integration-2")
        guard !control.accessKey.isEmpty else { return }
        backend.say(.approval(action: "write file", target: "outside/notes.txt"))
        let approval = try XCTUnwrap(model.state.pendingApproval?.id)
        XCTAssertTrue(until {
            let shown = self.phoneTask?["approval"] as? [String: String]
            return shown?["target"] == "outside/notes.txt" && shown?["id"] == nil
        })
        // A phone page that sends the answer anyway, naming the request it saw on the Mac.
        let answer: [String: Any] = ["id": "phone-approval-2", "op": "approve", "task": "phone-integration-2",
                                     "request": approval, "approved": true]
        XCTAssertEqual(try request("/api/command", answer).0, 202)
        XCTAssertTrue(until { receipt("phone-approval-2")?["ok"] as? Bool == false })
        XCTAssertTrue(backend.approvals.isEmpty)
        XCTAssertEqual(model.state.pendingApproval?.id, approval)

        // Turned back on in Settings: the next answer is taken without restarting phone control.
        on = true
        XCTAssertTrue(until { (self.phoneTask?["approval"] as? [String: String])?["id"] == approval })
        let again: [String: Any] = ["id": "phone-approval-3", "op": "approve", "task": "phone-integration-2",
                                    "request": approval, "approved": true]
        XCTAssertEqual(try request("/api/command", again).0, 202)
        XCTAssertTrue(until { backend.approvals == [true] })
        XCTAssertEqual(receipt("phone-approval-3")?["ok"] as? Bool, true)
    }
}
