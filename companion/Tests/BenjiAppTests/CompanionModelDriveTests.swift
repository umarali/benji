import AppKit
import XCTest
@testable import BenjiApp
import BenjiCore

/// Drive mode through the real CompanionModel and a fake backend: the consent card (named
/// goal, 45 s, only its own answer begins a drive), the notch's state with the Esc hint, the drive's
/// steps checked again by the app, and the user's input handing the screen back. No windows, no
/// events posted: the actuator is a fake.
final class CompanionModelDriveTests: XCTestCase {
    final class DriveBackend: CompanionBackend {
        var onEvent: ((_ run: Int, BackendEvent) -> Void)?
        var onFinished: ((_ run: Int, Int32) -> Void)?
        var approvalTimeout: TimeInterval = 60
        private(set) var runs: [Int] = []
        private(set) var approvals: [Bool] = []
        private(set) var stops: [String] = []
        private(set) var results: [(request: String, result: ScreenStepResult)] = []
        func start(run: Int, task: String, imagePath: String?, memory: ConversationMemory, allowPointing: Bool,
                   spoken: Bool, screen: ScreenshotGeometry?) { runs.append(run) }
        func resolveApproval(_ approved: Bool) { approvals.append(approved) }
        func cancel() {}
        func reset() {}
        func shutdown() {}
        func finishScreenStep(request: String, result: ScreenStepResult) { results.append((request, result)) }
        func stopDrive(reason: String) { stops.append(reason) }
        func say(_ event: BackendEvent) { onEvent?(runs.last!, event) }
    }

    var backend: DriveBackend!
    var model: CompanionModel!
    var driven: [(step: ScreenStep, pid: Int32?, cls: DriveClass?)] = []
    var old: [ScreenStep] = []
    var pendingDone: ((ScreenStepOutcome) -> Void)?
    var watching: [Bool] = []
    var handBacks = 0

    let high = ScreenStepIntent(intent: "to fill the form", confidence: .high)
    let next = ScreenStep.click(x: 300, y: 40, button: .left, count: 1, label: "Next button")
    let send = ScreenStep.click(x: 900, y: 700, button: .left, count: 1, label: "Send")
    let down = ScreenStep.scroll(x: 600, y: 400, direction: .down, amount: 5, label: "the page")

