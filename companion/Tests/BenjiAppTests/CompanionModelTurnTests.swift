import XCTest
@testable import BenjiApp
import BenjiCore

/// The coordinator's turn lifecycle with a fake engine: start, finish, cancel, and callbacks that
/// arrive late, twice or out of order.
final class CompanionModelTurnTests: XCTestCase {
    var backend: FakeBackend!
    var model: CompanionModel!
    var spoken: [String] = []
    var voiceCancels = 0

    override func setUp() {
        backend = FakeBackend()
        let suite = UserDefaults(suiteName: "benji-app-tests-\(UUID().uuidString)")!
        suite.set(ScreenMode.off.rawValue, forKey: ScreenModeState.defaultsKey)
        model = CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: suite))
        spoken = []
        voiceCancels = 0
        model.onSpeak = { [unowned self] in self.spoken.append($0) }
        model.onCancel = { [unowned self] in self.voiceCancels += 1 }
    }

    private func type(_ text: String) {
        model.composerText = text
        model.submit()
    }

    private var answers: [String] { model.state.lines.filter { $0.role == .assistant }.map(\.text) }
    private var errors: [String] { model.state.lines.filter { $0.role == .error }.map(\.text) }

    // Ready → Listening → Processing → Speaking → Ready, from real-shaped events.
    func testVoiceTurnRunsThroughEveryPhaseAndBackToReady() {
        XCTAssertEqual(model.state.phase, .idle)
        model.voiceListeningStarted()
        XCTAssertEqual(model.state.phase, .listening)
        model.voicePartial("what time")
        XCTAssertEqual(model.partialTranscript, "what time")
        model.voiceTranscribing()
        XCTAssertEqual(model.state.phase, .transcribing)
        model.voiceSubmit("what time is it")
        XCTAssertEqual(model.state.phase, .thinking)
        XCTAssertEqual(backend.starts.count, 1)
        XCTAssertTrue(backend.starts[0].spoken)
        backend.say(.accepted)
        backend.say(.answer("It's noon."))
        XCTAssertEqual(spoken, ["It's noon."])
        model.voiceSpeaking(true)
        XCTAssertEqual(model.state.phase, .speaking)
        backend.finish()
        XCTAssertEqual(model.state.phase, .speaking, "the process can end while the answer is still playing")
        model.voiceSpeaking(false)
        XCTAssertEqual(model.state.phase, .idle)
        XCTAssertEqual(answers, ["It's noon."])
    }

    // Cancel during Processing, then the engine's late success: nothing comes back.
    func testLateAnswerAfterCancelIsDropped() {
        type("summarise my notes")
        let run = backend.lastRun
        model.cancel()
        XCTAssertEqual(model.state.phase, .idle, "the panel updates at once")
        XCTAssertEqual(backend.cancels, 1)
        XCTAssertEqual(voiceCancels, 1)

        backend.say(.tool(name: "read_file", detail: "notes.md"), run: run)
        backend.say(.pointedAnswer(text: "Here's the summary.", targets: []), run: run)
        backend.finish(0, run: run)

        XCTAssertEqual(model.state.phase, .idle)
        XCTAssertTrue(answers.isEmpty)
        XCTAssertTrue(spoken.isEmpty)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertTrue(model.state.turns.last?.cutOff ?? false)
        // The cancelled answer isn't remembered as context for the next message.
        type("next")
        XCTAssertTrue(backend.starts.last!.memoryEmpty)
    }

    // …and its late failure: no error row, no Error state.
    func testLateFailureAfterCancelIsDropped() {
        type("do something")
        let run = backend.lastRun
        model.cancel()
        backend.say(.error("provider timed out"), run: run)
        backend.finish(1, run: run)
        XCTAssertEqual(model.state.phase, .idle)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertNil(model.state.lastError)
    }

    // A cancelled run that is still exiting must not end (or answer into) the next turn.
    func testCancelledRunsLateFinishDoesNotEndTheNextTurn() {
        type("first")
        let first = backend.lastRun
        model.cancel()
        type("second")
        let second = backend.lastRun
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(model.state.phase, .thinking)

        backend.say(.answer("answer to first"), run: first)
        backend.finish(0, run: first)
        XCTAssertEqual(model.state.phase, .thinking, "the second turn is still running")
        XCTAssertTrue(answers.isEmpty)

        backend.say(.answer("answer to second"), run: second)
        backend.finish(0, run: second)
        XCTAssertEqual(answers, ["answer to second"])
        XCTAssertEqual(model.state.phase, .idle)
    }

    // A duplicate finish (or one after the turn already ended) changes nothing.
    func testDuplicateFinishIsIgnored() {
        type("hi")
        backend.say(.answer("hello"))
        backend.finish(0)
        let after = model.state
        backend.finish(1)
        backend.say(.error("late"))
        XCTAssertEqual(model.state, after)
    }

    // Cancel while transcribing: the transcript that arrives afterwards never starts a turn.
    func testTranscriptArrivingAfterCancelIsDiscarded() {
        model.voiceListeningStarted()
        model.voiceTranscribing()
        model.cancel()
        model.voicePartial("open mail")
        model.voiceSubmit("open mail and delete everything")
        XCTAssertTrue(backend.starts.isEmpty)
        XCTAssertEqual(model.state.phase, .idle)
        XCTAssertEqual(model.partialTranscript, "")
        XCTAssertTrue(model.state.lines.isEmpty)
    }

    // Stop finalises: the transcript taken while Transcribing is sent once.
    func testStopFinalisesAndSendsOnce() {
        model.voiceListeningStarted()
        model.voiceTranscribing()
        model.voiceSubmit("hello there")
        model.voiceSubmit("hello there")   // a duplicate completion
        XCTAssertEqual(backend.starts.map(\.task), ["hello there"])
    }

    // A screenshot that finishes after Cancel is deleted and never sent.
    func testScreenCaptureFinishingAfterCancelIsNotSent() throws {
        model.setScreenMode(.on)
        var pending: ((Result<CapturedScreen, Error>) -> Void)?
        model.captureScreen = { pending = $0 }
        type("what's on screen")
        XCTAssertNotNil(pending)
        model.cancel()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("benji-test-\(UUID().uuidString).png")
        try Data([0]).write(to: url)
        pending?(.success(CapturedScreen(url: url, pixelSize: CGSize(width: 10, height: 10), thumbnail: NSImage(), screenFrame: .zero)))
        XCTAssertTrue(backend.starts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

/// The held-back note (another app was playing out loud) stays while the mic reopens and goes
/// once the user speaks again; nothing is sent.
final class CompanionModelHeldBackTests: XCTestCase {
    func testHeldBackNoteOutlastsReopeningAndClearsOnNewWords() {
        let backend = FakeBackend()
        let suite = UserDefaults(suiteName: "benji-app-tests-\(UUID().uuidString)")!
        suite.set(ScreenMode.off.rawValue, forKey: ScreenModeState.defaultsKey)
        let model = CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: suite))
        model.conversationChanged(on: true)
        model.voiceListeningStarted()
        model.voiceTranscribing()
        model.voiceIgnored()
        model.voiceHeldBack(HandsFreeHoldReason.otherAppAudio.notice)
        model.voiceListeningStarted()
        XCTAssertEqual(model.statusNote, HandsFreeHoldReason.otherAppAudio.notice)
        model.voicePartial("")
        XCTAssertNotNil(model.statusNote)
        model.voicePartial("what's")
        XCTAssertNil(model.statusNote)
        XCTAssertTrue(backend.starts.isEmpty)
        XCTAssertEqual(model.state.phase, .listening)
    }

    func testHeldBackWordsAreKeptInTheBoxNotLost() {
        let suite = UserDefaults(suiteName: "benji-app-tests-\(UUID().uuidString)")!
        suite.set(ScreenMode.off.rawValue, forKey: ScreenModeState.defaultsKey)
        let model = CompanionModel(backend: FakeBackend(), screenMode: ScreenModeStore(defaults: suite))
        model.voiceHeldBack(HandsFreeHoldReason.otherAppAudio.notice, words: "  How about the E?  ")
        XCTAssertEqual(model.composerText, "How about the E?")
        model.voiceHeldBack(HandsFreeHoldReason.otherAppAudio.notice, words: "and the T")
        XCTAssertEqual(model.composerText, "How about the E? and the T", "a second held-back utterance adds to the first")
        model.voiceHeldBack(HandsFreeHoldReason.otherAppAudio.notice)
        XCTAssertEqual(model.composerText, "How about the E? and the T")
    }
}
