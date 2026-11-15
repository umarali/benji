import Foundation

// Talking over Benji on speakers without the Mac's echo cancelling. Where the
// voice-processing engine won't start, Always keeps the plain mic open over Benji's
// answer and only stops for the user's own speech: words Benji isn't saying (`EchoGuard`), heard
// while the mic level is above what Benji's own playback explains (`SpeechGate`), and a short
// settle after Benji stops (`SettleWindow`). Tuned to miss a soft interruption rather than have
// Benji stop itself. Pure decisions only; the app owns the mic and the voice.

/// How the mic may listen while Benji speaks.
public enum TalkOverPath: String, Equatable, Sendable {
    /// The mic stays shut while Benji speaks.
    case closed
    /// The sound is in headphones: the mic can't hear Benji.
    case clean
    /// Speakers, with the voice and the mic on the Mac's echo-cancelling engine.
    case echoCancelled
    /// Speakers, plain mic: Benji's voice reaches it, so only clear speech of the user's own
    /// interrupts.
    case guarded

    public static func choose(mode: BargeInMode, route: OutputRoute, echoUnavailable: Bool) -> TalkOverPath {
        switch mode {
        case .off: return .closed
        case .headphones: return route == .headphones ? .clean : .closed
        case .always:
            if route == .headphones { return .clean }
            return echoUnavailable ? .guarded : .echoCancelled
        }
    }

    public var listensOverSpeech: Bool { self != .closed }
}

/// How loud Benji's own voice is, moment by moment, from the audio it plays (meter scale 0…1, as
/// `MicLevel`). Each buffer is cut into short frames; a buffer plays right after the one before it,
/// or now if the player had run dry.
public struct PlaybackEnvelope: Equatable, Sendable {
    public static let frame: TimeInterval = 0.05
    /// Sound reaches the mic a little late and echoes a little: a moment's level is the loudest
    /// frame this close to it.
    public static let slack: TimeInterval = 0.15
    /// What to assume while a voice whose audio Benji can't see (the Apple voice) is speaking.
    public static let unknownLevel: Float = 0.8

    public private(set) var starts: [Double] = []
    public private(set) var levels: [Float] = []
    /// When the audio scheduled so far ends.
    public private(set) var end: Double = 0

    public init() {}

    /// `samples` (mono, -1…1) were scheduled at `now`.
    public mutating func add(samples: [Float], sampleRate: Double, at now: Double) {
        guard sampleRate > 0, !samples.isEmpty else { return }
        var t = max(now, end)
        let step = max(1, Int(sampleRate * Self.frame))
        var i = 0
        while i < samples.count {
            let j = min(samples.count, i + step)
            var sum: Float = 0
            for k in i..<j { sum += samples[k] * samples[k] }
            starts.append(t)
            levels.append(MicLevel.normalized(rms: (sum / Float(j - i)).squareRoot()))
            t += Double(j - i) / sampleRate
            i = j
        }
        end = t
    }

    /// Benji's level around `time`: 0 when nothing plays then.
    public func level(at time: Double) -> Float {
        guard !starts.isEmpty else { return 0 }
        let from = time - Self.slack - Self.frame
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] < from { lo = mid + 1 } else { hi = mid }
        }
        var loudest: Float = 0
        var i = lo
        while i < starts.count, starts[i] <= time + Self.slack {
            if starts[i] + Self.frame >= time - Self.slack { loudest = max(loudest, levels[i]) }
            i += 1
        }
        return loudest
    }

    public mutating func reset() {
        starts = []
        levels = []
        end = 0
    }
}

/// Whether the mic hears someone other than Benji: its level well above what Benji's playback
/// explains, for long enough. Benji's voice reaches the mic at some fixed gain, so on the meter's
/// decibel scale the mic sits a roughly constant step (`coupling`) from the playback level; that
/// step is learnt from the last couple of seconds of Benji's voice, high in their spread (the
/// upper quartile: a louder room or a turned-up volume is learnt within half a second, at the cost
/// of absorbing a user who talks on over Benji's voice). In Benji's pauses the room's noise
/// floor is what's explained, so the user is heard best there.
public struct SpeechGate: Equatable, Sendable {
    /// Above what Benji's voice explains by this much (≈7.5 dB on the meter's 50 dB scale) is
    /// someone else's voice.
    public static let voiceMargin: Float = 0.15
    /// This much voice in the last `window` opens the gate.
    public static let minimumVoice: TimeInterval = 0.3
    public static let window: TimeInterval = 2.0
    /// Frames of Benji's playback needed before its level in the mic is known; until then nothing
    /// heard over its voice counts.
    public static let warmUpFrames = 12
    /// Playback below this is a pause in Benji's voice.
    static let playing: Float = 0.05
    static let couplingFrames = 40
    static let floorRise: Float = 0.004

