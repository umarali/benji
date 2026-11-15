import XCTest
@testable import BenjiApp
import BenjiCore

/// Which display a message's screenshot is taken of, through the same `CaptureRouting` the app uses,
/// with an injected display list and capture callback, and the model's display sources set as the app
/// sets them (the panel's display; the talk key's display). No screen, permission API or engine is used.
/// The symptom: the user starts a message about the external display, then moves the pointer to the
/// laptop's notch panel to answer the Ask card; the screenshot must still be of the external display.
/// This reproduces that sequence offline, without real displays.
final class CaptureTargetTests: XCTestCase {
    private let laptop = DisplayDescriptor(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                           notch: CGRect(x: 661, y: 950, width: 190, height: 32),
                                           name: "Built-in Retina Display")
    /// Left of and lower than the laptop: a negative origin on both axes.
    private let external = DisplayDescriptor(id: 2, frame: CGRect(x: -2560, y: -458, width: 2560, height: 1440),
                                             name: "Studio Display")
    private var onExternal: CGPoint { CGPoint(x: -1280, y: 400) }
    private var onLaptopPanel: CGPoint { CGPoint(x: 756, y: 900) }

    private var backend: FakeBackend!
    private var model: CompanionModel!
    private var displays: [DisplayDescriptor] = []
    private var pointer = CGPoint.zero
    /// The display each capture was taken of.
    private var captured: [UInt32] = []
    private var refuse = false
    private var deferred: [() -> Void] = []
    private var deferCaptures = false
    private var files: [URL] = []

