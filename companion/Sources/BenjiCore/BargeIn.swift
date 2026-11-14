import Foundation

// Talking over Benji to interrupt it (barge-in). In a conversation the mic may stay open while
// Benji speaks; as soon as it hears words that aren't Benji's own, the speech stops and what
// the user says becomes the next message. Pure decisions only; the app owns the mic and the voice.

/// Settings › Voice › "Talk over Benji to interrupt".
public enum BargeInMode: String, CaseIterable, Sendable {
    /// The mic stays shut while Benji speaks (the behaviour before barge-in).
    case off
    /// Only while the sound goes to headphones, where the mic can't hear Benji.
    case headphones
    /// On speakers too: Benji's voice and the mic share one audio engine with the Mac's echo
    /// cancellation, and words that match what Benji is saying are never taken as the user's.
    /// Where echo cancelling won't start, the plain mic listens, guarded (`TalkOverPath.guarded`).
    case always

    public static let defaultsKey = "bargeIn"

    /// The stored setting; headphones unless set (speakers need a live check first).
    public static func from(_ raw: Any?) -> BargeInMode {
        (raw as? String).flatMap(BargeInMode.init(rawValue:)) ?? .headphones
    }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .headphones: return "Headphones"
        case .always: return "Always"
        }
    }

    /// What the choice does, under it on the settings page.
    public var caption: String {
        switch self {
        case .off: return "Benji finishes its answer before it listens. Tap Right ⌥ to stop it sooner."
        case .headphones: return "While the sound is in your ears, start talking and Benji stops to listen."
        case .always: return "On speakers too: with the Mac's echo cancelling where it starts, otherwise by listening for clear words that aren't Benji's own."
        }
    }

    /// Whether the mic may listen while Benji speaks out of `route`.
    public func allows(_ route: OutputRoute) -> Bool {
        switch self {
        case .off: return false
        case .headphones: return route == .headphones
        case .always: return true
        }
    }

    /// Whether Benji's own voice has to be cancelled from the mic (it can reach it).
    public func needsEchoCancellation(_ route: OutputRoute) -> Bool {
        self == .always && route != .headphones
    }

    /// The mode the audio engines follow (D-119): Always acts like Headphones on a route where the
    /// Mac's echo cancellation is known not to start, so neither Benji's voice nor the mic opens
    /// on an engine that fails. Whether the mic still listens over Benji's voice there is
    /// `TalkOverPath` (D-122: on the plain mic, guarded).
    public func effective(route: OutputRoute, echoUnavailable: Bool) -> BargeInMode {
        self == .always && echoUnavailable && route != .headphones ? .headphones : self
    }

    /// The settings page's line when the Mac's echo cancelling won't start on these speakers (D-122).
    public static let echoUnavailableCaption =
        "The Mac's echo cancelling didn't start on these speakers, so Benji listens over its own voice without it and stops only for clear words that aren't its own. It may miss a quiet interruption: speak up, or tap the talk key. Headphones work best."

    /// Said once, on the status line, when Benji finds out.
    public static let echoUnavailableNotice =
        "Echo cancelling didn't start on these speakers. You can still talk over Benji: speak up, or tap the talk key."
}

/// Where the Mac's echo cancellation failed to start (D-119), so Benji stops trying it on every
/// turn: one failed start is remembered per audio setup (output route and input device) for
/// `retryAfter`, or until the user picks Always again. Stored in user defaults as
/// `[setup: seconds since 1970]`; holds device names only.
public struct EchoVerdicts: Equatable, Sendable {
    public static let defaultsKey = "echoCancellationFailures"
    public static let retryAfter: Double = 7 * 24 * 3600

    public private(set) var failures: [String: Double]

    public init(stored: Any?) {
        failures = (stored as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.doubleValue } ?? [:]
    }

    /// What goes back into user defaults.
    public var stored: [String: Double] { failures }

    public static func key(route: OutputRoute, input: String?) -> String {
        let device = (input ?? "").trimmingCharacters(in: .whitespaces)
        return "\(route)|\(device.isEmpty ? "default input" : device)"
    }

    public func isKnownBad(_ key: String, now: Double) -> Bool {
        guard let at = failures[key] else { return false }
        return now - at < Self.retryAfter
    }

    /// True when this is news (the setup wasn't already known bad).
    @discardableResult
    public mutating func recordFailure(_ key: String, now: Double) -> Bool {
        let news = !isKnownBad(key, now: now)
        failures[key] = now
        return news
    }

    /// The user chose Always again: try every setup afresh.
    public mutating func clearAll() { failures = [:] }
}

extension OutputRoute {
    /// Words in a Bluetooth or USB output's name that mean it sits on the ears.
    static let headphoneNames = ["airpods", "headphone", "headset", "earbud", "earphone", "buds", "beats",
                                 "wh-1000", "quietcomfort", "earpods"]

