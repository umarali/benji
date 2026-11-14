import Foundation

/// The composer's talk control (D-133): a wide capsule that names the talk key while the field is
/// empty, a round mic once there is text in it. Either one starts talking on a click; while
/// Benji listens it keeps its shape and colours (the band says "Listening"), only the glyph
/// turns orange and the words become "Stop listening" (D-134). Pure decisions only.
public enum ComposerTalk {
    public enum Shape: Equatable, Sendable {
        /// The capsule with its words, beside the empty field.
        case capsule
        /// The round mic, with read aloud and Send inside the field.
        case round
    }

    /// The capsule while the field is empty, the round mic once something is typed.
    public static func shape(text: String) -> Shape {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .capsule : .round
    }

    /// The capsule's words. `key` is the talk key's display string ("Right ⌥") when it is ready, nil
    /// otherwise. `needsSetup` is the key's name when it is on but not ready (no Accessibility):
    /// the capsule says so and never names another key (D-139).
    public static func title(key: String?, needsSetup: String? = nil, listening: Bool) -> String {
        if listening { return "Stop listening" }
        guard let key, !key.isEmpty else {
            if let needsSetup, !needsSetup.isEmpty { return "\(needsSetup) needs Accessibility" }
            return "Click to talk"
        }
        return "Hold \(key) to talk"
    }

    /// The control's tooltip and VoiceOver hint: what a tap of the key does follows
    /// `AppController.updateTalkHint` (`startsOnTap`: a tap starts hands-free listening).
    public static func help(key: String?, needsSetup: String? = nil, startsOnTap: Bool, listening: Bool) -> String {
        if listening { return "Listening. Click to stop, or say “that's all”" }
        guard let key, !key.isEmpty else {
            if let needsSetup, !needsSetup.isEmpty {
                return "\(needsSetup) needs Accessibility. Allow it in the Benji menu › Finish Setup…, or click to talk"
            }
            return "Click to talk"
        }
        let hold = "Click to talk. Or hold \(key) and let go to send"
        return startsOnTap
            ? hold + "; tap it and Benji keeps listening until you say “that's all”"
            : hold + ", or tap it and tap again to send"
    }

    /// The home and composer hint for talking (`AppController.updateTalkHint`). Right ⌥ is the only
    /// talk key (D-139): ready, the hint names it; on but not ready, it says why and points to Finish
    /// Setup; off, only the mic is left.
    public static func hint(key: String, ready: Bool, enabled: Bool, startsOnTap: Bool) -> String {
        guard ready else {
            return enabled
                ? "\(key) needs Accessibility: allow it in the Benji menu › Finish Setup…, or click to talk below."
                : "Click to talk below, or type."
        }
        let hold = "To talk: hold \(key) and let go to send"
        return startsOnTap
            ? hold + ". Or tap it, and Benji keeps listening until you say “that's all”, or type below."
            : hold + ", or tap it and tap again to send."
    }

    /// A click starts or stops listening only while nothing else runs (as the band's mic did):
    /// free, or listening already. Working, speaking and waiting on a card leave it disabled.
    public static func enabled(phase: CompanionPhase) -> Bool {
        switch phase {
        case .idle, .error, .listening: return true
        case .transcribing, .thinking, .speaking, .awaitingApproval: return false
        }
    }

    /// The VoiceOver label.
    public static func accessibilityLabel(listening: Bool) -> String { listening ? "Stop listening" : "Talk" }
}
