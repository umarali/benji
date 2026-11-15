import Foundation

// What the open panel shows: only the conversation in the transcript, one status word that is
// never drawn twice, and one quiet status line for everything else (the current step, how to
// stop listening, why listening stopped). Pure decisions only; the app draws them.

// MARK: - Transcript rows

/// A screen picture sent with a message: shown as a small mark on that message, not as a row.
public struct PanelScreenMark: Equatable, Sendable {
    /// What was sent and to whom ("Screen attached · 1330×864 · sent to Anthropic").
    public let summary: String
    /// The in-memory thumbnail's key.
    public let attachmentID: String?
}

/// Under a finished turn's last row: what Benji did, and whether the turn was cut off.
public struct PanelTurnFooter: Equatable, Sendable {
    public var activity: String?
    public var cutOff: Bool
    /// The cut-off turn is the last one and nothing is running: it gets a Retry button.
    public var canRetry: Bool
    /// The cut-off turn had already changed something, so it has no Retry and says why.
    public var changedSomething = false

    public var cutOffText: String { changedSomething ? TurnTrail.cutOffAfterChangeLine : TurnTrail.cutOffLine }
}

public struct PanelRow: Equatable, Identifiable, Sendable {
    public let line: TranscriptLine
    public var screen: PanelScreenMark?
    /// Your message, taken by the engine: a small "heard you" mark.
    public var heard = false
    public var footer: PanelTurnFooter?
    public var id: UUID { line.id }
}

public enum PanelTranscript {
    /// The conversation only: your messages, Benji's answers, errors and approval outcomes.
    /// Tool steps live in the status line while Benji works, and screen attachments become a
    /// mark on the message they were sent with.
    /// With `turns`, approval outcomes are told by the turn's activity line rather than as
    /// rows, your messages carry the heard mark, and each finished turn gets its footer.
    public static func rows(_ lines: [TranscriptLine], turns: [TurnTrail] = [], busy: Bool = false) -> [PanelRow] {
        let folded = turns.reduce(into: Set<UUID>()) { $0.formUnion($1.foldedLineIDs) }
        var rows: [PanelRow] = []
        for line in lines {
            switch line.role {
            case .system where folded.contains(line.id):
                continue
            case .user, .assistant, .error, .system:
                rows.append(PanelRow(line: line))
            case .tool:
                continue
            case .attachment:
                let mark = PanelScreenMark(summary: line.text, attachmentID: line.attachmentID)
                if let i = rows.lastIndex(where: { $0.line.role == .user }) { rows[i].screen = mark }
            }
        }
        for (n, turn) in turns.enumerated() {
            guard let start = rows.firstIndex(where: { $0.line.id == turn.userLineID }) else { continue }
            rows[start].heard = turn.heard
            guard turn.finished else { continue }
            let activity = turn.activityLine
            guard activity != nil || turn.cutOff else { continue }
            // The turn's last row: just before the next message, or the end.
            let next = rows[(start + 1)...].firstIndex { $0.line.role == .user } ?? rows.endIndex
            let changed = turn.cutOff && turn.changedSomething
            rows[next - 1].footer = PanelTurnFooter(activity: activity, cutOff: turn.cutOff,
                                                    canRetry: turn.cutOff && !changed && n == turns.count - 1 && !busy,
                                                    changedSomething: changed)
        }
        return rows
    }
}

// MARK: - The status word

/// The status word changes by fading the old word out and then the new one in, so only one
/// word is ever drawn. Cross-fading two labels in place would draw "Done" over "Speaking"
/// as "Doneking". Words that arrive mid-swap replace the pending one.
public struct StatusWordSwap: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// Nothing to do (the same word, or a swap already running that will pick this one up).
        case none
        /// Show the new word at once (Reduce Motion, or the label was already hidden).
        case show
        /// Fade the shown word out, then call `fadedOut()`.
        case fadeOut
    }

    /// The one word the label draws.
    public private(set) var shown: String
    /// Whether it is drawn at full strength (false while fading out or hidden).
    public private(set) var visible = true
    public private(set) var pending: String?

    public init(_ word: String) {
        shown = word
    }

    public mutating func request(_ word: String, reduceMotion: Bool) -> Step {
        if pending != nil {
            pending = word == shown ? nil : word
            if pending == nil { visible = true; return .show }
            return .none
        }
        guard word != shown else { return .none }
        if reduceMotion {
            shown = word
            visible = true
            return .show
        }
        pending = word
        visible = false
        return .fadeOut
    }

    /// The old word has faded out: the label now draws the newest word and fades it in.
    public mutating func fadedOut() {
        if let next = pending { shown = next }
        pending = nil
        visible = true
    }
}

// MARK: - The open panel's status line

extension NotchStatusInfo {
    /// The one quiet line under the open panel's band, or nil when the panel itself already
    /// says it (your message, the answer being spoken, the error row, the approval card) or
    /// there is nothing to say. `info` is `make(state, …)` without the live words: those show in
    /// the transcript.
    public static func openLine(_ info: NotchStatusInfo, state: CompanionState) -> String? {
        switch info.status {
        case .working:
            // Before the first tool step the working line is your own message, already a row.
            if state.acting != nil { return info.line }
            return state.lines.last { $0.role == .tool || $0.role == .user }?.role == .tool ? info.line : nil
        case .listening, .looking, .done: return info.line
        case .ready: return info.line == readyLine ? nil : info.line
        case .transcribing, .approval, .speaking, .error: return nil
        }
    }
}
