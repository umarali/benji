import XCTest
@testable import BenjiCore

final class KokoroVoicesTests: XCTestCase {
    /// What `voices-v1.0.bin` held when the list was picked (the service's `ready` event), English part.
    let installed = ["af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova",
                     "af_river", "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam",
                     "am_michael", "am_onyx", "am_puck", "am_santa", "bf_alice", "bf_emma", "bm_george"]

    func testSixVoicesThreeFemaleThenThreeMaleHeartFirst() {
        let offered = KokoroVoices.offered
        XCTAssertEqual(offered.count, 6)
        XCTAssertEqual(offered.first?.id, KokoroSettings.defaultVoice)
        XCTAssertEqual(offered.map(\.kind), [.female, .female, .female, .male, .male, .male])
        XCTAssertEqual(Set(offered.map(\.id)).count, 6)
        XCTAssertEqual(Set(offered.map(\.name)).count, 6)
        for voice in offered {
            XCTAssertTrue(installed.contains(voice.id), "\(voice.id) is in the voices file")
            XCTAssertNotEqual(voice.name, voice.id, "friendly names, not ids")
            XCTAssertFalse(voice.character.isEmpty)
            XCTAssertEqual(KokoroSettings.voice(voice.id), voice.id, "a valid voice id")
        }
    }

    func testChoicesFollowTheInstalledFile() {
        XCTAssertEqual(KokoroVoices.choices(installed: [], chosen: "af_heart"), KokoroVoices.offered,
                       "before the service says, all six")
        XCTAssertEqual(KokoroVoices.choices(installed: installed, chosen: "af_heart"), KokoroVoices.offered)
        let fewer = installed.filter { $0 != "af_nicole" }
        XCTAssertEqual(KokoroVoices.choices(installed: fewer, chosen: "af_heart").map(\.id),
                       ["af_heart", "af_bella", "am_michael", "am_fenrir", "am_puck"])
    }

    func testAVoiceSetOutsideTheListStillShowsChosen() {
        let list = KokoroVoices.choices(installed: installed, chosen: "bm_george")
        XCTAssertEqual(list.count, 7)
        XCTAssertEqual(list.last, KokoroVoice(id: "bm_george", name: "George", kind: .male,
                                              character: "Set outside Benji's list."))
        XCTAssertEqual(KokoroVoices.named("bf_emma").kind, .female)
        XCTAssertEqual(KokoroVoices.named("af_bella").name, "Bella")
    }

    func testResolveFallsBackWhenTheFileLacksTheVoice() {
        XCTAssertEqual(KokoroVoices.resolve(setting: nil, installed: installed), "af_heart")
        XCTAssertEqual(KokoroVoices.resolve(setting: "am_puck", installed: installed), "am_puck")
        XCTAssertEqual(KokoroVoices.resolve(setting: "am_nobody", installed: installed), "af_heart")
        XCTAssertEqual(KokoroVoices.resolve(setting: "am_nobody", installed: []), "am_nobody",
                       "before the service says, the setting stands")
        XCTAssertEqual(KokoroVoices.resolve(setting: "../x", installed: []), "af_heart")
    }

    func testSpeedChoices() {
        XCTAssertEqual(KokoroSpeed.nearest(nil), 1.0)
        XCTAssertEqual(KokoroSpeed.nearest(1.12), 1.15)
        XCTAssertEqual(KokoroSpeed.nearest(0.5), 0.9)
        XCTAssertEqual(KokoroSpeed.nearest(2), 1.3)
        XCTAssertEqual(KokoroSpeed.choices.map(KokoroSpeed.label), ["Slower", "Normal", "Faster", "Fastest"])
        XCTAssertTrue(KokoroSpeed.choices.contains(KokoroSpeed.nearest(nil)))
    }

    func testPickerStatus() {
        XCTAssertEqual(VoicePickerStatus.from(engine: .kokoro, installed: true, usable: true), .kokoro)
        XCTAssertEqual(VoicePickerStatus.from(engine: .system, installed: false, usable: false), .notInstalled)
        XCTAssertEqual(VoicePickerStatus.from(engine: .system, installed: true, usable: false), .appleChosen)
        XCTAssertEqual(VoicePickerStatus.from(engine: .kokoro, installed: true, usable: false), .failed)
        XCTAssertNil(VoicePickerStatus.kokoro.caption)
        XCTAssertTrue(VoicePickerStatus.notInstalled.caption?.contains("isn't installed") == true)
        XCTAssertEqual(SettingsSnapshot().voiceStatus, .notInstalled, "the Apple voice until the app says otherwise")
        XCTAssertEqual(SettingsSnapshot().voiceChosen, "af_heart")
    }

    func testPreviewNeverGetsInTheWayOfATurn() {
        func refusal(_ phase: CompanionPhase, mic: Bool = false, speech: Bool = false, headphones: Bool = false) -> VoicePreview.Refusal? {
            VoicePreview.refusal(phase: phase, micOpen: mic, speechActive: speech, headphones: headphones)
        }
        XCTAssertNil(refusal(.idle))
        XCTAssertNil(refusal(.error))
        for phase in [CompanionPhase.thinking, .transcribing, .speaking, .awaitingApproval] {
            XCTAssertEqual(refusal(phase, headphones: true), .busy)
        }
        XCTAssertEqual(refusal(.idle, speech: true), .busy, "an answer is still queued or playing")
        XCTAssertEqual(refusal(.listening, mic: true), .listening, "speakers: the mic would hear it")
        XCTAssertEqual(refusal(.idle, mic: true), .listening)
        XCTAssertNil(refusal(.listening, mic: true, headphones: true))
        XCTAssertTrue(VoicePreview.sentence(for: KokoroVoices.offered[1]).contains("Bella"))
    }
}
