import Foundation

// Hands-free conversation: once it's on, Benji listens, sends when the user pauses,
// answers, and listens again for the follow-up, with no key presses between turns.
// Pure decisions only (timing, turn-taking, stop phrases, noise); the app owns the mic.

// MARK: - Settings

/// The user's hands-free settings (`defaults write com.emerssive.heybenji.app …`), clamped to sane ranges.
public struct HandsFreeSettings: Equatable, Sendable {
    /// A tap of the talk key (or a click on the mic) starts a conversation. Off: a tap listens
    /// for one message, tap again to send. A hold is always one message.
    public var startsOnTap: Bool
    /// Silence after the last word before the message is sent (`handsFreeEndSilence`).
    public var endSilence: TimeInterval
    /// The conversation ends after this long listening with nothing said (`handsFreeIdleTimeout`).
    public var idleTimeout: TimeInterval

    public static let endSilenceDefault: TimeInterval = 1.0
    public static let endSilenceRange: ClosedRange<TimeInterval> = 0.5...3.0
    /// Two quiet minutes end listening: 60 s ended a conversation while the user was still
    /// reading, 300 s left the mic on too long.
    public static let idleTimeoutDefault: TimeInterval = 120
    public static let idleTimeoutRange: ClosedRange<TimeInterval> = 10...3600
    /// The quiet-spell choices Settings › Voice offers ("Stop listening after quiet"), in seconds.
    public static let idleTimeoutChoices: [TimeInterval] = [60, 120, 300, 900, 1800]

    /// Extra silence after a word that promises more ("and", "because", "um", a trailing comma).
    public static let continuationExtra: TimeInterval = 1.2
    /// Never wait longer than this for the end of a sentence, whatever the cue.
    public static let maximumSilence: TimeInterval = 3.5
    /// One message is sent after this long even if the user never pauses.
    public static let maximumUtterance: TimeInterval = 120
    /// The mic reopens this long after Benji stops talking, so the speaker's tail isn't heard.
    public static let resumeDelay: TimeInterval = 0.35
    /// A question from the user is a clear end of turn: it is sent after this share of
    /// `endSilence`, never below `questionSilenceFloor` (unless `endSilence` is lower).
    public static let questionSilenceShare: TimeInterval = 0.75
    public static let questionSilenceFloor: TimeInterval = 0.6
    /// Extra silence allowed while the user answers a question Benji asked (a quiz, a check
    /// that they followed): they may stop to think mid-answer.
    public static let answerPatience: TimeInterval = 0.8

    public init(startsOnTap: Bool = true,
                endSilence: TimeInterval = HandsFreeSettings.endSilenceDefault,
                idleTimeout: TimeInterval = HandsFreeSettings.idleTimeoutDefault) {
        self.startsOnTap = startsOnTap
        self.endSilence = Self.clamp(endSilence, Self.endSilenceRange)
        self.idleTimeout = Self.clamp(idleTimeout, Self.idleTimeoutRange)
    }

    /// From raw defaults values (Bool/NSNumber/String), so a typo never breaks voice.
    public static func from(handsFree: Any?, endSilence: Any?, idleTimeout: Any?) -> HandsFreeSettings {
        HandsFreeSettings(startsOnTap: bool(handsFree) ?? true,
                          endSilence: number(endSilence) ?? endSilenceDefault,
                          idleTimeout: number(idleTimeout) ?? idleTimeoutDefault)
    }

    private static func clamp(_ v: TimeInterval, _ r: ClosedRange<TimeInterval>) -> TimeInterval {
        v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : r.lowerBound
    }

    private static func bool(_ v: Any?) -> Bool? {
        switch v {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String:
            switch s.lowercased() {
            case "1", "on", "yes", "true": return true
            case "0", "off", "no", "false": return false
            default: return nil
            }
        default: return nil
        }
    }

    private static func number(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }
}

// MARK: - Words

/// Lower-case word tokens with their ranges in the original text, so a phrase found in the
/// tokens can be cut out of the original with its punctuation intact.
struct SpokenWords {
    let text: String
    let words: [String]
    let ranges: [Range<String.Index>]

