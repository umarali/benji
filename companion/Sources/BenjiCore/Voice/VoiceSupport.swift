import Foundation

/// Prepares answer text for speech: strips Markdown so the synthesizer doesn't
/// read out asterisks, backticks, or link URLs. Leaves snake_case intact.
public enum SpeechText {
    public static func plain(_ text: String) -> String {
        // A drawing tag is never read out, wherever it stands.
        var t = PointingTags.stripped(text)
        // A fenced block (code, or a figure that failed to parse) is never read out; an unclosed
        // one runs to the end.
        t = t.replacingOccurrences(of: #"(?ms)^[ \t]*```.*?(?:^[ \t]*```[ \t]*(?:\n|\z)|\z)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "```", with: "")
        t = t.replacingOccurrences(of: "`", with: "")
        t = t.replacingOccurrences(of: #"(\*\*|__|\*)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^\s*#{1,6}\s*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^\s*[-•]\s+"#, with: "", options: .regularExpression)
        t = withoutEmoji(t)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops emoji so the voice doesn't read "smiling face" aloud. Plain digits, # and * are
    /// emoji-capable too, so only characters drawn as emoji go: emoji-presentation scalars,
    /// text symbols turned into emoji with U+FE0F, and keycaps.
    public static func withoutEmoji(_ text: String) -> String {
        var out = ""
        for ch in text {
            let scalars = ch.unicodeScalars
            let isEmoji = scalars.contains { $0.properties.isEmojiPresentation }
                || scalars.contains { $0.value == 0xFE0F || $0.value == 0x20E3 }
            if !isEmoji { out.append(ch) }
        }
        return out.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" +([.,!?;:])"#, with: "$1", options: .regularExpression)
    }
}

/// Talk-key rules that don't depend on audio hardware. A quick tap latches
/// listening on (tap again to send); a longer hold sends on release.
public enum TalkGesturePolicy {
    /// Presses shorter than this are taps: listening stays on until the next tap.
    public static let minimumHold: TimeInterval = 0.35
    /// A latched recording is sent automatically after this long, so the mic is never left on.
    public static let maximumRecording: TimeInterval = 300

    public static func isTap(holdSeconds: TimeInterval) -> Bool {
        holdSeconds < minimumHold
    }
}

/// What one modifier key used on its own (e.g. Right Option) just did.
public enum ModifierKeyEvent: Equatable, Sendable {
    /// Pressed and released quickly.
    case tap
    /// Held cleanly for `ModifierTapDetector.holdDelay`: start listening.
    case holdBegan
    /// Let go after `holdBegan`: send.
    case holdEnded
}

/// Recognises one modifier key used on its own (e.g. Right Option): a quick tap, or a
/// hold that begins once the key has been down `holdDelay` with nothing else pressed.
/// Another key or modifier before then makes it a chord like ⌥E, which is neither.
/// A hold that has begun stays a hold until the key is let go, whatever else is pressed.
public struct ModifierTapDetector {
    public static let maximumTap: TimeInterval = 0.5
    /// Long enough that typing an ⌥-character or ⌥-shortcut never starts listening,
    /// short enough that holding to talk feels immediate.
    public static let holdDelay: TimeInterval = 0.3

    private var isDown = false
    private var downAt: TimeInterval?   // nil once the press is a chord
    private var holding = false

    public init() {}

    /// Call on every modifier change. Returns true when a clean tap just completed.
    public mutating func modifiersChanged(targetDown: Bool, othersDown: Bool, at time: TimeInterval) -> Bool {
        change(targetDown: targetDown, othersDown: othersDown, at: time) == .tap
    }

    /// Call on every modifier change. Reports a tap, or the end of a hold.
    public mutating func change(targetDown: Bool, othersDown: Bool, at time: TimeInterval) -> ModifierKeyEvent? {
        if targetDown {
            if !isDown {
                isDown = true
                downAt = othersDown ? nil : time
            } else if othersDown {
                downAt = nil
            }
            return nil
        }
        guard isDown else { return nil }
        isDown = false
        defer { downAt = nil; holding = false }
        if holding { return .holdEnded }
        guard let start = downAt, !othersDown else { return nil }
        return time - start <= Self.maximumTap ? .tap : nil
    }

    /// Call `holdDelay` after the key goes down (a timer: no event arrives while it is held).
    /// Returns `holdBegan` once, if the key is still down on its own and has been for long enough.
    public mutating func holdCheck(at time: TimeInterval) -> ModifierKeyEvent? {
        guard isDown, !holding, let start = downAt, time - start >= Self.holdDelay else { return nil }
        holding = true
        return .holdBegan
    }

    /// Any non-modifier key while the target is down makes it a chord, unless a hold has begun.
    public mutating func keyPressed() {
        downAt = nil
    }

    /// The key is no longer watched (the tap was removed). Ends a hold in progress.
    @discardableResult
    public mutating func reset() -> ModifierKeyEvent? {
        defer { isDown = false; downAt = nil; holding = false }
        return holding ? .holdEnded : nil
    }
}

/// Which speech-to-text engine push-to-talk uses.
public enum TranscriberKind: String, Equatable, Sendable {
    case onDevice   // Apple Speech framework, on-device only, no key
    case engine     // `benji --transcribe` (OpenAI Whisper / Deepgram; needs a key)

    public static func from(setting: String?) -> TranscriberKind {
        switch setting?.lowercased() {
        case "engine", "benji", "cloud", "whisper", "deepgram": return .engine
        default: return .onDevice
        }
    }
}

/// An installed speech voice, described without AVFoundation so the choice is testable.
public struct VoiceCandidate: Equatable, Sendable {
    public let id: String
    public let language: String   // BCP-47, e.g. "en-US"
    public let quality: Int       // 1 default, 2 enhanced, 3 premium (AVSpeechSynthesisVoiceQuality)
    public let isNovelty: Bool

    public init(id: String, language: String, quality: Int, isNovelty: Bool = false) {
        self.id = id
        self.language = language
        self.quality = quality
        self.isNovelty = isNovelty
    }
}

/// Picks the voice Benji speaks with. The basic "default"-quality voices sound robotic,
/// so Benji prefers an Enhanced or Premium voice in the user's language when one is installed.
public enum VoiceChoice {
    /// Returns a voice id, or nil to fall back to the system default for `language`.
    /// `preferredID` (the `ttsVoice` setting) wins when that voice is installed.
    public static func best(from voices: [VoiceCandidate], language: String, preferredID: String?) -> String? {
        if let preferredID, voices.contains(where: { $0.id == preferredID }) { return preferredID }
        let base = language.split(separator: "-").first.map(String.init) ?? language
        let sameLanguage = voices.filter {
            !$0.isNovelty && $0.quality > 1
                && ($0.language.split(separator: "-").first.map(String.init) ?? $0.language) == base
        }
        return sameLanguage.max { a, b in
            if a.quality != b.quality { return a.quality < b.quality }
            return (a.language == language ? 1 : 0) < (b.language == language ? 1 : 0)
        }?.id
    }
}

/// Maps a buffer's RMS amplitude to a 0…1 meter value on a decibel scale, so quiet
/// speech still moves the meter and loud speech doesn't pin it.
public enum MicLevel {
    public static let floorDecibels: Float = -50

    public static func normalized(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db - floorDecibels) / -floorDecibels))
    }
}
