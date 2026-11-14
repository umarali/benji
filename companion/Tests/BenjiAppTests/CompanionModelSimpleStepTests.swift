import AppKit
import XCTest
@testable import BenjiApp
import BenjiCore

/// Simple screen steps without a card (D-126) through the real CompanionModel and a fake backend:
/// a free scroll acts at once, a quiet click goes to the actuator with its beat, an asked step
/// raises the card with its intent, "Ask before every step" sends every step back to be asked,
/// and a take-over (a stopped step, Esc between steps, the talk key) stops the rest of the turn.
/// No windows, no events posted: the actuator is a fake.
final class CompanionModelSimpleStepTests: XCTestCase {
    typealias StepBackend = CompanionModelScreenStepTests.StepBackend

    var backend: StepBackend!
    var model: CompanionModel!
    var simple: [(step: ScreenStep, mode: ScreenStepClass)] = []
    var approved: [ScreenStep] = []
    var pendingDone: ((ScreenStepOutcome) -> Void)?
    var watching: [Bool] = []
    var actsOnSimpleSteps = true

    let high = ScreenStepIntent(intent: "to read the rest", confidence: .high)
    let down = ScreenStep.scroll(x: 600, y: 400, direction: .down, amount: 5, label: "the page")
    let settings = ScreenStep.click(x: 300, y: 40, button: .left, count: 1, label: "Settings tab")
    let send = ScreenStep.click(x: 900, y: 700, button: .left, count: 1, label: "Send")

