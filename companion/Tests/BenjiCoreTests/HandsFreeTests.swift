import XCTest
@testable import BenjiCore

final class HandsFreeSettingsTests: XCTestCase {
    func testDefaults() {
        let s = HandsFreeSettings.from(handsFree: nil, endSilence: nil, idleTimeout: nil)
        XCTAssertTrue(s.startsOnTap)
        XCTAssertEqual(s.endSilence, 1.0)
        XCTAssertEqual(s.idleTimeout, 120)   // D-134: two quiet minutes
        XCTAssertTrue(HandsFreeSettings.idleTimeoutChoices.contains(120))
        XCTAssertTrue(HandsFreeSettings.idleTimeoutChoices.contains(300), "a saved 5 minutes is still a choice")
    }

    func testParsesDefaultsValues() {
        let s = HandsFreeSettings.from(handsFree: "off", endSilence: NSNumber(value: 1.4), idleTimeout: "90")
        XCTAssertFalse(s.startsOnTap)
        XCTAssertEqual(s.endSilence, 1.4)
        XCTAssertEqual(s.idleTimeout, 90)
        XCTAssertFalse(HandsFreeSettings.from(handsFree: false, endSilence: nil, idleTimeout: nil).startsOnTap)
        XCTAssertFalse(HandsFreeSettings.from(handsFree: NSNumber(value: 0), endSilence: nil, idleTimeout: nil).startsOnTap)
    }

    func testClampsAndIgnoresJunk() {
        let s = HandsFreeSettings.from(handsFree: "maybe", endSilence: 0.05, idleTimeout: 100_000)
        XCTAssertTrue(s.startsOnTap)
        XCTAssertEqual(s.endSilence, 0.5)
        XCTAssertEqual(s.idleTimeout, 3600)
        XCTAssertEqual(HandsFreeSettings.from(handsFree: nil, endSilence: "soon", idleTimeout: 2).endSilence, 1.0)
        XCTAssertEqual(HandsFreeSettings.from(handsFree: nil, endSilence: nil, idleTimeout: 2).idleTimeout, 10)
        XCTAssertEqual(HandsFreeSettings(endSilence: .nan).endSilence, 0.5)
    }
}

final class SpokenNoiseTests: XCTestCase {
    func testEmptyAndHesitationsAreNoise() {
        for text in ["", "   ", "Um.", "uh, hmm", "Mm-hmm", "a", "I", "Hm?", "Oh"] {
            XCTAssertFalse(SpokenNoise.isMeaningful(text), text)
        }
    }

    func testRealWordsCount() {
        for text in ["Yes.", "OK", "no", "Open Mail", "um, open Mail", "7", "Why?"] {
            XCTAssertTrue(SpokenNoise.isMeaningful(text), text)
        }
    }
}

final class StopPhraseTests: XCTestCase {
    func testWholeUtteranceStops() {
        for text in ["That's all.", "that's all", "Stop listening.", "Thanks, Benji!", "Thank you Benji",
                     "Okay, that's all, thanks Benji.", "stop listening please", "That's all for now.",
                     "Thanks Benjy", "Bye Benji", "I'm done.", "We're done, thanks.", "End the conversation",
                     "That’s all", "Alright, thank you, Benji. That will be all."] {
            XCTAssertEqual(StopPhrases.match(text), .stopOnly, text)
        }
    }

    func testRequestThenStopSendsTheRequest() {
        XCTAssertEqual(StopPhrases.match("Open the downloads folder, that's all."),
                       .trailing(request: "Open the downloads folder"))
        XCTAssertEqual(StopPhrases.match("Draft a reply to Sam thanks Benji"),
                       .trailing(request: "Draft a reply to Sam"))
        XCTAssertEqual(StopPhrases.match("Read me the first line. Okay, stop listening."),
                       .trailing(request: "Read me the first line. Okay"))
    }

    func testOrdinarySentencesAreNotStops() {
        for text in ["Thanks Benji, now open Mail.", "That's all for the intro, now write the conclusion.",
                     "Check if that's all", "Tell me when we're done", "Let me know if I'm done",
                     "What does stop listening mean in this app?", "Is that all?", "Thanks", "Thank you",
                     "Open all", "Can you stop the music"] {
            XCTAssertEqual(StopPhrases.match(text), .none, text)
        }
    }

    func testMiddleOfUtteranceNeverStops() {
        XCTAssertEqual(StopPhrases.match("Say that's all to the team and then open Slack"), .none)
        XCTAssertEqual(StopPhrases.match("Write stop listening on a sticky note"), .none)
    }
}

