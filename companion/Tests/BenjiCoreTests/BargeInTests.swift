import XCTest
@testable import BenjiCore

/// Talking over Benji to interrupt it: the setting, the echo guard, headphones, and turn-taking.
final class BargeInTests: XCTestCase {
    func testTheSettingDefaultsToHeadphones() {
        XCTAssertEqual(BargeInMode.from(nil), .headphones)
        XCTAssertEqual(BargeInMode.from("always"), .always)
        XCTAssertEqual(BargeInMode.from("off"), .off)
        XCTAssertEqual(BargeInMode.from("nonsense"), .headphones)
        XCTAssertEqual(BargeInMode.allCases.map(\.title), ["Off", "Headphones", "Always"])
    }

    func testWhereTheMicMayListenOverSpeech() {
        XCTAssertFalse(BargeInMode.off.allows(.headphones))
        XCTAssertTrue(BargeInMode.headphones.allows(.headphones))
        XCTAssertFalse(BargeInMode.headphones.allows(.speakers))
        XCTAssertFalse(BargeInMode.headphones.allows(.unknown), "an unknown output may be speakers")
        XCTAssertTrue(BargeInMode.always.allows(.speakers))
        XCTAssertTrue(BargeInMode.always.needsEchoCancellation(.speakers))
        XCTAssertTrue(BargeInMode.always.needsEchoCancellation(.unknown))
        XCTAssertFalse(BargeInMode.always.needsEchoCancellation(.headphones))
        XCTAssertFalse(BargeInMode.headphones.needsEchoCancellation(.headphones))
    }

    func testAirPodsAndOtherNamedHeadphonesCount() {
        XCTAssertEqual(OutputRoute.classify(builtIn: false, dataSource: nil, name: "Umar’s AirPods Pro"), .headphones)
        XCTAssertEqual(OutputRoute.classify(builtIn: false, dataSource: nil, name: "WH-1000XM5"), .headphones)
        XCTAssertEqual(OutputRoute.classify(builtIn: false, dataSource: nil, name: "Galaxy Buds2"), .headphones)
        XCTAssertEqual(OutputRoute.classify(builtIn: false, dataSource: nil, name: "LG HDR 4K"), .unknown)
        XCTAssertEqual(OutputRoute.classify(builtIn: false, dataSource: nil, name: nil), .unknown)
        XCTAssertEqual(OutputRoute.classify(builtIn: true, dataSource: OutputRoute.builtInHeadphoneSource, name: "x"),
                       .headphones)
        XCTAssertEqual(OutputRoute.classify(builtIn: true, dataSource: OutputRoute.builtInSpeakerSource, name: "AirPods"),
                       .speakers, "the built-in output says which it is")
    }

    let answer = "The Share button is at the top right of the toolbar, next to the search field."

    func testBenjisOwnWordsAreEcho() {
        XCTAssertFalse(EchoGuard.interrupts(heard: "the share button is at the top right", spoken: answer))
        XCTAssertEqual(EchoGuard.userWords(heard: "the share buton is at the tool bar", spoken: answer), ["tool", "bar"],
                       "one letter off is still echo; words Benji never said are not")
        XCTAssertFalse(EchoGuard.interrupts(heard: "the share buton is next to the serch field", spoken: answer))
        XCTAssertEqual(EchoGuard.userWords(heard: "um the toolbar uh", spoken: answer), [])
    }

    func testTheUsersWordsInterrupt() {
        XCTAssertTrue(EchoGuard.interrupts(heard: "the share button what about mail", spoken: answer))
        XCTAssertEqual(EchoGuard.userWords(heard: "the share button what about mail", spoken: answer),
                       ["what", "about", "mail"])
        XCTAssertTrue(EchoGuard.interrupts(heard: "the share stop", spoken: answer), "one interrupt word")
        XCTAssertTrue(EchoGuard.interrupts(heard: "Benji", spoken: answer), "its name")
        XCTAssertFalse(EchoGuard.interrupts(heard: "mail", spoken: answer), "one ordinary word is not enough")
    }

    func testAnInterruptWordBenjiSaidItselfIsEcho() {
        XCTAssertFalse(EchoGuard.interrupts(heard: "stop", spoken: "Press Stop to end the recording."))
    }

