import Foundation

// Listening while Benji is open: opening the panel starts a hands-free conversation with no
// key. Closing it ends one, unless "Keep listening when the panel closes" is on: then a
// conversation that is already running carries on in the notch's peek; closing never starts one.
// The conversation's own rules (HandsFreeSession) still decide when the mic is actually open:
// never while Benji works, speaks or waits on a card.
// Pure decisions only; the app owns the mic and the permission checks.

public enum OpenListeningAction: Equatable, Sendable {
    /// Start a conversation (the mic opens as soon as Benji is free).
    case start
    /// End the conversation.
    case stop(HandsFreeEndReason)
}

/// When opening the panel starts listening and when it stops. Once listening ends while the
/// panel is open (a stop phrase, the quiet spell, Escape, the talk key, the Mac locking), it
/// stays off until the panel closes and opens again or the user starts it themselves, so the
/// mic never comes back on by itself.
public struct OpenListening: Equatable, Sendable {
    /// The UserDefaults key for Settings › Voice › "Listen while Benji is open" (default on).
    public static let defaultsKey = "listenWhileOpen"
    /// The UserDefaults key for Settings › Voice › "Keep listening when the panel closes"
    /// (default on).
    public static let keepWhenClosedKey = "keepListeningWhenClosed"

    public private(set) var enabled: Bool
    /// A running conversation goes on when the panel closes. The rule's own default is off
    /// (closing ends it); the app passes the stored setting, which is on unless turned off.
    public private(set) var keepsListeningWhenClosed: Bool
    public private(set) var panelOpen = false
    /// Listening ended during this open spell: don't start it again until the panel reopens.
    public private(set) var heldOff = false

    public init(enabled: Bool = true, keepsListeningWhenClosed: Bool = false) {
        self.enabled = enabled
        self.keepsListeningWhenClosed = keepsListeningWhenClosed
    }

    /// A setting's stored value: on unless it was explicitly turned off (both settings).
    public static func enabled(from raw: Any?) -> Bool {
        switch raw {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return !["0", "off", "no", "false"].contains(s.lowercased())
        default: return true
        }
    }

    /// The panel opened or closed, or something that matters changed.
    /// - `conversationOn`: a conversation is running now.
    /// - `canListen`: on-device recognition, with Microphone and Speech Recognition already
    ///   allowed. Opening the panel never asks for a permission; the talk key does.
    /// - `keepListening`: Benji collapsed the panel itself (to show a drawing), not the user:
    ///   the conversation carries on in the peek (as it does for any close with
    ///   `keepsListeningWhenClosed`).
    public mutating func update(panelOpen open: Bool, conversationOn: Bool, canListen: Bool,
                                keepListening: Bool = false) -> OpenListeningAction? {
        let wasOpen = panelOpen
        panelOpen = open
        if !open {
            guard wasOpen else { return nil }
            heldOff = false
            return conversationOn && !keepListening && !keepsListeningWhenClosed ? .stop(.panelClosed) : nil
        }
        guard enabled, canListen, !heldOff, !conversationOn else { return nil }
        return .start
    }

    /// The menu-bar item closed the panel: the conversation ends unless the user keeps it
    /// listening with the panel closed (the same rule as any other close).
    public func endsConversationOnMenuClose(conversationOn: Bool) -> Bool {
        conversationOn && !keepsListeningWhenClosed
    }

    /// The conversation ended. While the panel is open, that holds listening off.
    public mutating func conversationEnded(_ reason: HandsFreeEndReason) {
        if panelOpen && reason != .panelClosed { heldOff = true }
    }

    /// The user started listening themselves (the talk key, the mic glyph).
    public mutating func userStarted() {
        heldOff = false
    }

    /// The "Listen while Benji is open" setting changed. Turning it off stops a conversation it
    /// would have started; turning it on while open starts one.
    public mutating func setEnabled(_ on: Bool, conversationOn: Bool, canListen: Bool) -> OpenListeningAction? {
        guard on != enabled else { return nil }
        enabled = on
        if !on { return panelOpen && conversationOn ? .stop(.user) : nil }
        heldOff = false
        return update(panelOpen: panelOpen, conversationOn: conversationOn, canListen: canListen)
    }

    /// The "Keep listening when the panel closes" setting changed. Turning it off while the panel
    /// is closed ends a conversation that was going on only because of it; turning it on never
    /// starts one.
    public mutating func setKeepsListeningWhenClosed(_ on: Bool, conversationOn: Bool) -> OpenListeningAction? {
        guard on != keepsListeningWhenClosed else { return nil }
        keepsListeningWhenClosed = on
        return !on && !panelOpen && conversationOn ? .stop(.panelClosed) : nil
    }

    /// Stopping the current task (Cancel, Adjust, an unanswered screen card) keeps listening
    /// while the panel is open with the setting on: "stop" means the task, not the mic.
    public var keepsListeningOnCancel: Bool { enabled && panelOpen }
}