final class UtteranceEndpointerTests: XCTestCase {
    func testNeverEndsBeforeWords() {
        var e = UtteranceEndpointer(endSilence: 1.0)
        for i in 0..<100 { e.level(0.6, at: Double(i) * 0.05) }   // a loud room, nobody talking
        XCTAssertFalse(e.shouldEnd(at: 30))
        XCTAssertFalse(e.hasSpeech)
    }

    func testEndsAfterSilence() {
        var e = UtteranceEndpointer(endSilence: 1.0)
        e.transcript("Open", at: 0.5)
        e.transcript("Open Mail", at: 0.9)
        XCTAssertFalse(e.shouldEnd(at: 1.8))
        XCTAssertTrue(e.shouldEnd(at: 1.9))
    }

    func testNewWordsRestartTheSilence() {
        var e = UtteranceEndpointer(endSilence: 1.0)
        e.transcript("Open", at: 0)
        e.transcript("Open Mail and", at: 0.8)
        e.transcript("Open Mail and Safari", at: 1.6)
        XCTAssertFalse(e.shouldEnd(at: 2.5))
        XCTAssertTrue(e.shouldEnd(at: 2.6))
    }

    func testSameTranscriptIsNotActivity() {
        var e = UtteranceEndpointer(endSilence: 1.0)
        e.transcript("Open Mail", at: 0)
        e.transcript("Open Mail ", at: 0.9)
        XCTAssertTrue(e.shouldEnd(at: 1.0))
    }

    func testContinuationWordWaitsLonger() {
        var e = UtteranceEndpointer(endSilence: 1.0)
        e.transcript("Find the file I saved yesterday and", at: 0)
        XCTAssertEqual(e.silenceNeeded, 2.2, accuracy: 1e-9)
        XCTAssertFalse(e.shouldEnd(at: 2.1))
        XCTAssertTrue(e.shouldEnd(at: 2.2))
        e.transcript("Find the file I saved yesterday, um", at: 3)
        XCTAssertEqual(e.silenceNeeded, 2.2, accuracy: 1e-9)
        e.transcript("Find the file I saved yesterday,", at: 3)
        XCTAssertEqual(e.silenceNeeded, 2.2, accuracy: 1e-9)
        e.transcript("Find the file I saved yesterday.", at: 3)
        XCTAssertEqual(e.silenceNeeded, 1.0, accuracy: 1e-9)
    }

    func testContinuationNeverPastTheMaximum() {
        var e = UtteranceEndpointer(endSilence: 3.0)
        e.transcript("Open the", at: 0)
        XCTAssertEqual(e.silenceNeeded, HandsFreeSettings.maximumSilence, accuracy: 1e-9)
    }

    func testVoiceWithoutNewWordsKeepsTheSentenceOpen() {
        var e = UtteranceEndpointer(endSilence: 1.0)
        for i in 0..<20 { e.level(0.1, at: Double(i) * 0.05) }   // quiet room settles the floor
        e.transcript("Rename the photos from", at: 1.0)
        // A long "ummm" the recogniser doesn't write down: voice, no words.
        var t = 1.0
        while t < 3.0 { e.level(0.55, at: t); t += 0.05 }
        XCTAssertFalse(e.shouldEnd(at: 3.0))
        // Then quiet.
        while t < 6.0 { e.level(0.1, at: t); t += 0.05 }
        XCTAssertTrue(e.shouldEnd(at: 6.0))
    }

    func testSteadyNoiseStopsCountingAsVoice() {
        var e = UtteranceEndpointer(endSilence: 1.0)
        e.transcript("Open Mail", at: 0)
        // A fan comes on and stays: the floor rises to it, then it no longer holds the sentence.
        var t = 0.0
        while t < 60 { e.level(0.4, at: t); t += 0.05 }
        XCTAssertTrue(e.shouldEnd(at: 60))
    }

    func testVeryLongUtteranceIsSentAnyway() {
        var e = UtteranceEndpointer(endSilence: 1.0)
        var t = 0.0, text = ""
        while t <= HandsFreeSettings.maximumUtterance {
            text += " word"
            e.transcript(text, at: t)
            t += 0.5
        }
        XCTAssertTrue(e.shouldEnd(at: HandsFreeSettings.maximumUtterance))
    }
}

