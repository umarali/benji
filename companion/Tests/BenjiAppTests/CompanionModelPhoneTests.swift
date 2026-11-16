import XCTest
@testable import BenjiApp
import BenjiCore

/// The model's side of phone control: which phone commands it takes, what the phone is shown, and
/// how a phone task and the Mac's own use share one conversation. No process, no network.
final class CompanionModelPhoneTests: XCTestCase {
    var backend: FakeBackend!
    var model: CompanionModel!

    override func setUp() {
        backend = FakeBackend()
        let defaults = UserDefaults(suiteName: "benji-phone-tests-\(UUID().uuidString)")!
        defaults.set(ScreenMode.off.rawValue, forKey: ScreenModeState.defaultsKey)
        model = CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: defaults))
        model.phoneAnswersApprovals = { true }
    }

    override func tearDown() {
        model.endRemoteControl()
        model.cancel()
    }

    @discardableResult private func send(_ id: String = "phone-task-1", _ text: String = "Hello") -> Bool {
        model.remoteCommand(["op": "send", "id": id, "text": text]).0
    }

    private var task: [String: Any] { model.remoteSnapshot["task"] as? [String: Any] ?? [:] }

    private func approve(_ request: String, task: String = "phone-task-1", _ approved: Bool = true) -> (Bool, String) {
        model.remoteCommand(["op": "approve", "task": task, "request": request, "approved": approved])
    }

    func testAPhoneTaskIgnoresScreenModeKeepsTheDraftAndIsNotSpoken() {
        model.setScreenMode(.on)
        model.composerText = "Mac draft"
        var spoken = [String]()
        model.onSpeak = { spoken.append($0) }
        XCTAssertTrue(send())
        XCTAssertEqual(backend.remoteStarts, 1)
        XCTAssertNil(backend.starts.last?.imagePath)
        XCTAssertEqual(backend.starts.last?.spoken, false)
        XCTAssertNil(model.pendingScreenSend)
        XCTAssertEqual(model.composerText, "Mac draft")
        backend.say(.answer("Phone answer"))
        backend.finish()
        XCTAssertTrue(spoken.isEmpty)
        XCTAssertEqual(task["status"] as? String, "Done")
    }

    func testThePhoneTaskUsesTheConversationButIsShownOnlyItsOwnLines() {
        model.composerText = "Private earlier question"
        model.submit()
        backend.say(.answer("Earlier answer"))
        backend.finish()
        XCTAssertTrue(send())
        XCTAssertFalse(backend.starts.last!.memoryEmpty)
        backend.say(.delta("New stream"))
        XCTAssertEqual(task["stream"] as? String, "New stream")
        backend.say(.answer("Phone result"))
        backend.finish()
        let frozenLines = task["lines"] as? [[String: String]]
        let shown = String(describing: task)
        XCTAssertFalse(shown.contains("Earlier answer"))
        XCTAssertTrue(shown.contains("Phone result"))
        model.composerText = "Later local task"
        model.submit()
        backend.say(.answer("Later local answer"))
        backend.finish()
        XCTAssertEqual(task["lines"] as? [[String: String]], frozenLines)
        XCTAssertFalse(String(describing: task).contains("Later local answer"))
    }

    func testABusyMacListeningAndASecondPhoneTaskAreRefused() {
        model.composerText = "Local work"
        model.submit()
        XCTAssertFalse(send())
        XCTAssertTrue((model.remoteSnapshot["unavailableReason"] as? String)?.contains("busy") == true)
        model.cancel()
        model.voiceListeningStarted()
        XCTAssertFalse(send())
        model.voiceCancelled()
        XCTAssertTrue(send())
        XCTAssertFalse(send("phone-task-2"))
        XCTAssertEqual(backend.remoteStarts, 1)
    }

    func testWhileThePhoneTaskRunsTheMacCannotSendRetryOrClearTheConversation() {
        XCTAssertTrue(send())
        model.composerText = "Mac message"
        model.submit()
        model.newConversation()
        XCTAssertEqual(backend.starts.count, 1)
        XCTAssertEqual(model.composerText, "Mac message")
        XCTAssertFalse(model.canSwitchConversation)
    }

    func testAnApprovalIsAnsweredOnceAndAnOldOneCannotAnswerTheNext() {
        XCTAssertTrue(send())
        backend.say(.approval(action: "overwrite file", target: "notes.txt"))
        let first = model.state.pendingApproval!.id
        XCTAssertFalse(approve(first, task: "wrong-task").0)
        XCTAssertTrue(approve(first).0)
        XCTAssertFalse(approve(first).0)
        backend.say(.approval(action: "delete file", target: "other.txt"))
        XCTAssertFalse(approve(first).0)
        XCTAssertEqual(backend.approvals, [true])
        let shown = task["approval"] as! [String: String]
        XCTAssertEqual(shown["target"], "other.txt")
        model.decideApproval(.no)   // the Mac's card answers first
        XCTAssertFalse(approve(shown["id"]!).0)
        XCTAssertEqual(backend.approvals, [true, false])
    }

    func testATimeoutOrAStopCannotBeUndoneByALateYesFromThePhone() {
        send()
        backend.say(.approval(action: "write file", target: "notes.txt"))
        let request = model.state.pendingApproval!.id
        model.resolveApproval(false, timedOut: true)
        XCTAssertFalse(approve(request).0)
        XCTAssertEqual(backend.approvals, [false])
        XCTAssertFalse(model.remoteCommand(["op": "stop", "task": "wrong-task"]).0)
        XCTAssertTrue(model.remoteCommand(["op": "stop", "task": "phone-task-1"]).0)
        XCTAssertEqual(backend.cancels, 1)
        XCTAssertFalse(approve(request).0)
    }

    // MARK: Settings › Phone › Answer approvals from the phone

    func testWithPhoneApprovalsOffTheAnswerIsRefusedAndTheMacStillAnswers() {
        model.phoneAnswersApprovals = { false }
        send()
        backend.say(.approval(action: "write file", target: "notes.txt"))
        let request = model.state.pendingApproval!.id
        let (ok, words) = approve(request)
        XCTAssertFalse(ok)
        XCTAssertTrue(words.contains("turned off"))
        XCTAssertFalse(approve(request, false).0, "a No from the phone is refused too")
        XCTAssertTrue(backend.approvals.isEmpty)
        XCTAssertEqual(model.state.pendingApproval?.id, request)
        let shown = task["approval"] as? [String: String]
        XCTAssertEqual(shown?["target"], "notes.txt")
        XCTAssertNil(shown?["id"], "the phone is not given a request it could answer")
        XCTAssertEqual(task["status"] as? String, "Waiting for your answer on the Mac")
        model.decideApproval(.yes, request: request)
        XCTAssertEqual(backend.approvals, [true])
        XCTAssertTrue(model.remoteCommand(["op": "stop", "task": "phone-task-1"]).0, "the phone can still stop its task")
    }

    func testWithPhoneApprovalsOnTheAnswerIsTaken() {
        model.phoneAnswersApprovals = { true }
        send()
        backend.say(.approval(action: "write file", target: "notes.txt"))
        let request = model.state.pendingApproval!.id
        XCTAssertEqual((task["approval"] as? [String: String])?["id"], request)
        XCTAssertTrue(approve(request).0)
        XCTAssertEqual(backend.approvals, [true])
    }

    func testTheSwitchIsReadAtEachApprovalSoAChangeNeedsNoRestart() {
        var on = false
        model.phoneAnswersApprovals = { on }
        send()
        backend.say(.approval(action: "write file", target: "notes.txt"))
        let request = model.state.pendingApproval!.id
        XCTAssertFalse(approve(request).0)
        on = true
        XCTAssertTrue(approve(request).0)
        XCTAssertEqual(backend.approvals, [true])
    }

    func testTheSwitchIsOnByDefaultAndReadFromItsDefaultsKey() {
        let fresh = CompanionModel(backend: FakeBackend())
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: PhoneApprovals.defaultsKey)
        defer { defaults.set(saved, forKey: PhoneApprovals.defaultsKey) }
        defaults.removeObject(forKey: PhoneApprovals.defaultsKey)
        XCTAssertTrue(fresh.phoneAnswersApprovals())
        defaults.set(false, forKey: PhoneApprovals.defaultsKey)
        XCTAssertFalse(fresh.phoneAnswersApprovals())
    }

    // MARK: who answered, for the audit log

    func testTheMacCardAnsweringAPhoneTaskSaysCard() {
        send()
        backend.say(.approval(action: "write file", target: "notes.txt"))
        model.decideApproval(.yes, request: model.state.pendingApproval!.id)
        XCTAssertEqual(backend.approvals, [true])
        XCTAssertEqual(backend.approvalSources, [.card])
    }

    func testThePhoneAnsweringItsTaskSaysPhone() {
        send()
        backend.say(.approval(action: "write file", target: "notes.txt"))
        XCTAssertTrue(approve(model.state.pendingApproval!.id, false).0)
        XCTAssertEqual(backend.approvals, [false])
        XCTAssertEqual(backend.approvalSources, [.phone])
    }

    func testTheCardsTimeoutSaysTimeoutAndAStopAnswersNothing() {
        send()
        backend.say(.approval(action: "write file", target: "notes.txt"))
        model.resolveApproval(false, timedOut: true)
        XCTAssertEqual(backend.approvalSources, [.timeout])
        backend.say(.approval(action: "delete file", target: "old.txt"))
        XCTAssertTrue(model.remoteCommand(["op": "stop", "task": "phone-task-1"]).0)
        XCTAssertEqual(backend.approvalSources, [.timeout], "a stop cancels the turn; the engine records it as stop")
        XCTAssertEqual(backend.cancels, 1)
    }

    // MARK: ownership

    func testTurningPhoneControlOffAfterThePhoneTaskLeavesALaterMacTaskRunning() {
        send()
        backend.say(.answer("Done"))
        backend.finish()
        model.composerText = "Local"
        model.submit()
        model.endRemoteControl()
        XCTAssertEqual(backend.cancels, 0)
        XCTAssertNil(model.remoteSnapshot["task"])
        XCTAssertTrue(model.state.isBusy)
    }

    func testTurningPhoneControlOffStopsThePhoneTask() {
        send()
        model.endRemoteControl()
        XCTAssertEqual(backend.cancels, 1)
        XCTAssertNil(model.remoteSnapshot["task"])
        XCTAssertFalse(model.state.isBusy)
    }

    func testTheTalkKeyOnTheMacTakesOverAndThePhoneTaskSeesNoLateAnswer() {
        send()
        let oldRun = backend.lastRun
        model.voiceListeningStarted()
        model.voiceTranscribing()
        model.voiceSubmit("Local voice")
        XCTAssertEqual(backend.cancels, 1)
        XCTAssertEqual(backend.remoteStarts, 1)
        XCTAssertEqual(backend.starts.last?.spoken, true)
        backend.say(.answer("Late remote answer"), run: oldRun)
        XCTAssertFalse(String(describing: task).contains("Late remote answer"))
        XCTAssertEqual(task["status"] as? String, "Stopped")
    }

    func testAnErrorBeforeTheRunEndsKeepsThePhoneTaskInCharge() {
        send()
        backend.say(.error("Provider failed"))
        model.newConversation()
        model.retry()
        XCTAssertFalse(send("phone-task-2"))
        XCTAssertEqual(backend.remoteStarts, 1)
        XCTAssertFalse(model.canSwitchConversation)
        backend.finish(1)
        XCTAssertEqual(task["status"] as? String, "Failed")
        XCTAssertTrue(send("phone-task-2"))
    }

    func testABackgroundJobKeepsThePhoneOutAndItsApprovalStaysOnTheMac() {
        backend.job(JobSnapshot(id: "job-1234", title: "Local job", state: .needsYou,
                                pending: JobPending(request: "approval-1234", action: "write file", target: "notes.txt")))
        XCTAssertFalse(send())
        XCTAssertFalse(approve("approval-1234", task: "job-1234").0)
        XCTAssertTrue(backend.jobAnswers.isEmpty)
    }

    func testAScreenOrDriveRequestStopsThePhoneTaskInsteadOfAsking() {
        send()
        backend.say(.driveApproval(goal: "Click a button", seconds: 30))
        XCTAssertEqual(backend.cancels, 1)
        XCTAssertNil(model.state.pendingApproval)
        XCTAssertNil(task["approval"])
        XCTAssertEqual(task["running"] as? Bool, false)
    }

    func testLongTextIsShortenedButALongApprovalIsLeftForTheMac() {
        send()
        backend.say(.answer(String(repeating: "x", count: 3000)))
        let lines = task["lines"] as! [[String: String]]
        XCTAssertTrue(lines.last!["text"]!.contains("Shortened"))
        backend.say(.approval(action: "write file", target: String(repeating: "x", count: 17000)))
        XCTAssertNil(task["approval"])
        XCTAssertFalse(approve(model.state.pendingApproval!.id).0)
        XCTAssertTrue(backend.approvals.isEmpty)
    }
}
