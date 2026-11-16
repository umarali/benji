import AppKit
import XCTest
@testable import BenjiApp
import BenjiCore

/// Screen steps through the real CompanionModel: the card is worded from the step and
/// names the app, only the step the user approved is done, once, the screen after it becomes the
/// turn's screenshot, and a cancelled turn's late result is dropped. No windows, no events posted.
final class CompanionModelScreenStepTests: XCTestCase {
    /// FakeBackend's side plus the screen results the model sends back.
    final class StepBackend: CompanionBackend {
        var onEvent: ((_ run: Int, BackendEvent) -> Void)?
        var onFinished: ((_ run: Int, Int32) -> Void)?
        var approvalTimeout: TimeInterval = 60
        private(set) var runs: [Int] = []
        private(set) var approvals: [Bool] = []
        private(set) var results: [(request: String, result: ScreenStepResult)] = []

        func start(run: Int, task: String, imagePath: String?, memory: ConversationMemory, allowPointing: Bool,
                   spoken: Bool, screen: ScreenshotGeometry?) { runs.append(run) }
        func resolveApproval(_ approved: Bool, from source: ApprovalSource) { approvals.append(approved) }
        func cancel() {}
        func reset() {}
        func shutdown() {}
        func finishScreenStep(request: String, result: ScreenStepResult) { results.append((request, result)) }
        func say(_ event: BackendEvent) { onEvent?(runs.last!, event) }
    }

    var backend: StepBackend!
    var model: CompanionModel!
    var performed: [(step: ScreenStep, shot: CapturedScreen, pid: Int32?)] = []
    var pendingDone: ((ScreenStepOutcome) -> Void)?
    var cancels = 0
    let save = ScreenStep.click(x: 412, y: 300, button: .left, count: 1, label: "Save button")

    private func shot(_ name: String) -> CapturedScreen {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("benji-screen-test-\(name)-\(UUID().uuidString).jpg")
        FileManager.default.createFile(atPath: url.path, contents: Data([1]))
        return CapturedScreen(url: url, pixelSize: CGSize(width: 1330, height: 864), thumbnail: NSImage(),
                              screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982))
    }

    override func setUp() {
        backend = StepBackend()
        let suite = UserDefaults(suiteName: "benji-screen-step-tests-\(UUID().uuidString)")!
        model = CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: suite))
        model.setScreenMode(.on)
        let first = shot("first")
        model.captureScreen = { done in done(.success(first)) }
        model.describeScreenStep = { _, _ in ScreenTarget(pid: 42, bundleID: "com.apple.TextEdit", appName: "TextEdit") }
        model.performScreenStep = { [unowned self] step, shot, pid, _, done in
            performed.append((step, shot, pid))
            pendingDone = done
        }
        model.cancelScreenStep = { [unowned self] in cancels += 1 }
        model.composerText = "save it"
        model.submit()
        XCTAssertEqual(backend.runs.count, 1)
    }

    private func approve(_ step: ScreenStep, _ yes: Bool = true) {
        backend.say(.screenApproval(action: "engine words", target: "engine target", step: step))
        model.decideApproval(yes ? .yes : .no)
    }

    func testTheCardIsWordedFromTheStepAndNamesTheApp() {
        backend.say(.screenApproval(action: "click on the screen", target: "Save button at 412,300", step: save))
        XCTAssertEqual(model.state.pendingApproval?.action, "click in TextEdit")
        XCTAssertEqual(model.state.pendingApproval?.target, "Save button; then Benji looks at the screen again")
    }

    func testADragsCardNamesBothAppsAndTheirPIDsReachTheActuator() {
        let drag = ScreenStep.drag(x: 10, y: 10, toX: 900, toY: 700, label: "report.pdf to the Trash")
        model.describeScreenStep = { _, _ in ScreenTarget(pid: 42, bundleID: "com.apple.finder", appName: "Finder") }
        model.describeScreenStepEnd = { _, _ in ScreenTarget(pid: 43, bundleID: "com.apple.dock", appName: "Dock") }
        var endPID: Int32?
        model.performScreenStep = { [unowned self] step, shot, pid, end, done in
            performed.append((step, shot, pid))
            endPID = end
            pendingDone = done
        }
        backend.say(.screenApproval(action: "engine words", target: "engine target", step: drag))
        XCTAssertEqual(model.state.pendingApproval?.action, "drag from Finder to Dock")
        model.decideApproval(.yes)
        backend.say(.screenAction(request: "s1", step: drag))
        XCTAssertEqual(performed.first?.pid, 42)
        XCTAssertEqual(endPID, 43)
    }

    func testAnApprovedStepIsDoneOnceAndTheScreenAfterItIsUsedNext() {
        approve(save)
        XCTAssertEqual(backend.approvals, [true])
        backend.say(.screenAction(request: "s1", step: save))
        XCTAssertEqual(performed.count, 1)
        XCTAssertEqual(performed[0].pid, 42, "the app the card named")
        let after = shot("after")
        pendingDone?(ScreenStepOutcome(status: .done, text: "Clicked Save button in TextEdit.", shot: after))
        XCTAssertEqual(backend.results.map(\.request), ["s1"])
        XCTAssertEqual(backend.results[0].result, ScreenStepResult(status: .done, text: "Clicked Save button in TextEdit.",
                                                                    imagePath: after.url.path))

        backend.say(.screenAction(request: "s2", step: save))
        XCTAssertEqual(performed.count, 1, "the approval was used up")
        XCTAssertEqual(backend.results[1].result, .refused(.notApproved))

        let tab = ScreenStep.pressKey(key: "tab", modifiers: [])
        approve(tab)
        backend.say(.screenAction(request: "s3", step: tab))
        XCTAssertEqual(performed.last?.shot.url, after.url, "the next step acts on the screen after the last one")

        pendingDone?(ScreenStepOutcome(status: .done, text: "Pressed Tab.", shot: nil))
        backend.onFinished?(backend.runs.last!, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: after.url.path), "step screenshots go with the turn")
    }

    func testOnlyTheApprovedStepIsDone() {
        approve(save)
        backend.say(.screenAction(request: "s1", step: .click(x: 10, y: 10, button: .left, count: 1, label: "Delete")))
        XCTAssertTrue(performed.isEmpty)
        XCTAssertEqual(backend.results.first?.result, .refused(.notApproved))
    }

    func testADeclinedOrUnreadableStepIsNeverDone() {
        approve(save, false)
        backend.say(.screenAction(request: "s1", step: save))
        backend.say(.screenAction(request: "s2", step: nil))
        XCTAssertTrue(performed.isEmpty)
        XCTAssertEqual(backend.results.map(\.result), [.refused(.notApproved), .refused(.unreadable)])
    }

    func testTakingOverSaysSoInThePanel() {
        approve(save)
        backend.say(.screenAction(request: "s1", step: save))
        pendingDone?(ScreenStepOutcome(status: .stopped, text: "Stopped: you took over, so nothing was done.", shot: nil))
        XCTAssertEqual(model.statusNote, "Stopped: you took over")
        XCTAssertEqual(backend.results.first?.result.status, .stopped)
    }

    func testCancelStopsTheStepAndDropsItsLateResult() {
        approve(save)
        backend.say(.screenAction(request: "s1", step: save))
        model.cancel()
        XCTAssertEqual(cancels, 1)
        let late = shot("late")
        pendingDone?(ScreenStepOutcome(status: .done, text: "Clicked.", shot: late))
        XCTAssertTrue(backend.results.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.url.path))
    }
}
