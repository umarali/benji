import Foundation
import BenjiCore

/// Appends the voice controller's trace lines to `~/.benji/voice.log` (`VoiceLog`), on a queue of
/// its own; rotates to `voice.log.1` past 200 KB. States, formats, engines and error codes only:
/// the callers never pass words that were heard, and no audio is ever written.
final class VoiceLogFile {
    static let shared = VoiceLogFile()

    private let queue = DispatchQueue(label: "benji.voice-log", qos: .utility)
    private var directory: URL { WorkingFolder.url() }

    func append(_ text: String) {
        let line = VoiceLog.line(text, at: Date())
        let directory = self.directory
        queue.async {
            let url = directory.appendingPathComponent(VoiceLog.fileName)
            // Mode 0600, an existing wider file tightened, rotated to voice.log.1 past the limit.
            try? PrivateFile.append(Data(line.utf8), to: url, maxBytes: VoiceLog.maximumBytes, keep: 1)
        }
    }
}
