import XCTest
@testable import BenjiApp
import BenjiCore

/// D-173 through the model, on the exact wrapper chain the app builds
/// (`FigureStageBackend(ExplainCardBackend(backend))`): a muted Mac gets text instead of speech, the
/// talk key's prewarm reaches the engine through both wrappers, a call holds the job peek, and a
/// permission is asked for once. No windows, no microphone, no audio, no clipboard.
final class QuietModelTests: XCTestCase {
    var fake: FakeBackend!
    var model: CompanionModel!
    var spoken: [String] = []
    var clipboard: [String] = []

    override func setUp() {
        fake = FakeBackend()
        let chain = FigureStageBackend(ExplainCardBackend(fake, stage: ExplainCardBackendTests.FakeStage()), stage: { nil })
        let suite = UserDefaults(suiteName: "benji-quiet-model-\(UUID().uuidString)")!
        suite.set(ScreenMode.off.rawValue, forKey: ScreenModeState.defaultsKey)
        model = CompanionModel(backend: chain, screenMode: ScreenModeStore(defaults: suite))
        spoken = []
        clipboard = []
        model.onSpeak = { [unowned self] in self.spoken.append($0) }
        model.writeClipboard = { [unowned self] in self.clipboard.append($0) }
    }

    private func spokenTurn(_ words: String = "what time is it", answer: String = "It's noon.") {
        model.voiceListeningStarted()
        model.voiceTranscribing()
        model.voiceSubmit(words)
        fake.say(.accepted)
        fake.say(.answer(answer))
    }

    // MARK: muted output

    func testAMutedMacGetsTheAnswerAsTextAndNothingIsSpokenOrCopied() {
        model.outputState = { OutputState(muted: true, volume: 0.5) }
        spokenTurn()
        XCTAssertTrue(spoken.isEmpty, "nothing is read aloud into a muted Mac")
        XCTAssertEqual(model.silentAnswer, SilentAnswer(why: .muted, text: "It's noon."))
        XCTAssertTrue(model.silentAnswer!.hint.contains("Unmute"))
        XCTAssertEqual(model.state.lines.filter { $0.role == .assistant }.map(\.text), ["It's noon."], "the answer is in the panel as always")
        XCTAssertTrue(clipboard.isEmpty, "the clipboard is not written unasked")
        model.copySilentAnswer()
        XCTAssertEqual(clipboard, ["It's noon."], "Copy copies when pressed")
    }

    func testAMutedMacStartsNoStreamedSpeechEither() {
        var sentences: [String] = []
        model.onSpeakSentence = { sentences.append($0) }
        model.outputState = { OutputState(muted: true, volume: 0.5) }
        model.voiceListeningStarted()
        model.voiceTranscribing()
        model.voiceSubmit("what time is it")
        fake.say(.accepted)
        fake.say(.delta("It's noon. It is sunny. "))
        XCTAssertTrue(sentences.isEmpty)
        fake.say(.answer("It's noon. It is sunny."))
        XCTAssertTrue(spoken.isEmpty && sentences.isEmpty)
        XCTAssertEqual(model.silentAnswer?.text, "It's noon. It is sunny.")
        // And with sound on, the same stream does speak its sentences (the control for this test).
        fake.finish()
        model.outputState = { OutputState(muted: false, volume: 0.5) }
        model.voiceListeningStarted()
        model.voiceTranscribing()
        model.voiceSubmit("again")
        fake.say(.accepted)
        fake.say(.delta("It's noon. It is sunny. "))
        XCTAssertFalse(sentences.isEmpty, "unmuted, the sentences are spoken as they arrive")
    }

    func testZeroVolumeIsTheSameAsMuted() {
        model.outputState = { OutputState(muted: false, volume: 0) }
        spokenTurn()
        XCTAssertTrue(spoken.isEmpty)
        XCTAssertEqual(model.silentAnswer?.why, .zeroVolume)
    }

