import Foundation

/// When each stage of one turn happened, so speed work can be aimed. Times are
/// seconds on one monotonic clock (system uptime). The first time a mark is set wins. The record
/// holds durations and switches only: no message text, no file names, nothing that leaves the Mac.
public struct TurnLatency: Equatable, Sendable {
    public enum Mark: String, CaseIterable, Sendable {
        /// The talk key went down (voice turns).
        case keyDown
        /// The talk key went up, or the conversation heard the end of what was said.
        case keyUp
        /// The words were final and the message was handed to the app.
        case transcript
        /// The message went to the engine.
        case sent
        /// The engine took it (`accepted`).
        case accepted
        /// The first streamed words arrived.
        case firstText
        /// The first sentence was handed to the voice.
        case firstSentence
        /// The voice started playing.
        case firstAudio
        /// The whole answer arrived.
        case answer
        /// The run ended.
        case finished
    }

    public private(set) var marks: [Mark: Double] = [:]
    public var spoken = false
    public var screen = false
    public var backend = "serve"
    public var streamed = false

    public init() {}

    public mutating func mark(_ m: Mark, at t: Double) {
        if marks[m] == nil { marks[m] = t }
    }

    public func time(_ m: Mark) -> Double? { marks[m] }

    /// Milliseconds from `a` to `b`, when both happened and in that order.
    public func ms(_ a: Mark, _ b: Mark) -> Int? {
        guard let x = marks[a], let y = marks[b], y >= x else { return nil }
        return Int(((y - x) * 1000).rounded())
    }

    /// The stages, in the order a turn goes through them, as (name, milliseconds). Stages that
    /// didn't happen (a typed turn has no key, a silent one no audio) are left out.
    public var stages: [(String, Int)] {
        let pairs: [(String, Mark, Mark)] = [
            ("release_to_transcript_ms", .keyUp, .transcript),
            ("transcript_to_sent_ms", .transcript, .sent),
            ("sent_to_accepted_ms", .sent, .accepted),
            ("sent_to_first_text_ms", .sent, .firstText),
            ("first_text_to_first_sentence_ms", .firstText, .firstSentence),
            ("first_sentence_to_first_audio_ms", .firstSentence, .firstAudio),
            ("sent_to_first_audio_ms", .sent, .firstAudio),
            ("sent_to_answer_ms", .sent, .answer),
            ("release_to_first_audio_ms", .keyUp, .firstAudio),
            ("sent_to_finished_ms", .sent, .finished),
        ]
        return pairs.compactMap { name, a, b in ms(a, b).map { (name, $0) } }
    }

    /// One JSON line for the local log. `at` is the wall-clock time of the record, ISO 8601.
    public func jsonLine(at date: Date) -> String {
        var obj: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: date),
            "spoken": spoken,
            "screen": screen,
            "backend": backend,
            "streamed": streamed,
        ]
        for (name, value) in stages { obj[name] = value }
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// A short line for the debug trace: "sent→text 412 ms · sent→audio 980 ms · …".
    public var summary: String {
        stages.map { "\($0.0.replacingOccurrences(of: "_ms", with: "")) \($0.1)" }.joined(separator: " · ")
    }
}
