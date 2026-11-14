import Foundation

/// Which synthesizer speaks answers to voice turns.
public enum SpeechEngine: String, Equatable, Sendable {
    case kokoro   // on-device Kokoro through `benji --tts` (optional extra, ./voice-setup.sh)
    case system   // AVSpeechSynthesizer

    /// The `ttsEngine` setting: "system" (or "apple", "avspeech") keeps the Apple voice.
    /// Anything else, including unset, uses Kokoro when it's installed.
    public static func resolve(setting: String?, kokoroInstalled: Bool) -> SpeechEngine {
        switch setting?.lowercased() {
        case "system", "apple", "avspeech", "say": return .system
        default: return kokoroInstalled ? .kokoro : .system
        }
    }
}

/// Where Kokoro lives on disk. Everything is under the data folder (~/.benji), outside git.
public struct KokoroInstall: Equatable, Sendable {
    public static let modelFiles = ["kokoro-v1.0.onnx", "kokoro-v1.0.int8.onnx"]
    public static let voicesFile = "voices-v1.0.bin"

    public let python: String
    public let voicesDir: String

    /// `dataDir` is $BENJI_WORKDIR when set, else ~/.benji (same rule as the engine).
    public init(dataDir: String) {
        let base = (dataDir as NSString).expandingTildeInPath
        python = (base as NSString).appendingPathComponent("voice-venv/bin/python3")
        voicesDir = (base as NSString).appendingPathComponent("voices")
    }

    public static func dataDir(environment: [String: String]) -> String {
        if let dir = LegacyEnvironment.workingFolderOverride(environment) { return dir }
        return WorkingFolder.runFolderURL?.path ?? "~/.benji"
    }

    /// The venv's Python, a model and the voices file are all present.
    public func isInstalled(fileExists: (String) -> Bool) -> Bool {
        let file = { (name: String) in (voicesDir as NSString).appendingPathComponent(name) }
        return fileExists(python) && fileExists(file(Self.voicesFile))
            && Self.modelFiles.contains { fileExists(file($0)) }
    }
}

/// The user's Kokoro voice and speed (`kokoroVoice`, `kokoroSpeed` settings).
public enum KokoroSettings {
    public static let defaultVoice = "af_heart"

    /// A voice id like `af_heart` or `bm_george`; anything malformed falls back to the default.
    public static func voice(_ setting: String?) -> String {
        guard let v = setting?.trimmingCharacters(in: .whitespaces).lowercased(),
              v.range(of: #"^[a-z]{2}_[a-z0-9]+$"#, options: .regularExpression) != nil
        else { return defaultVoice }
        return v
    }

    public static func speed(_ setting: Double?) -> Double {
        guard let s = setting, s > 0 else { return 1.0 }
        return min(2.0, max(0.5, s))
    }
}

/// Requests to the speech service (`benji --tts`, benji/tts.py), one JSON object per line.
public enum KokoroRequest: Equatable {
    case speak(id: String, text: String, voice: String, speed: Double)
    case stop

    public func line() -> Data {
        let obj: [String: Any]
        switch self {
        case .speak(let id, let text, let voice, let speed):
            obj = ["type": "speak", "id": id, "text": text, "voice": voice, "speed": speed]
        case .stop:
            obj = ["type": "stop"]
        }
        var data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }
}

/// Events from the speech service.
public enum KokoroEvent: Equatable {
    case ready(sampleRate: Double, voices: [String], model: String)
    /// Little-endian int16 mono PCM for one sentence, and that sentence's text ("" from an
    /// older service).
    case audio(id: String, seq: Int, text: String, pcm16: Data)
    case done(id: String, stopped: Bool)
    /// `id` is nil when the service couldn't start at all.
    case error(id: String?, text: String)
    case unknown