    private func shot(_ name: String) -> CapturedScreen {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("benji-simple-test-\(name)-\(UUID().uuidString).jpg")
        FileManager.default.createFile(atPath: url.path, contents: Data([1]))
        return CapturedScreen(url: url, pixelSize: CGSize(width: 1330, height: 864), thumbnail: NSImage(),
                              screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982))
    }

    override func setUp() {
        backend = StepBackend()
        let suite = UserDefaults(suiteName: "benji-simple-step-tests-\(UUID().uuidString)")!
        model = CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: suite))
        model.setScreenMode(.on)
        let first = shot("first")
        model.captureScreen = { done in done(.success(first)) }
        model.describeScreenStep = { _, _ in ScreenTarget(pid: 42, bundleID: "com.apple.Safari", appName: "Safari") }
        model.performScreenStep = { [unowned self] step, _, _, _, done in
            approved.append(step)
            pendingDone = done
        }
        model.performSimpleScreenStep = { [unowned self] step, _, mode, done in
            simple.append((step, mode))
            pendingDone = done
        }
        model.watchScreenTurn = { [unowned self] on in watching.append(on) }
        model.actsOnSimpleSteps = { [unowned self] in actsOnSimpleSteps }
        model.composerText = "what does the end say?"
        model.submit()
        XCTAssertEqual(backend.runs.count, 1)
    }

    private func unasked(_ request: String, _ step: ScreenStep, _ mode: ScreenStepClass,
                         _ intent: ScreenStepIntent? = nil) {
        backend.say(.screenAction(request: request, step: step, mode: mode, intent: intent ?? high))
    }

    func testAFreeScrollActsWithoutACardAndSaysSo() {
        unasked("s1", down, .free)
        XCTAssertNil(model.state.pendingApproval, "no card")
        XCTAssertEqual(simple.map(\.step), [down])
        XCTAssertEqual(simple.first?.mode, .free)
        XCTAssertEqual(model.state.acting, "Scrolling down in Safari · Esc stops", "the peek and panel say Benji is acting")
        XCTAssertEqual(watching, [true], "Esc is watched between steps")
        let after = shot("after")
        pendingDone?(ScreenStepOutcome(status: .done, text: "Scrolled down about half a screen in Safari.", shot: after))
        XCTAssertNil(model.state.acting)
        XCTAssertEqual(backend.results.map(\.request), ["s1"])
        XCTAssertEqual(backend.results.first?.result.status, .done)
        XCTAssertEqual(backend.results.first?.result.imagePath, after.url.path)
        backend.onFinished?(backend.runs.last!, 0)
        XCTAssertEqual(watching, [true, false], "the watch ends with the turn")
        XCTAssertFalse(FileManager.default.fileExists(atPath: after.url.path), "step screenshots go with the turn")
    }

    func testAQuietClickGoesToTheActuatorWithItsBeat() {
        unasked("s1", settings, .quiet, ScreenStepIntent(intent: "to open settings", confidence: .high))
        XCTAssertNil(model.state.pendingApproval)
        XCTAssertEqual(simple.first?.mode, .quiet, "the actuator rings it for the longer beat")
        XCTAssertEqual(model.state.acting, "Clicking Settings tab in Safari · Esc stops")
        pendingDone?(ScreenStepOutcome(status: .done, text: "Clicked Settings tab in Safari.", shot: nil))
        XCTAssertEqual(backend.results.first?.result.status, .done)
    }

    func testAQuietStepTheEngineSentAsFreeKeepsItsStricterClass() {
        unasked("s1", .pressKey(key: "l", modifiers: [.cmd]), .free)
        XCTAssertEqual(simple.first?.mode, .quiet, "the app's own plan for ⌘L is quiet")
    }

    func testAnAskedClickRaisesTheCardWithItsIntent() {
        backend.say(.screenApproval(action: "click on the screen", target: "Send at 900,700", step: send,
                                    intent: ScreenStepIntent(intent: "to send your reply to Sara", confidence: .high)))
        XCTAssertEqual(model.state.pendingApproval?.action, "click in Safari")
        XCTAssertEqual(model.state.pendingApproval?.target,
                       "Send · to send your reply to Sara; then Benji looks at the screen again")
        model.decideApproval(.yes)
        backend.say(.screenAction(request: "s1", step: send))
        XCTAssertEqual(approved, [send], "the approved path, unchanged")
        XCTAssertTrue(simple.isEmpty)
    }

    func testAStepThatMustBeAskedIsSentBackNeverDone() {
        unasked("s1", send, .quiet)   // an engine that got it wrong: "Send" commits
        unasked("s2", down, .free, ScreenStepIntent(intent: "to read", confidence: .medium))
        unasked("s3", .pressKey(key: "return", modifiers: []), .quiet)
        XCTAssertTrue(simple.isEmpty)
        XCTAssertEqual(backend.results.map(\.result.status), [.ask, .ask, .ask])
        XCTAssertNil(model.state.acting)
    }

    func testTheActuatorsAskBringsACardThatSaysWhy() {
        unasked("s1", settings, .quiet, ScreenStepIntent(intent: "to open settings", confidence: .high))
        pendingDone?(ScreenStepOutcome(status: .ask, text: "it's in a dialog", shot: nil))
        XCTAssertEqual(backend.results.first?.result, .ask("it's in a dialog"))
        backend.say(.screenApproval(action: "click on the screen", target: "x", step: settings,
                                    intent: ScreenStepIntent(intent: "to open settings", confidence: .high)))
        XCTAssertEqual(model.state.pendingApproval?.target,
                       "Settings tab · to open settings; then Benji looks at the screen again. Asked because it's in a dialog")
    }

    func testAskBeforeEveryStepSendsAScrollBackToBeAsked() {
        actsOnSimpleSteps = false
        unasked("s1", down, .free)
        XCTAssertTrue(simple.isEmpty, "nothing done unasked")
        XCTAssertEqual(backend.results.first?.result.status, .ask)
        backend.say(.screenApproval(action: "scroll down on the screen", target: "x", step: down, intent: high))
        XCTAssertEqual(model.state.pendingApproval?.action, "scroll down in Safari", "the card")
        model.decideApproval(.yes)
        backend.say(.screenAction(request: "s2", step: down))
        XCTAssertEqual(approved, [down])
    }

    func testAStoppedStepStopsTheRestOfTheTurn() {
        unasked("s1", down, .free)
        pendingDone?(ScreenStepOutcome(status: .stopped, text: "Stopped: you took over, so nothing was done.", shot: nil))
        XCTAssertEqual(model.statusNote, ScreenActionPolicy.tookOverLine)
        XCTAssertTrue(model.screenStopped)
        unasked("s2", down, .free)
        XCTAssertEqual(simple.count, 1, "the next step isn't done")
        XCTAssertEqual(backend.results.map(\.result.status), [.stopped, .stopped])
    }

    func testEscBetweenStepsStopsTheNextOne() {
        unasked("s1", down, .free)
        pendingDone?(ScreenStepOutcome(status: .done, text: "Scrolled.", shot: nil))
        model.screenTurnEscape()
        XCTAssertEqual(model.statusNote, ScreenActionPolicy.tookOverLine)
        unasked("s2", down, .free)
        XCTAssertEqual(simple.count, 1)
        XCTAssertEqual(backend.results.last?.result.status, .stopped, "the engine is told stopped")
    }

    func testTheTalkKeyDuringATurnStopsTheSteps() {
        model.voiceListeningStarted()
        unasked("s1", down, .free)
        XCTAssertTrue(simple.isEmpty)
        XCTAssertEqual(backend.results.first?.result.status, .stopped)
    }

    func testANewMessageStartsWithTheScreenGivenBack() {
        unasked("s1", down, .free)
        pendingDone?(ScreenStepOutcome(status: .stopped, text: "Stopped.", shot: nil))
        backend.onFinished?(backend.runs.last!, 0)
        model.composerText = "and the next one?"
        model.submit()
        unasked("s1", down, .free)
        XCTAssertEqual(simple.count, 2, "a take-over lasts one turn")
    }

    func testCancelEndsTheActingLineAndTheWatch() {
        unasked("s1", down, .free)
        model.cancel()
        XCTAssertNil(model.state.acting)
        XCTAssertEqual(watching, [true, false])
        pendingDone?(ScreenStepOutcome(status: .done, text: "late", shot: nil))
        XCTAssertTrue(backend.results.isEmpty, "a cancelled turn's late result is dropped")
    }
}