final class HandsFreeSessionTests: XCTestCase {
    private let idle = HandsFreeSnapshot(phase: .idle)
    private let listening = HandsFreeSnapshot(phase: .listening)
    private let thinking = HandsFreeSnapshot(phase: .thinking)
    private let speaking = HandsFreeSnapshot(phase: .speaking)

    private func session(idleTimeout: TimeInterval = 60) -> HandsFreeSession {
        HandsFreeSession(settings: HandsFreeSettings(idleTimeout: idleTimeout))
    }

    func testStartOpensTheMicWhenFree() {
        var s = session()
        XCTAssertEqual(s.start(at: 0), [.openMic])
        XCTAssertTrue(s.isOn)
        XCTAssertTrue(s.micOpen)
        XCTAssertEqual(s.start(at: 1), [])   // already on
    }

    func testStartWhileBusyWaitsForTheAnswer() {
        var s = session()
        _ = s.update(thinking, at: 0)
        XCTAssertEqual(s.start(at: 0), [])
        XCTAssertEqual(s.update(idle, at: 5), [])
        XCTAssertEqual(s.tick(at: 5.2), [])
        XCTAssertEqual(s.tick(at: 5 + HandsFreeSettings.resumeDelay), [.openMic])
    }

    func testThreeFollowUpsWithNoKeys() {
        var s = session()
        var t = 0.0
        XCTAssertEqual(s.start(at: t), [.openMic])
        for question in ["What's on my calendar?", "Move the 3 pm to 4.", "And email Sam about it."] {
            _ = s.update(listening, at: t)
            t += 2
            XCTAssertEqual(s.utteranceFinished(question, at: t), [.submit(question)])
            XCTAssertFalse(s.micOpen)
            XCTAssertEqual(s.update(HandsFreeSnapshot(phase: .transcribing), at: t), [])
            XCTAssertEqual(s.update(thinking, at: t), [])
            XCTAssertEqual(s.update(HandsFreeSnapshot(phase: .thinking, speechPending: true), at: t + 3), [])
            XCTAssertEqual(s.update(speaking, at: t + 4), [])
            XCTAssertEqual(s.tick(at: t + 6), [])            // never listens while Benji speaks
            t += 8
            XCTAssertEqual(s.update(idle, at: t), [])         // speech ended: resume delay
            t += HandsFreeSettings.resumeDelay
            XCTAssertEqual(s.tick(at: t), [.openMic])         // listening again, no key
        }
        XCTAssertTrue(s.isOn)
    }

    func testAnswerWaitingForTheVoiceDoesNotOpenTheMic() {
        // The engine has finished (idle) but Kokoro hasn't started speaking yet.
        var s = session()
        _ = s.start(at: 0)
        _ = s.utteranceFinished("Hello there", at: 1)
        _ = s.update(thinking, at: 1)
        XCTAssertEqual(s.update(HandsFreeSnapshot(phase: .idle, speechPending: true), at: 3), [])
        XCTAssertEqual(s.tick(at: 10), [])
        XCTAssertFalse(s.micOpen)
    }

    func testApprovalPausesListeningAndVoiceCannotAnswerIt() {
        var s = session()
        _ = s.start(at: 0)
        _ = s.utteranceFinished("Delete the build folder", at: 2)
        _ = s.update(thinking, at: 2)
        let approval = HandsFreeSnapshot(phase: .awaitingApproval, approvalPending: true)
        XCTAssertEqual(s.update(approval, at: 3), [])
        for t in stride(from: 3.0, through: 40, by: 0.5) {
            XCTAssertEqual(s.tick(at: t), [], "mic must stay shut while the card waits")
        }
        XCTAssertFalse(s.micOpen)
        XCTAssertTrue(s.isOn)
        // Answered by click: the engine resumes, finishes, and then the conversation listens again.
        _ = s.update(thinking, at: 41)
        _ = s.update(idle, at: 43)
        XCTAssertEqual(s.tick(at: 43 + HandsFreeSettings.resumeDelay), [.openMic])
    }

    func testScreenCardPausesListening() {
        var s = session()
        _ = s.start(at: 0)
        XCTAssertEqual(s.update(HandsFreeSnapshot(phase: .idle, screenCardPending: true), at: 1), [.closeMic])
        XCTAssertEqual(s.tick(at: 5), [])
        _ = s.update(idle, at: 6)
        XCTAssertEqual(s.tick(at: 6 + HandsFreeSettings.resumeDelay), [.openMic])
    }

