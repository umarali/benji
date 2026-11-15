import Foundation

// What the panel says about each turn besides the conversation itself: a quiet "heard
// you" mark once the engine took the message, one line of what Benji did, and "Cut off before
// it finished." with Retry when a turn that reached the engine ended without an answer.

/// One thing Benji did in a turn. Built only from what the app saw (a screenshot it sent, an
/// approval it showed, a drawing it made) and the engine's `activity` events, which name a kind
/// and, for a saved file, the file name only.
public enum TurnActivity: Equatable, Sendable {
    case lookedAtScreen
    case ranCommand
    case savedFile(name: String?)
    case readFile
    case lookedThroughFiles
    case lookedOnline
    case ranAutomation
    case ranShortcut
    case remembered
    case drewOnScreen
    /// A click, scroll, typing or key press done on the user's screen.
    case actedOnScreen
    /// An approval card: what Benji asked to do (the card's action, never its target) and how it ended.
    case asked(action: String, outcome: ApprovalOutcome)

    public enum ApprovalOutcome: Equatable, Sendable {
        case allowed, declined, noAnswer, stopped
    }

    /// It may have changed something on the Mac (ran, saved, automated, remembered, or an approved
    /// action). Doing the message again could do it twice, so such a turn gets no Retry.
    public var changesSomething: Bool {
        switch self {
        case .ranCommand, .savedFile, .ranAutomation, .ranShortcut, .remembered, .actedOnScreen: return true
        case .asked(_, let outcome): return outcome == .allowed
        case .lookedAtScreen, .readFile, .lookedThroughFiles, .lookedOnline, .drewOnScreen: return false
        }
    }

    /// The engine's `activity` event; nil for a kind this build doesn't know (a newer engine).
    public init?(kind: String, name: String?) {
        switch kind {
        case "command": self = .ranCommand
        case "file_saved":
            let file = name.map { ($0 as NSString).lastPathComponent }   // a name, never a folder
            self = .savedFile(name: file?.isEmpty == false ? file : nil)
        case "file_read": self = .readFile
        case "files_looked": self = .lookedThroughFiles
        case "web": self = .lookedOnline
        case "automation": self = .ranAutomation
        case "shortcut": self = .ranShortcut
        case "remembered": self = .remembered
        case "screen": self = .actedOnScreen
        default: return nil
        }
    }
}

public enum ActivityLine {
    public static let separator = " · "

