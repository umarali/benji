import Foundation

/// One Kokoro voice as Settings › Voice shows it: a name and a line on how it sounds, never the id.
public struct KokoroVoice: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable { case female, male }

    public let id: String
    public let name: String
    public let kind: Kind
    public let character: String

    public init(id: String, name: String, kind: Kind, character: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.character = character
    }
}

/// The voices Benji offers (Settings › Voice), picked from what `voices-v1.0.bin` holds:
/// three female and three male American English voices, the ones Kokoro rates best, with
/// `af_heart` (the voice Benji always had) first and the default.
public enum KokoroVoices {
    public static let offered: [KokoroVoice] = [
        KokoroVoice(id: "af_heart", name: "Heart", kind: .female, character: "Warm and natural. Benji's usual voice."),
        KokoroVoice(id: "af_bella", name: "Bella", kind: .female, character: "Bright and expressive."),
        KokoroVoice(id: "af_nicole", name: "Nicole", kind: .female, character: "Soft and slow, close to a whisper."),
        KokoroVoice(id: "am_michael", name: "Michael", kind: .male, character: "Low, calm and unhurried."),
        KokoroVoice(id: "am_fenrir", name: "Fenrir", kind: .male, character: "Clear and confident."),
        KokoroVoice(id: "am_puck", name: "Puck", kind: .male, character: "Quick and lively."),
    ]

    /// A voice by id: one of `offered`, or a name made from the id (`bm_george` → "George") for a
    /// voice set outside the list (the `kokoroVoice` default).
    public static func named(_ id: String) -> KokoroVoice {
        if let voice = offered.first(where: { $0.id == id }) { return voice }
        let parts = id.split(separator: "_", maxSplits: 1)
        let name = parts.count == 2 ? parts[1].prefix(1).uppercased() + parts[1].dropFirst() : id
        let kind: KokoroVoice.Kind = parts.first.map { $0.count == 2 && $0.hasSuffix("m") } == true ? .male : .female
        return KokoroVoice(id: id, name: name, kind: kind, character: "Set outside Benji's list.")
    }

    /// What the picker lists: the offered voices the installed voices file holds (all of them
    /// until the speech service has said which it has), then the chosen voice if it's none of those.
    public static func choices(installed: [String], chosen: String) -> [KokoroVoice] {
        var list = installed.isEmpty ? offered : offered.filter { installed.contains($0.id) }
        if !list.contains(where: { $0.id == chosen }) { list.append(named(chosen)) }
        return list
    }

    /// The voice to ask the speech service for: the setting (`KokoroSettings.voice`), or the
    /// default when the service has said it doesn't have that voice.
    public static func resolve(setting: String?, installed: [String]) -> String {
        let voice = KokoroSettings.voice(setting)
        guard !installed.isEmpty, !installed.contains(voice) else { return voice }
        return KokoroSettings.defaultVoice
    }
}

/// The speaking speeds Settings › Voice offers for Kokoro (`kokoroSpeed`).
public enum KokoroSpeed {
    public static let choices: [Double] = [0.9, 1.0, 1.15, 1.3]

    public static func label(_ speed: Double) -> String {
        switch speed {
        case ..<0.95: return "Slower"
        case ..<1.05: return "Normal"
        case ..<1.2: return "Faster"
        default: return "Fastest"
        }
    }

    /// The choice nearest the stored speed, so a hand-set value still shows one chosen.
    public static func nearest(_ setting: Double?) -> Double {
        let speed = KokoroSettings.speed(setting)
        return choices.min { abs($0 - speed) < abs($1 - speed) } ?? 1.0
    }
}

/// Whether Benji can speak in a Kokoro voice, which decides what Settings › Voice shows.
public enum VoicePickerStatus: String, Equatable, Sendable {
    case kokoro
    case notInstalled
    /// `ttsEngine` is set to the Apple voice.
    case appleChosen
    /// The speech service wouldn't start (twice), so the Apple voice speaks until Benji reopens.
    case failed

    public static func from(engine: SpeechEngine, installed: Bool, usable: Bool) -> VoicePickerStatus {
        guard installed else { return .notInstalled }
        guard engine == .kokoro else { return .appleChosen }
        return usable ? .kokoro : .failed
    }

    /// The line under the Speech card when the picker isn't shown.
    public var caption: String? {
        switch self {
        case .kokoro: return nil
        case .notInstalled:
            return "Kokoro isn't installed, so Benji speaks with this Apple voice. Run ./voice-setup.sh to choose from six on-device voices."
        case .appleChosen:
            return "The Apple voice is chosen (the ttsEngine setting), so Kokoro's voices aren't offered."
        case .failed:
            return "Kokoro's voice didn't start, so Benji speaks with this Apple voice until it's reopened."
        }
    }
}

/// Settings › Voice's Preview button: one sentence in the chosen voice, only when it can't get in
/// the way of a turn.
public enum VoicePreview {
    public enum Refusal: Equatable, Sendable {
        /// Benji is thinking, answering or waiting on an approval.
        case busy
        /// The mic is open on speakers: the preview would be heard as the user.
        case listening
        /// Kokoro isn't running.
        case unavailable

        public var note: String {
            switch self {
            case .busy: return "Benji is busy with a message. Preview again once it's done."
            case .listening: return "Benji is listening, and on speakers it would hear the preview as you. Pause the mic or use headphones to preview."
            case .unavailable: return "Kokoro's voice isn't running, so there's nothing to preview."
            }
        }
    }

    public static func sentence(for voice: KokoroVoice) -> String {
        "Hi, I'm \(voice.name). This is how Benji sounds with my voice."
    }

    /// Nil when a preview may play now. Listening is fine only when the sound goes to headphones.
    public static func refusal(phase: CompanionPhase, micOpen: Bool, speechActive: Bool,
                               headphones: Bool) -> Refusal? {
        switch phase {
        case .thinking, .transcribing, .speaking, .awaitingApproval: return .busy
        case .idle, .error, .listening: break
        }
        if speechActive { return .busy }
        if (micOpen || phase == .listening) && !headphones { return .listening }
        return nil
    }
}
