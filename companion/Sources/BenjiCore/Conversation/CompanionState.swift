import Foundation

/// The presentation states the app can show. Only states backed by a real
/// backend or voice event are ever entered.
public enum CompanionPhase: String, Equatable, Sendable {
    case idle
    case listening       // the mic is open
    case transcribing    // turning speech into text
    case thinking        // backend running / tools executing
    case speaking        // Benji is reading the answer aloud
    case awaitingApproval
    case error
}

public struct ApprovalRequest: Equatable, Identifiable, Sendable {
    public let id: String
    public let action: String   // e.g. "run a potentially destructive shell command"
    public let target: String   // e.g. "rm -rf build"

    public init(id: String, action: String, target: String) {
        self.id = id
        self.action = action
        self.target = target
    }
}

public enum TranscriptRole: String, Equatable, Sendable {
    case user, tool, assistant, system, error, attachment
}

public struct TranscriptLine: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let role: TranscriptRole
    public let text: String
    /// For `.attachment` lines: key the UI uses to look up the thumbnail it sent.
    public let attachmentID: String?
    /// When the line was added, for the panel's date lines. Nil for lines restored from
    /// a saved conversation that has no times.
    public let at: Date?

    public init(role: TranscriptRole, text: String, attachmentID: String? = nil, id: UUID = UUID(),
                at: Date? = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.attachmentID = attachmentID
        self.at = at
    }
}

public struct CompanionState: Equatable, Sendable {
    public var phase: CompanionPhase = .idle
    public var lines: [TranscriptLine] = []
    public var pendingApproval: ApprovalRequest?
    public var lastError: String?
    public var micActive: Bool = false
    /// One per message, in order: heard, what Benji did, cut off.
    public var turns: [TurnTrail] = []
    /// While Benji does a step on the screen without a card: "Scrolling down in Safari ·
    /// Esc stops", for the peek and the panel's status line.
    public var acting: String?
    public init() {}

    public var isBusy: Bool {
        switch phase {
        case .idle, .error: return false
        default: return true
        }
    }
}

/// Events that drive the state. Each corresponds to a real backend signal or a
/// user action — there is no synthetic/mock conversation.
public enum CompanionEvent: Equatable, Sendable {
    case submitText(String)
    case backendStarted
    case toolProgress(name: String, detail: String)
    case assistantAnswer(String)
    case approvalRequested(ApprovalRequest)
    case approvalResolved(Bool)
    /// Nobody answered the approval in time: a denial, recorded as timed out.
    case approvalTimedOut
    case backendError(String)
    case backendFinished(Int32)
    case cancel
    // Screen context (the mode itself lives in ScreenModeState):
    case screenAttached(id: String, summary: String)
    // Voice:
    case micStarted
    case micStopped
    case transcribingStarted
    case transcribed(String)
    case speakingStarted
    case speakingFinished
    /// The conversation's mic opened while Benji speaks (barge-in): it hears, Benji talks on.
    case micOpenedOverSpeech
    // Clears the panel for a fresh conversation (ignored while busy).
    case newConversation
    /// Shows a saved conversation's lines as the current one (only while nothing runs: idle, an
    /// error, or listening). A listening mic stays on.
    case openConversation([TranscriptLine])
    // A one-line note from Benji itself (e.g. "Conversation ended."); the phase is unchanged.
    case notice(String)
    // The turn's message went to the engine, and the engine took it.
    case turnSent
    case engineAccepted
    /// Something Benji did this turn, for the activity line.
    case activity(TurnActivity)
    /// Resend the last, cut-off message (ignored unless `retryableTurn`).
    case retry
    /// The user cut Benji's spoken answer off: the last answer line shows only what was
    /// said aloud (`CutOffReply.shown`), and a note says Benji stopped there.
    case answerCutOff(shown: String?)
    /// Benji started a screen step without a card: what it is doing, and how to stop it.
    case screenActing(String)
    case screenActingEnded
}

