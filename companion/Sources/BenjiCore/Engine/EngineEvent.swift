import Foundation

/// What a backend tells `CompanionModel` about a run, one event at a time (from `ServeEvent`).
public enum BackendEvent: Equatable, Sendable {
    case tool(name: String, detail: String)
    /// An answer as plain text, any pointing tags still in it (the app parses them). The engine
    /// sends `pointedAnswer`; the tests' fake backends and the render tools say this.
    case answer(String)
    /// An answer whose pointing tags the engine already parsed.
    case pointedAnswer(text: String, targets: [PointingTarget])
    case error(String)
    case approval(action: String, target: String)
    /// An approval for a screen step: the app words the card itself.
    case screenApproval(action: String, target: String, step: ScreenStep, intent: ScreenStepIntent? = nil)
    /// Act on the approved step and answer through `finishScreenStep`.
    /// `mode` free or quiet: a simple step the engine didn't ask about.
    /// `drive`: the step is inside a consented drive, so the app checks it by the drive's rules.
    case screenAction(request: String, step: ScreenStep?, mode: ScreenStepClass? = nil, intent: ScreenStepIntent? = nil,
                      drive: Bool = false)
    /// The drive card: the engine asks to take over the screen for `goal`. Granted only by
    /// the app's own button or key; it declines itself after `seconds`.
    case driveApproval(goal: String, seconds: Double)
    /// The drive began or ended; an end carries a plain spoken and written line.
    case drive(DriveEvent)
    /// The engine took the turn's message.
    case accepted
    /// A tool that ran: its kind and, for a saved file, the file name only.
    case activity(kind: String, name: String?)
    /// A piece of the reply as it streams (`benji --serve` with streaming on).
    case delta(String)
    /// The streamed text so far was not the answer (a tool call followed it): forget it.
    case deltaReset
    /// A card line of the reply as it closes.
    /// `at`: spoken characters before it, when the engine says (`ServeEvent.cardLine`).
    case cardLine(ExplainCardLine, at: Int?)
    /// The reply's card lines are all in.
    case cardEnd
    /// The conversation now holds outside content (it comes just before the turn's answer).
    case carriedTaint(CarriedTaint)
}

extension BackendEvent {
    /// The event asks to act on the screen, or reports a step that does: a screen step's card, the
    /// step itself, a drive's card or the drive. A task from the phone never gets one.
    public var actsOnTheScreen: Bool {
        switch self {
        case .screenApproval, .screenAction, .driveApproval, .drive: return true
        default: return false
        }
    }
}