    private func shot() -> CapturedScreen {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("benjy-drive-test-\(UUID().uuidString).jpg")
        FileManager.default.createFile(atPath: url.path, contents: Data([1]))
        return CapturedScreen(url: url, pixelSize: CGSize(width: 1330, height: 864), thumbnail: NSImage(),
                              screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982))
    }

    override func setUp() {
        backend = DriveBackend()
        let suite = UserDefaults(suiteName: "benji-drive-tests-\(UUID().uuidString)")!
        model = CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: suite))
        model.setScreenMode(.on)
        let first = shot()
        model.captureScreen = { done in done(.success(first)) }
        model.describeScreenStep = { _, _ in ScreenTarget(pid: 42, bundleID: "com.apple.Safari", appName: "Safari") }
        model.performScreenStep = { [unowned self] step, _, _, _, done in old.append(step); pendingDone = done }
        model.performSimpleScreenStep = { [unowned self] step, _, _, done in old.append(step); pendingDone = done }
        model.performDriveStep = { [unowned self] step, _, pid, _, cls, done in
            driven.append((step, pid, cls))
            pendingDone = done
        }
        model.watchDrive = { [unowned self] on in watching.append(on) }
        model.handBackDriveStep = { [unowned self] in handBacks += 1 }
        model.actsOnSimpleSteps = { true }
        model.composerText = "fill in this form for me"
        model.submit()
        XCTAssertEqual(backend.runs.count, 1)
    }

    /// The card, a Yes on it, and the engine saying the drive began.
    private func startDrive(goal: String = "fill in the form") {
        backend.say(.driveApproval(goal: goal, seconds: 45))
        model.decideApproval(.yes)
        backend.say(.drive(DriveEvent(state: .active, goal: goal)))
    }

    private func unasked(_ request: String, _ step: ScreenStep, _ mode: ScreenStepClass, _ intent: ScreenStepIntent? = nil) {
        backend.say(.screenAction(request: request, step: step, mode: mode, intent: intent ?? high, drive: true))
    }

    // MARK: the card

    func testTheCardNamesTheGoalAndDeclinesItselfAfter45Seconds() {
        backend.say(.driveApproval(goal: "fill in the form", seconds: 45))
        let card = model.state.pendingApproval
        XCTAssertEqual(card?.action, "take over your screen")
        XCTAssertTrue(card?.target.hasPrefix("fill in the form\n") == true)
        XCTAssertEqual(model.cardTimeout, 45, "the app's own timer: 45 s, whatever the engine's approval timeout")
        XCTAssertEqual(model.approvalTimeout, 60)
        model.resolveApproval(false, timedOut: true)
        XCTAssertEqual(backend.approvals, [false])
        XCTAssertNil(model.state.pendingApproval)
        XCTAssertEqual(model.cardTimeout, 60, "an ordinary card keeps its own")
    }

    func testAYesOnTheCardGrantsAndTheEngineBeginsTheDrive() {
        startDrive()
        XCTAssertEqual(backend.approvals, [true])
        XCTAssertEqual(model.driveGoal, "fill in the form")
        XCTAssertEqual(model.state.acting, "Driving · fill in the form · Esc stops", "the notch says it, with the Esc hint")
        XCTAssertEqual(watching, [true], "the user's own input is watched")
    }

    func testADriveTheUserDidNotAgreeToNeverBegins() {
        backend.say(.drive(DriveEvent(state: .active, goal: "fill in the form")))
        XCTAssertNil(model.driveGoal)
        XCTAssertNil(model.state.acting)
        XCTAssertEqual(backend.stops, ["user_stop"], "the engine is told to stop")
        XCTAssertTrue(watching.isEmpty)
    }

    func testANoOrATimeoutOnTheCardGrantsNothing() {
        backend.say(.driveApproval(goal: "g", seconds: 45))
        model.decideApproval(.no)
        backend.say(.drive(DriveEvent(state: .active, goal: "g")))
        XCTAssertNil(model.driveGoal)
        backend.say(.driveApproval(goal: "g", seconds: 45))
        model.resolveApproval(true, timedOut: true)
        backend.say(.drive(DriveEvent(state: .active, goal: "g")))
        XCTAssertNil(model.driveGoal, "a timeout is a No")
    }

    func testAnAgreementIsUsedOnceAndNotRemembered() {
        startDrive()
        backend.say(.drive(DriveEvent(state: .ended, goal: "fill in the form", reason: "finished", spoken: "Done.", written: "Done.")))
        XCTAssertNil(model.driveGoal)
        backend.say(.drive(DriveEvent(state: .active, goal: "another")))
        XCTAssertNil(model.driveGoal, "a second drive needs its own card")
    }

    func testAnAgreementDoesNotSurviveTheTurn() {
        backend.say(.driveApproval(goal: "g", seconds: 45))
        model.decideApproval(.yes)
        backend.onFinished?(backend.runs.last!, 0)       // the turn ends without a drive
        model.composerText = "again"
        model.submit()
        backend.say(.drive(DriveEvent(state: .active, goal: "g")))
        XCTAssertNil(model.driveGoal)
    }

    // MARK: the drive's steps

    func testAQuietClickInADriveGoesToTheActuatorAsADriveStep() {
        startDrive()
        unasked("s1", next, .quiet)
        XCTAssertNil(model.state.pendingApproval)
        XCTAssertEqual(driven.count, 1)
        XCTAssertEqual(driven.first?.cls, .quiet)
        XCTAssertTrue(old.isEmpty, "not the older path")
        pendingDone?(ScreenStepOutcome(status: .done, text: "Clicked Next button.", shot: nil))
        XCTAssertEqual(backend.results.first?.result.status, .done)
        XCTAssertEqual(model.state.acting, "Driving · fill in the form · Esc stops", "the banner stays between steps")
    }

    func testAScrollIsFreeAndASixthStepIsNotAskedInADrive() {
        startDrive()
        for i in 1...8 {
            unasked("s\(i)", i % 2 == 0 ? down : next, i % 2 == 0 ? .free : .quiet)
            pendingDone?(ScreenStepOutcome(status: .done, text: "ok", shot: nil))
        }
        XCTAssertEqual(driven.count, 8, "no five-step cap inside a drive")
        XCTAssertEqual(backend.results.map(\.result.status), Array(repeating: .done, count: 8))
    }

    func testWhatLooksOutboundIsSentBackToBeAskedNeverDone() {
        startDrive()
        unasked("s1", send, .quiet)                                                    // an engine that got it wrong
        unasked("s2", .click(x: 1, y: 1, button: .left, count: 1, label: "Sеnd"), .quiet)   // Cyrillic е
        unasked("s3", .click(x: 1, y: 1, button: .left, count: 1, label: "S e n d"), .quiet)
        unasked("s4", next, .quiet, ScreenStepIntent(intent: "x", confidence: .low))
        XCTAssertTrue(driven.isEmpty)
        XCTAssertEqual(backend.results.map(\.result.status), [.ask, .ask, .ask, .ask])
    }

    func testATypedCardNumberIsRefusedNotAsked() {
        startDrive()
        unasked("s1", .typeText("4242 4242 4242 4242"), .quiet)
        XCTAssertTrue(driven.isEmpty)
        XCTAssertEqual(backend.results.first?.result.status, .refused)
    }

    func testAStepTheUserApprovedOnACardRunsAsADriveStepWithItsApp() {
        startDrive()
        backend.say(.screenApproval(action: "click on the screen", target: "Send", step: send, intent: high))
        XCTAssertEqual(model.state.pendingApproval?.action, "click in Safari")
        model.decideApproval(.yes)
        backend.say(.screenAction(request: "s1", step: send, mode: nil, intent: high, drive: true))
        XCTAssertEqual(driven.count, 1)
        XCTAssertNil(driven.first?.cls, "the approved step: the actuator only looks for fields it must refuse")
        XCTAssertEqual(driven.first?.pid, 42)
    }

    func testAnUnapprovedStepThatSaysItIsApprovedIsRefused() {
        startDrive()
        backend.say(.screenAction(request: "s1", step: send, mode: nil, intent: high, drive: true))
        XCTAssertTrue(driven.isEmpty)
        XCTAssertEqual(backend.results.first?.result.status, .refused, "one yes, one step: the gate is the card's")
    }

    func testAStepThatClaimsToBeADriveWithNoDriveOnTakesTheOlderRules() {
        backend.say(.screenAction(request: "s1", step: next, mode: .quiet, intent: high, drive: true))
        XCTAssertTrue(driven.isEmpty, "the engine cannot put the app into a drive")
        XCTAssertEqual(old, [next])
    }

    func testAnAskTheActuatorMakesBringsACard() {
        startDrive()
        unasked("s1", next, .quiet)
        pendingDone?(ScreenStepOutcome(status: .ask, text: "it's in a dialog", shot: nil))
        XCTAssertEqual(backend.results.first?.result, .ask("it's in a dialog"))
    }

    func testAskBeforeEveryStepSendsADriveStepBack() {
        startDrive()
        model.actsOnSimpleSteps = { false }
        unasked("s1", next, .quiet)
        XCTAssertTrue(driven.isEmpty)
        XCTAssertEqual(backend.results.first?.result, .ask("you chose to be asked before every step"))
    }

    // MARK: the user takes the screen back

    func testEscEndsTheDriveAtOnce() {
        startDrive()
        unasked("s1", next, .quiet)
        model.driveInput(.keyDown(KeyCodes.escape), at: 5)
        XCTAssertEqual(backend.stops, ["user_stop"])
        XCTAssertEqual(handBacks, 1, "the step in flight stops")
        XCTAssertNil(model.driveGoal)
        XCTAssertNil(model.state.acting)
        XCTAssertEqual(watching, [true, false])
        XCTAssertEqual(model.statusNote, "Stopped: you took over")
        unasked("s2", next, .quiet)
        XCTAssertEqual(backend.results.last?.result.status, .stopped, "no more steps this turn")
        XCTAssertEqual(driven.count, 1)
    }

    func testTypingClickingAndScrollingEndItWithTheirOwnReasons() {
        for (input, why) in [(DriveHandBack.Input.keyDown(0), "typing"), (.mouseDown, "click"), (.scroll, "scroll")] {
            setUp()
            startDrive()
            model.driveInput(input, at: 3)
            XCTAssertEqual(backend.stops, [why])
            XCTAssertNil(model.driveGoal)
        }
    }

    func testTheStopButtonEndsTheDriveAtOnce() {
        startDrive()
        model.cancel()       // the band's Stop button
        XCTAssertEqual(backend.stops, ["user_stop"], "the engine hears why before the turn is cancelled")
        XCTAssertNil(model.driveGoal)
        XCTAssertNil(model.state.acting)
    }

    func testASmallMoveOfTheMousePausesAndSaysSoWithoutEnding() {
        startDrive()
        model.driveInput(.pointerMoved(CGPoint(x: NSEvent.mouseLocation.x + 40, y: NSEvent.mouseLocation.y)), at: 1)
        XCTAssertTrue(model.drivePaused)
        XCTAssertEqual(model.state.acting, "Paused: you're moving the mouse · Esc stops")
        XCTAssertEqual(model.driveGoal, "fill in the form")
        XCTAssertTrue(backend.stops.isEmpty)
    }

    func testALongRunOfMouseMovementHandsTheScreenBack() {
        startDrive()
        let origin = NSEvent.mouseLocation
        for i in 1...40 {
            model.driveInput(.pointerMoved(CGPoint(x: origin.x + Double(i) * 10, y: origin.y)), at: Double(i) * 0.1)
        }
        XCTAssertEqual(backend.stops, ["mouse"])
        XCTAssertNil(model.driveGoal)
        XCTAssertEqual(model.statusNote, "Handed back: you moved the mouse.")
    }

    func testTheEndOfADriveShowsItsWrittenLine() {
        startDrive()
        backend.say(.drive(DriveEvent(state: .ended, goal: "fill in the form", reason: "finished",
                                      spoken: "I filled in the form.", written: "Filled in the form.")))
        XCTAssertNil(model.driveGoal)
        XCTAssertNil(model.state.acting)
        XCTAssertEqual(model.statusNote, "Filled in the form.")
        XCTAssertEqual(watching, [true, false])
    }

    func testCancellingTheTurnEndsTheDriveUI() {
        startDrive()
        model.cancel()
        XCTAssertNil(model.driveGoal)
        XCTAssertNil(model.state.acting)
        XCTAssertEqual(watching, [true, false])
    }

    func testInputWhenNoDriveIsOnIsIgnored() {
        model.driveInput(.keyDown(KeyCodes.escape), at: 1)
        XCTAssertTrue(backend.stops.isEmpty)
        XCTAssertFalse(model.screenStopped)
    }
}
