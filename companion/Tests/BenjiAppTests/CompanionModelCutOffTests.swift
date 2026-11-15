import XCTest
@testable import BenjiApp
import BenjiCore

/// Cutting Benji off with a fake engine: the conversation keeps only what was said aloud,
/// whether the answer was still being written or had arrived.
final class CompanionModelCutOffTests: XCTestCase {
    var backend: FakeBackend!
    var model: CompanionModel!
    var sentences: [String] = []

    override func setUp() {
        backend = FakeBackend()
        let suite = UserDefaults(suiteName: "benji-app-tests-\(UUID().uuidString)")!
        suite.set(ScreenMode.off.rawValue, forKey: ScreenModeState.defaultsKey)
        model = CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: suite))
        sentences = []
        model.onSpeak = { [unowned self] in self.sentences.append($0) }
        model.onSpeakSentence = { [unowned self] in self.sentences.append($0) }
        model.onSpeakStreamEnd = { _ in }
    }

    private func ask(_ text: String) {
        model.voiceListeningStarted()
        model.voiceTranscribing()
        model.voiceSubmit(text)
    }

    private var lines: [(TranscriptRole, String)] { model.state.lines.map { ($0.role, $0.text) } }

    func testCutInWhileTheAnswerIsStillBeingWrittenStopsTheRunAndKeepsWhatWasSaid() {
        ask("how do planes fly?")
        let run = backend.lastRun
        backend.say(.accepted)
        backend.say(.delta("Planes fly because the wings push air down. The engines "))
        XCTAssertEqual(sentences, ["Planes fly because the wings push air down."])
        model.voiceSpeaking(true)

        model.speechCutOff(heard: "Planes fly because the")
        XCTAssertEqual(backend.cancels, 1, "a backend with no cut-off of its own stops the running turn")
        XCTAssertEqual(model.conversationMemory.exchanges.last,
                       .init(user: "how do planes fly?", assistant: "Planes fly because the … \(CutOffReply.marker)"))
        XCTAssertEqual(lines.map(\.1), ["how do planes fly?", "Planes fly because the —", CutOffReply.notice])
        XCTAssertNil(model.state.retryableTurn, "an answer was heard: nothing to retry")
        model.voiceSpeaking(false)
        XCTAssertEqual(model.state.phase, .idle)

        // The stopped run's late words never speak or show.
        backend.say(.delta("push it forward."), run: run)
        backend.say(.answer("Planes fly because the wings push air down. The engines push it forward."), run: run)
        backend.finish(run: run)
        XCTAssertEqual(sentences.count, 1)
        XCTAssertEqual(model.state.lines.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(model.conversationMemory.exchanges.count, 1)
    }

    func testCutInAfterTheAnswerArrivedShortensIt() {
        ask("how do planes fly?")
        backend.say(.answer("The wings push air down. That pushes the wings up. Engines move it forward."))
        backend.finish()
        model.voiceSpeaking(true)
        model.speechCutOff(heard: "The wings push air down.")
        XCTAssertEqual(backend.cancels, 0)
        XCTAssertEqual(model.conversationMemory.exchanges.last?.assistant,
                       "The wings push air down. … \(CutOffReply.marker)")
        XCTAssertEqual(lines.map(\.1), ["how do planes fly?", "The wings push air down. —", CutOffReply.notice])
        model.speechCutOff(heard: "The")
        XCTAssertEqual(lines.count, 3, "an answer is cut off once")
    }

    func testCutInBeforeAnyWordWasSaid() {
        ask("how do planes fly?")
        backend.say(.answer("The wings push air down."))
        backend.finish()
        model.speechCutOff(heard: "")
        XCTAssertEqual(model.conversationMemory.exchanges.last?.assistant, CutOffReply.unheard)
        XCTAssertEqual(lines.map(\.1), ["how do planes fly?", "The wings push air down.", CutOffReply.notice])
    }

    func testAnAnswerHeardToTheEndIsLeftAlone() {
        ask("hi")
        backend.say(.answer("Hello there."))
        backend.finish()
        model.speechCutOff(heard: "Hello there.")
        XCTAssertEqual(model.conversationMemory.exchanges.last?.assistant, "Hello there.")
        XCTAssertEqual(lines.count, 2)
    }

    func testATypedAnswerThatWasntReadAloudIsNeverCut() {
        model.setReadAloud(false)
        model.composerText = "hi"
        model.submit()
        backend.say(.answer("Hello there, this is long."))
        backend.finish()
        model.speechCutOff(heard: "Hello")
        XCTAssertEqual(model.conversationMemory.exchanges.last?.assistant, "Hello there, this is long.")
    }

    func testTheLastReplyIsBenjisOnlyUntilTheUserSpeaks() {
        XCTAssertNil(model.lastReply)
        ask("quiz me on capitals")
        backend.say(.answer("What is the capital of Peru?"))
        backend.finish()
        XCTAssertEqual(model.lastReply, "What is the capital of Peru?")
        ask("Lima")
        XCTAssertNil(model.lastReply)
    }
}