    func testCardArrivingWhileTheMicIsOpenClosesIt() {
        var s = session()
        _ = s.start(at: 0)
        let approval = HandsFreeSnapshot(phase: .awaitingApproval, approvalPending: true)
        XCTAssertEqual(s.update(approval, at: 1), [.closeMic])
        XCTAssertFalse(s.micOpen)
    }

    func testQuietSpellEndsTheConversation() {
        var s = session(idleTimeout: 60)
        XCTAssertEqual(s.start(at: 0), [.openMic])
        XCTAssertEqual(s.tick(at: 59.9), [])
        XCTAssertEqual(s.tick(at: 60), [.closeMic, .ended(.timeout)])
        XCTAssertFalse(s.isOn)
        XCTAssertEqual(s.tick(at: 100), [])
    }

    func testSpeechResetsTheQuietSpell() {
        var s = session(idleTimeout: 60)
        _ = s.start(at: 0)
        s.heardSpeech(at: 50)
        XCTAssertEqual(s.tick(at: 100), [])
        XCTAssertEqual(s.tick(at: 110), [.closeMic, .ended(.timeout)])
    }

    func testQuietSpellOnlyCountsWhileListening() {
        var s = session(idleTimeout: 60)
        _ = s.start(at: 0)
        _ = s.utteranceFinished("Summarise this long report", at: 5)
        _ = s.update(thinking, at: 5)
        XCTAssertEqual(s.tick(at: 200), [])   // a long answer doesn't time the conversation out
        _ = s.update(idle, at: 200)
        XCTAssertEqual(s.tick(at: 200 + HandsFreeSettings.resumeDelay), [.openMic])
        XCTAssertEqual(s.tick(at: 259), [])
        XCTAssertEqual(s.tick(at: 260.4), [.closeMic, .ended(.timeout)])
    }

    func testNoiseIsIgnoredSilentlyAndDoesNotResetTheQuietSpell() {
        var s = session(idleTimeout: 60)
        _ = s.start(at: 0)
        XCTAssertEqual(s.utteranceFinished("", at: 20), [.openMic])
        XCTAssertEqual(s.utteranceFinished("Um.", at: 40), [.openMic])
        XCTAssertTrue(s.micOpen)
        XCTAssertEqual(s.tick(at: 60), [.closeMic, .ended(.timeout)])
    }

    func testHeldBackOtherAppAudioDoesNotResetTheQuietSpell() {
        var s = session(idleTimeout: 60)
        _ = s.start(at: 0)
        s.otherAppAudio(true)
        s.heardSpeech(at: 30)
        XCTAssertEqual(s.utteranceFinished("here is a podcast talking away", at: 40), [.heldBack(.otherAppAudio), .openMic])
        XCTAssertEqual(s.tick(at: 59), [])
        XCTAssertEqual(s.tick(at: 60), [.closeMic, .ended(.timeout)], "the spell ran on from before the held-back words")
    }

    func testARealRequestStillResetsTheQuietSpell() {
        var s = session(idleTimeout: 60)
        _ = s.start(at: 0)
        s.heardSpeech(at: 30)
        XCTAssertEqual(s.utteranceFinished("open Mail please", at: 40), [.submit("open Mail please")])
        _ = s.update(thinking, at: 40)
        _ = s.update(idle, at: 50)
        XCTAssertEqual(s.tick(at: 50 + HandsFreeSettings.resumeDelay), [.openMic])
        XCTAssertEqual(s.tick(at: 109), [])
        XCTAssertEqual(s.tick(at: 111), [.closeMic, .ended(.timeout)])
    }

    func testNoiseWhileFinalisingWaitsForTheCompanionToBeFree() {
        var s = session()
        _ = s.start(at: 0)
        _ = s.update(HandsFreeSnapshot(phase: .transcribing), at: 1)
        XCTAssertEqual(s.utteranceFinished("hmm", at: 1.2), [])
        XCTAssertEqual(s.update(idle, at: 1.3), [])
        XCTAssertEqual(s.tick(at: 1.3 + HandsFreeSettings.resumeDelay), [.openMic])
    }

    func testStopPhraseEndsTheConversation() {
        var s = session()
        _ = s.start(at: 0)
        XCTAssertEqual(s.utteranceFinished("That's all, thanks Benji.", at: 3), [.ended(.stopPhrase)])
        XCTAssertFalse(s.isOn)
        XCTAssertFalse(s.micOpen)
    }

