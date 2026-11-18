import Foundation

// Background jobs: the app's side. The engine
// runs a job as a second turn and sends one `job` event per change, a snapshot whose `state` it
// derived in code from the stored record (benji/jobs.py `derive_state`); nothing here reads a
// state out of text the model wrote. Pure, so it is tested headlessly.

/// The state of a job as the panel shows it. The raw values are the engine's.
public enum JobState: String, CaseIterable, Equatable, Sendable {
    case queued, working
    case needsYou = "needs-you"
    case done, failed, stopped

    /// The job is still the engine's to run: it can be steered or stopped.
    public var isLive: Bool { self == .queued || self == .working || self == .needsYou }

    /// The short word in the row.
    public var word: String {
        switch self {
        case .queued: return "Starting"
        case .working: return "Working"
        case .needsYou: return "Needs you"
        case .done: return "Done"
        case .failed: return "Didn't finish"
        case .stopped: return "Stopped"
        }
    }
}

/// The approval a parked job waits on. Answered with the app's own button, never by speech.
public struct JobPending: Equatable, Sendable {
    public let request: String
    public let action: String
    public let target: String

    public init(request: String, action: String, target: String) {
        self.request = request
        self.action = action
        self.target = target
    }
}

/// A file a job made. The engine checked that it exists when the job ended.
public struct JobFile: Equatable, Sendable {
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// A job's schedule, as the engine says it: the words, when it runs next, and whether it is
/// paused and why. The user changes it with the row's own buttons; the model can only propose one,
/// on a card. Repeat runs happen only while Benji is open and the Mac is awake.
public struct JobSchedule: Equatable, Sendable {
    /// "Every day at 09:00", or "…, paused after three runs in a row didn't finish".
    public let text: String
    /// The next run, unless the schedule is paused or all schedules are switched off.
    public let next: Date?
    public let paused: Bool
    /// "user" or "failures" when paused.
    public let reason: String
    public let last: Date?
    /// The global switch (Settings) is on. Off: nothing runs, whatever the job says.
    public let switchOn: Bool

    public init(text: String, next: Date? = nil, paused: Bool = false, reason: String = "", last: Date? = nil,
                switchOn: Bool = true) {
        self.text = text
        self.next = next
        self.paused = paused
        self.reason = reason
        self.last = last
        self.switchOn = switchOn
    }

    static func decode(_ o: [String: Any]) -> JobSchedule? {
        guard let text = o["text"] as? String, !text.isEmpty else { return nil }
        func date(_ key: String) -> Date? { (o[key] as? Double).map { Date(timeIntervalSince1970: $0) } }
        return JobSchedule(text: text, next: date("next"), paused: o["paused"] as? Bool ?? false,
                           reason: o["reason"] as? String ?? "", last: date("last"),
                           switchOn: o["switch_on"] as? Bool ?? true)
    }

    /// The row's line: what repeats and when it next runs, or why it doesn't. Dates are written in
    /// the user's calendar ("Mon 09:00"); `now` and `calendar` are passed in for the tests.
    public func rowLine(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        if !switchOn { return "\(text) · all repeating is switched off in Settings" }
        if paused { return text }
        guard let next else { return text }
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = locale
        f.timeZone = calendar.timeZone
        let sameDay = calendar.isDate(next, inSameDayAs: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now).map { calendar.isDate(next, inSameDayAs: $0) } ?? false
        f.dateFormat = sameDay || tomorrow ? "HH:mm" : "EEE HH:mm"
        let when = sameDay ? "today \(f.string(from: next))" : tomorrow ? "tomorrow \(f.string(from: next))" : f.string(from: next)
        return "\(text) · next \(when)"
    }

    /// The buttons the row offers for it: pause or resume, and delete.
    public var canPause: Bool { !paused }
    public var canResume: Bool { paused }
}

/// One `job` event: the job as of now.
public struct JobSnapshot: Equatable, Sendable, Identifiable {
    public static let maxChips = 3

