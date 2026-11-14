import Foundation
import BenjiCore

/// Appends each turn's stage times to `latency.jsonl` in Benji's working folder (D-118 step 1),
/// beside the engine's `usage.jsonl`. Durations and switches only: no message text, no file
/// names. The file is created readable by this user only and never leaves the Mac.
/// `BENJI_LATENCY_LOG=0` turns it off; `BENJI_DEBUG=1` also prints a summary line.
enum LatencyLog {
    static var url: URL {
        WorkingFolder.url().appendingPathComponent("latency.jsonl")
    }

    static var enabled: Bool {
        let v = ProcessInfo.processInfo.environment["BENJI_LATENCY_LOG"]?.lowercased() ?? "1"
        return !["0", "false", "no", "off"].contains(v)
    }

    private static let queue = DispatchQueue(label: "benji.latency-log", qos: .utility)

    static func record(_ turn: TurnLatency) {
        if ProcessInfo.processInfo.environment["BENJI_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("[latency] \(turn.summary)\n".utf8))
        }
        guard enabled, !turn.stages.isEmpty else { return }
        let line = turn.jsonLine(at: Date()) + "\n"
        let url = url
        queue.async {
            // Created 0600, and an older file that is wider is tightened on this write (D-144).
            try? PrivateFile.append(Data(line.utf8), to: url)
        }
    }
}