    /// Recent mic-minus-playback steps while Benji's voice played.
    public private(set) var steps: [Float] = []
    public private(set) var noiseFloor: Float = 0.15
    /// Spells of voice in the last `window`, as (start, end).
    public private(set) var voiced: [VoiceSpell] = []

    public struct VoiceSpell: Equatable, Sendable {
        public let start: Double
        public let end: Double
    }

    public init() {}

    /// The learnt step from the playback level to Benji's voice in the mic; nil until warmed up.
    public var coupling: Float? {
        guard steps.count >= Self.warmUpFrames else { return nil }
        let sorted = steps.sorted()
        return sorted[sorted.count * 3 / 4]
    }

    /// One mic buffer: its level, Benji's playback level then (`PlaybackEnvelope.level`), and how
    /// long it lasted, ending at `time`.
    public mutating func mic(_ level: Float, playback: Float, duration: Double, at time: Double) {
        let explained: Float?
        if playback >= Self.playing {
            steps.append(level - playback)
            if steps.count > Self.couplingFrames { steps.removeFirst(steps.count - Self.couplingFrames) }
            explained = coupling.map { max(noiseFloor, playback + $0) }
        } else {
            if level < noiseFloor { noiseFloor = level } else { noiseFloor += (level - noiseFloor) * Self.floorRise }
            explained = noiseFloor
        }
        if let explained, level > explained + Self.voiceMargin {
            let start = time - max(duration, 0)
            if let last = voiced.last, start - last.end < 0.12 {
                voiced[voiced.count - 1] = VoiceSpell(start: last.start, end: time)
            } else {
                voiced.append(VoiceSpell(start: start, end: time))
            }
        }
        voiced.removeAll { $0.end < time - Self.window }
    }

    /// Seconds of voice in the last `window` before `time`.
    public func voice(at time: Double) -> Double {
        voiced.reduce(0) { sum, s in sum + max(0, s.end - max(s.start, time - Self.window)) }
    }

    public func isOpen(at time: Double) -> Bool { voice(at: time) >= Self.minimumVoice - 1e-9 }

    /// When the user started talking, as far as the level says: the start of the first spell in
    /// the window (nil: none heard).
    public func voiceStarted(at time: Double) -> Double? {
        voiced.first { $0.end >= time - Self.window }?.start
    }
}

/// The interrupt decision on the guarded path: stricter than `EchoGuard.interrupts`, since the
/// recogniser hears Benji's voice through the speakers and can mishear it as other words.
public enum GuardedTalkOver {
    /// Words of the user's own needed, unless one is an interrupt word or Benji's name.
    public static let minimumWords = 3
    /// Short words a misheard answer rarely turns into ("no" and "hey" do, so they're left out).
    static let interruptWords: Set<String> = ["stop", "wait", "hold", "pause", "enough", "quiet"]

    public static func interrupts(heard: String, spoken: String, voiceOpen: Bool) -> Bool {
        guard voiceOpen else { return false }
        let own = EchoGuard.userWords(heard: heard, spoken: spoken)
        return own.count >= minimumWords
            || own.contains { interruptWords.contains($0) || StopPhrases.names.contains($0) }
    }
}

/// Right after Benji stops, the mic can still catch its last words: the room's echo, or the
/// recogniser finishing a word. Words at the start of an utterance that begins this soon after
/// Benji stopped, and that Benji had just said, are its own and are dropped.
public enum SettleWindow {
    public static let duration: TimeInterval = 0.6
    /// How far back in Benji's answer to look for those words.
    static let tailWords = 12

    public static func strip(_ heard: String, spoken: String, firstWordAt: Double, speechEndedAt: Double?) -> String {
        guard let ended = speechEndedAt, firstWordAt - ended <= duration else { return heard }
        let tail = Set(SpokenWords(spoken).words.suffix(tailWords))
        let words = SpokenWords(heard)
        guard let k = words.words.indices.first(where: { !EchoGuard.isEcho(words.words[$0], tail) }) else { return "" }
        return String(heard[words.ranges[k].lowerBound...])
    }
}