    public let id: String
    public let title: String
    public let state: JobState
    /// What a working job is doing ("Reading a page"): a kind, never a command, path or query.
    public let line: String
    public let pending: JobPending?
    /// The turn_end's spoken line, when done: for the speaker ("output slash tea dot txt").
    public let spoken: String
    /// The turn_end's written line, when done: what the row, the peek and the thread show. The
    /// engine makes one from the spoken line when the model gave none. Empty when the event has none.
    public let written: String
    public let files: [JobFile]
    /// At most three next steps, when done.
    public let chips: [String]
    public let error: String
    /// The job read outside content (or inherited that from the turn that started it): every write asks.
    public let tainted: Bool
    /// Which kinds of outside content: "screen", "web", "browser", "file" joined with "+" in that
    /// order (engine: gate.taint_string). Empty when the event says only `tainted`.
    public let taint: String
    /// The sites (https origins) the user approved for this job to read in their Chrome; empty
    /// for a job with no browser access. A card adds one during the job.
    public let sites: [String]
    /// The sites the user also allowed this job to click and type on, one second card each.
    public let actSites: [String]
    // The fields below are optional in the event; each has a default when it is left out.
    /// What the job was told (its goal, what done means, what the user said, the sites and files they
    /// named), cut. Shown on the start row and in the details so the user sees it.
    public let brief: String
    /// Which run of the job this is (1 for the first); a continued or repeating job counts up.
    public let run: Int
    /// A finished (or limit-stopped) job reports back: what is done, what is left, and a question.
    public let done: String
    public let left: String
    public let ask: String
    /// The run used all its steps and said so, rather than failing.
    public let stoppedAtLimit: Bool
    /// A failed or stopped job can be continued from the row.
    public let canContinue: Bool
    public private(set) var canResume: Bool
    public private(set) var recoveryGeneration: String
    /// This run was started by the schedule and nobody is watching it.
    public let unattended: Bool
    /// The run found something the last one didn't (decided by the engine, in code).
    public let news: Bool
    /// A repeat run with nothing the user needs to hear: no peek, no sound, no thread.
    public let quiet: Bool
    public let schedule: JobSchedule?

    public init(id: String, title: String, state: JobState, line: String = "", pending: JobPending? = nil,
                spoken: String = "", written: String = "", files: [JobFile] = [], chips: [String] = [],
                error: String = "", tainted: Bool = false, taint: String = "", sites: [String] = [],
                brief: String = "", run: Int = 1, done: String = "", left: String = "", ask: String = "",
                stoppedAtLimit: Bool = false, canContinue: Bool = false, unattended: Bool = false,
                news: Bool = true, quiet: Bool = false, schedule: JobSchedule? = nil,
                actSites: [String] = [], canResume: Bool = false, recoveryGeneration: String = "") {
        self.id = id
        self.title = title
        self.state = state
        self.line = line
        self.pending = pending
        self.spoken = spoken
        self.written = written
        self.files = files
        self.chips = Array(chips.prefix(Self.maxChips))
        self.error = error
        self.tainted = tainted
        self.taint = taint
        self.sites = sites
        self.actSites = actSites
        self.brief = brief
        self.run = max(1, run)
        self.done = done
        self.left = left
        self.ask = ask
        self.stoppedAtLimit = stoppedAtLimit
        self.canContinue = canContinue
        self.canResume = canResume && state == .failed && !recoveryGeneration.isEmpty
        self.recoveryGeneration = self.canResume ? recoveryGeneration : ""
        self.unattended = unattended
        self.news = news
        self.quiet = quiet
        self.schedule = schedule
    }

    public func withoutResume() -> JobSnapshot {
        var copy = self
        copy.canResume = false
        copy.recoveryGeneration = ""
        return copy
    }

    /// What the row, the peek and the thread say a finished job did: the written line, else the
    /// spoken one when there is no written line.
    public var shownResult: String { written.isEmpty ? spoken : written }

    /// The line under a tainted job's row: what actually applies. Looking at the screen alone is
    /// weaker than a page, a file or the browser, and the line says so; anything stronger,
    /// or an engine that doesn't say which, keeps the general wording. Nil when it read nothing.
    public var taintLine: String? {
        guard tainted else { return nil }
        if taint == "screen" { return "Benji looked at your screen, so changes ask first." }
        return "It read outside content, so everything it changes asks first."
    }

    /// "Can read in your Chrome: example.com, other.org", or nil for a job with no browser access.
    public var sitesLine: String? {
        sites.isEmpty ? nil : "Can read in your Chrome: " + BrowserSites.line(sites)
    }

    /// "Can click and type on: example.com", or nil when the user hasn't allowed that for any site.
    public var actSitesLine: String? {
        actSites.isEmpty ? nil : "Can click and type on: " + BrowserSites.line(actSites)
    }