    init(_ text: String) {
        self.text = text
        var words: [String] = [], ranges: [Range<String.Index>] = []
        var start: String.Index?
        var i = text.startIndex
        func close(_ end: String.Index) {
            guard let s = start else { return }
            // Apostrophes join a word ("that's") but are dropped from the token ("thats").
            let token = text[s..<end].lowercased().filter { $0 != "'" && $0 != "’" }
            if !token.isEmpty { words.append(token); ranges.append(s..<end) }
            start = nil
        }
        while i < text.endIndex {
            let c = text[i]
            if c.isLetter || c.isNumber || ((c == "'" || c == "’") && start != nil) {
                if start == nil { start = i }
            } else {
                close(i)
            }
            i = text.index(after: i)
        }
        close(text.endIndex)
        self.words = words
        self.ranges = ranges
    }
}

// MARK: - Noise

/// Empty or noise-only transcripts are dropped silently in a conversation.
public enum SpokenNoise {
    /// Hesitation sounds the recogniser writes down when nobody said anything meant.
    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "hmm", "hm", "mm", "mmm", "mhm",
                                       "ah", "ahh", "oh", "er", "erm", "eh", "huh"]

    /// True when the transcript carries at least one real word: not only hesitations, and not a
    /// lone letter. "Yes", "OK" and "no" count (they answer Benji's questions).
    public static func isMeaningful(_ text: String) -> Bool {
        SpokenWords(text).words.contains { word in
            !fillers.contains(word) && (word.count >= 2 || word.first?.isNumber == true)
        }
    }
}

// MARK: - Stop phrases

/// "That's all", "stop listening", "thanks Benji": ends the conversation. Matched on-device,
/// in the words of one finished utterance, only at its end or as the whole utterance (with
/// filler like "okay" or "thanks" around it), never in the middle.
public enum StopPhrases {
    public enum Match: Equatable, Sendable {
        /// Not a stop: send the text as it is.
        case none
        /// The utterance is only a stop: end now, send nothing.
        case stopOnly
        /// A request followed by a stop ("open Mail, that's all"): send `request`, then end
        /// after the reply.
        case trailing(request: String)
    }

    /// What the recogniser writes for "Benji".
    static let names: [String] = ["benji", "benjy", "benjie", "benjee"]

    static let phrases: [[String]] = {
        var p: [[String]] = [
            ["thats", "all"], ["that", "is", "all"], ["thatll", "be", "all"], ["that", "will", "be", "all"],
            ["stop", "listening"], ["end", "conversation"], ["end", "the", "conversation"],
            ["stop", "conversation"], ["stop", "the", "conversation"],
        ]
        for name in names {
            p += [["thanks", name], ["thank", "you", name], ["bye", name], ["goodbye", name]]
        }
        return p + wholeOnly
    }()

    /// Ordinary sentences end with these ("tell me when we're done"), so they stop the
    /// conversation only as the whole utterance.
    static let wholeOnly: [[String]] = [["were", "done"], ["we", "are", "done"], ["im", "done"], ["i", "am", "done"]]

    /// Addressed to Benji, or about listening itself: a stop even right after a request.
    /// Other phrases ("that's all") need a pause mark before them to end a request
    /// ("Open Mail, that's all." but not "check if that's all").
    static func isStrong(_ phrase: [String]) -> Bool {
        phrase.contains { names.contains($0) } || phrase.contains("listening") || phrase.contains("conversation")
    }

    /// Words that may sit around a stop phrase without making the utterance a request.
    static let filler: Set<String> = {
        var f: Set<String> = ["okay", "ok", "alright", "all", "right", "great", "cool", "perfect", "nice",
                              "so", "well", "yeah", "yep", "yes", "no", "please", "then", "now", "for",
                              "hey", "thanks", "thank", "you", "very", "much", "bye", "goodbye", "good",
                              "awesome", "and"]
        f.formUnion(names)
        f.formUnion(SpokenNoise.fillers)
        return f
    }()

