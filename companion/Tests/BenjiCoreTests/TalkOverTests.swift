import XCTest
@testable import BenjiCore

/// Talking over Benji on speakers without echo cancelling: which path the mic takes, the
/// playback envelope, the speech gate, the guarded interrupt and the settle window.
final class TalkOverPathTests: XCTestCase {
    func testAlwaysOnSpeakersWithoutEchoCancellingListensGuarded() {
        XCTAssertEqual(TalkOverPath.choose(mode: .always, route: .speakers, echoUnavailable: true), .guarded)
        XCTAssertEqual(TalkOverPath.choose(mode: .always, route: .unknown, echoUnavailable: true), .guarded)
        XCTAssertEqual(TalkOverPath.choose(mode: .always, route: .speakers, echoUnavailable: false), .echoCancelled)
        XCTAssertEqual(TalkOverPath.choose(mode: .always, route: .headphones, echoUnavailable: true), .clean)
    }

    func testHeadphonesAndOffAreUnchanged() {
        XCTAssertEqual(TalkOverPath.choose(mode: .headphones, route: .headphones, echoUnavailable: false), .clean)
        XCTAssertEqual(TalkOverPath.choose(mode: .headphones, route: .speakers, echoUnavailable: true), .closed)
        XCTAssertEqual(TalkOverPath.choose(mode: .off, route: .headphones, echoUnavailable: false), .closed)
        XCTAssertFalse(TalkOverPath.closed.listensOverSpeech)
        XCTAssertTrue(TalkOverPath.guarded.listensOverSpeech)
    }

    func testTheGuardedPathStillUsesThePlainEngineAndBenjisOwnOutput() {
        // The engines follow the echo-cancelling fallback: no voice-processing engine where it failed.
        let acting = BargeInMode.always.effective(route: .speakers, echoUnavailable: true)
        XCTAssertEqual(MicEngine.choose(mode: acting, route: .speakers, handsFreeOn: true, handsFreeAvailable: true), .plain)
        XCTAssertFalse(acting.needsEchoCancellation(.speakers))
    }

    func testTheSettingsWordingIsHonestAboutTheGuardedPath() {
        XCTAssertTrue(BargeInMode.echoUnavailableCaption.contains("may miss"))
        XCTAssertTrue(BargeInMode.echoUnavailableCaption.hasSuffix("."))
        XCTAssertFalse(BargeInMode.echoUnavailableNotice.contains("doesn't work"))
        XCTAssertFalse(BargeInMode.always.caption.contains("stops by itself"))
    }
}

final class PlaybackEnvelopeTests: XCTestCase {
    func testLevelFollowsTheScheduledAudioBackToBack() {
        var e = PlaybackEnvelope()
        let loud = [Float](repeating: 0.5, count: 2400)     // 0.1 s at 24 kHz
        let quiet = [Float](repeating: 0.005, count: 2400)
        e.add(samples: loud, sampleRate: 24000, at: 10)
        e.add(samples: quiet, sampleRate: 24000, at: 10.02)  // queued: plays after the first
        XCTAssertEqual(e.end, 10.2, accuracy: 1e-9)
        XCTAssertEqual(e.level(at: 10.05), MicLevel.normalized(rms: 0.5), accuracy: 1e-4)
        // Well into the quiet part, past the slack, only the quiet audio counts.
        XCTAssertLessThan(e.level(at: 10.2 + PlaybackEnvelope.slack + 0.01), 0.01)
        XCTAssertEqual(e.level(at: 9), 0)
    }

    func testAfterARunDryTheNextBufferPlaysNow() {
        var e = PlaybackEnvelope()
        e.add(samples: [Float](repeating: 0.3, count: 1200), sampleRate: 24000, at: 0)
        e.add(samples: [Float](repeating: 0.3, count: 1200), sampleRate: 24000, at: 5)
        XCTAssertEqual(e.starts.last!, 5, accuracy: 1e-9)
        XCTAssertEqual(e.level(at: 2.5), 0)
        e.reset()
        XCTAssertEqual(e.level(at: 5), 0)
    }

    func testTheSlackCoversTheMicsLateness() {
        var e = PlaybackEnvelope()
        e.add(samples: [Float](repeating: 0.4, count: 1200), sampleRate: 24000, at: 0)   // 0–0.05 s
        XCTAssertGreaterThan(e.level(at: 0.05 + PlaybackEnvelope.slack - 0.01), 0.5)
        XCTAssertEqual(e.level(at: 0.05 + PlaybackEnvelope.slack + 0.02), 0)
    }
}

