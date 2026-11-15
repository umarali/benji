import Foundation

// The in-panel ApprovalCard's rules (docs/design-system/project/components/ApprovalCard, and
// principle 5 of that folder's README): Return, Escape and the timeout all mean No; Yes needs a
// click or ⌘Return; Adjust hands the action back to the composer. Pure, so the app's key handling
// and wording are unit-tested.

/// The three answers on the card.
public enum ApprovalChoice: String, Equatable, Sendable {
    case no, adjust, yes
}

public enum ApprovalPolicy {
    /// Return and keypad Enter.
    public static let returnKeyCodes: Set<UInt16> = [36, 76]
    public static let escapeKeyCode: UInt16 = 53

    /// What a key press means while an approval waits. Yes is exactly ⌘Return; any other Return
    /// (plain, ⇧, ⌥, ⌘⇧…) and Escape mean No. Other keys aren't the card's (nil), so typing still
    /// reaches the composer.
    public static func choice(keyCode: UInt16, command: Bool, otherModifiers: Bool) -> ApprovalChoice? {
        if keyCode == escapeKeyCode { return .no }
        guard returnKeyCodes.contains(keyCode) else { return nil }
        return command && !otherModifiers ? .yes : .no
    }

    /// On the card from the start, so the expiry is never a surprise: "No answer in 55 s means No."
    public static func expiryLine(timeout: TimeInterval) -> String {
        "No answer in \(max(1, Int(timeout.rounded()))) s means No."
    }

    /// The target (a command, a whole AppleScript) shows this many lines until the card is opened.
    public static let collapsedTargetLines = 3

    /// The target won't fit the closed card, so it offers "Show all": the whole text is always on
    /// the card, never cut by the engine, so the user always sees exactly what they approve.
    public static func targetNeedsOpening(_ target: String) -> Bool {
        target.split(separator: "\n", omittingEmptySubsequences: false).count > collapsedTargetLines
            || target.count > 160
    }

    /// Said when nobody answered in time (Content fundamentals: say what didn't happen).
    public static let timedOutLine = "Timed out, so I didn't do it."

    /// The transcript row for a timeout.
    public static func timedOutRecord(action: String) -> String {
        "Timed out, so I didn't do it: \(action)"
    }

    /// What Adjust puts in the composer: the action and its target, ready to edit and resend.
    public static func adjustText(for request: ApprovalRequest) -> String {
        let action = request.action.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = request.target.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty { return action }
        if action.isEmpty { return target }
        return "\(action): \(target)"
    }
}
