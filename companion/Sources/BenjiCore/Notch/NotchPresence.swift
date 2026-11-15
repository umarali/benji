import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// What the notch object shows and when (README "Where Benji lives", Motion.md "Transitions").
// Pure decisions only; the app draws and schedules.

extension NotchSize: Comparable {
    /// Closed < peek < card < open: the sizes are nested, so the larger one always contains the smaller.
    public var rank: Int {
        switch self { case .closed: return 0; case .peek: return 1; case .card: return 2; case .open: return 3 }
    }

    public static func < (a: NotchSize, b: NotchSize) -> Bool { a.rank < b.rank }
}

// MARK: - Which size

/// The real signals that decide the size. Nothing else may open the notch object.
public struct NotchPresenceInputs: Equatable, Sendable {
    public var phase: CompanionPhase
    /// The user asked for the full panel (click, typing, menu item, a typed turn).
    public var userOpened: Bool
    /// The pointer rested in the hot zone and hasn't been gone longer than the close grace.
    public var hovered: Bool
    /// The Done hold after an answer is running.
    public var doneHolding: Bool
    /// The user has seen the current error (opened the panel, or hovered and left).
    public var errorDismissed: Bool
    /// A background job is in its beat, or has news the user hasn't seen.
    public var jobPeek: Bool
    /// An app offer is waiting for an answer.
    public var appOffer: Bool

    public init(phase: CompanionPhase, userOpened: Bool = false, hovered: Bool = false,
                doneHolding: Bool = false, errorDismissed: Bool = false, jobPeek: Bool = false,
                appOffer: Bool = false) {
        self.phase = phase
        self.userOpened = userOpened
        self.hovered = hovered
        self.doneHolding = doneHolding
        self.errorDismissed = errorDismissed
        self.jobPeek = jobPeek
        self.appOffer = appOffer
    }
}

public enum NotchPresence {
    /// Open when asked, or while an approval waits for its answer (the card needs the room and
    /// the keyboard); peek while something real is going on (listening, transcribing, working,
    /// speaking), during the Done hold, while an unseen error is held, while hovered, or while a
    /// background job has a beat or news to show; the card while an app offer waits, and only when
    /// nothing else has the notch; closed otherwise.
    public static func targetSize(_ i: NotchPresenceInputs) -> NotchSize {
        if i.userOpened { return .open }
        switch i.phase {
        case .awaitingApproval:
            return .open
        case .listening, .transcribing, .thinking, .speaking:
            return .peek
        case .error where !i.errorDismissed:
            return .peek
        case .idle where i.appOffer && !i.doneHolding && !i.jobPeek:
            return .card
        case .idle, .error:
            return i.doneHolding || i.hovered || i.jobPeek ? .peek : .closed
        }
    }

    /// Whether the pointer leaving may close the object after the grace: only when nothing is
    /// going on and nothing is waiting in the composer. Never while a conversation is on: the
    /// moments between turns are idle, and the user is often reading with the pointer elsewhere.
    public static func mayCloseOnLeave(phase: CompanionPhase, composerEmpty: Bool, panelFocused: Bool,
                                       conversationOn: Bool = false) -> Bool {
        (phase == .idle || phase == .error) && composerEmpty && !panelFocused && !conversationOn
    }

    /// A turn finished with an answer: the engine exited while working, or the spoken answer ended.
    /// Cancels and errors are never Done.
    public static func isDone(event: CompanionEvent, before: CompanionPhase, after: CompanionPhase) -> Bool {
        guard after == .idle else { return false }
        switch event {
        case .backendFinished: return before == .thinking
        case .speakingFinished: return before == .speaking
        default: return false
        }
    }

    /// Done hold for the Done line ("All set." is 2 words → 1.5 s).
    public static var doneHold: Double {
        MotionTiming.doneHold(words: NotchStatusInfo.doneLine.split(separator: " ").count)
    }
}

// MARK: - The morph between sizes

/// What fades: the wings beside the hardware notch (glyph and state word, every size but closed),
/// the peek's line row, the card's offer, and the open panel's content.
public enum NotchLayer: CaseIterable, Sendable {
    case wings, line, offer, panel

    public static func layers(for size: NotchSize) -> Set<NotchLayer> {
        switch size {
        case .closed: return []
        case .peek: return [.wings, .line]
        case .card: return [.wings, .offer]
        case .open: return [.wings, .panel]
        }
    }
}

/// One size change as Motion.md schedules it.
public struct NotchMorphPlan: Equatable, Sendable {
    /// The spring for the shape; nil under Reduce Motion (a `motion-reduce` crossfade instead).
    public var spring: SpringToken?
    /// When the shape starts: 100 ms after content starts fading out when shrinking from rest.
    public var shapeDelay: Double
    /// Layers that fade out at once (`motion-fade` out).
    public var fadeOut: Set<NotchLayer>
    /// Layers that fade in at `fadeInDelay` (`motion-fade` in), at 65% of the morph.
    public var fadeIn: Set<NotchLayer>
    public var fadeInDelay: Double
    /// When the shape has settled, so a window sized for the larger shape may shrink.
    public var settleTime: Double