    public static func match(_ text: String) -> Match {
        let spoken = SpokenWords(text)
        let w = spoken.words
        guard !w.isEmpty else { return .none }

        // Peel stop phrases and filler off the end.
        var end = w.count
        var last: [String]?   // the earliest stop phrase peeled, nearest the request
        var cut = end         // its first word
        while end > 0 {
            if let p = phrases.first(where: { $0.count <= end && Array(w[(end - $0.count)..<end]) == $0 }) {
                end -= p.count
                last = p
                cut = end
            } else if filler.contains(w[end - 1]) {
                end -= 1
            } else {
                break
            }
        }
        guard let phrase = last else { return .none }
        if end == 0 { return .stopOnly }
        if wholeOnly.contains(phrase) { return .none }

        // Leave the filler before the phrase with the request ("open Mail, okay, that's all" keeps
        // "open Mail, okay"), then trim trailing punctuation.
        let head = String(text[..<spoken.ranges[cut].lowerBound])
        let request = head.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard SpokenNoise.isMeaningful(request) else { return .stopOnly }
        let paused = head.reversed().prefix { !$0.isLetter && !$0.isNumber }.contains { ",.;:!?-–—…".contains($0) }
        guard isStrong(phrase) || paused else { return .none }
        return .trailing(request: request)
    }
}

// MARK: - End of utterance

/// Decides when the user has finished a sentence, from the recogniser's words and the mic
/// level. The message ends after `endSilence` with no new words and no voice; a word that
/// promises more (a conjunction, "um", a trailing comma) earns extra time, a finished question
/// a little less; while the user answers Benji's own question (`patience`) it waits longer; the
/// sentence is never ended before anything has been heard.
public struct UtteranceEndpointer: Sendable {
    public let endSilence: TimeInterval
    /// Extra silence for this utterance (`TurnPatience.after`), never past `maximumSilence`.
    public let patience: TimeInterval
    public private(set) var text = ""
    private var firstSpeech: TimeInterval?
    private var lastActivity: TimeInterval?
    /// Running estimate of the room's level (0…1 meter scale), so steady noise isn't voice.
    private(set) var noiseFloor: Float = 0.15

    /// Above the noise floor by this much (≈7.5 dB on the meter's 50 dB scale) counts as voice.
    static let voiceMargin: Float = 0.15
    /// How fast the floor rises toward a louder room, per buffer (falls at once).
    static let floorRise: Float = 0.004

    static let continuationWords: Set<String> = [
        "and", "or", "but", "so", "because", "cause", "then", "if", "when", "while", "that", "which",
        "who", "the", "a", "an", "to", "of", "for", "with", "in", "on", "at", "from", "into", "about",
        "my", "your", "our", "their", "this", "is", "are", "was", "like", "also", "plus", "than",
    ]

    public init(endSilence: TimeInterval, patience: TimeInterval = 0) {
        self.endSilence = endSilence
        self.patience = max(0, patience)
    }

    public var hasSpeech: Bool { firstSpeech != nil }

    /// Every mic buffer's level (`MicLevel.normalized`). Voice keeps the sentence open, but only
    /// once words have been heard: a noisy room alone never sends anything.
    public mutating func level(_ level: Float, at time: TimeInterval) {
        if level < noiseFloor {
            noiseFloor = level
        } else {
            noiseFloor += (level - noiseFloor) * Self.floorRise
        }
        if level > noiseFloor + Self.voiceMargin, firstSpeech != nil {
            lastActivity = time
        }
    }

    /// The recogniser's running transcript. A change with real words is activity.
    public mutating func transcript(_ new: String, at time: TimeInterval) {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != text else { return }
        text = trimmed
        guard !trimmed.isEmpty else { return }
        if firstSpeech == nil { firstSpeech = time }
        lastActivity = time
    }