    public static func decode(_ line: String) -> KokoroEvent {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return .unknown }
        let id = obj["id"] as? String
        switch type {
        case "ready":
            return .ready(sampleRate: (obj["sample_rate"] as? Double) ?? 24000,
                          voices: obj["voices"] as? [String] ?? [],
                          model: obj["model"] as? String ?? "")
        case "audio":
            guard let id, let b64 = obj["pcm16"] as? String,
                  let pcm = Data(base64Encoded: b64) else { return .unknown }
            return .audio(id: id, seq: obj["seq"] as? Int ?? 0, text: obj["text"] as? String ?? "", pcm16: pcm)
        case "done":
            guard let id else { return .unknown }
            return .done(id: id, stopped: obj["stopped"] as? Bool ?? false)
        case "error":
            return .error(id: id, text: obj["text"] as? String ?? "Kokoro failed")
        default:
            return .unknown
        }
    }

    /// int16 PCM as floats in -1…1, ready for an AVAudioPCMBuffer.
    public static func floats(fromPCM16 data: Data) -> [Float] {
        let count = data.count / 2
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                out[i] = Float(v) / 32768
            }
        }
        return out
    }
}

/// Tracks one utterance's playback so the Speaking state follows real audio: it starts
/// when the first sentence is scheduled on the player and ends when the service is done
/// and every scheduled sentence has played back.
public struct KokoroPlayback: Equatable, Sendable {
    public private(set) var scheduled = 0
    public private(set) var played = 0
    public private(set) var engineDone = false

    public init() {}

    public var hasStarted: Bool { scheduled > 0 }
    public var isFinished: Bool { engineDone && played >= scheduled }

    /// Returns true when this is the first sentence (speaking starts now).
    public mutating func didSchedule() -> Bool {
        scheduled += 1
        return scheduled == 1
    }

    /// Returns true when the utterance just finished.
    public mutating func didPlay() -> Bool {
        played += 1
        return isFinished
    }

    /// Returns true when the utterance just finished.
    public mutating func didFinishSynthesis() -> Bool {
        engineDone = true
        return isFinished
    }
}

/// One word of a spoken sentence: where it starts in the spoken text (UTF-16) and how long
/// after the sentence starts playing it is heard.
public struct SpeechMilestone: Equatable, Sendable {
    public let offset: Int
    public let delay: Double

    public init(offset: Int, delay: Double) {
        self.offset = offset
        self.delay = delay
    }
}

/// Follows a voice that only says which sentence it's playing (Kokoro), so marks can still
/// appear on their words: the sentence is found in the spoken text, and its words are spread
/// over its playing time by their syllables (a comma and a sentence end count as pauses, as in
/// `RevealTiming`).
public enum SpeechFollow {
    /// `sentence` as the voice reports it, looked for in `text` from UTF-16 offset `from` on;
    /// `duration` is how long its audio plays. Returns each word's milestone and the offset
    /// just past the sentence (where to look for the next one); nil if it isn't found.
    public static func milestones(sentence: String, in text: String, from: Int,
                                  duration: Double) -> (milestones: [SpeechMilestone], end: Int)? {
        let spoken = RevealTiming.tokenize(sentence)
        let words = spoken.compactMap(\.word)
        guard let first = words.first else { return nil }
        let textWords = RevealTiming.tokenize(text).filter { $0.word != nil && $0.offset >= from }
        // The sentence starts where its first two words do.
        guard let start = textWords.indices.first(where: { i in
            textWords[i].word == first
                && (words.count < 2 || (i + 1 < textWords.count && textWords[i + 1].word == words[1]))
        }) else { return nil }

        let total = max(RevealTiming.seconds(before: spoken.count, in: spoken), 0.001)
        var out: [SpeechMilestone] = []
        var k = start
        for (i, token) in spoken.enumerated() where token.word != nil {
            guard k < textWords.count, textWords[k].word == token.word else { break }
            let share = RevealTiming.seconds(before: i, in: spoken) / total
            out.append(SpeechMilestone(offset: textWords[k].offset, delay: duration * share))
            k += 1
        }
        let last = textWords[k - 1]
        return (out, last.offset + (last.word ?? "").utf16.count)
    }
}