    public static func plan(from: NotchSize, to: NotchSize, fromRest: Bool, reduceMotion: Bool) -> NotchMorphPlan {
        let before = NotchLayer.layers(for: from), after = NotchLayer.layers(for: to)
        let out = before.subtracting(after), into = after.subtracting(before)
        if reduceMotion {
            return NotchMorphPlan(spring: nil, shapeDelay: 0, fadeOut: out, fadeIn: into,
                                  fadeInDelay: 0, settleTime: MotionTokens.reduceDuration)
        }
        let spring = MotionTokens.morph(from: from, to: to)
        let delay = to < from && fromRest ? MotionTiming.shrinkShapeDelay : 0
        return NotchMorphPlan(spring: spring, shapeDelay: delay, fadeOut: out, fadeIn: into,
                              fadeInDelay: delay + spring.contentFadeInDelay,
                              settleTime: delay + spring.settleTime)
    }
}

// MARK: - What the wings and line say

/// The states the notch can show, each from a real signal (README, States). The README also
/// lists Pointing and Needs permission; neither is a notch status here.
public enum NotchStatus: String, CaseIterable, Sendable {
    case ready, listening, transcribing, working, looking, approval, speaking, done, error
}

/// Which colour token a glyph uses. The app maps these to the dark-appearance system colours.
public enum NotchTint: Equatable, Sendable {
    case mint, listening, listeningDimmed, secondary, looking, approval, done, error
}

public struct NotchStatusInfo: Equatable, Sendable {
    public var status: NotchStatus
    /// SF Symbol name.
    public var symbol: String
    /// The word in the right wing (`peek-status`), short enough for the 74 pt wing.
    public var word: String
    /// The one `peek-line` below the notch.
    public var line: String
    public var tint: NotchTint

    public static let readyLine = "Here if you need me."
    public static let listeningLine = "Go on."
    /// Listening in a hands-free conversation, before anything is heard: how to end it.
    public static let conversationListeningLine = "Go on. Say “that's all” to stop."
    public static let doneLine = "All set."

    public init(status: NotchStatus, symbol: String, word: String, line: String, tint: NotchTint) {
        self.status = status
        self.symbol = symbol
        self.word = word
        self.line = line
        self.tint = tint
    }

    /// The status for a state. `partial` is what the recogniser has heard so far; `doneHolding`
    /// is true during the Done hold; `conversation` while a hands-free conversation is on;
    /// `note` is a short system note for the Ready line ("Stopped listening."), or, while listening
    /// with nothing heard yet, why the last words weren't sent.
    /// `job`: a background job speaks in the peek's line while nothing else is going on:
    /// the Done hold and the ready line give way to it.
    public static func make(_ s: CompanionState, partial: String = "", doneHolding: Bool = false,
                            conversation: Bool = false, note: String? = nil,
                            job: JobSnapshot? = nil) -> NotchStatusInfo {
        switch s.phase {
        case .listening:
            let heard = partial.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = conversation ? conversationListeningLine : listeningLine
            return .init(status: .listening, symbol: "mic.fill", word: "Listening",
                         line: heard.isEmpty ? (note ?? prompt) : heard, tint: .listening)
        case .transcribing:
            return .init(status: .transcribing, symbol: "waveform", word: "Transcribing", line: "…",
                         tint: .listeningDimmed)
        case .thinking:
            if s.lines.last?.role == .attachment {
                return .init(status: .looking, symbol: "viewfinder", word: "Looking",
                             line: "Looking at this screen once", tint: .looking)
            }
            if let acting = s.acting {   // a step on the screen without a card
                return .init(status: .working, symbol: "cursorarrow.motionlines", word: "Acting", line: acting,
                             tint: .secondary)
            }
            let step = s.lines.last { $0.role == .tool || $0.role == .user }
            return .init(status: .working, symbol: "circle.dotted", word: "Working",
                         line: firstLine(step?.text ?? "") ?? "…", tint: .secondary)
        case .awaitingApproval:
            let req = s.pendingApproval
            let line = [req?.action, req?.target].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
            return .init(status: .approval, symbol: "hand.raised.fill", word: "Approval",
                         line: line.isEmpty ? "Needs your approval" : line, tint: .approval)
        case .speaking:
            let answer = s.lines.last { $0.role == .assistant }.map { PanelMarkdown.plain($0.text) }
            // The mic is open over the answer (barge-in): orange, as the mic always is when on.
            return .init(status: .speaking, symbol: s.micActive ? "waveform.and.mic" : "waveform", word: "Speaking",
                         line: answer.flatMap(firstLine) ?? "…", tint: s.micActive ? .listening : .mint)
        case .error:
            return .init(status: .error, symbol: "exclamationmark.triangle.fill", word: "Error",
                         line: firstLine(s.lastError ?? "") ?? "Something went wrong", tint: .error)
        case .idle:
            if let job, let line = job.peekLine, !(doneHolding && !job.wantsAttention) {
                switch job.state {
                case .needsYou:
                    return .init(status: .approval, symbol: "hand.raised.fill", word: "Approval", line: line, tint: .approval)
                case .done:
                    return .init(status: .done, symbol: "checkmark", word: "Done", line: line, tint: .done)
                case .failed:
                    return .init(status: .error, symbol: "exclamationmark.triangle.fill", word: "Error", line: line,
                                 tint: .error)
                case .queued, .working:
                    return .init(status: .working, symbol: "circle.dotted", word: "Job", line: line, tint: .secondary)
                case .stopped:
                    break
                }
            }
            if doneHolding {
                return .init(status: .done, symbol: "checkmark", word: "Done", line: doneLine, tint: .done)
            }
            return .init(status: .ready, symbol: "circle.fill", word: "Ready", line: note ?? readyLine, tint: .mint)
        }
    }