    /// Nil when it isn't a job this build understands (no id, an unknown state).
    public static func decode(_ o: [String: Any]) -> JobSnapshot? {
        guard let id = o["id"] as? String, !id.isEmpty,
              let state = (o["state"] as? String).flatMap(JobState.init(rawValue:)) else { return nil }
        func str(_ key: String) -> String { o[key] as? String ?? "" }
        let pending = (o["pending"] as? [String: Any]).map {
            JobPending(request: $0["request"] as? String ?? "", action: $0["action"] as? String ?? "",
                       target: $0["target"] as? String ?? "")
        }
        let files = (o["files"] as? [[String: Any]] ?? []).compactMap { f -> JobFile? in
            guard let name = f["name"] as? String, let path = f["path"] as? String else { return nil }
            return JobFile(name: name, path: path)
        }
        return JobSnapshot(id: id, title: str("title"), state: state, line: str("line"),
                           pending: state == .needsYou ? pending.flatMap { $0.request.isEmpty ? nil : $0 } : nil,
                           spoken: str("spoken"), written: str("written"), files: files,
                           chips: (o["chips"] as? [String] ?? []).filter { !$0.isEmpty },
                           error: str("error"), tainted: o["tainted"] as? Bool ?? false, taint: str("taint"),
                           sites: (o["sites"] as? [String] ?? []).filter { $0.hasPrefix("https://") },
                           brief: str("brief"), run: o["run"] as? Int ?? 1, done: str("done"), left: str("left"),
                           ask: str("ask"), stoppedAtLimit: o["stopped_at_limit"] as? Bool ?? false,
                           canContinue: o["can_continue"] as? Bool ?? false, unattended: o["unattended"] as? Bool ?? false,
                           news: o["news"] as? Bool ?? true, quiet: o["quiet"] as? Bool ?? false,
                           schedule: (o["schedule"] as? [String: Any]).flatMap(JobSchedule.decode),
                           actSites: (o["act_sites"] as? [String] ?? []).filter { $0.hasPrefix("https://") },
                           canResume: o["can_resume"] as? Bool ?? false, recoveryGeneration: str("recovery_generation"))
    }

    /// The row's second line.
    public var detail: String {
        switch state {
        case .queued: return "Starting · Esc cancels"
        case .working: return line.isEmpty ? "Working" : line
        case .needsYou: return "Waiting for your answer"   // the card's words are in the row's approval block
        case .done: return shownResult.isEmpty ? "Done" : shownResult
        case .failed: return error.isEmpty ? "Didn't finish" : error
        case .stopped: return stoppedAtLimit && !shownResult.isEmpty ? shownResult : "Stopped"
        }
    }

    /// The peek's line under the notch, or nil when the job isn't worth a peek (stopped, or a repeat
    /// run with nothing new: quiet by default).
    public var peekLine: String? {
        if quiet { return nil }
        switch state {
        case .queued: return "Starting “\(title)” · Esc cancels"
        case .working: return "\(title): \(line.isEmpty ? "Working" : line)"
        case .needsYou: return "\(title) needs you" + (pending.map { ": \($0.action)" } ?? "")
        case .done: return shownResult.isEmpty ? "\(title) is done" : shownResult
        case .failed: return "\(title) didn't finish"
        case .stopped: return stoppedAtLimit ? "\(title) stopped at its step limit" : nil
        }
    }

    /// Worth opening the notch's peek for by itself: it needs the user, or just ended (until seen).
    /// Never for a quiet run.
    public var wantsAttention: Bool {
        !quiet && (state == .needsYou || state == .done || state == .failed || (state == .stopped && stoppedAtLimit))
    }

    /// The row's "Continue" button: a job that failed or stopped can be picked up again.
    /// Not a job that was stopped by the user in the beat (nothing was done yet).
    public var offersContinue: Bool { canContinue && (state == .failed || state == .stopped) }

    /// What a finished job leaves in the details: what is done, what is left, and its question.
    public var reportBack: [String] {
        var lines: [String] = []
        if !done.isEmpty { lines.append("Done: \(done)") }
        if !left.isEmpty { lines.append("Left: \(left)") }
        if !ask.isEmpty { lines.append(ask) }
        return lines
    }

    /// The thread keeps the story of a job; a quiet repeat run adds nothing to it.
    public var savesThread: Bool { !quiet }
}

// MARK: - Cues

/// Which of the three cues a change of state maps to, behind a setting that is off by default.
public enum JobCue: String, Equatable, Sendable {
    case done, needsApproval, error
}

public enum JobCues {
    public static let defaultsKey = "jobCues"

    /// Off unless switched on: Benji makes no sounds by default.
    public static func isOn(_ stored: Any?) -> Bool { (stored as? Bool) ?? false }

    /// The cue for a job going from `old` (nil: first seen) to `new`; nil when nothing to cue.
    public static func cue(from old: JobState?, to new: JobState) -> JobCue? {
        guard old != new else { return nil }
        switch new {
        case .needsYou: return .needsApproval
        case .done: return .done
        case .failed: return .error
        case .queued, .working, .stopped: return nil
        }
    }
}

/// "Background jobs": on unless set to false (`defaults write com.emerssive.heybenji.app backgroundJobs -bool NO`).
public enum JobsSetting {
    public static let defaultsKey = "backgroundJobs"

