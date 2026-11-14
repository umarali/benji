import XCTest
@testable import BenjiApp
import BenjiCore

/// (5) Approval lifecycle: every way an approval ends other than an explicit Yes is a No, and the
/// engine is answered exactly once per request.
final class CompanionModelApprovalTests: XCTestCase {
    var backend: FakeBackend!
    var model: CompanionModel!

    override func setUp() {
        backend = FakeBackend()
        let suite = UserDefaults(suiteName: "benji-app-tests-\(UUID().uuidString)")!
        suite.set(ScreenMode.off.rawValue, forKey: ScreenModeState.defaultsKey)
        model = CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: suite))
        model.composerText = "tidy my downloads"
        model.submit()
        backend.say(.approval(action: "run a potentially destructive shell command", target: "rm -rf ~/Downloads/old"))
    }

    private var pending: ApprovalRequest { model.state.pendingApproval! }

    func testApprovalShowsTheExactActionAndTarget() {
        XCTAssertEqual(model.state.phase, .awaitingApproval)
        XCTAssertEqual(pending.action, "run a potentially destructive shell command")
        XCTAssertEqual(pending.target, "rm -rf ~/Downloads/old")
    }

    func testDuplicateYesAnswersOnce() {
        let id = pending.id
        model.decideApproval(.yes, request: id)
        model.decideApproval(.yes, request: id)
        model.decideApproval(.yes)
        model.resolveApproval(true)
        XCTAssertEqual(backend.approvals, [true])
        XCTAssertEqual(model.state.phase, .thinking)
    }

    func testDenialThenLateYesStaysNo() {
        let id = pending.id
        model.decideApproval(.no, request: id)
        model.decideApproval(.yes, request: id)
        XCTAssertEqual(backend.approvals, [false])
    }

    func testAnswerFromAStaleCardIsIgnored() {
        let first = pending.id
        model.decideApproval(.no, request: first)
        backend.say(.approval(action: "overwrite a file", target: "notes.md"))
        model.decideApproval(.yes, request: first)   // the old card's button, clicked late
        XCTAssertEqual(backend.approvals, [false])
        XCTAssertEqual(pending.action, "overwrite a file", "the new request still waits")
    }

    func testSecondRequestNeverReplacesTheWaitingOne() {
        let first = pending
        backend.say(.approval(action: "overwrite a file", target: "notes.md"))
        XCTAssertEqual(model.state.pendingApproval, first)
        XCTAssertTrue(backend.approvals.isEmpty)
    }

    func testCancelWhileWaitingDeniesWithoutApproving() {
        model.cancel()
        XCTAssertNil(model.state.pendingApproval)
        XCTAssertEqual(backend.cancels, 1)
        XCTAssertFalse(backend.approvals.contains(true))
        model.decideApproval(.yes)
        XCTAssertFalse(backend.approvals.contains(true))
        XCTAssertEqual(model.state.turns.last?.activities, [.asked(action: "run a potentially destructive shell command", outcome: .stopped)])
    }

    func testAdjustDeniesAndPutsTheRequestInTheComposer() {
        model.decideApproval(.adjust, request: pending.id)
        XCTAssertEqual(backend.approvals, [false])
        XCTAssertEqual(model.composerText, "run a potentially destructive shell command: rm -rf ~/Downloads/old")
        XCTAssertEqual(model.state.phase, .idle)
    }

    func testApprovalArrivingAfterCancelIsNeverShown() {
        model.decideApproval(.no)
        let run = backend.lastRun
        model.cancel()
        backend.say(.approval(action: "send an email", target: "boss@example.com"), run: run)
        XCTAssertNil(model.state.pendingApproval)
        XCTAssertEqual(model.state.phase, .idle)
    }

    func testTimeoutDeniesOnceAndALateClickDoesNothing() {
        // A fresh model whose backend times approvals out quickly.
        backend = FakeBackend()
        backend.approvalTimeout = 0.05
        let suite = UserDefaults(suiteName: "benji-app-tests-\(UUID().uuidString)")!
        suite.set(ScreenMode.off.rawValue, forKey: ScreenModeState.defaultsKey)
        model = CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: suite))
        model.composerText = "x"
        model.submit()
        backend.say(.approval(action: "run a shortcut", target: "Clean Up"))
        let id = pending.id
        let gone = expectation(description: "timed out")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { gone.fulfill() }
        wait(for: [gone], timeout: 2)
        XCTAssertEqual(backend.approvals, [false])
        XCTAssertNil(model.state.pendingApproval)
        XCTAssertTrue(model.state.lines.contains { $0.text == ApprovalPolicy.timedOutRecord(action: "run a shortcut") })
        model.decideApproval(.yes, request: id)
        XCTAssertEqual(backend.approvals, [false])
    }

    func testEngineFinishingWhileWaitingClearsTheCard() {
        backend.finish(1)
        XCTAssertNil(model.state.pendingApproval)
        model.decideApproval(.yes)
        XCTAssertTrue(backend.approvals.isEmpty)
    }
}