    /// The silence the current words call for.
    public var silenceNeeded: TimeInterval {
        let t = text.trimmingCharacters(in: .whitespaces)
        let longer = min(endSilence + HandsFreeSettings.continuationExtra + patience, HandsFreeSettings.maximumSilence)
        if let last = t.last, ",;:-–—…".contains(last) || t.hasSuffix("...") { return longer }
        let words = SpokenWords(t).words
        if let word = words.last, !".?!".contains(t.last ?? " "),
           Self.continuationWords.contains(word) || SpokenNoise.fillers.contains(word) {
            return longer
        }
        if t.hasSuffix("?"), words.count >= Self.questionWords {
            let share = endSilence * HandsFreeSettings.questionSilenceShare
            return min(endSilence, max(share, HandsFreeSettings.questionSilenceFloor))
        }
        return min(endSilence + patience, max(endSilence, HandsFreeSettings.maximumSilence))
    }

    /// A question this short ("what?", "really?") may be the start of a longer one.
    static let questionWords = 3

    /// True once the user has stopped: words were heard and the silence since is long enough,
    /// or the utterance has run past `maximumUtterance`.
    public func shouldEnd(at time: TimeInterval) -> Bool {
        guard let first = firstSpeech, let last = lastActivity, !text.isEmpty else { return false }
        if time - first >= HandsFreeSettings.maximumUtterance { return true }
        return time - last >= silenceNeeded - 1e-9
    }
}

// MARK: - Turn-taking

/// What the app is doing, as far as turn-taking cares.
public struct HandsFreeSnapshot: Equatable, Sendable {
    public var phase: CompanionPhase
    public var approvalPending: Bool
    public var screenCardPending: Bool
    /// An answer has been handed to the voice and hasn't started or finished playing yet.
    public var speechPending: Bool
    /// The mic may listen while Benji speaks (`BargeInMode.allows` for where the sound goes).
    public var bargeIn: Bool

    public init(phase: CompanionPhase = .idle, approvalPending: Bool = false,
                screenCardPending: Bool = false, speechPending: Bool = false, bargeIn: Bool = false) {
        self.phase = phase
        self.approvalPending = approvalPending
        self.screenCardPending = screenCardPending
        self.speechPending = speechPending
        self.bargeIn = bargeIn
    }

    /// Benji is saying, or about to say, an answer.
    public var overSpeech: Bool { speechPending || phase == .speaking }

    /// Benji may have the mic open: nothing is running, no card waits for a click, and Benji
    /// isn't speaking or about to speak, unless barge-in lets the user talk over it.
    /// (`.listening` is the conversation's own mic.)
    public var mayListen: Bool {
        guard !approvalPending, !screenCardPending else { return false }
        if overSpeech {
            guard bargeIn else { return false }
            return phase == .speaking || phase == .idle || phase == .listening
        }
        switch phase {
        case .idle, .error, .listening: return true
        case .transcribing, .thinking, .speaking, .awaitingApproval: return false
        }
    }
}

public enum HandsFreeEndReason: String, Equatable, Sendable {
    case user           // the Conversation control, or a tap with nothing said
    case escape
    case stopPhrase
    case timeout        // a quiet spell with nothing said
    case locked         // screen locked, session switched
    case sleep
    case panelClosed
    case cancelled      // Cancel, Adjust, or an unanswered screen card
    case micUnavailable

    /// The one line shown in the status line when listening ends (nil: say nothing). Never a
    /// transcript row: the transcript is only the conversation.
    public var notice: String? {
        switch self {
        case .timeout: return "Stopped listening after a quiet spell."
        case .micUnavailable: return nil   // the voice error says why
        case .panelClosed: return nil      // the panel is gone; nothing to read it on
        default: return "Stopped listening."
        }
    }
}

/// Why a finished utterance was heard but not sent.
public enum HandsFreeHoldReason: Equatable, Sendable {
    /// Another app played sound out loud while it was heard: those words may not be the user's.
    case otherAppAudio

    /// The status line, saying what didn't happen and what to do instead.
    public var notice: String {
        switch self {
        case .otherAppAudio:
            return "Not sent: another app was playing sound. Your words are in the box: Return sends them, or hold the talk key."
        }
    }
}

/// Where the Mac's sound comes out, as far as the mic is concerned.
public enum OutputRoute: Equatable, Sendable {
    case speakers, headphones, unknown

    /// Core Audio's data source codes for the built-in output.
    public static let builtInSpeakerSource: UInt32 = 0x6973_706B   // 'ispk'
    public static let builtInHeadphoneSource: UInt32 = 0x6864_706E // 'hdpn'