final class SpeechGateTests: XCTestCase {
    let dt = 2048.0 / 48000

    func testNothingCountsOverBenjisVoiceUntilItsLevelInTheMicIsKnown() {
        var g = SpeechGate()
        var t = 0.0
        for _ in 0..<(SpeechGate.warmUpFrames - 1) {
            t += dt
            g.mic(0.95, playback: 0.5, duration: dt, at: t)
        }
        XCTAssertNil(g.coupling)
        XCTAssertEqual(g.voice(at: t), 0)
    }

    func testBenjisOwnVoiceNeverOpensTheGate() {
        var g = SpeechGate()
        var t = 0.0
        for i in 0..<400 {
            t += dt
            let playback: Float = i % 25 < 20 ? 0.55 + Float(i % 5) * 0.03 : 0   // words, then a pause
            let echo = playback > 0 ? playback + 0.1 + (i % 2 == 0 ? 0.04 : -0.04) : 0.15
            g.mic(echo, playback: playback, duration: dt, at: t)
            XCTAssertFalse(g.isOpen(at: t), "frame \(i)")
        }
    }

    func testAVoiceInBenjisPauseOpensIt() {
        var g = SpeechGate()
        var t = 0.0
        for _ in 0..<40 { t += dt; g.mic(0.7, playback: 0.6, duration: dt, at: t) }
        for _ in 0..<20 { t += dt; g.mic(0.15, playback: 0, duration: dt, at: t) }   // the room
        let start = t
        for _ in 0..<10 { t += dt; g.mic(0.5, playback: 0, duration: dt, at: t) }   // the user, 0.43 s
        XCTAssertTrue(g.isOpen(at: t))
        XCTAssertEqual(g.voiceStarted(at: t)!, start, accuracy: 0.001)
    }

    func testAVoiceWellAboveBenjisOpensItOverSpeech() {
        var g = SpeechGate()
        var t = 0.0
        for _ in 0..<40 { t += dt; g.mic(0.6, playback: 0.5, duration: dt, at: t) }
        for _ in 0..<10 { t += dt; g.mic(0.85, playback: 0.5, duration: dt, at: t) }
        XCTAssertTrue(g.isOpen(at: t))
    }

    func testABriefSoundIsNotAVoice() {
        var g = SpeechGate()
        var t = 0.0
        for _ in 0..<20 { t += dt; g.mic(0.15, playback: 0, duration: dt, at: t) }
        for _ in 0..<3 { t += dt; g.mic(0.8, playback: 0, duration: dt, at: t) }   // a cough, 0.13 s
        XCTAssertFalse(g.isOpen(at: t))
        for _ in 0..<60 { t += dt; g.mic(0.15, playback: 0, duration: dt, at: t) }
        XCTAssertEqual(g.voice(at: t), 0, "it leaves the window")
    }
}

final class GuardedTalkOverTests: XCTestCase {
    let spoken = "A wing pushes air down, and the air pushes the wing up. That's lift."

    func testWordsAloneNeverInterrupt() {
        XCTAssertFalse(GuardedTalkOver.interrupts(heard: "wait what about the engines", spoken: spoken, voiceOpen: false))
    }

    func testThreeOwnWordsOrAClearInterruptWordWithAVoice() {
        XCTAssertTrue(GuardedTalkOver.interrupts(heard: "what about the engines", spoken: spoken, voiceOpen: true))
        XCTAssertTrue(GuardedTalkOver.interrupts(heard: "wait", spoken: spoken, voiceOpen: true))
        XCTAssertTrue(GuardedTalkOver.interrupts(heard: "Benji", spoken: spoken, voiceOpen: true))
        XCTAssertFalse(GuardedTalkOver.interrupts(heard: "what engines", spoken: spoken, voiceOpen: true))
        // "no" and "hey" are what a misheard answer turns into; on speakers they don't stop Benji.
        XCTAssertFalse(GuardedTalkOver.interrupts(heard: "no", spoken: spoken, voiceOpen: true))
        XCTAssertTrue(EchoGuard.interrupts(heard: "no", spoken: spoken), "the other paths keep their rule")
    }