    func testAnAudibleMacSpeaksAsBeforeWithNoNote() {
        model.outputState = { OutputState(muted: false, volume: 0.5) }
        spokenTurn()
        XCTAssertEqual(spoken, ["It's noon."])
        XCTAssertNil(model.silentAnswer)
        model.outputState = nil     // the Mac can't say: speak as before
        spokenTurn("and now?", answer: "Still noon.")
        XCTAssertEqual(spoken.last, "Still noon.")
        XCTAssertNil(model.silentAnswer)
    }

    func testATypedAnswerThatWouldNotBeSpokenGetsNoNoteEvenWhenMuted() {
        model.outputState = { OutputState(muted: true, volume: 0.5) }
        model.composerText = "what time is it"
        model.submit()
        fake.say(.accepted)
        fake.say(.answer("It's noon."))
        XCTAssertTrue(spoken.isEmpty)
        XCTAssertNil(model.silentAnswer, "Read answers aloud is off, so nothing was lost")
    }

    func testTheNoteGoesWithTheNextMessageAndTheClipboardIsNeverTouchedByTheModel() {
        model.outputState = { OutputState(muted: true, volume: 0.5) }
        spokenTurn()
        XCTAssertNotNil(model.silentAnswer)
        fake.finish()
        model.outputState = { OutputState(muted: false, volume: 0.5) }
        spokenTurn("again", answer: "Noon.")
        XCTAssertNil(model.silentAnswer)
        XCTAssertEqual(spoken, ["Noon."])
        XCTAssertTrue(clipboard.isEmpty)
    }

    // MARK: prewarm through the wrappers

    func testPrewarmReachesTheEngineThroughBothWrappers() {
        XCTAssertEqual(fake.prewarms, 0)
        model.prewarm()
        XCTAssertEqual(fake.prewarms, 1)
    }

    // MARK: the quiet check holds the job peek

    func testAJobPeekWaitsWhileTheUserIsOnACall() {
        let id = "5b0f3a52-2c61-4f0e-9d0a-0f5a1c1a7e11"
        fake.job(JobSnapshot(id: id, title: "Headphones", state: .working, line: "Reading a page"))
        fake.job(JobSnapshot(id: id, title: "Headphones", state: .done))
        XCTAssertTrue(model.jobPeek, "news the user hasn't seen opens the peek")
        model.quietNow = { .meetingWindow }
        XCTAssertFalse(model.jobPeek, "but not during a call; the row still has it")
        XCTAssertEqual(model.job?.state, .done)
        model.quietNow = { nil }
        XCTAssertTrue(model.jobPeek)
    }

    func testTheJobsOwnBeatIsNotHeldBecauseTheUserAskedForIt() {
        model.quietNow = { .microphoneInCall }
        fake.job(JobSnapshot(id: "5b0f3a52-2c61-4f0e-9d0a-0f5a1c1a7e11", title: "Headphones", state: .queued))
        XCTAssertTrue(model.jobPeek, "the beat in which Esc cancels the job is part of the user's own request")
    }

    func testTheCueHookStillOnlyFiresWithTheSwitchOn() {
        var cues: [JobCue] = []
        model.onJobCue = { cues.append($0) }
        let id = "5b0f3a52-2c61-4f0e-9d0a-0f5a1c1a7e12"
        UserDefaults.standard.removeObject(forKey: CueSettings.defaultsKey)
        fake.job(JobSnapshot(id: id, title: "x", state: .working))
        fake.job(JobSnapshot(id: id, title: "x", state: .done))
        XCTAssertTrue(cues.isEmpty, "cues are off by default")
    }

    // MARK: the permission ask

    func testAPermissionIsAskedForOnceAndOnlyWhenMissing() {
        model.needPermission(.microphoneToHear, granted: true)
        XCTAssertNil(model.permissionAsk)
        model.needPermission(.microphoneToHear, granted: false)
        XCTAssertEqual(model.permissionAsk, .microphoneToHear)
        model.dismissPermissionAsk()
        model.needPermission(.microphoneToHear, granted: false)
        XCTAssertNil(model.permissionAsk, "once per launch")
        model.needPermission(.screenToLook, granted: false)
        XCTAssertEqual(model.permissionAsk, .screenToLook)
    }
}