    /// Only the built-in output says which it is. Bluetooth, USB, HDMI and AirPlay outputs can be
    /// speakers or headphones, so they are `unknown`, and treated as audible.
    public static func from(builtIn: Bool, dataSource: UInt32?) -> OutputRoute {
        guard builtIn, let dataSource else { return .unknown }
        switch dataSource {
        case builtInHeadphoneSource: return .headphones
        case builtInSpeakerSource: return .speakers
        default: return .unknown
        }
    }
}

/// Another app's sound reaching the mic. The recogniser can't tell whose voice it hears (another
/// assistant's spoken answer would be sent as the user's words), so the conversation holds back
/// an utterance heard while another app played sound that the mic could pick up. `playing` nil
/// (the Mac couldn't say) holds nothing back.
public enum OtherAppAudio {
    public static func audible(playing: Bool?, route: OutputRoute) -> Bool {
        playing == true && route != .headphones
    }
}

/// Settings › Voice › "Hold back words heard over other apps' sound". Off by default: off, a
/// conversation sends what it heard; on, an utterance heard while another app plays out loud is
/// held back and the status line says why.
public enum OtherAppAudioGuard {
    public static let defaultsKey = "holdBackOverOtherAppAudio"

    /// The stored setting: off unless it was explicitly turned on.
    public static func isOn(from raw: Any?) -> Bool {
        (raw as? Bool) ?? false
    }
}

public enum HandsFreeAction: Equatable, Sendable {
    /// Open the mic and start a fresh utterance.
    case openMic
    /// Close the mic and drop what was heard (a card arrived, or the conversation ended).
    case closeMic
    /// Send this finished utterance to the engine, as text.
    case submit(String)
    /// The conversation is over.
    case ended(HandsFreeEndReason)
    /// Words were heard but not sent; listening goes on.
    case heldBack(HandsFreeHoldReason)
}

/// The conversation's turn-taking. The app feeds it its state, the mic's real
/// events and a clock tick; it answers with what to do with the mic. The mic is open only while
/// the conversation is on and `HandsFreeSnapshot.mayListen`: never while Benji works, speaks or
/// waits on an approval or the screen card (voice never answers those).
public struct HandsFreeSession: Sendable {
    /// Changeable mid-conversation (Settings' "Stop listening after quiet"); applies from the next tick.
    public var settings: HandsFreeSettings
    public private(set) var isOn = false
    /// The session asked for the mic and hasn't been told it closed.
    public private(set) var micOpen = false
    public private(set) var snapshot = HandsFreeSnapshot()
    /// A stop phrase came after a request: end once the reply is over.
    public private(set) var endAfterReply = false
    /// When the mic may reopen (Benji finished; the resume delay is running).
    private var resumeAt: TimeInterval?
    /// Listening with nothing said since then.
    private var quietSince: TimeInterval?
    /// A noise-only utterance doesn't restart the quiet spell: carried to the next opening.
    private var carriedQuiet: TimeInterval?
    /// `quietSince` as it stood before this utterance's first words: words that end up held
    /// back as another app's audio put the quiet spell back to this, not to the time they were heard.
    private var quietBeforeSpeech: TimeInterval?
    /// Another app was heard playing out loud while this utterance's mic was open.
    public private(set) var otherAudioDuringUtterance = false
    /// The endpointer fired and the final words are being taken (Transcribing): `utteranceFinished`
    /// is still to come. Ending the conversation meanwhile waits for it (`endWhenFinished`).
    public private(set) var utterancePending = false
    /// The conversation was ended while an utterance was pending: the words are still sent as the
    /// turn, and only then does the conversation end.
    private var endWhenFinished: HandsFreeEndReason?

    public init(settings: HandsFreeSettings) {
        self.settings = settings
    }

    /// The user turned the conversation on. Opens the mic now if Benji is free, otherwise as
    /// soon as it is.
    public mutating func start(at time: TimeInterval) -> [HandsFreeAction] {
        guard !isOn else { return [] }
        isOn = true
        utterancePending = false
        endWhenFinished = nil
        endAfterReply = false
        resumeAt = snapshot.mayListen ? time : nil
        return tick(at: time)
    }