    func testOneEditApart() {
        XCTAssertTrue(EchoGuard.oneEditApart("button", "buttons"))
        XCTAssertFalse(EchoGuard.oneEditApart("share", "shear"), "two letters changed")
        XCTAssertTrue(EchoGuard.oneEditApart("toolbar", "tolbar"))
        XCTAssertTrue(EchoGuard.oneEditApart("field", "fields"))
        XCTAssertFalse(EchoGuard.oneEditApart("mail", "nails"))
    }

    // Turn-taking.

    func testWithoutBargeInTheMicStaysShutWhileBenjiSpeaks() {
        XCTAssertFalse(HandsFreeSnapshot(phase: .speaking).mayListen)
        XCTAssertFalse(HandsFreeSnapshot(phase: .idle, speechPending: true).mayListen)
        XCTAssertTrue(HandsFreeSnapshot(phase: .idle).mayListen)
    }

    func testWithBargeInTheMicMayListenOverSpeechButNeverOverWorkOrCards() {
        XCTAssertTrue(HandsFreeSnapshot(phase: .speaking, bargeIn: true).mayListen)
        XCTAssertTrue(HandsFreeSnapshot(phase: .idle, speechPending: true, bargeIn: true).mayListen)
        XCTAssertTrue(HandsFreeSnapshot(phase: .listening, speechPending: true, bargeIn: true).mayListen)
        XCTAssertFalse(HandsFreeSnapshot(phase: .thinking, bargeIn: true).mayListen)
        XCTAssertFalse(HandsFreeSnapshot(phase: .speaking, approvalPending: true, bargeIn: true).mayListen)
        XCTAssertFalse(HandsFreeSnapshot(phase: .speaking, screenCardPending: true, bargeIn: true).mayListen)
        XCTAssertTrue(HandsFreeSnapshot(phase: .speaking, bargeIn: true).overSpeech)
    }

    func testTheConversationOpensTheMicOverTheAnswerAndKeepsItOpenAfter() {
        var s = HandsFreeSession(settings: HandsFreeSettings())
        _ = s.update(HandsFreeSnapshot(phase: .idle), at: 0)
        XCTAssertEqual(s.start(at: 0), [.openMic])
        _ = s.utteranceEnding()
        XCTAssertEqual(s.utteranceFinished("what's the weather", at: 1), [.submit("what's the weather")])
        XCTAssertEqual(s.update(HandsFreeSnapshot(phase: .thinking, bargeIn: true), at: 1.1), [])
        // The answer is handed to the voice: the mic opens after the resume delay, over the speech.
        XCTAssertEqual(s.update(HandsFreeSnapshot(phase: .idle, speechPending: true, bargeIn: true), at: 3), [])
        XCTAssertEqual(s.tick(at: 3 + HandsFreeSettings.resumeDelay), [.openMic])
        XCTAssertEqual(s.update(HandsFreeSnapshot(phase: .speaking, speechPending: true, bargeIn: true), at: 4), [])
        // The answer ends: the same mic carries on.
        XCTAssertEqual(s.update(HandsFreeSnapshot(phase: .idle, bargeIn: true), at: 9), [])
        XCTAssertTrue(s.micOpen)
    }

    func testTurningBargeInOffMidAnswerClosesTheMic() {
        var s = HandsFreeSession(settings: HandsFreeSettings())
        _ = s.update(HandsFreeSnapshot(phase: .speaking, bargeIn: true), at: 0)
        XCTAssertEqual(s.start(at: 0), [.openMic])
        XCTAssertEqual(s.update(HandsFreeSnapshot(phase: .speaking, bargeIn: false), at: 1), [.closeMic],
                       "headphones unplugged: the speakers would be heard")
    }

    func testThePanelSaysTheMicIsOnOverTheAnswer() {
        var state = CompanionState()
        reduce(&state, .speakingStarted)
        XCTAssertEqual(NotchStatusInfo.make(state).tint, .mint)
        reduce(&state, .micOpenedOverSpeech)
        XCTAssertEqual(state.phase, .speaking, "Benji talks on")
        let info = NotchStatusInfo.make(state)
        XCTAssertEqual(info.word, "Speaking")
        XCTAssertEqual(info.tint, .listening)
        XCTAssertEqual(info.symbol, "waveform.and.mic")
    }
}