    static func firstLine(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).first.map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        return line?.isEmpty == false ? line : nil
    }
}

// MARK: - VoiceOver

public struct NotchAnnouncement: Equatable, Sendable {
    public var text: String
    public var highPriority: Bool
}

extension NotchStatusInfo {
    /// One announcement per real event (Motion.md, VoiceOver): state changes, never animations.
    /// `answer` is the latest answer, read for Done instead of the generic Done line.
    public static func announcement(from old: NotchStatus?, to new: NotchStatusInfo,
                                    answer: String? = nil) -> NotchAnnouncement? {
        guard old != new.status else { return nil }
        switch new.status {
        case .listening: return .init(text: "Listening", highPriority: false)
        case .approval: return .init(text: "Benji needs approval: \(new.line)", highPriority: true)
        case .done:
            let spoken = answer.map(PanelMarkdown.plain).flatMap(firstLine) ?? doneLine
            return .init(text: spoken, highPriority: false)
        case .error: return .init(text: new.line, highPriority: true)
        case .ready, .transcribing, .working, .looking, .speaking: return nil
        }
    }
}

// MARK: - Hover

/// Hover opens the peek after the pointer has rested in the hot zone for `rest` seconds, moving
/// slower than `maxSpeed`, so a pointer passing through the menu bar doesn't (Motion.md, Timing).
public struct HoverRestDetector: Sendable {
    public let rest: Double
    public let maxSpeed: Double
    private var last: (point: CGPoint, time: Double)?
    private var restStart: Double?
    private var inside = false
    private var fired = false

    public init(rest: Double = MotionTiming.hoverRest, maxSpeed: Double = MotionTiming.hoverMaxSpeed) {
        self.rest = rest
        self.maxSpeed = maxSpeed
    }

    /// Feed every pointer move. Returns true once per visit, when the rest condition is met.
    public mutating func sample(_ point: CGPoint, at time: Double, zone: CGRect) -> Bool {
        let previous = last
        last = (point, time)
        guard zone.contains(point) else {
            inside = false
            fired = false
            restStart = nil
            return false
        }
        var speed = 0.0
        if let previous, time > previous.time {
            speed = Double(hypot(point.x - previous.point.x, point.y - previous.point.y)) / (time - previous.time)
        }
        if speed >= maxSpeed {
            restStart = nil
        } else if !inside || restStart == nil {
            restStart = time
        }
        inside = true
        return check(at: time)
    }

    /// Call on a timer while the pointer sits still (no moves arrive then). A pointer that stopped
    /// has been resting since its last move at the latest.
    public mutating func check(at time: Double) -> Bool {
        guard inside, !fired, let start = restStart ?? last?.time, time - start >= rest - 1e-9 else { return false }
        fired = true
        return true
    }

    /// Re-arm so the next rest fires again (after the notch closed with the pointer still inside).
    public mutating func reset() {
        fired = false
        restStart = nil
    }
}

// MARK: - The hardware notch

extension PanelGeometry {
    /// The hardware notch between the menu-bar areas either side of it
    /// (`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`), flush with the top of the
    /// display; nil when the display has none.
    public static func hardwareNotch(screenFrame: CGRect, leftArea: CGRect?, rightArea: CGRect?,
                                     safeAreaTop: CGFloat) -> CGRect? {
        guard let left = leftArea, let right = rightArea, safeAreaTop > 0, right.minX > left.maxX else { return nil }
        return CGRect(x: left.maxX, y: screenFrame.maxY - safeAreaTop,
                      width: right.minX - left.maxX, height: safeAreaTop)
    }
}