    func testRequestThenStopPhraseEndsAfterTheReply() {
        var s = session()
        _ = s.start(at: 0)
        XCTAssertEqual(s.utteranceFinished("Open Mail, that's all.", at: 3), [.submit("Open Mail")])
        XCTAssertTrue(s.endAfterReply)
        _ = s.update(thinking, at: 3)
        _ = s.update(speaking, at: 5)
        XCTAssertEqual(s.update(idle, at: 8), [.ended(.stopPhrase)])
        XCTAssertFalse(s.isOn)
        XCTAssertEqual(s.tick(at: 9), [])
    }

    func testStopClosesTheMicWithTheReason() {
        for reason: HandsFreeEndReason in [.user, .escape, .locked, .sleep, .panelClosed, .cancelled] {
            var s = session()
            _ = s.start(at: 0)
            XCTAssertEqual(s.stop(reason), [.closeMic, .ended(reason)])
            XCTAssertEqual(s.stop(reason), [])
        }
    }

    func testStopWhileBenjiIsWorkingHasNoMicToClose() {
        var s = session()
        _ = s.start(at: 0)
        _ = s.utteranceFinished("Find my tax PDF", at: 2)
        _ = s.update(thinking, at: 2)
        XCTAssertEqual(s.stop(.sleep), [.ended(.sleep)])
        _ = s.update(idle, at: 9)
        XCTAssertEqual(s.tick(at: 10), [])
    }

    func testAdoptedMicCountsTheQuietSpellFromThere() {
        var s = session(idleTimeout: 60)
        _ = s.update(listening, at: 0)
        s.adoptOpenMic(at: 0)
        XCTAssertTrue(s.isOn)
        XCTAssertEqual(s.tick(at: 60), [.closeMic, .ended(.timeout)])
    }

    func testMicClosedByItselfReopens() {
        var s = session()
        _ = s.start(at: 0)
        _ = s.update(idle, at: 1)
        s.micClosed(at: 1)
        XCTAssertFalse(s.micOpen)
        XCTAssertEqual(s.tick(at: 1 + HandsFreeSettings.resumeDelay), [.openMic])
    }

    func testOffSessionIgnoresEverything() {
        var s = session()
        XCTAssertEqual(s.update(idle, at: 0), [])
        XCTAssertEqual(s.tick(at: 10), [])
        XCTAssertEqual(s.utteranceFinished("hello there", at: 11), [])
        XCTAssertEqual(s.stop(.user), [])
    }

    func testMayListen() {
        XCTAssertTrue(HandsFreeSnapshot(phase: .idle).mayListen)
        XCTAssertTrue(HandsFreeSnapshot(phase: .error).mayListen)
        XCTAssertTrue(HandsFreeSnapshot(phase: .listening).mayListen)
        for phase: CompanionPhase in [.transcribing, .thinking, .speaking, .awaitingApproval] {
            XCTAssertFalse(HandsFreeSnapshot(phase: phase).mayListen, phase.rawValue)
        }
        XCTAssertFalse(HandsFreeSnapshot(phase: .idle, approvalPending: true).mayListen)
        XCTAssertFalse(HandsFreeSnapshot(phase: .idle, screenCardPending: true).mayListen)
        XCTAssertFalse(HandsFreeSnapshot(phase: .idle, speechPending: true).mayListen)
    }

    func testEndNotices() {
        XCTAssertEqual(HandsFreeEndReason.timeout.notice, "Stopped listening after a quiet spell.")
        XCTAssertEqual(HandsFreeEndReason.stopPhrase.notice, "Stopped listening.")
        XCTAssertNil(HandsFreeEndReason.panelClosed.notice)
        XCTAssertNil(HandsFreeEndReason.micUnavailable.notice)
    }
}

final class RecognizerRestartTests: XCTestCase {
    func testKeepsRestartingHealthyRequests() {
        var r = RecognizerRestarts()
        for i in 0..<10 {
            XCTAssertTrue(r.requestEnded(started: Double(i) * 30, ended: Double(i) * 30 + 25, heardWords: false))
        }
    }

    func testGivesUpAfterThreeInstantFailures() {
        var r = RecognizerRestarts()
        XCTAssertTrue(r.requestEnded(started: 0, ended: 0.1, heardWords: false))
        XCTAssertTrue(r.requestEnded(started: 0.2, ended: 0.3, heardWords: false))
        XCTAssertFalse(r.requestEnded(started: 0.4, ended: 0.5, heardWords: false))
    }

