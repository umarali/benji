import Foundation

// When the user cuts Benji off (talks over it, or presses the talk key or the mic while it
// speaks), the conversation keeps only the part of the answer that was said aloud, marked as cut
// off, so the next turn doesn't assume the user heard the rest. Pure decisions only.

/// How far a spoken answer has got: when each word starts being heard, from the voice's own
/// events (Kokoro's sentence milestones, the Apple voice's word callbacks). Offsets are UTF-16, in
/// the text the voice was given.
public struct SpokenProgress: Equatable, Sendable {
    public struct Mark: Equatable, Sendable {
        public let at: Double
        public let offset: Int

        public init(at: Double, offset: Int) {
            self.at = at
            self.offset = offset
        }
    }

    public private(set) var marks: [Mark] = []

    public init() {}

    /// A sentence started playing at `time`; its words are heard after their `milestones` delays.
    public mutating func sentenceStarted(at time: Double, milestones: [SpeechMilestone]) {
        marks += milestones.map { Mark(at: time + $0.delay, offset: $0.offset) }
    }

    /// The word starting at `offset` is heard from `time` on.
    public mutating func reached(offset: Int, at time: Double) {
        marks.append(Mark(at: time, offset: offset))
    }

    public mutating func reset() { marks = [] }

    /// The UTF-16 offset just past the last word that had started by `time` (0: none had).
    public func heardEnd(in text: String, at time: Double) -> Int {
        guard let last = marks.filter({ $0.at <= time + 1e-9 }).max(by: { $0.offset < $1.offset }) else { return 0 }
        let units = Array(text.utf16)
        guard last.offset < units.count else { return units.count }
        var end = last.offset
        while end < units.count, !Self.isSpace(units[end]) { end += 1 }
        return end
    }

    /// What of `text` had been said by `time`.
    public func heard(_ text: String, at time: Double) -> String {
        let end = heardEnd(in: text, at: time)
        guard end > 0 else { return "" }
        let units = Array(text.utf16)
        let prefix = String(decoding: units[..<min(end, units.count)], as: UTF16.self)
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isSpace(_ unit: UTF16.CodeUnit) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x0D || unit == 0x09 || unit == 0xA0
    }
}

/// The reply the conversation keeps for an answer that was cut off.
public enum CutOffReply {
    /// After the words that were heard. The engine's prompt explains it (benji/prompts.py).
    public static let marker = "[cut off: the user interrupted here and didn't hear the rest]"
    /// When nothing had been said aloud yet.
    public static let unheard = "[cut off before any of it was said aloud: the user heard none of this reply]"
    /// The panel's note under the shortened answer.
    public static let notice = "You cut in, so Benji stopped there."

    /// `heard`: what was said aloud. `full`: the whole answer when it is known (nil while it is
    /// still being written: then the rest is always taken as unsaid). An answer heard to its last
    /// word is kept whole.
    public static func reply(heard: String, full: String?) -> String {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return unheard }
        if let full {
            let f = full.trimmingCharacters(in: .whitespacesAndNewlines)
            if SpokenWords(h).words.count >= SpokenWords(SpeechText.plain(f)).words.count { return f }
        }
        return "\(h) … \(marker)"
    }

    /// True when `reply` is a cut-off one (not the whole answer).
    public static func isCutOff(_ reply: String) -> Bool {
        reply.hasSuffix(marker) || reply == unheard
    }

    /// What the panel shows in place of the answer: the words that were said, with a dash where
    /// Benji stopped (nil: nothing was said, keep the line as it is).
    public static func shown(heard: String) -> String? {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        return h.isEmpty ? nil : "\(h) —"
    }
}
