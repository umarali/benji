import Foundation

/// Settings › Copy diagnostics. The report is `benji --diagnose`, run by the app as it runs
/// `--print-provider`; this is the part that doesn't need a process or a pasteboard, so tests can run
/// it with a fake of each. The report holds no message text (the engine builds it from `events.jsonl`'s
/// fixed fields); the app only puts it on the clipboard.
public enum DiagnosticsCopy {
    public static let hours = 24
    public static let command = "--diagnose --hours \(hours)"
    public static let title = "Copy diagnostics"
    public static let detail = "A short report of the last 24 hours to paste into a bug report: errors, what Benji refused and why, approvals, failed jobs, slow turns. It holds no message text, page text or file contents."
    public static let copiedNote = "Copied."
    public static let failedNote = "Benji couldn't make the report."

    public enum Status: Equatable, Sendable {
        case idle, working, copied, failed

        public var note: String? {
            switch self {
            case .copied: return DiagnosticsCopy.copiedNote
            case .failed: return DiagnosticsCopy.failedNote
            case .idle, .working: return nil
            }
        }
    }

    /// The text to copy from the command's output, or nil when it failed or said nothing.
    public static func text(from output: Data?, exitCode: Int32) -> String? {
        guard exitCode == 0, let output else { return nil }
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Run the report, copy it, and say how it went in the audit log (the fact that it was copied,
    /// never the report).
    public static func perform(run: () -> (output: Data?, exitCode: Int32), copy: (String) -> Void,
                               audit: (AuditEvent) -> Void) -> Status {
        let result = run()
        guard let text = text(from: result.output, exitCode: result.exitCode) else {
            audit(.diagnosticsCopied(ok: false))
            return .failed
        }
        copy(text)
        audit(.diagnosticsCopied(ok: true))
        return .copied
    }
}