    func testAHealthyRequestResetsTheCount() {
        var r = RecognizerRestarts()
        _ = r.requestEnded(started: 0, ended: 0.1, heardWords: false)
        _ = r.requestEnded(started: 0.2, ended: 0.3, heardWords: false)
        XCTAssertTrue(r.requestEnded(started: 1, ended: 1.2, heardWords: true))
        XCTAssertTrue(r.requestEnded(started: 2, ended: 2.1, heardWords: false))
        XCTAssertTrue(r.requestEnded(started: 3, ended: 3.1, heardWords: false))
    }

    func testTranscriptJoin() {
        XCTAssertEqual(TranscriptJoin.join("", "Open Mail"), "Open Mail")
        XCTAssertEqual(TranscriptJoin.join("Open Mail", ""), "Open Mail")
        XCTAssertEqual(TranscriptJoin.join("Open Mail ", " and Safari"), "Open Mail and Safari")
    }
}

final class HandsFreeFinalisingTests: XCTestCase {
    func testWaitingForTheFinalWordsNeitherClosesNorReopens() {
        var s = HandsFreeSession(settings: HandsFreeSettings())
        _ = s.update(HandsFreeSnapshot(phase: .listening), at: 0)
        _ = s.start(at: 0)
        s.utteranceEnding()
        // The app shows Transcribing while the recogniser finishes: no closeMic (it would drop
        // the pending result) and no reopen.
        XCTAssertEqual(s.update(HandsFreeSnapshot(phase: .transcribing), at: 2), [])
        XCTAssertEqual(s.tick(at: 3), [])
        XCTAssertEqual(s.utteranceFinished("Open Mail", at: 3.2), [.submit("Open Mail")])
    }

    func testNoiseAfterFinalisingListensAgainOnceFree() {
        var s = HandsFreeSession(settings: HandsFreeSettings())
        _ = s.start(at: 0)
        s.utteranceEnding()
        _ = s.update(HandsFreeSnapshot(phase: .transcribing), at: 2)
        XCTAssertEqual(s.utteranceFinished("uh", at: 2.3), [])
        _ = s.update(HandsFreeSnapshot(phase: .idle), at: 2.3)
        XCTAssertEqual(s.tick(at: 2.3 + HandsFreeSettings.resumeDelay), [.openMic])
    }
}

final class UtteranceEndingTests: XCTestCase {
    private func pendingSession() -> HandsFreeSession {
        var s = HandsFreeSession(settings: HandsFreeSettings())
        _ = s.update(HandsFreeSnapshot(phase: .listening), at: 0)
        _ = s.start(at: 0)
        _ = s.tick(at: 0)
        s.utteranceEnding()
        _ = s.update(HandsFreeSnapshot(phase: .transcribing), at: 2)
        return s
    }

    func testTapWhileTranscribingSubmitsAndConversationGoesOn() {
        var s = pendingSession()
        XCTAssertTrue(s.utterancePending)
        XCTAssertEqual(s.utteranceFinished("Open Mail", at: 2.1), [.submit("Open Mail")])
        XCTAssertTrue(s.isOn)
        XCTAssertFalse(s.utterancePending)
    }

    func testEndDuringTranscribingSubmitsThenEnds() {
        for reason in [HandsFreeEndReason.user, .escape, .locked, .sleep, .panelClosed, .timeout] {
            var s = pendingSession()
            XCTAssertEqual(s.stop(reason), [], "\(reason) waits for the words")
            XCTAssertTrue(s.isOn)
            XCTAssertEqual(s.utteranceFinished("Open Mail", at: 2.1), [.submit("Open Mail"), .ended(reason)])
            XCTAssertFalse(s.isOn)
        }
    }

    func testEscapeDuringTranscribingWithNoiseJustEnds() {
        var s = pendingSession()
        _ = s.stop(.escape)
        XCTAssertEqual(s.utteranceFinished("uh", at: 2.1), [.ended(.escape)])
        XCTAssertFalse(s.isOn)
        XCTAssertEqual(s.tick(at: 5), [])
    }

    func testTrailingStopPhraseSubmitsRequestOnce() {
        var s = pendingSession()
        _ = s.stop(.user)
        XCTAssertEqual(s.utteranceFinished("open Mail, that's all", at: 2.1), [.submit("open Mail"), .ended(.user)])
    }

    func testCancelDuringTranscribingEndsAtOnceAndDropsWords() {
        var s = pendingSession()
        XCTAssertEqual(s.stop(.cancelled), [.ended(.cancelled)])
        XCTAssertEqual(s.utteranceFinished("Open Mail", at: 2.1), [])
        XCTAssertFalse(s.utterancePending)
    }