    /// The conversation started with the mic already open (a tap that began recording).
    public mutating func adoptOpenMic(at time: TimeInterval) {
        isOn = true
        utterancePending = false
        endWhenFinished = nil
        endAfterReply = false
        micOpen = true
        resumeAt = nil
        quietSince = time
        quietBeforeSpeech = nil
        otherAudioDuringUtterance = false
    }

    /// Ends the conversation. While an utterance is being finalised, every reason but a deliberate
    /// cancel (`cancelled`, `micUnavailable`) waits for it: the words heard are sent as the turn
    /// (`utteranceFinished`), then the conversation ends.
    public mutating func stop(_ reason: HandsFreeEndReason) -> [HandsFreeAction] {
        guard isOn else { return [] }
        if utterancePending, reason != .cancelled, reason != .micUnavailable {
            endWhenFinished = endWhenFinished ?? reason
            return []
        }
        utterancePending = false
        endWhenFinished = nil
        isOn = false
        endAfterReply = false
        resumeAt = nil
        quietSince = nil
        carriedQuiet = nil
        let close: [HandsFreeAction] = micOpen ? [.closeMic] : []
        micOpen = false
        return close + [.ended(reason)]
    }

    /// The app's state changed.
    public mutating func update(_ new: HandsFreeSnapshot, at time: TimeInterval) -> [HandsFreeAction] {
        let wasFree = snapshot.mayListen
        snapshot = new
        guard isOn else { return [] }
        if !new.mayListen {
            resumeAt = nil
            if micOpen {
                micOpen = false
                quietSince = nil
                return [.closeMic]
            }
            return []
        }
        if micOpen { return [] }
        if endAfterReply { return stop(.stopPhrase) }
        // Just became free (the answer ended): give the speaker's tail a moment to die away.
        if !wasFree || resumeAt == nil { resumeAt = time + HandsFreeSettings.resumeDelay }
        return tick(at: time)
    }

    /// The user stopped Benji to talk (the talk key or the mic while it spoke): listen at once,
    /// without the resume delay, and forget a pending "end after this reply" (they want to talk).
    public mutating func listenNow(_ new: HandsFreeSnapshot, at time: TimeInterval) -> [HandsFreeAction] {
        snapshot = new
        endAfterReply = false
        guard isOn, !micOpen, new.mayListen else { return [] }
        resumeAt = time
        return tick(at: time)
    }

    /// The mic closed by itself (recognition failed, the engine stopped). Reopens on the next tick.
    public mutating func micClosed(at time: TimeInterval) {
        if utterancePending {   // the words being finalised were dropped on purpose (Stop, a typed message)
            utterancePending = false
            if let reason = endWhenFinished { endWhenFinished = nil; _ = stop(reason); return }
            if isOn && snapshot.mayListen { resumeAt = time + HandsFreeSettings.resumeDelay }
            return
        }
        guard micOpen else { return }
        micOpen = false
        if isOn && snapshot.mayListen { resumeAt = time + HandsFreeSettings.resumeDelay }
    }

    /// The user paused and the app closed the mic to take the final words. Nothing reopens until
    /// `utteranceFinished` says what they were.
    public mutating func utteranceEnding() {
        utterancePending = true
        micOpen = false
        resumeAt = nil
    }

    /// Whether another app is playing sound the mic could pick up (`OtherAppAudio.audible`). Sampled
    /// while the mic is open and once more as the utterance ends; one audible sample holds it back.
    public mutating func otherAppAudio(_ audible: Bool) {
        if audible && isOn { otherAudioDuringUtterance = true }   // cleared each time the mic opens
    }

    /// The recogniser heard words: the quiet spell starts again.
    public mutating func heardSpeech(at time: TimeInterval) {
        guard micOpen else { return }
        if quietBeforeSpeech == nil { quietBeforeSpeech = quietSince ?? time }
        quietSince = time
    }

