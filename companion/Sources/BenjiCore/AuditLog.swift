import Foundation

/// The app's side of the audit log (D-144): events only the app sees, appended to the same
/// `events.jsonl` the engine writes (`benji/audit.py` has the closed list of kinds and checks
/// every line it reads). Metadata only, by construction: an event is a case of `AuditEvent`, so
/// there is no way to hand this a message, a file name or an address. Job ids are the engine's own
/// ids and are dropped if they aren't in that shape. `Tests/audit-cases.json` holds lines both sides
/// agree on.
public enum AuditEvent: Equatable, Sendable {
    public enum JobAction: String, Sendable {
        case answer, stop, steer, dismiss
        // Second pass (D-172): the row's Continue, its schedule buttons, and the one switch.
        case `continue`, schedulePause = "schedule_pause", scheduleResume = "schedule_resume"
        case scheduleDelete = "schedule_delete", schedulesOff = "schedules_off", schedulesOn = "schedules_on"
    }
    public enum Place: String, Sendable { case app }
    public enum ErrorCode: String, Sendable { case engineExit = "engine_exit", engineLaunch = "engine_launch" }

    /// The app started the engine.
    case engineStart
    /// The engine process ended. `clean`: it exited 0.
    case engineExit(code: Int32, clean: Bool)
    /// A job-row button. `approved` only for `answer`.
    case jobAction(JobAction, job: String?, approved: Bool?)
    case browserSwitch(enabled: Bool)
    case diagnosticsCopied(ok: Bool)
    /// The one-time move to `~/.benji` (D-175), by kind only: "renamed", "left_old" or "failed".
    case homeMoved(HomeMigration.Kind)
    case error(ErrorCode)
}

public struct AuditLog {
    public static let fileName = "events.jsonl"
    public static let maxBytes = 1_000_000
    public static let keep = 3

    public let url: URL
    public let enabled: Bool
    private let now: () -> Date

    public init(folder: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
                now: @escaping () -> Date = Date.init) {
        url = folder.appendingPathComponent(Self.fileName)
        enabled = environment["BENJI_AUDIT"]?.trimmingCharacters(in: .whitespaces) != "0"
        self.now = now
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 40 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// The event as the fields the engine's schema takes (`kind` and `src` included, `time` added by `line`).
    public func fields(_ event: AuditEvent) -> [String: Any] {
        var out: [String: Any] = ["src": "app"]
        switch event {
        case .engineStart:
            out["kind"] = "engine_start"
            out["mode"] = "serve"
        case let .engineExit(code, clean):
            out["kind"] = "engine_exit"
            out["clean"] = clean
            out["code"] = Int(max(-255, min(255, code)))
        case let .jobAction(action, job, approved):
            out["kind"] = "job_action"
            out["action"] = action.rawValue
            if let job, Self.validID(job) { out["job"] = job }
            if action == .answer, let approved { out["decision"] = approved ? "yes" : "no" }
        case let .browserSwitch(enabled):
            out["kind"] = "browser_switch"
            out["enabled"] = enabled
        case let .diagnosticsCopied(ok):
            out["kind"] = "diagnostics_copied"
            out["ok"] = ok
        case let .homeMoved(kind):
            out["kind"] = "home_moved"
            out["how"] = kind.rawValue
        case let .error(code):
            out["kind"] = "error"
            out["where"] = "app"
            out["code"] = code.rawValue
        }
        return out
    }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f
    }()

    public func line(_ event: AuditEvent) -> String {
        var obj = fields(event)
        obj["time"] = Self.timeFormat.string(from: now())
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Append the event. False when the log is off or the write failed; a failure is reported once
    /// on stderr (the kind of failure only) and never reaches the caller as an error.
    @discardableResult
    public func append(_ event: AuditEvent) -> Bool {
        guard enabled else { return false }
        do {
            try PrivateFile.append(Data(line(event).utf8), to: url, maxBytes: Self.maxBytes, keep: Self.keep)
            return true
        } catch {
            if !Self.reported.swap(true) {
                FileHandle.standardError.write(Data("[Benji] audit log: write failed (\((error as NSError).domain) \((error as NSError).code))\n".utf8))
            }
            return false
        }
    }

    private static let reported = Flag()

    private final class Flag: @unchecked Sendable {
        private var value = false
        private let lock = NSLock()
        func swap(_ new: Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let old = value
            value = new
            return old
        }
    }
}

/// Where Benji's working folder is, for the whole app (D-175): `$BENJI_WORKDIR`, else Benji's one hidden
/// home, `~/.benji` (the engine's rule, benji/config.py `workdir_path`). Every file the app reads or
/// writes in it (memory, conversations, jobs, logs, the voice) is found through this, so the one switch
/// means the same thing everywhere. The app passes the same folder to its engine (`BENJI_WORKDIR`).
public enum WorkingFolder {
    public static let directoryName = ".benji"
    /// The name before this one; see `HomeMigration.oldNames` for all of them.
    public static let legacyDirectoryName = ".chilly"

    public static func url(environment: [String: String] = ProcessInfo.processInfo.environment,
                           home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let dir = LegacyEnvironment.workingFolderOverride(environment) {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        if let kept = runFolder.get() { return kept }
        return home.appendingPathComponent(directoryName)
    }

    /// `~/.benji` itself, whatever the override (what Settings › Show Benji's folder reveals is `url()`).
    public static func home(_ home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(directoryName)
    }

    /// The move to `~/.benji` was impossible this run: keep using the folder it is in, for this run only.
    public static func useForThisRun(_ folder: URL?) { runFolder.set(folder) }

    /// The folder `useForThisRun` set, if any.
    public static var runFolderURL: URL? { runFolder.get() }

    private static let runFolder = Box()

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: URL?
        func get() -> URL? { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ new: URL?) { lock.lock(); defer { lock.unlock() }; value = new }
    }
}

/// `engine.log` (D-144): every line the engine writes to stderr, after `LogRedaction`, with the time
/// before it. 0600, rotated at `maxBytes`, two older copies kept.
public struct EngineLog {
    public static let fileName = "engine.log"
    public static let maxBytes = 1_000_000
    public static let keep = 2

    public let url: URL
    private let now: () -> Date

    public init(folder: URL, now: @escaping () -> Date = Date.init) {
        url = folder.appendingPathComponent(Self.fileName)
        self.now = now
    }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f
    }()

    /// The text of the line as it is kept, or nil for a blank one.
    public func line(_ stderrLine: String) -> String? {
        let trimmed = stderrLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "\(Self.timeFormat.string(from: now())) \(LogRedaction.redact(stderrLine.trimmingCharacters(in: .newlines)))\n"
    }

    @discardableResult
    public func append(_ stderrLine: String) -> Bool {
        guard let text = line(stderrLine) else { return false }
        return (try? PrivateFile.append(Data(text.utf8), to: url, maxBytes: Self.maxBytes, keep: Self.keep)) != nil
    }
}
