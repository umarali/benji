import XCTest
@testable import BenjiCore

final class VoiceSupportTests: XCTestCase {
    func testSpeechTextStripsMarkdown() {
        let md = "## Result\n- **Two** files: `notes.md` and [the spec](https://x.y/spec)"
        let plain = SpeechText.plain(md)
        XCTAssertFalse(plain.contains("*"))
        XCTAssertFalse(plain.contains("`"))
        XCTAssertFalse(plain.contains("#"))
        XCTAssertFalse(plain.contains("https://"))
        XCTAssertTrue(plain.contains("the spec"))
        XCTAssertTrue(plain.contains("Two files"))
    }

    func testSpeechTextDropsEmoji() {
        let plain = SpeechText.plain("Done! 😊 Your file is ready ✅. Call 1-800 #3 now ❤️ 👍🏽 🇵🇰 ok.")
        XCTAssertEqual(plain, "Done! Your file is ready. Call 1-800 #3 now ok.")
        XCTAssertEqual(SpeechText.plain("Step 1: open it * 2"), "Step 1: open it 2")
    }

    func testSpeechTextNeverReadsFencedBlocks() {
        let reply = "I fixed it.\n\n```figure\n{\"title\":\"An airliner\",\"parts\":[{\"kind\":\"box\"}]}\n```\nTake a look."
        XCTAssertEqual(SpeechText.plain(reply), "I fixed it.\n\nTake a look.")
        // Cut off before the closing fence: the rest of the text is the block.
        XCTAssertEqual(SpeechText.plain("Done.\n```figure\n{\"parts\":[{\"na"), "Done.")
        XCTAssertEqual(SpeechText.plain("```figure\n{\"parts\":[]}\n```"), "")
        // Backticks inside a sentence are still just read as words.
        XCTAssertEqual(SpeechText.plain("Run ```ls``` now"), "Run ls now")
    }

    func testSpeechTextKeepsSnakeCase() {
        XCTAssertEqual(SpeechText.plain("ran list_dir"), "ran list_dir")
    }

    func testAccidentalTapIsDiscarded() {
        XCTAssertTrue(TalkGesturePolicy.isTap(holdSeconds: 0.1))
        XCTAssertFalse(TalkGesturePolicy.isTap(holdSeconds: 1.0))
    }

    func testTranscriberSelection() {
        XCTAssertEqual(TranscriberKind.from(setting: nil), .onDevice)
        XCTAssertEqual(TranscriberKind.from(setting: "pal"), .engine)
        XCTAssertEqual(TranscriberKind.from(setting: "Cloud"), .engine)
        XCTAssertEqual(TranscriberKind.from(setting: "nonsense"), .onDevice)
    }

    func testSpeakingSurvivesBackendExit() {
        var s = CompanionState()
        for e: CompanionEvent in [.transcribed("hi"), .assistantAnswer("hello"),
                                   .speakingStarted, .backendFinished(0)] {
            reduce(&s, e)
        }
        XCTAssertEqual(s.phase, .speaking)        // process exit must not cut speech state
        reduce(&s, .speakingFinished)
        XCTAssertEqual(s.phase, .idle)
    }

    func testErrorWhileListeningTurnsMicOff() {
        var s = CompanionState()
        reduce(&s, .micStarted)
        reduce(&s, .backendError("Microphone access is off"))
        XCTAssertFalse(s.micActive)
        XCTAssertEqual(s.phase, .error)
    }

    // MARK: voice choice

    private let voices = [
        VoiceCandidate(id: "samantha.compact", language: "en-US", quality: 1),
        VoiceCandidate(id: "ava.enhanced", language: "en-US", quality: 2),
        VoiceCandidate(id: "serena.premium", language: "en-GB", quality: 3),
        VoiceCandidate(id: "zoe.premium", language: "en-US", quality: 3),
        VoiceCandidate(id: "bells", language: "en-US", quality: 3, isNovelty: true),
        VoiceCandidate(id: "anna.premium", language: "de-DE", quality: 3),
    ]

    func testVoicePrefersHighestQualityThenExactLocale() {
        XCTAssertEqual(VoiceChoice.best(from: voices, language: "en-US", preferredID: nil), "zoe.premium")
        XCTAssertEqual(VoiceChoice.best(from: voices, language: "en-GB", preferredID: nil), "serena.premium")
    }

    func testVoiceFallsBackToSystemDefaultWhenOnlyBasicVoices() {
        let basic = [VoiceCandidate(id: "samantha.compact", language: "en-US", quality: 1)]
        XCTAssertNil(VoiceChoice.best(from: basic, language: "en-US", preferredID: nil))
        XCTAssertNil(VoiceChoice.best(from: voices, language: "fr-FR", preferredID: nil))
    }

    func testVoiceSettingWinsOnlyWhenInstalled() {
        XCTAssertEqual(VoiceChoice.best(from: voices, language: "en-US", preferredID: "samantha.compact"), "samantha.compact")
        XCTAssertEqual(VoiceChoice.best(from: voices, language: "en-US", preferredID: "missing"), "zoe.premium")
    }

    // MARK: modifier tap

    func testCleanModifierTap() {
        var d = ModifierTapDetector()
        XCTAssertFalse(d.modifiersChanged(targetDown: true, othersDown: false, at: 0))
        XCTAssertTrue(d.modifiersChanged(targetDown: false, othersDown: false, at: 0.2))
    }

    func testLongModifierHoldIsNotATap() {
        var d = ModifierTapDetector()
        _ = d.modifiersChanged(targetDown: true, othersDown: false, at: 0)
        XCTAssertFalse(d.modifiersChanged(targetDown: false, othersDown: false, at: 0.8))
    }