    /// One utterance is finished (the endpointer fired and the mic is closed). Sends it, drops it
    /// as noise and listens again, or ends the conversation on a stop phrase. Words heard while
    /// another app played out loud are never sent (a stop phrase still ends listening: that is
    /// safe whoever said it); listening goes on.
    public mutating func utteranceFinished(_ text: String, at time: TimeInterval) -> [HandsFreeAction] {
        micOpen = false
        let otherAudio = otherAudioDuringUtterance
        otherAudioDuringUtterance = false
        utterancePending = false
        guard isOn else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reason = endWhenFinished {
            // Ended while the words were being finalised: send them, then end. Nothing reopens.
            endWhenFinished = nil
            var actions: [HandsFreeAction] = []
            if SpokenNoise.isMeaningful(trimmed) {
                switch StopPhrases.match(trimmed) {
                case .stopOnly: break
                case .trailing(let request):
                    if !otherAudio { actions = [.submit(request)] } else { actions = [.heldBack(.otherAppAudio)] }
                case .none:
                    actions = otherAudio ? [.heldBack(.otherAppAudio)] : [.submit(trimmed)]
                }
            }
            return actions + stop(reason)
        }
        guard SpokenNoise.isMeaningful(trimmed) else {
            // Silently listen again, without restarting the quiet spell.
            carriedQuiet = quietSince
            quietSince = nil
            resumeAt = time
            return tick(at: time)
        }
        let before = quietBeforeSpeech
        quietSince = nil
        carriedQuiet = nil
        quietBeforeSpeech = nil
        let match = StopPhrases.match(trimmed)
        if otherAudio, match != .stopOnly {
            // Not a request: the quiet spell keeps running from before these words, as for noise.
            carriedQuiet = before
            resumeAt = time
            return [.heldBack(.otherAppAudio)] + tick(at: time)
        }
        switch match {
        case .stopOnly:
            return stop(.stopPhrase)
        case .trailing(let request):
            endAfterReply = true
            return [.submit(request)]
        case .none:
            return [.submit(trimmed)]
        }
    }

    /// Call a few times a second while the conversation is on.
    public mutating func tick(at time: TimeInterval) -> [HandsFreeAction] {
        guard isOn else { return [] }
        if micOpen {
            if let quiet = quietSince, time - quiet >= settings.idleTimeout - 1e-9 { return stop(.timeout) }
            return []
        }
        guard !utterancePending, snapshot.mayListen, let at = resumeAt, time >= at - 1e-9 else { return [] }
        resumeAt = nil
        micOpen = true
        quietSince = carriedQuiet ?? time
        carriedQuiet = nil
        otherAudioDuringUtterance = false
        quietBeforeSpeech = nil
        return [.openMic]
    }
}

/// How much longer to wait for the end of the user's next utterance, given Benji's last reply:
/// after a question (a quiz, "does that make sense?") the user may pause to think.
public enum TurnPatience {
    public static func after(reply: String?) -> TimeInterval {
        guard let r = reply?.trimmingCharacters(in: .whitespacesAndNewlines), r.hasSuffix("?") else { return 0 }
        return HandsFreeSettings.answerPatience
    }
}

/// Restarts of the recogniser inside one listening spell. A recognition request can end on its
/// own (no speech for a while, a final result); the mic stays open and a new request carries on.
/// Requests that die at once, three times running, mean recognition is broken: stop retrying.
public struct RecognizerRestarts: Sendable {
    public static let quickFailure: TimeInterval = 1.0
    public static let maxQuickFailures = 3
    private var quickFailures = 0

    public init() {}

    /// A request that started at `started` ended at `ended`, having heard `heardWords`.
    /// Returns whether to start another.
    public mutating func requestEnded(started: TimeInterval, ended: TimeInterval, heardWords: Bool) -> Bool {
        if heardWords || ended - started >= Self.quickFailure {
            quickFailures = 0
        } else {
            quickFailures += 1
        }
        return quickFailures < Self.maxQuickFailures
    }
}

/// Joins the text of successive recognition requests in one utterance.
public enum TranscriptJoin {
    public static func join(_ committed: String, _ current: String) -> String {
        let a = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}