    /// Like `from(builtIn:dataSource:)`, and an external output whose name says headphones
    /// ("Umar's AirPods Pro", "WH-1000XM5") counts as headphones too. Any other external output
    /// stays `unknown` (treated as speakers).
    public static func classify(builtIn: Bool, dataSource: UInt32?, name: String?) -> OutputRoute {
        if builtIn { return from(builtIn: true, dataSource: dataSource) }
        let lower = (name ?? "").lowercased()
        return headphoneNames.contains { lower.contains($0) } ? .headphones : .unknown
    }
}

/// Tells the user's words from Benji's own voice coming back through the mic. The recogniser
/// can't say whose voice it hears, but Benji knows exactly what it is saying: a heard word that
/// is in that text (or one letter off it) is taken as echo.
public enum EchoGuard {
    /// Two words of the user's own interrupt; one is enough if it is one of these.
    public static let minimumWords = 2
    static let interruptWords: Set<String> = ["stop", "wait", "hold", "pause", "enough", "quiet", "sorry",
                                              "hey", "no", "nope", "actually"]

    /// The heard words Benji's `spoken` text doesn't explain, in order, without hesitations.
    public static func userWords(heard: String, spoken: String) -> [String] {
        let said = Set(SpokenWords(spoken).words)
        return SpokenWords(heard).words.filter { word in
            !SpokenNoise.fillers.contains(word) && !isEcho(word, said)
        }
    }

    /// The user is talking over Benji: enough words of their own, or one interrupt word
    /// (including Benji's name).
    public static func interrupts(heard: String, spoken: String) -> Bool {
        let own = userWords(heard: heard, spoken: spoken)
        return own.count >= minimumWords
            || own.contains { interruptWords.contains($0) || StopPhrases.names.contains($0) }
    }

    static func isEcho(_ word: String, _ said: Set<String>) -> Bool {
        if said.contains(word) { return true }
        guard word.count >= 4 else { return false }
        return said.contains { abs($0.count - word.count) <= 1 && $0.count >= 4 && oneEditApart($0, word) }
    }

    /// True when `a` becomes `b` with at most one letter changed, added or removed.
    static func oneEditApart(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        if x == y { return true }
        if x.count == y.count { return zip(x, y).filter { $0 != $1 }.count <= 1 }
        let (long, short) = x.count > y.count ? (x, y) : (y, x)
        guard long.count - short.count == 1 else { return false }
        var i = 0, j = 0, skipped = false
        while i < long.count, j < short.count {
            if long[i] == short[j] { i += 1; j += 1; continue }
            if skipped { return false }
            skipped = true
            i += 1
        }
        return true
    }
}

/// Which audio engine the mic opens on. One per conversation: while the voice may need echo
/// cancelling (Always mode, sound not in headphones), every utterance of the conversation opens
/// on the echo-cancelling engine, whether Benji is speaking or not. Two engines taking turns on
/// one mic, one with voice processing and one without, failed to start (-10875,
/// kAudioUnitErr_FailedInitialization) in the user's live round. Push-to-talk stays on the plain
/// engine.
public enum MicEngine: String, Equatable, Sendable {
    case plain
    case echoCancelling

    public static func choose(mode: BargeInMode, route: OutputRoute, handsFreeOn: Bool,
                              handsFreeAvailable: Bool) -> MicEngine {
        handsFreeOn && handsFreeAvailable && mode.needsEchoCancellation(route) ? .echoCancelling : .plain
    }

    /// The engine to try once when this one fails to start.
    public var other: MicEngine { self == .plain ? .echoCancelling : .plain }

    /// "Couldn't start recording" with what the system said, and what to try.
    public static func failureMessage(code: Int, description: String, triedBoth: Bool) -> String {
        let tried = triedBoth ? " (tried both microphone paths)" : ""
        return "Couldn't start recording\(tried): \(description) (error \(code)). "
            + "Try Settings › Voice › Talk over Benji → Headphones."
    }
}

/// `~/.benji/voice.log`: the voice controller's trace lines (states, formats, engines, error
/// codes), so a failure in a live round can be read afterwards. Never words that were heard, never
/// audio. Rotated to `voice.log.1` past `maximumBytes`.
public enum VoiceLog {
    public static let maximumBytes = 200 * 1024
    public static let fileName = "voice.log"
    public static let previousFileName = "voice.log.1"

    public static func shouldRotate(currentSize: Int, adding: Int) -> Bool {
        currentSize > 0 && currentSize + adding > maximumBytes
    }

    /// One line: a local timestamp, then the trace text with any line breaks flattened.
    public static func line(_ text: String, at date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return "\(f.string(from: date)) [ptt] \(flat)\n"
    }
}