    func testMicUnavailableDuringTranscribingEndsAtOnce() {
        var s = pendingSession()
        XCTAssertEqual(s.stop(.micUnavailable), [.ended(.micUnavailable)])
    }

    func testDroppedWordsClearPendingAndListenAgain() {
        var s = pendingSession()
        s.micClosed(at: 3)
        XCTAssertFalse(s.utterancePending)
        _ = s.update(HandsFreeSnapshot(phase: .idle), at: 3)
        XCTAssertEqual(s.tick(at: 3 + HandsFreeSettings.resumeDelay), [.openMic])
    }

    func testDroppedWordsAfterEndRequestStillEnd() {
        var s = pendingSession()
        _ = s.stop(.escape)
        s.micClosed(at: 3)
        XCTAssertFalse(s.isOn)
    }

    func testNothingReopensWhileFinalising() {
        var s = pendingSession()
        XCTAssertEqual(s.update(HandsFreeSnapshot(phase: .idle), at: 5), [])
        XCTAssertEqual(s.tick(at: 9), [])
    }

    func testMenuToggleRespectsKeepListening() {
        let off = OpenListening(enabled: true, keepsListeningWhenClosed: false)
        let keep = OpenListening(enabled: true, keepsListeningWhenClosed: true)
        XCTAssertTrue(off.endsConversationOnMenuClose(conversationOn: true))
        XCTAssertFalse(keep.endsConversationOnMenuClose(conversationOn: true))
        XCTAssertFalse(off.endsConversationOnMenuClose(conversationOn: false))
    }
}

final class ConversationStateTests: XCTestCase {
    func testMicStoppedEndsAnEmptyTranscription() {
        var s = CompanionState()
        reduce(&s, .micStarted)
        reduce(&s, .transcribingStarted)
        reduce(&s, .micStopped)
        XCTAssertEqual(s.phase, .idle)
        XCTAssertTrue(s.lines.isEmpty, "noise leaves no line and no error")
        XCTAssertNil(s.lastError)
    }

    func testMicStoppedDoesNotInterruptWork() {
        var s = CompanionState()
        reduce(&s, .submitText("hi"))
        reduce(&s, .micStopped)
        XCTAssertEqual(s.phase, .thinking)
    }

    func testNoticeAddsASystemLineOnly() {
        var s = CompanionState()
        reduce(&s, .notice("Conversation ended."))
        XCTAssertEqual(s.lines.map(\.role), [.system])
        XCTAssertEqual(s.lines.first?.text, "Conversation ended.")
        XCTAssertEqual(s.phase, .idle)
    }

    func testListeningLineInAConversation() {
        var s = CompanionState()
        reduce(&s, .micStarted)
        XCTAssertEqual(NotchStatusInfo.make(s).line, NotchStatusInfo.listeningLine)
        XCTAssertEqual(NotchStatusInfo.make(s, conversation: true).line, NotchStatusInfo.conversationListeningLine)
        XCTAssertEqual(NotchStatusInfo.make(s, partial: "open Mail", conversation: true).line, "open Mail")
        XCTAssertEqual(NotchStatusInfo.make(s, conversation: true).word, "Listening")
    }

    func testListeningAlwaysShowsInTheNotch() {
        // The mic is never open while the notch is closed: listening is at least the peek, whose
        // wings carry the mic glyph and meter (the open panel keeps the wings too).
        XCTAssertEqual(NotchPresence.targetSize(NotchPresenceInputs(phase: .listening)), .peek)
        XCTAssertEqual(NotchPresence.targetSize(NotchPresenceInputs(phase: .listening, userOpened: true)), .open)
        XCTAssertTrue(NotchLayer.layers(for: .peek).contains(.wings))
        XCTAssertTrue(NotchLayer.layers(for: .open).contains(.wings))
    }
}

/// The user's live test: while the conversation listened, another app's spoken answer was
/// transcribed and sent as the user's words. Words heard while another app played out loud are
/// held back; push-to-talk (an explicit hold) is not affected.
final class OtherAppAudioTests: XCTestCase {
    private func listeningSession() -> HandsFreeSession {
        var s = HandsFreeSession(settings: HandsFreeSettings(idleTimeout: 60))
        XCTAssertEqual(s.start(at: 0), [.openMic])
        _ = s.update(HandsFreeSnapshot(phase: .listening), at: 0)
        return s
    }

