import AppKit
import XCTest
@testable import BenjiApp
import BenjiCore

/// D-164 through the real CompanionModel: an answer about the screen speaks its first sentence
/// while the rest is being written, its marks say the voice went first, and the setting puts the
/// old way back.
final class CompanionModelEarlySpeechTests: XCTestCase {
    var backend: FakeBackend!
    var model: CompanionModel!
    var sentences: [String] = []
    var whole: [String] = []
    var plans: [PointingPlan] = []
    var saved: Any?

    override func setUp() {
        saved = UserDefaults.standard.object(forKey: FastPath.earlyScreenSpeechKey)
        UserDefaults.standard.removeObject(forKey: FastPath.earlyScreenSpeechKey)
        backend = FakeBackend()
        let suite = UserDefaults(suiteName: "benji-early-speech-tests-\(UUID().uuidString)")!
        model = CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: suite))
        model.setScreenMode(.on)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("benji-screen-test-early-\(UUID().uuidString).jpg")
        FileManager.default.createFile(atPath: url.path, contents: Data([1]))
        let shot = CapturedScreen(url: url, pixelSize: CGSize(width: 1330, height: 864), thumbnail: NSImage(),
                                  screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        model.captureScreen = { done in done(.success(shot)) }
        sentences = []; whole = []; plans = []
        model.onSpeak = { [unowned self] in self.whole.append($0) }
        model.onSpeakSentence = { [unowned self] in self.sentences.append($0) }
        model.onSpeakStreamEnd = { _ in }
        model.onPoint = { [unowned self] in self.plans.append($0) }
    }

    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: FastPath.earlyScreenSpeechKey) }
        else { UserDefaults.standard.removeObject(forKey: FastPath.earlyScreenSpeechKey) }
    }

    private func ask(_ text: String) {
        model.voiceListeningStarted()
        model.voiceTranscribing()
        model.voiceSubmit(text)
    }

    private let target = PointingTarget(shape: .point(x: 400, y: 300), label: "Save")

    func testAScreenAnswerSpeaksWhileItIsWritten() throws {
        ask("where do I save?")
        XCTAssertEqual(backend.starts.count, 1)
        XCTAssertNotNil(model.currentScreenshotGeometry, "the turn carries the screenshot")
        backend.say(.accepted)
        backend.say(.delta("Click Save at the top right. "))
        XCTAssertEqual(sentences, ["Click Save at the top right."], "spoken before the answer is whole")
        backend.say(.pointedAnswer(text: "Click Save at the top right. It keeps your changes.", targets: [target]))
        let plan = try XCTUnwrap(plans.last)
        XCTAssertTrue(plan.spokenFirst, "the overlay is told the voice went first")
        XCTAssertTrue(whole.isEmpty, "nothing is said twice")
    }

    func testTheSettingPutsTheOldWayBack() throws {
        UserDefaults.standard.set(false, forKey: FastPath.earlyScreenSpeechKey)
        ask("where do I save?")
        backend.say(.accepted)
        backend.say(.delta("Click Save at the top right. "))
        XCTAssertTrue(sentences.isEmpty, "the answer waits to be whole")
        backend.say(.pointedAnswer(text: "Click Save at the top right.", targets: [target]))
        XCTAssertEqual(whole, ["Click Save at the top right."])
        XCTAssertFalse(try XCTUnwrap(plans.last).spokenFirst)
    }

    // D-173 meets D-164: a muted Mac and an answer about the screen.

    func testAMutedMacStopsEarlySpeechForAScreenAnswerButTheMarksAndTheTextStay() throws {
        model.outputState = { OutputState(muted: true, volume: 0.5) }
        ask("where do I save?")
        backend.say(.accepted)
        backend.say(.delta("Click Save at the top right. "))
        XCTAssertTrue(sentences.isEmpty, "nothing starts speaking into a muted Mac")
        backend.say(.pointedAnswer(text: "Click Save at the top right. It keeps your changes.", targets: [target]))
        XCTAssertTrue(sentences.isEmpty && whole.isEmpty)
        let plan = try XCTUnwrap(plans.last, "the pointing still shows")
        XCTAssertFalse(plan.spokenFirst)
        XCTAssertEqual(model.silentAnswer?.text, "Click Save at the top right. It keeps your changes.")
        XCTAssertEqual(model.silentAnswer?.why, .muted)
    }

    func testWithSoundOnTheEarlySpeechStillWorksAndLeavesNoNote() throws {
        model.outputState = { OutputState(muted: false, volume: 0.5) }
        ask("where do I save?")
        backend.say(.accepted)
        backend.say(.delta("Click Save at the top right. "))
        XCTAssertEqual(sentences, ["Click Save at the top right."])
        backend.say(.pointedAnswer(text: "Click Save at the top right. It keeps your changes.", targets: [target]))
        XCTAssertTrue(try XCTUnwrap(plans.last).spokenFirst)
        XCTAssertNil(model.silentAnswer)
    }

    func testAMutedMacWithEarlySpeechOffGivesTheSameTextNote() {
        UserDefaults.standard.set(false, forKey: FastPath.earlyScreenSpeechKey)
        model.outputState = { OutputState(muted: false, volume: 0) }
        ask("where do I save?")
        backend.say(.accepted)
        backend.say(.pointedAnswer(text: "Click Save.", targets: [target]))
        XCTAssertTrue(whole.isEmpty && sentences.isEmpty)
        XCTAssertEqual(model.silentAnswer?.why, .zeroVolume)
    }
}

