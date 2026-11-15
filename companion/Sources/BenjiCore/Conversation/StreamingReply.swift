import Foundation

// A reply as it streams (the engine's `delta` events): what the panel may show before the answer
// is complete, and the sentences the voice can start on while the rest is still being written.

/// The part of a streaming reply that is safe to show or say.
public enum StreamingReply {
    /// Everything before the first code fence: a figure block streams as a fenced JSON block and
    /// must never flash up in the panel or be read aloud (the finished answer shows any real code).
    /// A trailing run of backticks is held back, since it may be the start of a fence.
    public static func visible(_ raw: String) -> String {
        var text = raw
        if let fence = text.range(of: "```") {
            text = String(text[..<fence.lowerBound])
        }
        while text.hasSuffix("`") { text.removeLast() }
        return text
    }
}

/// Cuts a growing reply into sentences the voice can say while the model is still writing.
/// Feed it the whole visible text so far each time (not just the newest piece); it hands back
/// only the sentences that became complete since the last call. `reset()` starts a new segment
/// (the engine took back text that turned out to come before a tool call). `finish(_:)` returns
/// what is left to say once the answer is known.
public struct SentenceStream: Equatable, Sendable {
    /// Characters of the current segment already handed out.
    private var cut = 0
    /// The segment's visible text as last fed.
    private var text = ""
    /// Something was handed out this turn (in any segment).
    public private(set) var spokeAny = false

    /// Words that end in a full stop without ending a sentence.
    static let abbreviations: Set<String> = [
        "e.g", "i.e", "etc", "vs", "mr", "mrs", "ms", "dr", "st", "no", "approx", "fig", "inc", "jr", "sr",
    ]

    public init() {}

    /// The sentences that became complete since the last call.
    public mutating func feed(_ visible: String) -> [String] {
        guard visible.count >= text.count, visible.hasPrefix(text) || text.isEmpty else {
            // The segment changed under us (shouldn't happen between resets): start it again from
            // what is already said, so nothing is repeated.
            text = visible
            cut = min(cut, visible.count)
            return []
        }
        text = visible
        var out: [String] = []
        while let end = Self.sentenceEnd(in: text, from: cut) {
            let chunk = Self.slice(text, cut, end).trimmingCharacters(in: .whitespacesAndNewlines)
            cut = end
            if !chunk.isEmpty {
                out.append(chunk)
                spokeAny = true
            }
        }
        return out
    }

    /// The segment's text after the last sentence handed out: the sentence still being written.
    public var pending: String {
        Self.slice(text, cut, text.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every sentence of `text` in order, the last one whether or not it is finished (a finished
    /// answer, or the rest of one, cut the way `feed` cuts a stream).
    public static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var from = 0
        while let end = sentenceEnd(in: text, from: from) {
            let s = slice(text, from, end).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            from = end
        }
        let last = slice(text, from, text.count).trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { out.append(last) }
        return out
    }

    /// The engine took back what streamed so far: what comes next is a new segment.
    public mutating func reset() {
        cut = 0
        text = ""
    }

    /// What is left to say of `final` (the visible finished answer): everything after the part
    /// already handed out. Nil when nothing is left.
    public mutating func finish(_ final: String) -> String? {
        // What was said, without the white space that ended its last sentence: the finished answer
        // may be trimmed there (a figure block taken out after "Here's a kettle.\n"), and that is
        // no reason to say the last word again.
        var said = Self.slice(text, 0, cut)
        while let last = said.last, last.isWhitespace { said.removeLast() }
        var start: Int
        if final.hasPrefix(said) {
            start = said.count
        } else {
            // Not expected (the engine's deltas join to the answer): resume after the common
            // prefix, backed up to a word boundary, so no word is said twice or cut in half.
            start = zip(final, said).prefix { $0 == $1 }.count
            let chars = Array(final)
            while start > 0, !chars[start - 1].isWhitespace { start -= 1 }
        }
        cut = 0
        text = ""
        let rest = Self.slice(final, start, final.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }
        spokeAny = true
        return rest
    }

    /// Where the first complete sentence after `from` ends (a character offset), or nil.
    /// A sentence ends at a line break, or at . ! ? or … followed by white space (closing quotes
    /// and brackets go with it), unless the full stop belongs to an abbreviation, a single
    /// letter (an initial) or a number.
    static func sentenceEnd(in text: String, from: Int) -> Int? {
        let chars = Array(text)
        var i = from
        while i < chars.count {
            let c = chars[i]
            if c == "\n" {
                return i + 1
            }
            if c == "!" || c == "?" || c == "…" || c == "." {
                var j = i + 1
                while j < chars.count, "\"'”’)]".contains(chars[j]) { j += 1 }
                guard j < chars.count else { return nil }   // can't tell yet: wait for more
                if chars[j].isWhitespace, !(c == "." && isAbbreviation(chars, dotAt: i, from: from)) {
                    return j
                }
            }
            i += 1
        }
        return nil
    }

    private static func isAbbreviation(_ chars: [Character], dotAt dot: Int, from: Int) -> Bool {
        var start = dot
        while start > from, chars[start - 1].isLetter || chars[start - 1] == "." { start -= 1 }
        let word = String(chars[start..<dot]).lowercased()
        if word.isEmpty { return dot > from && chars[dot - 1].isNumber }   // "3." in a list is fine; "v3.5" has no space
        if word.count == 1 { return true }   // an initial: "J. Smith"
        return abbreviations.contains(word)
    }

    private static func slice(_ s: String, _ from: Int, _ to: Int) -> String {
        let a = s.index(s.startIndex, offsetBy: min(from, s.count))
        let b = s.index(s.startIndex, offsetBy: min(max(to, from), s.count))
        return String(s[a..<b])
    }
}
