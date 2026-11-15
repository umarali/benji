import Foundation

/// The fast path: the reply streamed, so the panel shows words and the voice starts
/// on the first sentence while the model is still writing (an answer about the screen too).
/// The way back, read from user defaults:
///   defaults write com.emerssive.heybenji.app streamReplies -bool NO  the engine sends only the finished answer
public enum FastPath {
    public static let streamKey = "streamReplies"

    /// Streaming is on unless turned off.
    public static func streams(_ stored: Any?) -> Bool { (stored as? Bool) ?? true }

    /// The value the engine's `BENJI_STREAM` gets.
    public static func engineStreamValue(_ stored: Any?) -> String { streams(stored) ? "1" : "0" }
}

/// Positions in the text the voice is saying, mapped to the same place in another rendering of the
/// same words. A streamed answer is spoken sentence by sentence, each cleaned for speech and joined
/// with single spaces, while the marks' cues index the whole answer cleaned at once; the two differ
/// only in white space, so a position is matched by how many other characters come before it.
public enum SpokenAlignment {
    /// The UTF-16 offset in `target` matching `offset` in `spoken`; nil past the end of `target`.
    public static func offset(_ offset: Int, in spoken: String, to target: String) -> Int? {
        if spoken == target { return offset <= (target as NSString).length ? offset : nil }
        let s = Array(spoken.utf16), t = Array(target.utf16)
        var count = 0
        for i in 0..<min(max(offset, 0), s.count) where !isSpace(s[i]) { count += 1 }
        var seen = 0
        for (j, u) in t.enumerated() {
            if isSpace(u) { continue }
            if seen == count { return j }
            seen += 1
        }
        return seen == count ? t.count : nil
    }

    private static func isSpace(_ u: UInt16) -> Bool { u == 32 || u == 9 || u == 10 || u == 13 || u == 0xA0 }
}