    func testModifierChordsAreNotTaps() {
        var d = ModifierTapDetector()
        _ = d.modifiersChanged(targetDown: true, othersDown: false, at: 0)
        d.keyPressed()   // ⌥E
        XCTAssertFalse(d.modifiersChanged(targetDown: false, othersDown: false, at: 0.2))

        _ = d.modifiersChanged(targetDown: true, othersDown: false, at: 1)
        _ = d.modifiersChanged(targetDown: true, othersDown: true, at: 1.1)    // ⇧ added
        _ = d.modifiersChanged(targetDown: true, othersDown: false, at: 1.15)  // ⇧ released
        XCTAssertFalse(d.modifiersChanged(targetDown: false, othersDown: false, at: 1.2))

        _ = d.modifiersChanged(targetDown: true, othersDown: true, at: 2)      // ⌘ already held
        XCTAssertFalse(d.modifiersChanged(targetDown: false, othersDown: true, at: 2.1))
    }

    func testTapAfterChordStillWorks() {
        var d = ModifierTapDetector()
        _ = d.modifiersChanged(targetDown: true, othersDown: false, at: 0)
        d.keyPressed()
        _ = d.modifiersChanged(targetDown: false, othersDown: false, at: 0.1)
        _ = d.modifiersChanged(targetDown: true, othersDown: false, at: 1)
        XCTAssertTrue(d.modifiersChanged(targetDown: false, othersDown: false, at: 1.1))
    }

    // MARK: modifier hold

    func testCleanHoldBeginsAndEndsOnRelease() {
        var d = ModifierTapDetector()
        XCTAssertNil(d.change(targetDown: true, othersDown: false, at: 0))
        XCTAssertNil(d.holdCheck(at: 0.1))   // too early
        XCTAssertEqual(d.holdCheck(at: ModifierTapDetector.holdDelay), .holdBegan)
        XCTAssertNil(d.holdCheck(at: 0.5))   // reported once
        XCTAssertEqual(d.change(targetDown: false, othersDown: false, at: 2), .holdEnded)
        XCTAssertNil(d.holdCheck(at: 2.5))   // nothing held any more
    }

    func testQuickTapReportsTapAndNoHold() {
        var d = ModifierTapDetector()
        _ = d.change(targetDown: true, othersDown: false, at: 0)
        XCTAssertEqual(d.change(targetDown: false, othersDown: false, at: 0.15), .tap)
        XCTAssertNil(d.holdCheck(at: ModifierTapDetector.holdDelay))   // the timer from that press
    }

    func testStaleHoldCheckFromEarlierPressIsIgnored() {
        var d = ModifierTapDetector()
        _ = d.change(targetDown: true, othersDown: false, at: 0)
        _ = d.change(targetDown: false, othersDown: false, at: 0.1)
        _ = d.change(targetDown: true, othersDown: false, at: 0.2)
        XCTAssertNil(d.holdCheck(at: 0.3))   // the first press's timer; the second is 0.1 s old
        XCTAssertEqual(d.holdCheck(at: 0.5), .holdBegan)
    }

    func testChordsNeverBeginAHold() {
        var d = ModifierTapDetector()
        _ = d.change(targetDown: true, othersDown: false, at: 0)
        d.keyPressed()   // ⌥E
        XCTAssertNil(d.holdCheck(at: 1))
        XCTAssertNil(d.change(targetDown: false, othersDown: false, at: 1.5))

        _ = d.change(targetDown: true, othersDown: false, at: 2)
        _ = d.change(targetDown: true, othersDown: true, at: 2.1)   // ⇧ added
        XCTAssertNil(d.holdCheck(at: 2.4))
        XCTAssertNil(d.change(targetDown: false, othersDown: false, at: 3))

        _ = d.change(targetDown: true, othersDown: true, at: 4)     // ⌘ already held
        XCTAssertNil(d.holdCheck(at: 5))
        XCTAssertNil(d.change(targetDown: false, othersDown: true, at: 5.1))
    }

    func testHoldThatBeganStaysAHoldThroughAChord() {
        var d = ModifierTapDetector()
        _ = d.change(targetDown: true, othersDown: false, at: 0)
        XCTAssertEqual(d.holdCheck(at: 0.4), .holdBegan)
        d.keyPressed()
        XCTAssertNil(d.change(targetDown: true, othersDown: true, at: 0.6))
        XCTAssertEqual(d.change(targetDown: false, othersDown: true, at: 1), .holdEnded)
    }

    func testResetEndsAHoldInProgress() {
        var d = ModifierTapDetector()
        XCTAssertNil(d.reset())
        _ = d.change(targetDown: true, othersDown: false, at: 0)
        XCTAssertEqual(d.holdCheck(at: 0.4), .holdBegan)
        XCTAssertEqual(d.reset(), .holdEnded)
        XCTAssertNil(d.change(targetDown: false, othersDown: false, at: 1))   // the release after it
        _ = d.change(targetDown: true, othersDown: false, at: 2)
        XCTAssertEqual(d.change(targetDown: false, othersDown: false, at: 2.1), .tap)
    }

    // MARK: mic level

    func testMicLevelScale() {
        XCTAssertEqual(MicLevel.normalized(rms: 0), 0)
        XCTAssertEqual(MicLevel.normalized(rms: 0.001), 0, accuracy: 0.001)   // -60 dB, below the floor
        XCTAssertEqual(MicLevel.normalized(rms: 1), 1, accuracy: 0.001)       // 0 dB
        XCTAssertEqual(MicLevel.normalized(rms: 0.0316), 0.4, accuracy: 0.01) // -30 dB
    }
}