    public static func isOn(_ stored: Any?) -> Bool { (stored as? Bool) ?? true }
}

/// The words Settings uses for repeating jobs.
public enum JobCopy {
    public static let schedulesDetail = "A job you asked to repeat runs again on its schedule. Turning this off stops every schedule at once, and a repeat run in progress."
    public static let schedulesFooter = "Repeat runs happen only while Benji is open and your Mac is awake; a run missed while it slept happens once when it wakes. They only read: anything that writes or acts waits for you."
}

/// "Run repeating jobs": the one switch for every schedule. On unless set to false
/// (`defaults write com.emerssive.heybenji.app jobSchedules -bool NO`, or Settings). Nothing repeats until a user
/// has approved a schedule on a card, so on is not a surprise; off stops every schedule at once.
public enum JobSchedulesSetting {
    public static let defaultsKey = "jobSchedules"

    public static func isOn(_ stored: Any?) -> Bool { (stored as? Bool) ?? true }

    /// A schedule is kept beside its job's folder as `<id>.schedule.json` (benji/schedule.py).
    /// The app starts the engine at launch only when at least one exists, so a repeat run can happen
    /// while Benji is open and idle; a `.bad` or `.tmp` file is not a schedule.
    public static func existsOnDisk(jobsFolder: URL, fileManager: FileManager = .default) -> Bool {
        let names = (try? fileManager.contentsOfDirectory(atPath: jobsFolder.path)) ?? []
        return names.contains { $0.hasSuffix(".schedule.json") && ConversationStore.isValidID(String($0.dropLast(".schedule.json".count))) }
    }
}

/// A job's own folder (`<jobs>/<id>/`: `report.md`, `output/`), for the row's
/// "Show in Finder". Only a real job id makes a path, so nothing else can be reached through it.
public enum JobFolder {
    public static let buttonTitle = "Show in Finder"
    public static let help = "Show this job's folder (its report and output) in Finder"

    public static func url(id: String, jobsFolder: URL) -> URL? {
        guard ConversationStore.isValidID(id) else { return nil }
        return jobsFolder.appendingPathComponent(id, isDirectory: true)
    }
}

// MARK: - The thread

/// A job's thread as a saved conversation, so it opens in the existing history view: its id is
/// the job's id (a UUID, as the store wants), its lines say what happened and what came of it.
public enum JobThread {
    public static let titlePrefix = "Job · "

    public static func conversation(_ job: JobSnapshot, started: Date, now: Date) -> SavedConversation? {
        guard ConversationStore.isValidID(job.id) else { return nil }
        var lines = [SavedLine(role: .system, text: "Background job: \(job.title)", at: started)]
        switch job.state {
        case .queued, .working:
            break
        case .needsYou:
            lines.append(SavedLine(role: .system, text: "Waiting for you: \(job.pending?.action ?? "an approval")", at: now))
        case .done:
            var text = job.shownResult.isEmpty ? "Done." : job.shownResult
            if !job.left.isEmpty { text += "\n\nLeft: " + job.left }
            if !job.ask.isEmpty { text += "\n\n" + job.ask }
            if !job.files.isEmpty { text += "\n\nFiles: " + job.files.map(\.name).joined(separator: ", ") }
            lines.append(SavedLine(role: .assistant, text: text, at: now))
        case .failed:
            lines.append(SavedLine(role: .error, text: job.error.isEmpty ? "The job didn't finish." : job.error, at: now))
        case .stopped:
            if job.stoppedAtLimit, !job.shownResult.isEmpty {
                var text = job.shownResult
                if !job.ask.isEmpty { text += "\n\n" + job.ask }
                lines.append(SavedLine(role: .assistant, text: text, at: now))
            } else {
                lines.append(SavedLine(role: .system, text: "Stopped.", at: now))
            }
        }
        return SavedConversation(id: job.id, title: titlePrefix + ConversationTitle.shorten(job.title),
                                 started: started, updated: now, lines: lines, taint: taint(of: job))
    }

    /// The outside content the job read stays in its thread: continuing the thread asks before a
    /// change, as the job did. The screen alone does not carry over. A job that says only `tainted`
    /// counts as a file read outside its folder, as the engine counts it.
    public static func taint(of job: JobSnapshot) -> CarriedTaint? {
        guard job.tainted else { return nil }
        let carried = ["web", "browser", "file"]
        let named = job.taint.split(separator: "+").map(String.init)
        let kinds = job.taint.isEmpty ? ["file"] : carried.filter(named.contains)
        return kinds.isEmpty ? nil : CarriedTaint(kinds: kinds, note: "content a background job read")
    }
}