    func testBenjisOwnWordsAreNotTheUsers() {
        XCTAssertFalse(GuardedTalkOver.interrupts(heard: "pushes the wing up that's lift", spoken: spoken, voiceOpen: true))
        XCTAssertFalse(GuardedTalkOver.interrupts(heard: "pushes the wink up that's lifts", spoken: spoken, voiceOpen: true))
    }
}

final class SettleWindowTests: XCTestCase {
    let spoken = "The moon pulls the sea toward it. That's the tide."

    func testBenjisLastWordsRightAfterItStoppedAreDropped() {
        XCTAssertEqual(SettleWindow.strip("the tide why twice a day", spoken: spoken, firstWordAt: 10.3, speechEndedAt: 10),
                       "why twice a day")
        XCTAssertEqual(SettleWindow.strip("tide", spoken: spoken, firstWordAt: 10.2, speechEndedAt: 10), "")
    }

    func testLaterOrUnrelatedWordsAreKept() {
        XCTAssertEqual(SettleWindow.strip("the tide again", spoken: spoken, firstWordAt: 11, speechEndedAt: 10),
                       "the tide again")
        XCTAssertEqual(SettleWindow.strip("why twice", spoken: spoken, firstWordAt: 10.1, speechEndedAt: 10), "why twice")
        XCTAssertEqual(SettleWindow.strip("the tide", spoken: spoken, firstWordAt: 10.1, speechEndedAt: nil), "the tide")
    }
}

/// A measured run of the guarded path over simulated audio: Benji's voice from the speakers, its
/// echo in the mic at several volumes, a recogniser that mishears a fifth of Benji's words, and
/// sometimes the user talking. Counts false interrupts (Benji stopping itself) and misses. The
/// tuning prefers a miss: no false interrupt is allowed anywhere in the runs.
/// Levels are on the meter's scale (0 = -50 dBFS, 1 = 0 dBFS). Kokoro's audio peaks near 0.8
/// (-10 dBFS); `coupling` -0.4 puts its echo in the built-in mic near 0.4 (-30 dBFS), a moderate
/// volume; 0 is the speakers turned right up. A user at arm's length talks near 0.45, speaking up
/// near 0.65. These are assumptions, not measurements.
final class TalkOverSimulationTests: XCTestCase {
    struct Rng {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    static let rate = 4800.0
    static let dt = 2048.0 / 48000
    static let words = ("a wing is shaped so the air over it moves faster than the air under it and that "
        + "difference in pressure pushes the wing up which we call lift the engines only push the plane "
        + "forward so the wings can keep making lift").split(separator: " ").map(String.init)
    static let spoken = words.joined(separator: " ")

    /// Benji's level over `seconds`: words of syllables, with a pause every few seconds.
    static func playback(seconds: Double, rng: inout Rng) -> (samples: [Float], level: (Double) -> Float) {
        var samples: [Float] = []
        var t = 0.0
        while t < seconds {
            let inPause = t.truncatingRemainder(dividingBy: 3.0) > 2.6
            let syllable = sin(.pi * (t * 4).truncatingRemainder(dividingBy: 1))
            let amp: Float = inPause ? 0 : Float(0.05 + 0.25 * syllable * (0.6 + 0.4 * rng.next()))
            for _ in 0..<48 { samples.append(amp) }   // 10 ms steps
            t += 0.01
        }
        let s = samples
        return (s, { time in
            let i = Int(time * rate)
            guard i >= 0, i < s.count else { return 0 }
            return MicLevel.normalized(rms: abs(s[i]))
        })
    }

    static func sum(_ levels: [Float]) -> Float {
        let power = levels.reduce(0.0) { $0 + pow(10, Double($1 * 50 - 50) / 10) }
        return Float((10 * log10(max(power, 1e-12)) + 50) / 50).clamped
    }

    struct Outcome { var interruptedAt: Double? }