/// Pure reducer: applies one event to the state. Default-safe: cancellation while
/// awaiting approval is treated as a denial.
public func reduce(_ s: inout CompanionState, _ e: CompanionEvent) {
    switch e {
    case .screenActing(let line):
        if s.phase == .thinking { s.acting = line }
        return
    case .screenActingEnded:
        s.acting = nil
        return
    case .cancel, .backendFinished, .backendError, .assistantAnswer, .approvalRequested, .newConversation:
        s.acting = nil
    default:
        break
    }
    switch e {
    case .submitText(let raw):
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let line = TranscriptLine(role: .user, text: text)
        s.lines.append(line)
        s.startTurn(userLineID: line.id, spoken: false)
        s.lastError = nil
        s.phase = .thinking

    case .screenAttached(let id, let summary):
        s.lines.append(TranscriptLine(role: .attachment, text: summary, attachmentID: id))
        s.noteActivity(.lookedAtScreen)

    case .backendStarted:
        if s.phase == .idle { s.phase = .thinking }

    case .toolProgress(let name, let detail):
        let text = detail.isEmpty ? name : "\(name) \(detail)"
        s.lines.append(TranscriptLine(role: .tool, text: text))
        if s.phase != .awaitingApproval { s.phase = .thinking }

    case .assistantAnswer(let answer):
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            s.lines.append(TranscriptLine(role: .assistant, text: text))
            if let i = s.openTurnIndex { s.turns[i].answered = true }
        }

    case .approvalRequested(let req):
        s.pendingApproval = req
        s.phase = .awaitingApproval

    case .approvalResolved(let approved):
        if let req = s.pendingApproval {
            s.noteApproval(req.action, approved ? .allowed : .declined, line: TranscriptLine(
                role: .system,
                text: (approved ? "Approved: " : "Denied: ") + req.action))
        }
        s.pendingApproval = nil
        s.phase = .thinking   // backend resumes after the decision

    case .approvalTimedOut:
        if let req = s.pendingApproval {
            s.noteApproval(req.action, .noAnswer,
                           line: TranscriptLine(role: .system, text: ApprovalPolicy.timedOutRecord(action: req.action)))
        }
        s.pendingApproval = nil
        s.phase = .thinking   // the backend is told No

    case .backendError(let message):
        s.lastError = message
        s.lines.append(TranscriptLine(role: .error, text: message))
        s.pendingApproval = nil
        s.micActive = false
        s.phase = .error

    case .backendFinished:
        s.finishTurn()
        s.pendingApproval = nil
        // The process can exit while the answer is still being spoken; speaking
        // ends via its own event.
        if s.phase != .error && s.phase != .speaking { s.phase = .idle }

    case .cancel:
        if let req = s.pendingApproval {
            s.noteApproval(req.action, .stopped, line: TranscriptLine(role: .system, text: "Denied: cancelled"))
        }
        s.finishTurn()
        s.pendingApproval = nil
        s.micActive = false
        s.phase = .idle

    case .micStarted:
        s.micActive = true
        s.phase = .listening

    case .micStopped:
        // Also ends a transcription that came to nothing (a conversation drops noise silently).
        s.micActive = false
        if s.phase == .listening || s.phase == .transcribing { s.phase = .idle }

    case .transcribingStarted:
        s.micActive = false
        s.phase = .transcribing

    case .transcribed(let text):
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            let line = TranscriptLine(role: .user, text: t)
            s.lines.append(line)
            s.startTurn(userLineID: line.id, spoken: true)
        }
        s.micActive = false
        s.phase = .thinking

    case .speakingStarted:
        s.phase = .speaking

    case .micOpenedOverSpeech:
        s.micActive = true

    case .speakingFinished:
        if s.phase == .speaking { s.phase = .idle }

    case .notice(let text):
        s.lines.append(TranscriptLine(role: .system, text: text))

    case .newConversation:
        guard !s.isBusy else { return }
        s.lines.removeAll()
        s.turns.removeAll()
        s.lastError = nil
        s.phase = .idle

    case .openConversation(let lines):
        guard HomeView.keepsRequest(phase: s.phase) else { return }
        s.lines = lines
        s.turns.removeAll()
        s.lastError = nil
        s.pendingApproval = nil
        if s.phase == .error { s.phase = .idle }

    case .turnSent:
        if let i = s.openTurnIndex { s.turns[i].sent = true }

    case .engineAccepted:
        if let i = s.openTurnIndex, s.turns[i].sent { s.turns[i].heard = true }

    case .activity(let activity):
        s.noteActivity(activity)

    case .retry:
        _ = s.retryLastTurn()

    case .screenActing, .screenActingEnded:
        break   // handled above
    case .answerCutOff(let shown):
        if let shown, let i = s.lines.lastIndex(where: { $0.role == .assistant }),
           !s.lines[i...].contains(where: { $0.role == .user }) {
            s.lines[i] = TranscriptLine(role: .assistant, text: shown, id: s.lines[i].id, at: s.lines[i].at)
        }
        s.lines.append(TranscriptLine(role: .system, text: CutOffReply.notice))
    }
}
