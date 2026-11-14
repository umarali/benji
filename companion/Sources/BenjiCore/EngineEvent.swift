import Foundation

/// A single parsed line of the engine's output stream.
public enum BackendEvent: Equatable, Sendable {
    case tool(name: String, detail: String)
    case answer(String)
    /// An answer whose pointing tags the backend already parsed (`benji --serve`).
    case pointedAnswer(text: String, targets: [PointingTarget])
    case error(String)
    case approval(action: String, target: String)
    /// An approval for a screen step (`benji --serve`, D-123): the app words the card itself.
    case screenApproval(action: String, target: String, step: ScreenStep, intent: ScreenStepIntent? = nil)
    /// Act on the approved step and answer through `finishScreenStep` (`benji --serve`, D-123).
    /// `mode` free or quiet: a simple step the engine didn't ask about (D-126).
    /// `drive`: the step is inside a consented drive (D-170), so the app checks it by the drive's rules.
    case screenAction(request: String, step: ScreenStep?, mode: ScreenStepClass? = nil, intent: ScreenStepIntent? = nil,
                      drive: Bool = false)
    /// The drive card (D-170): the engine asks to take over the screen for `goal`. Granted only by
    /// the app's own button or key; it declines itself after `seconds`.
    case driveApproval(goal: String, seconds: Double)
    /// The drive began or ended (D-170); an end carries a plain spoken and written line.
    case drive(DriveEvent)
    /// The engine took the turn's message (`benji --serve`; one-shot: the process started).
    case accepted
    /// A tool that ran (D-98): its kind and, for a saved file, the file name only.
    case activity(kind: String, name: String?)
    /// A piece of the reply as it streams (`benji --serve` with streaming on).
    case delta(String)
    /// The streamed text so far was not the answer (a tool call followed it): forget it.
    case deltaReset
    /// A card line of the reply as it closes (`benji --serve`, chilly-beats).
    /// `at`: spoken characters before it, when the engine says (`ServeEvent.cardLine`).
    case cardLine(ExplainCardLine, at: Int?)
    /// The reply's card lines are all in.
    case cardEnd
    case raw(String)
}

/// Parses the engine's stdout lines into typed events. The engine marks structured output with
/// control-character sentinels (so they never collide with normal text):
///   \x01BENJI-APPROVE\x01<reason>\x01        (approval request)
///   \x01BENJI-EVENT\x01<json>\x01            (tool / answer / error, when BENJI_EVENTS=1)
/// Anything else is `.raw`.
public enum EngineEventParser {
    public static let approveSentinel = "\u{1}BENJI-APPROVE\u{1}"
    public static let eventSentinel = "\u{1}BENJI-EVENT\u{1}"

    public static func parse(_ line: String) -> BackendEvent {
        if line.hasPrefix(approveSentinel) {
            let reason = trimSentinel(line, prefix: approveSentinel)
            let (action, target) = splitReason(reason)
            return .approval(action: action, target: target)
        }
        if line.hasPrefix(eventSentinel) {
            let json = trimSentinel(line, prefix: eventSentinel)
            if let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let type = obj["type"] as? String {
                switch type {
                case "tool":
                    return .tool(name: obj["name"] as? String ?? "",
                                 detail: obj["detail"] as? String ?? "")
                case "answer":
                    return .answer(obj["text"] as? String ?? "")
                case "error":
                    return .error(obj["text"] as? String ?? "")
                default:
                    break
                }
            }
            return .raw(line)
        }
        return .raw(line)
    }

    static func trimSentinel(_ line: String, prefix: String) -> String {
        var rest = String(line.dropFirst(prefix.count))
        if rest.hasSuffix("\u{1}") { rest.removeLast() }
        return rest
    }

    /// Split a reason like "overwrite existing file: /path" into (action, target).
    static func splitReason(_ reason: String) -> (String, String) {
        if let r = reason.range(of: ": ") {
            return (String(reason[..<r.lowerBound]), String(reason[r.upperBound...]))
        }
        return (reason, "")
    }
}