    /// One short line, in the order things first happened: "Looked at your screen · Ran 2
    /// commands · Saved notes.md". Repeats are counted, not listed. Nil when nothing happened.
    public static func text(_ items: [TurnActivity]) -> String? {
        var order: [String] = []                 // group keys, first-seen order
        var counts: [String: Int] = [:]
        var files: [String] = []
        var unnamedFiles = 0
        var phrases: [String: String] = [:]      // one-off phrases (approvals) by key

        func see(_ key: String) {
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        for (i, item) in items.enumerated() {
            switch item {
            case .lookedAtScreen: see("screen")
            case .ranCommand: see("command")
            case .savedFile(let name):
                see("saved")
                if let name, !files.contains(name) { files.append(name) } else if name == nil { unnamedFiles += 1 }
            case .readFile: see("read")
            case .lookedThroughFiles: see("files")
            case .lookedOnline: see("web")
            case .ranAutomation: see("automation")
            case .ranShortcut: see("shortcut")
            case .remembered: see("remembered")
            case .drewOnScreen: see("drew")
            case .actedOnScreen: see("acted")
            case .asked(let action, let outcome):
                let key = "asked\(i)"
                see(key)
                phrases[key] = asked(action, outcome)
            }
        }
        let parts: [String] = order.compactMap { key in
            let n = counts[key] ?? 0
            switch key {
            case "screen": return "Looked at your screen"
            case "command": return n == 1 ? "Ran a command" : "Ran \(n) commands"
            case "saved": return saved(files, unnamed: unnamedFiles)
            case "read": return n == 1 ? "Read a file" : "Read \(n) files"
            case "files": return "Looked through your files"
            case "web": return "Looked online"
            case "automation": return n == 1 ? "Ran an automation" : "Ran \(n) automations"
            case "shortcut": return n == 1 ? "Ran a Shortcut" : "Ran \(n) Shortcuts"
            case "remembered": return "Remembered something"
            case "drew": return "Drew on your screen"
            case "acted": return n == 1 ? "Took a step on your screen" : "Took \(n) steps on your screen"
            default: return phrases[key]
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    static func saved(_ names: [String], unnamed: Int) -> String {
        let total = names.count + unnamed
        if unnamed == 0, names.count == 1 { return "Saved \(names[0])" }
        if unnamed == 0, names.count == 2 { return "Saved \(names[0]) and \(names[1])" }
        return total == 1 ? "Saved a file" : "Saved \(total) files"
    }

    static func asked(_ action: String, _ outcome: TurnActivity.ApprovalOutcome) -> String {
        let what = action.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = what.isEmpty ? "Asked first" : "Asked to \(what)"
        switch outcome {
        case .allowed: return "\(lead), you allowed it"
        case .declined: return "\(lead), you said no"
        case .noAnswer: return "\(lead), no answer, so no"
        case .stopped: return "\(lead), stopped"
        }
    }
}

/// One turn as the panel tells it: the user's message and what happened to it.
public struct TurnTrail: Equatable, Sendable {
    public let userLineID: UUID
    /// The user said it (a retry is spoken back the same way).
    public let spoken: Bool
    /// The message went to the engine (not still waiting on the Screen Ask card or a capture).
    public var sent = false
    /// The engine took it (`accepted`): the user's line gets its "heard you" mark.
    public var heard = false
    public var activities: [TurnActivity] = []
    public var answered = false
    public var finished = false
    /// Finished without an answer after reaching the engine: "Cut off before it finished."
    public var cutOff = false
    /// Approval outcome lines told by the activity line instead of as rows of their own.
    public var foldedLineIDs: Set<UUID> = []
    /// A retry is under way: if it ends unanswered, even before reaching the engine, it is cut off again.
    var retrying = false

    public init(userLineID: UUID, spoken: Bool) {
        self.userLineID = userLineID
        self.spoken = spoken
    }

    public static let cutOffLine = "Cut off before it finished."
    /// A cut-off turn that had already changed something: no Retry, since a retry could repeat it.
    public static let cutOffAfterChangeLine = "Cut off after it had started changing things. Check what was done before asking again."

    /// Something this turn did may have changed the Mac (see `TurnActivity.changesSomething`).
    public var changedSomething: Bool { activities.contains { $0.changesSomething } }

    /// The activity line, once the turn has finished.
    public var activityLine: String? { finished ? ActivityLine.text(activities) : nil }
}

extension CompanionState {
    /// The turn still running (or waiting to be sent), if any.
    var openTurnIndex: Int? {
        guard let i = turns.indices.last, !turns[i].finished else { return nil }
        return i
    }

    /// The last turn, when it was cut off: Retry resends its message (once nothing is running;
    /// a conversation that is only listening stops listening first, as for a typed message).
    /// Never a turn that had already changed something: a retry must not repeat a side effect.
    public var retryableTurn: TurnTrail? {
        guard let last = turns.last, last.cutOff, !last.changedSomething,
              lines.contains(where: { $0.id == last.userLineID }) else { return nil }
        return last
    }

    /// Benji is working on a sent message and has no answer yet: the conversation shows three soft dots.
    public var showsThinking: Bool {
        guard phase == .thinking, let i = openTurnIndex else { return false }
        return turns[i].sent && !turns[i].answered
    }

    mutating func startTurn(userLineID: UUID, spoken: Bool) {
        finishTurn()
        turns.append(TurnTrail(userLineID: userLineID, spoken: spoken))
    }

    mutating func finishTurn() {
        guard let i = openTurnIndex else { return }
        turns[i].finished = true
        turns[i].cutOff = !turns[i].answered && (turns[i].sent || turns[i].retrying)
        turns[i].retrying = false
    }

    mutating func noteActivity(_ activity: TurnActivity) {
        guard let i = openTurnIndex else { return }
        if activity == .lookedAtScreen || activity == .drewOnScreen, turns[i].activities.contains(activity) { return }
        turns[i].activities.append(activity)
    }

    /// An approval ended: its outcome row is still recorded, and the activity line tells it.
    mutating func noteApproval(_ action: String, _ outcome: TurnActivity.ApprovalOutcome, line: TranscriptLine) {
        lines.append(line)
        guard let i = openTurnIndex else { return }
        turns[i].activities.append(.asked(action: action, outcome: outcome))
        turns[i].foldedLineIDs.insert(line.id)
    }

    /// Retry: the cut-off attempt (its error, steps and screen mark) is dropped and the message
    /// starts again from the top, through the screen rules like any new message.
    mutating func retryLastTurn() -> Bool {
        guard !isBusy, let turn = retryableTurn, let at = lines.firstIndex(where: { $0.id == turn.userLineID }) else { return false }
        lines.removeSubrange((at + 1)...)
        var fresh = TurnTrail(userLineID: turn.userLineID, spoken: turn.spoken)
        fresh.retrying = true
        turns[turns.count - 1] = fresh
        lastError = nil
        phase = .thinking
        return true
    }
}
