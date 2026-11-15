import Foundation

// A muted or zero-volume Mac: check before speaking. If the answer would be
// read aloud into nothing, it is shown as text with a line that says why and a Copy button.
//
// What Benji never does here: change the system volume or unmute (the line only tells the user how),
// and write the clipboard (Copy copies when the user presses it, and not before).

/// What the default output device says. `volume` is 0...1; nil when the device has no volume control
/// (some outputs have none, and that is not silence).
public struct OutputState: Equatable, Sendable {
    public var muted: Bool
    public var volume: Double?

    public init(muted: Bool, volume: Double?) {
        self.muted = muted
        self.volume = volume
    }
}

public enum OutputSilence: String, Equatable, Sendable {
    case muted, zeroVolume

    /// Below this a scalar volume is treated as zero (a slider at its lowest notch).
    public static let zeroBelow = 0.005

    /// Silence, or nil when the output is audible or the Mac can't say.
    public static func of(_ state: OutputState?) -> OutputSilence? {
        guard let state else { return nil }
        if state.muted { return .muted }
        if let volume = state.volume, volume < zeroBelow { return .zeroVolume }
        return nil
    }

    /// The line above the answer: what happened and how to hear it. A hint, not a button: Benji does
    /// not touch the volume.
    public var hint: String {
        switch self {
        case .muted:
            return "Your Mac is muted, so I didn't read this out. Unmute it (the mute key, or the speaker icon in the menu bar) to hear me."
        case .zeroVolume:
            return "Your Mac's volume is at zero, so I didn't read this out. Turn the volume up (the volume keys, or the speaker icon in the menu bar) to hear me."
        }
    }
}

/// What the panel shows under an answer that was not spoken because the output is silent.
public struct SilentAnswer: Equatable, Sendable {
    public let why: OutputSilence
    /// The answer's plain text, copied only when the user presses Copy.
    public let text: String

    public init(why: OutputSilence, text: String) {
        self.why = why
        self.text = text
    }

    public var hint: String { why.hint }
    public static let copyTitle = "Copy"
    public static let copiedTitle = "Copied"
}

public enum SilentSpeech {
    /// Whether to speak: not when the output is silent. A user's own request is spoken or not by
    /// this alone; the setting (read aloud) and the spoken-turn rule come first, in `ReadAloud`.
    public static func shouldSpeak(wouldSpeak: Bool, state: OutputState?) -> Bool {
        wouldSpeak && OutputSilence.of(state) == nil
    }

    /// The note to show for an answer that would have been spoken but the output is silent; nil otherwise.
    public static func note(wouldSpeak: Bool, state: OutputState?, answer: String) -> SilentAnswer? {
        guard wouldSpeak, let why = OutputSilence.of(state) else { return nil }
        let plain = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.isEmpty ? nil : SilentAnswer(why: why, text: plain)
    }
}