    func testAudibleOnlyWhenAnotherAppPlaysAndTheMicCanHearIt() {
        XCTAssertTrue(OtherAppAudio.audible(playing: true, route: .speakers))
        XCTAssertTrue(OtherAppAudio.audible(playing: true, route: .unknown))
        XCTAssertFalse(OtherAppAudio.audible(playing: true, route: .headphones))
        XCTAssertFalse(OtherAppAudio.audible(playing: false, route: .speakers))
        XCTAssertFalse(OtherAppAudio.audible(playing: nil, route: .speakers), "unknown never holds anything back")
    }

    func testRouteFromCoreAudio() {
        XCTAssertEqual(OutputRoute.from(builtIn: true, dataSource: OutputRoute.builtInHeadphoneSource), .headphones)
        XCTAssertEqual(OutputRoute.from(builtIn: true, dataSource: OutputRoute.builtInSpeakerSource), .speakers)
        XCTAssertEqual(OutputRoute.from(builtIn: true, dataSource: nil), .unknown)
        XCTAssertEqual(OutputRoute.from(builtIn: false, dataSource: OutputRoute.builtInHeadphoneSource), .unknown,
                       "Bluetooth, USB and display outputs can't say whether they are speakers")
    }

    func testWordsHeardOverAnotherAppAreHeldBackAndListeningGoesOn() {
        var s = listeningSession()
        s.otherAppAudio(true)
        let actions = s.utteranceFinished("Sure, I've opened Safari for you.", at: 3)
        XCTAssertEqual(actions, [.heldBack(.otherAppAudio), .openMic])
        XCTAssertTrue(s.isOn)
        XCTAssertFalse(actions.contains { if case .submit = $0 { return true } else { return false } })
    }

    func testTheNextUtteranceStartsClean() {
        var s = listeningSession()
        s.otherAppAudio(true)
        _ = s.utteranceFinished("someone else talking", at: 3)
        s.otherAppAudio(false)
        XCTAssertEqual(s.utteranceFinished("What's the time?", at: 6), [.submit("What's the time?")])
    }

    func testQuietSamplesHoldNothingBack() {
        var s = listeningSession()
        s.otherAppAudio(false)
        s.otherAppAudio(false)
        XCTAssertEqual(s.utteranceFinished("Open Mail.", at: 3), [.submit("Open Mail.")])
    }

    func testAStopPhraseStillEndsListening() {
        var s = listeningSession()
        s.otherAppAudio(true)
        XCTAssertEqual(s.utteranceFinished("stop listening", at: 3), [.ended(.stopPhrase)])
        XCTAssertFalse(s.isOn)
    }

    func testARequestBeforeAStopPhraseIsHeldBackToo() {
        var s = listeningSession()
        s.otherAppAudio(true)
        let actions = s.utteranceFinished("Delete my notes, that's all.", at: 3)
        XCTAssertEqual(actions.first, .heldBack(.otherAppAudio))
        XCTAssertFalse(s.endAfterReply)
    }

    func testTheNoticeSaysWhatDidntHappenAndWhatToDo() {
        let note = HandsFreeHoldReason.otherAppAudio.notice
        XCTAssertTrue(note.hasPrefix("Not sent"))
        XCTAssertTrue(note.contains("talk key"))
        XCTAssertTrue(note.contains("in the box"), "the words are kept, and the note says where")
    }
}

final class HeldBackStatusLineTests: XCTestCase {
    func testListeningShowsWhyTheLastWordsWerentSentUntilNewWordsArrive() {
        var s = CompanionState()
        reduce(&s, .micStarted)
        let note = HandsFreeHoldReason.otherAppAudio.notice
        XCTAssertEqual(NotchStatusInfo.make(s, conversation: true, note: note).line, note)
        XCTAssertEqual(NotchStatusInfo.make(s, partial: "what's the", conversation: true, note: note).line, "what's the")
        XCTAssertEqual(NotchStatusInfo.make(s, conversation: true).line, NotchStatusInfo.conversationListeningLine)
    }
}

final class OtherAppAudioGuardTests: XCTestCase {
    func testOffUnlessExplicitlyOn() {
        XCTAssertFalse(OtherAppAudioGuard.isOn(from: nil))
        XCTAssertFalse(OtherAppAudioGuard.isOn(from: false))
        XCTAssertFalse(OtherAppAudioGuard.isOn(from: "yes"))
        XCTAssertFalse(OtherAppAudioGuard.isOn(from: 1))
        XCTAssertTrue(OtherAppAudioGuard.isOn(from: true))
    }
}
