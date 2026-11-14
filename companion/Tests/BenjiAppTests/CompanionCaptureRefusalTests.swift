import XCTest
@testable import BenjiApp
import BenjiCore

/// Refused captures are injected. No screen, microphone, permission API or real engine is used.
final class CompanionCaptureRefusalTests: XCTestCase {
    var backend: FakeBackend!
    var model: CompanionModel!
    var captures = 0

    override func setUp() {
        backend = FakeBackend()
        let defaults = UserDefaults(suiteName: "benji-capture-refusal-tests-\(UUID().uuidString)")!
        defaults.set(ScreenMode.on.rawValue, forKey: ScreenModeState.defaultsKey)
        model = CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: defaults))
        model.captureScreen = { [unowned self] done in
            self.captures += 1
            done(.failure(ScreenCaptureError.permissionNeeded))
        }
    }

    private func send(spoken: Bool) {
        if spoken {
            model.voiceListeningStarted()
            model.voiceTranscribing()
            model.voiceSubmit("keep these words")
        } else {
            model.composerText = "keep these words"
            model.submit()
        }
    }

    func testTypedRefusalOffersTheSameMessageWithoutRecapturingOrDuplicatingIt() {
        send(spoken: false)
        XCTAssertEqual(model.permissionAsk, .screenToLook)
        XCTAssertEqual(model.pendingScreenSend?.task, "keep these words")
        XCTAssertFalse(model.canSendTyped, "the retained message still awaits a decision")
        XCTAssertTrue(backend.starts.isEmpty)
        model.decideScreenSend(.withoutScreen)
        model.decideScreenSend(.withoutScreen)
        XCTAssertEqual(backend.starts.map(\.task), ["keep these words"])
        XCTAssertEqual(backend.starts.first?.spoken, false)
        XCTAssertEqual(captures, 1)
        XCTAssertNil(model.pendingScreenSend)
        XCTAssertNil(model.permissionAsk, "the notice must not keep claiming this message wasn't sent")
        XCTAssertEqual(model.composerText, "")
        XCTAssertEqual(model.state.lines.filter { $0.role == .user }.map(\.text), ["keep these words"])
        XCTAssertFalse(model.state.lines.contains { $0.role == .attachment })
        XCTAssertEqual(model.screenMode.mode, .on, "the user's screen preference is unchanged")
    }

    func testSpokenRefusalCanSendTheSameWordsWithoutScreen() {
        send(spoken: true)
        XCTAssertEqual(model.permissionAsk, .screenToLook)
        XCTAssertEqual(model.pendingScreenSend?.task, "keep these words")
        XCTAssertTrue(backend.starts.isEmpty)
        model.decideScreenSend(.withoutScreen)
        XCTAssertEqual(backend.starts.map(\.task), ["keep these words"])
        XCTAssertEqual(backend.starts.first?.spoken, true)
        XCTAssertEqual(captures, 1)
    }

    func testCancelKeepsTypedAndSpokenWordsInTheComposer() {
        for spoken in [false, true] {
            send(spoken: spoken)
            model.decideScreenSend(.cancel)
            XCTAssertEqual(model.composerText, "keep these words")
            XCTAssertNil(model.pendingScreenSend)
            XCTAssertEqual(model.state.phase, .idle)
        }
        XCTAssertTrue(backend.starts.isEmpty)
    }

    func testPermissionRefusedAfterAskStillOffersSendWithoutScreen() {
        model.setScreenMode(.ask)
        send(spoken: false)
        XCTAssertEqual(captures, 0)
        model.decideScreenSend(.send)
        XCTAssertEqual(model.permissionAsk, .screenToLook)
        XCTAssertEqual(model.pendingScreenSend?.task, "keep these words")
        model.decideScreenSend(.withoutScreen)
        XCTAssertEqual(backend.starts.map(\.task), ["keep these words"])
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(model.screenMode.mode, .ask)
    }

    func testLatePermissionRefusalAfterCancelDoesNotReopenTheCard() {
        var completion: ((Result<CapturedScreen, Error>) -> Void)?
        model.captureScreen = { completion = $0 }
        send(spoken: true)
        model.cancel()
        completion?(.failure(ScreenCaptureError.permissionNeeded))
        XCTAssertNil(model.pendingScreenSend)
        XCTAssertNil(model.permissionAsk)
        XCTAssertTrue(backend.starts.isEmpty)
    }

    func testEscapeKeepsTheRefusedSpokenWordsInTheComposer() {
        send(spoken: true)
        let presenter = NotchPresenter(model: model,
                                       layout: NotchLayoutInfo(notch: nil, screenFrame: .zero),
                                       accessibility: NotchAccessibility(reduceMotion: true))
        presenter.escape()
        XCTAssertEqual(model.composerText, "keep these words")
        XCTAssertNil(model.pendingScreenSend)
        XCTAssertEqual(model.permissionAsk, .screenToLook)
        XCTAssertFalse(model.expanded)
        XCTAssertTrue(backend.starts.isEmpty)
    }

    func testRetryingTheRefusedCaptureKeepsTheWordsUntilSendWithoutScreen() {
        send(spoken: true)
        model.decideScreenSend(.send)
        XCTAssertEqual(captures, 2)
        XCTAssertEqual(model.pendingScreenSend?.task, "keep these words")
        XCTAssertTrue(backend.starts.isEmpty)
        model.decideScreenSend(.withoutScreen)
        XCTAssertEqual(backend.starts.map(\.task), ["keep these words"])
        XCTAssertEqual(captures, 2)
    }

    func testOtherCaptureFailuresKeepTheirExistingErrorAndTypedRestoration() {
        model.captureScreen = { $0(.failure(ScreenCaptureError.encodeFailed)) }
        send(spoken: false)
        XCTAssertEqual(model.state.phase, .error)
        XCTAssertNil(model.pendingScreenSend)
        XCTAssertNil(model.permissionAsk)
        XCTAssertEqual(model.composerText, "keep these words")
        XCTAssertTrue(backend.starts.isEmpty)
    }

    func testASuccessfulCaptureRetryClearsTheRefusalNoticeAndSendsOnce() throws {
        send(spoken: false)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("benji-test-\(UUID().uuidString).png")
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        model.captureScreen = { done in
            done(.success(CapturedScreen(url: url, pixelSize: CGSize(width: 10, height: 10),
                                        thumbnail: NSImage(), screenFrame: .zero)))
        }
        model.decideScreenSend(.send)
        XCTAssertNil(model.permissionAsk)
        XCTAssertNil(model.pendingScreenSend)
        XCTAssertEqual(backend.starts.map(\.task), ["keep these words"])
        XCTAssertEqual(model.currentScreenshotURL, url)
        XCTAssertEqual(model.state.lines.filter { $0.role == .attachment }.count, 1)
        model.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func escape() {
        let presenter = NotchPresenter(model: model,
                                       layout: NotchLayoutInfo(notch: nil, screenFrame: .zero),
                                       accessibility: NotchAccessibility(reduceMotion: true))
        presenter.escape()
    }

    func testAskEscapeRestoresTypedAndSpokenWordsIntoAnEmptyComposer() {
        model.setScreenMode(.ask)
        for spoken in [false, true] {
            for empty in ["", " \n\t"] {
                model.composerText = ""
                send(spoken: spoken)
                XCTAssertNotNil(model.pendingScreenSend)
                model.composerText = empty
                escape()
                XCTAssertEqual(model.composerText, "keep these words")
                XCTAssertNil(model.pendingScreenSend)
                XCTAssertEqual(model.state.phase, .idle)
                XCTAssertFalse(model.expanded)
            }
        }
        XCTAssertEqual(captures, 0)
        XCTAssertTrue(backend.starts.isEmpty)
    }

    func testAskCancelRestoresSpokenWordsIntoWhitespace() {
        model.setScreenMode(.ask)
        send(spoken: true)
        model.composerText = " \n\t"
        model.decideScreenSend(.cancel)
        XCTAssertEqual(model.composerText, "keep these words")
        XCTAssertNil(model.pendingScreenSend)
        XCTAssertTrue(backend.starts.isEmpty)
    }

    func testExplicitDismissalsPreserveADraftTypedWhileTheCardWasUp() {
        for mode in [ScreenMode.ask, .on] {
            model.setScreenMode(mode)
            for spoken in [false, true] {
                for useEscape in [false, true] {
                    model.composerText = ""
                    send(spoken: spoken)
                    model.composerText = "  my next draft  "
                    if useEscape { escape() } else { model.decideScreenSend(.cancel) }
                    XCTAssertEqual(model.composerText, "  my next draft  ")
                    XCTAssertNil(model.pendingScreenSend)
                    XCTAssertEqual(model.state.phase, .idle)
                    XCTAssertEqual(model.state.lines.last(where: { $0.role == .user })?.text, "keep these words")
                }
            }
        }
        XCTAssertTrue(backend.starts.isEmpty)
    }

    func testExplicitDismissalsPreserveADraftFromBeforeSpeaking() {
        model.setScreenMode(.ask)
        for useEscape in [false, true] {
            model.composerText = "an earlier draft"
            send(spoken: true)
            XCTAssertEqual(model.composerText, "an earlier draft")
            if useEscape { escape() } else { model.decideScreenSend(.cancel) }
            XCTAssertEqual(model.composerText, "an earlier draft")
            XCTAssertNil(model.pendingScreenSend)
        }
        XCTAssertTrue(backend.starts.isEmpty)
    }

    func testStopNeverWritesTheComposerWhileAConfirmationWaits() {
        for mode in [ScreenMode.ask, .on] {
            model.setScreenMode(mode)
            for spoken in [false, true] {
                for draft in ["", " \n\t", "my next draft"] {
                    model.composerText = ""
                    send(spoken: spoken)
                    model.composerText = draft
                    model.cancel() // The Stop button's action.
                    XCTAssertEqual(model.composerText, draft)
                    XCTAssertNil(model.pendingScreenSend)
                    XCTAssertEqual(model.state.phase, .idle)
                }
            }
        }
        XCTAssertTrue(backend.starts.isEmpty)
    }

    func testConfirmationTimerNeverWritesTheComposer() throws {
        for mode in [ScreenMode.ask, .on] {
            model.setScreenMode(mode)
            for spoken in [false, true] {
                for draft in ["", " \n\t", "my next draft"] {
                    model.composerText = ""
                    send(spoken: spoken)
                    model.composerText = draft
                    // Fire the actual scheduled timer, without waiting 60 seconds or adding a test-only clock.
                    let timer = try XCTUnwrap(Mirror(reflecting: model!).descendant("screenConfirmTimer") as? Timer)
                    XCTAssertEqual(timer.fireDate.timeIntervalSinceNow, 60, accuracy: 1)
                    timer.fire()
                    XCTAssertFalse(timer.isValid)
                    XCTAssertEqual(model.composerText, draft)
                    XCTAssertNil(model.pendingScreenSend)
                    XCTAssertEqual(model.state.phase, .idle)
                    model.decideScreenSend(.withoutScreen)
                }
            }
        }
        XCTAssertTrue(backend.starts.isEmpty)
    }

    private func assertScreenOffSendClearsRefusal(spoken: Bool) {
        send(spoken: spoken)
        escape()
        XCTAssertEqual(model.permissionAsk, .screenToLook, "Escape keeps the refusal notice")
        model.setScreenMode(.off)
        send(spoken: spoken)
        XCTAssertNil(model.permissionAsk, "the later turn has actually been sent")
        XCTAssertEqual(backend.starts.map(\.task), ["keep these words"])
        XCTAssertEqual(backend.starts.first?.spoken, spoken)
        XCTAssertNil(model.currentScreenshotURL)
        model.cancel()
    }

    func testSuccessfulScreenOffTypedSendClearsAnEarlierRefusalNotice() {
        assertScreenOffSendClearsRefusal(spoken: false)
    }

    func testSuccessfulScreenOffSpokenSendClearsAnEarlierRefusalNotice() {
        assertScreenOffSendClearsRefusal(spoken: true)
    }
}