    override func setUp() {
        backend = FakeBackend()
        displays = [laptop, external]
        pointer = onExternal
        captured = []
        refuse = false
        deferred = []
        deferCaptures = false
        let defaults = UserDefaults(suiteName: "benji-capture-target-tests-\(UUID().uuidString)")!
        defaults.set(ScreenMode.ask.rawValue, forKey: ScreenModeState.defaultsKey)
        model = CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: defaults))
        panel(on: external.id)   // the panel visited the external display (its bar)
        model.captureScreen = { [unowned self] done in
            CaptureRouting.route(target: self.model.captureTarget, displays: self.displays, pointer: self.pointer,
                                 fallback: self.laptop.id, capture: { id, finish in
                self.captured.append(id)
                if self.refuse { return finish(.failure(ScreenCaptureError.permissionNeeded)) }
                let shot = self.shot(of: id)
                if self.deferCaptures { self.deferred.append { finish(.success(shot)) } } else { finish(.success(shot)) }
            }, completion: done)
        }
    }

    override func tearDown() {
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func shot(of id: UInt32) -> CapturedScreen {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("benji-test-\(UUID().uuidString).jpg")
        try? Data([0]).write(to: url)
        files.append(url)
        let frame = displays.first { $0.id == id }?.frame ?? .zero
        return CapturedScreen(url: url, pixelSize: CGSize(width: 1280, height: 720), thumbnail: NSImage(),
                              screenFrame: frame, displayID: id)
    }

    /// What the app does when the panel moves or the displays change.
    private func panel(on id: UInt32) {
        model.panelDisplay = CaptureDisplay.target(id: id, among: displays)
    }

    /// What the app does when the talk key goes down over a display.
    private func talkKey(over id: UInt32) {
        model.voiceEngaged(on: CaptureDisplay.target(id: id, among: displays))
    }

    private func speak(_ text: String) {
        model.voiceListeningStarted()
        model.voiceTranscribing()
        model.voiceSubmit(text)
    }

    private func type(_ text: String) {
        model.composerText = text
        model.submit()
    }

    func testAskCardCapturesTheDisplayTheMessageStartedOnAfterThePointerMovesToTheNotch() {
        type("what's on this chart")
        XCTAssertNotNil(model.pendingScreenSend)
        XCTAssertTrue(captured.isEmpty, "nothing is captured before Send")
        pointer = onLaptopPanel                      // to the panel on the laptop, to press Send
        model.decideScreenSend(.send)
        XCTAssertEqual(captured, [external.id])
        XCTAssertEqual(backend.starts.map(\.task), ["what's on this chart"])
        XCTAssertNotNil(backend.starts.first?.imagePath)
        XCTAssertEqual(model.screenMode.mode, .ask, "the saved mode is left alone")
    }

    func testTheTalkKeyDisplayIsKeptForASpokenMessageSentFromTheLaptop() {
        model.setScreenMode(.on)
        panel(on: laptop.id)
        talkKey(over: external.id)
        pointer = onLaptopPanel
        speak("summarise this page")
        XCTAssertEqual(captured, [external.id])
    }

    func testASlowCaptureStillSendsTheLatchedDisplayAfterThePointerMoves() {
        model.setScreenMode(.on)
        deferCaptures = true
        type("read this")
        pointer = onLaptopPanel
        panel(on: laptop.id)                         // closed and went home before the picture landed
        XCTAssertTrue(backend.starts.isEmpty)
        deferred.removeFirst()()
        XCTAssertEqual(captured, [external.id])
        XCTAssertEqual(backend.starts.count, 1)
        XCTAssertEqual(model.currentScreenshotGeometry?.screenFrame, external.frame,
                       "pointing and screen steps map onto the captured display")
    }

    func testARefusedCaptureAskedAgainKeepsTheSameDisplay() {
        refuse = true
        type("what's this")
        model.decideScreenSend(.send)
        XCTAssertEqual(model.pendingScreenSend?.task, "what's this", "the refused message waits on the card")
        pointer = onLaptopPanel
        refuse = false
        model.decideScreenSend(.send)
        XCTAssertEqual(captured, [external.id, external.id])
        XCTAssertEqual(backend.starts.count, 1)
    }

    func testCancelDropsTheDisplayAndALateCaptureOfTheOldMessage() {
        model.setScreenMode(.on)
        deferCaptures = true
        type("first")
        model.cancel()
        XCTAssertNil(model.captureTarget)
        pointer = onLaptopPanel
        panel(on: laptop.id)
        type("second")
        XCTAssertEqual(captured, [external.id, laptop.id])
        deferred.removeFirst()()                     // the first message's capture lands late
        XCTAssertTrue(backend.starts.isEmpty, "a cancelled message's picture is never sent")
        deferred.removeFirst()()
        XCTAssertEqual(backend.starts.map(\.task), ["second"])
        XCTAssertEqual(model.currentScreenshotGeometry?.screenFrame, laptop.frame)
    }

    func testADisconnectedDisplayFailsClearlyAndNoOtherDisplayIsCaptured() {
        type("look at the external one")
        displays = [laptop]                          // unplugged while the card waits
        panel(on: laptop.id)
        pointer = onLaptopPanel
        model.decideScreenSend(.send)
        XCTAssertTrue(captured.isEmpty)
        XCTAssertTrue(backend.starts.isEmpty)
        XCTAssertEqual(model.state.phase, .error)
        XCTAssertTrue(model.state.lastError?.contains("Studio Display isn't connected") ?? false,
                      model.state.lastError ?? "no error")
        XCTAssertEqual(model.composerText, "look at the external one", "the typed words come back")
    }

    func testWithoutScreenSendsNoPictureAndTheNextMessageLatchesAfresh() {
        type("one")
        model.decideScreenSend(.withoutScreen)
        XCTAssertTrue(captured.isEmpty)
        XCTAssertNil(backend.starts.first?.imagePath)
        backend.finish(0)
        panel(on: laptop.id)
        type("two")
        model.decideScreenSend(.send)
        XCTAssertEqual(captured, [laptop.id])
    }

    func testTheCardNamesTheDisplayOnlyWhenSeveralAreConnected() {
        type("this")
        XCTAssertEqual(model.captureTarget, CaptureTarget(id: external.id, name: "Studio Display"))
        model.decideScreenSend(.cancel)
        displays = [laptop]
        panel(on: laptop.id)
        type("that")
        XCTAssertEqual(model.captureTarget, CaptureTarget(id: laptop.id, name: nil))
    }

    func testOffNeverCapturesOrLatches() {
        model.setScreenMode(.off)
        type("hello")
        XCTAssertTrue(captured.isEmpty)
        XCTAssertNil(model.captureTarget)
        XCTAssertEqual(backend.starts.count, 1)
    }

    // MARK: each source is scoped to its own kind of message

    func testAVoiceTurnOverTheExternalDisplayDoesNotPinALaterTypedMessage() {
        model.setScreenMode(.on)
        panel(on: laptop.id)
        talkKey(over: external.id)
        speak("what is this graph")
        backend.finish(0)
        type("and in the laptop window?")            // typed in the panel on the laptop
        XCTAssertEqual(captured, [external.id, laptop.id])
    }

    func testATalkKeyDisplayUnpluggedBeforeTheWordsAreSentFailsInsteadOfFallingBack() {
        model.setScreenMode(.on)
        panel(on: laptop.id)
        talkKey(over: external.id)
        model.voiceListeningStarted()
        displays = [laptop]                          // unplugged while speaking
        panel(on: laptop.id)
        model.voiceTranscribing()
        model.voiceSubmit("what's on the big screen")
        XCTAssertTrue(captured.isEmpty, "the laptop is never captured in its place")
        XCTAssertTrue(backend.starts.isEmpty)
        XCTAssertEqual(model.state.phase, .error)
        XCTAssertTrue(model.state.lastError?.contains("Studio Display isn't connected") ?? false, model.state.lastError ?? "")
    }

    // MARK: Include this display once (Ask)

    func testIncludeOnceSendsOnePictureWithoutTheCardThenAsksAgain() {
        model.includeDisplayOnce()
        XCTAssertEqual(model.includeOnce, CaptureTarget(id: external.id, name: "Studio Display"))
        panel(on: laptop.id)                         // the label keeps the display chosen
        type("first")
        XCTAssertNil(model.pendingScreenSend, "the user already said yes for this message")
        XCTAssertEqual(captured, [external.id])
        XCTAssertNil(model.includeOnce, "used up by this message")
        backend.finish(0)
        type("second")
        XCTAssertNotNil(model.pendingScreenSend, "the next message asks as usual")
        XCTAssertEqual(captured, [external.id])
        XCTAssertEqual(model.screenMode.mode, .ask)
    }

    func testIncludeOnceAlsoGoesWithASpokenMessage() {
        model.includeDisplayOnce()
        talkKey(over: laptop.id)
        speak("read me this")
        XCTAssertEqual(captured, [external.id], "the explicit choice wins over the talk key's display")
    }

    func testDontIncludeEscapeAndAModeChangeClearTheChoice() {
        model.includeDisplayOnce()
        model.clearIncludeOnce()
        type("one")
        XCTAssertNotNil(model.pendingScreenSend)
        model.decideScreenSend(.cancel)
        model.composerText = ""
        model.includeDisplayOnce()
        model.cancel()                               // Stop
        XCTAssertNil(model.includeOnce)
        model.setExpanded(true)
        model.includeDisplayOnce()
        model.setExpanded(false)                     // Esc or Collapse folds the panel
        XCTAssertNil(model.includeOnce)
        model.includeDisplayOnce()
        model.setScreenMode(.on)
        XCTAssertNil(model.includeOnce)
        XCTAssertTrue(captured.isEmpty)
    }

    func testIncludeOnceIsOfferedOnlyInAskAndNeverForAModelThatCantSee() {
        XCTAssertTrue(model.canIncludeOnce)
        model.setScreenMode(.on)
        XCTAssertFalse(model.canIncludeOnce, "On already sends the display")
        model.setScreenMode(.off)
        XCTAssertFalse(model.canIncludeOnce, "Off means Benji can't see the screen")
        model.includeDisplayOnce()
        XCTAssertNil(model.includeOnce)
        model.setScreenMode(.ask)
        model.visionUnavailable = "text-only-model"
        XCTAssertFalse(model.canIncludeOnce)
        model.includeDisplayOnce()
        type("hello")
        XCTAssertTrue(captured.isEmpty)
        XCTAssertNil(backend.starts.first?.imagePath)
    }

    func testAnIncludedDisplayUnpluggedBeforeSendFailsClearly() {
        model.includeDisplayOnce()
        displays = [laptop]
        panel(on: laptop.id)
        type("look at that one")
        XCTAssertTrue(captured.isEmpty)
        XCTAssertTrue(backend.starts.isEmpty)
        XCTAssertEqual(model.state.phase, .error)
        XCTAssertEqual(model.composerText, "look at that one")
        XCTAssertNil(model.includeOnce, "a failed choice doesn't linger for the next message")
    }

    func testARefusedIncludeOnceFallsBackToTheCardForTheSameDisplay() {
        refuse = true
        model.includeDisplayOnce()
        type("what's this")
        XCTAssertEqual(model.pendingScreenSend?.task, "what's this")
        XCTAssertEqual(model.captureTarget?.id, external.id)
        model.decideScreenSend(.withoutScreen)
        XCTAssertEqual(backend.starts.map(\.task), ["what's this"])
        XCTAssertNil(backend.starts.first?.imagePath)
        XCTAssertEqual(captured, [external.id])
    }
    func testPanelMicAfterATalkKeyTurnUsesTheNewPanelDisplay() {
        model.setScreenMode(.on)
        panel(on: laptop.id)
        talkKey(over: laptop.id)
        speak("first")
        backend.finish(0)
        panel(on: external.id)
        model.onMicToggle = { [unowned self] in self.speak("second") }
        model.toggleMicFromPanel()
        XCTAssertEqual(captured, [laptop.id, external.id])
    }

    func testOpeningThePanelForListeningReplacesAnEarlierTalkKeyDisplay() {
        model.setScreenMode(.on)
        panel(on: laptop.id)
        talkKey(over: laptop.id)
        speak("first")
        backend.finish(0)
        model.setExpanded(false)
        panel(on: external.id)
        model.onExpandedChange = { [unowned self] open, _ in
            if open { self.speak("second") }
        }
        model.setExpanded(true)
        XCTAssertEqual(captured, [laptop.id, external.id])
    }

    func testThePanelMicCanFinishATalkKeyRecordingWithoutChangingItsDisplay() {
        model.setScreenMode(.on)
        talkKey(over: external.id)
        model.voiceListeningStarted()
        panel(on: laptop.id)
        model.onMicToggle = { [unowned self] in
            self.model.voiceTranscribing()
            self.model.voiceSubmit("finish the external recording")
        }
        model.toggleMicFromPanel()
        XCTAssertEqual(captured, [external.id])
    }

    func testOpeningFromTheTalkKeyKeepsItsDisplayForAutomaticListening() {
        model.setScreenMode(.on)
        panel(on: laptop.id)
        talkKey(over: external.id)
        model.onExpandedChange = { [unowned self] open, _ in
            if open { self.speak("the key started this") }
        }
        model.setExpanded(true, preservingVoiceDisplay: true)
        XCTAssertEqual(captured, [external.id])
    }

    func testStartingANewPanelConversationDropsADisconnectedOldVoiceDisplay() {
        model.setScreenMode(.on)
        panel(on: laptop.id)
        talkKey(over: external.id)
        speak("first")
        backend.finish(0)
        displays = [laptop]
        model.voiceStartedInPanel()
        speak("a new panel conversation")
        XCTAssertEqual(captured, [external.id, laptop.id])
    }

    func testAStopTapDoesNotRetargetARecordingToThePointersNewDisplay() {
        model.setScreenMode(.on)
        talkKey(over: external.id)
        model.voiceListeningStarted()
        talkKey(over: laptop.id)   // a second key press sends the recording, it does not start it again
        model.voiceTranscribing()
        model.voiceSubmit("keep the display this recording started on")
        XCTAssertEqual(captured, [external.id])
    }

}
