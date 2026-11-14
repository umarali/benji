import Foundation
import BenjiCore

/// The app's appends to the working folder's `events.jsonl` and `engine.log` (D-144), each on a
/// queue of its own so a write never holds up the UI. Kept this simple on purpose: the app writes the
/// file itself, one line per event (`AuditLog`), and the engine writes the same file from its side;
/// the implementation note on logging says why that beat sending events through the engine.
final class AuditFile {
    static let shared = AuditFile()

    private let queue = DispatchQueue(label: "benji.audit-log", qos: .utility)

    func record(_ event: AuditEvent) {
        let log = AuditLog(folder: WorkingFolder.url())
        queue.async { log.append(event) }
    }
}

/// Every line the engine writes to stderr goes to `engine.log` after redaction (`EngineLog`).
final class EngineLogFile {
    static let shared = EngineLogFile()

    private let queue = DispatchQueue(label: "benji.engine-log", qos: .utility)

    func append(_ line: String) {
        let log = EngineLog(folder: WorkingFolder.url())
        queue.async { log.append(line) }
    }
}