    /// One run: `coupling` is how much louder Benji sounds in the mic than its playback level
    /// (meter scale); `user` is when and how loud the user talks, and what they say.
    static func run(seed: UInt64, coupling: Float, volumeJumpAt: Double? = nil,
                    user: (start: Double, level: Float, words: [String])? = nil) -> Outcome {
        var rng = Rng(state: seed)
        let seconds = 20.0
        let (samples, trueLevel) = playback(seconds: seconds, rng: &rng)
        var envelope = PlaybackEnvelope()
        envelope.add(samples: samples, sampleRate: rate, at: 0)
        var gate = SpeechGate()
        var heard: [String] = []
        var nextWordAt = 0.8
        var wordIndex = 0
        var t = 0.0
        while t < seconds {
            t += dt
            let jump: Float = (volumeJumpAt.map { t >= $0 } ?? false) ? 0.1 : 0
            let p = trueLevel(t - 0.03)
            var parts: [Float] = [0.15 + Float(rng.next() * 0.03)]
            if p > 0.05 { parts.append(p + coupling + jump + Float(rng.next() * 0.08 - 0.04)) }
            if let u = user, t >= u.start, t < u.start + 1.6 { parts.append(u.level + Float(rng.next() * 0.06 - 0.03)) }
            gate.mic(sum(parts), playback: envelope.level(at: t), duration: dt, at: t)
            // The recogniser: Benji's words come in late, a fifth of them misheard.
            if t >= nextWordAt, p > 0.05 || trueLevel(t - 0.3) > 0.05 {
                let w = words[wordIndex % words.count]
                heard.append(rng.next() < 0.2 ? ["zorb", "plim", "kesh", "vond", "trel"][Int(rng.next() * 5)] : w)
                wordIndex += 1
                nextWordAt = t + 0.35
            }
            if let u = user, t >= u.start + 0.6 {
                let n = min(u.words.count, Int((t - u.start - 0.6) / 0.3) + 1)
                let said = heard + u.words.prefix(n)
                if GuardedTalkOver.interrupts(heard: said.joined(separator: " "), spoken: spoken, voiceOpen: gate.isOpen(at: t)) {
                    return Outcome(interruptedAt: t)
                }
            } else if GuardedTalkOver.interrupts(heard: heard.joined(separator: " "), spoken: spoken,
                                                 voiceOpen: gate.isOpen(at: t)) {
                return Outcome(interruptedAt: t)
            }
        }
        return Outcome(interruptedAt: nil)
    }

    func testBenjiNeverStopsItselfAtAnyVolume() {
        var runs = 0, falseInterrupts = 0
        for coupling: Float in [-0.5, -0.4, -0.3, -0.2, -0.1, 0] {
            for seed in 1...20 {
                runs += 1
                if Self.run(seed: UInt64(seed), coupling: coupling).interruptedAt != nil { falseInterrupts += 1 }
            }
        }
        XCTAssertEqual(falseInterrupts, 0, "false interrupts in \(runs) runs of 20 s")
    }

    func testAModestVolumeChangeMidAnswerDoesntStopIt() {
        let stops = (1...20).filter { Self.run(seed: UInt64($0), coupling: -0.3, volumeJumpAt: 7).interruptedAt != nil }
        XCTAssertEqual(stops, [])
    }

    func testAUserWhoSpeaksUpIsHeardWithinAboutTwoSeconds() {
        var caught = 0
        let n = 20
        for seed in 1...n {
            let start = 4.0 + Double(seed % 7) * 0.9
            let outcome = Self.run(seed: UInt64(seed), coupling: -0.4,
                                   user: (start, 0.65, ["wait", "what", "about", "the", "engines"]))
            if let at = outcome.interruptedAt {
                XCTAssertGreaterThanOrEqual(at, start)
                if at - start <= 2.2 { caught += 1 }
            }
        }
        print("guarded talk-over, user speaking up: caught \(caught) of \(n) within 2.2 s")
        XCTAssertGreaterThanOrEqual(caught, n * 9 / 10, "caught \(caught) of \(n)")
    }

    func testASoftUserMayBeMissedButNeverCausesAFalseStopBeforeTheyTalk() {
        // A user about as loud as Benji's echo: caught in Benji's pauses or not at all (the honest
        // limit on speakers). Whatever happens, never before they start.
        var caught = 0
        for seed in 1...20 {
            let start = 5.0 + Double(seed % 5) * 0.7
            let outcome = Self.run(seed: UInt64(seed), coupling: -0.3, user: (start, 0.45, ["could", "you", "go", "back"]))
            if let at = outcome.interruptedAt {
                XCTAssertGreaterThanOrEqual(at, start)
                caught += 1
            }
        }
        print("guarded talk-over, soft user: caught \(caught) of 20")
    }
}

private extension Float {
    var clamped: Float { Swift.min(1, Swift.max(0, self)) }
}
