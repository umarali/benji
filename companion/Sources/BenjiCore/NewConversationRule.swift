import Foundation

/// When "New conversation" may run (D-134). It was greyed out whenever Benji was "busy", and
/// listening counts as busy, so with listen-while-open on it was almost never available.
public enum NewConversationRule {
    /// The phases in which clearing the conversation is allowed: at rest, and while the mic is
    /// open or taking the final words (the half-heard words are dropped and the mic stays open for
    /// the new conversation). Not while a reply is running (Stop shows there) or a card waits.
    public static func allows(phase: CompanionPhase) -> Bool {
        switch phase {
        case .idle, .error, .listening, .transcribing: return true
        case .thinking, .speaking, .awaitingApproval: return false
        }
    }

    /// The button's enabled state: allowed now, and there is something to clear.
    public static func enabled(phase: CompanionPhase, hasConversation: Bool) -> Bool {
        hasConversation && allows(phase: phase)
    }

    /// The half-heard words are dropped first (the mic is open or being finalised).
    public static func dropsHeardWords(phase: CompanionPhase) -> Bool {
        phase == .listening || phase == .transcribing
    }
}
