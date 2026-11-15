import Foundation

// One quiet check, in code, before anything Benji does unasked.
//
// "Unasked" means a sound, speech or a notch event the user did not just cause: a cue for a job that
// finished while they were doing something else, a nudge. The user's own key press and typed message
// are never gated by anything in this file: there is deliberately no `UnaskedSurface` for them, so
// the check cannot be called for them (a test pins the list of surfaces).
//
// What counts as "on a call" is decided on a short list of meeting apps, not on microphone use
// alone: GarageBand, Logic, a recorder or a music app uses the microphone and is not a call.
// Signals come from public APIs only and need no permission (see QuietSignalsReader.swift). Focus
// (Do Not Disturb) is not read: the public API for it (`INFocusStatusCenter`) asks the user for a new
// permission, and Benji does not ask for a permission only to stay quiet. It is listed in
// `QuietCheck.notRead` so the Settings page and the notes can say so.

/// The things Benji may do on its own, each behind this check.
public enum UnaskedSurface: String, CaseIterable, Sendable {
    /// One of Benji's own cues for a job's outcome.
    case cue
    /// A notch peek or row highlight that opens by itself (a job needs the user, a job finished).
    case notchEvent
    /// Speech nobody asked for just now (a hands-free follow-on, a spoken job result).
    case speech
    /// The notch offering a skill for the app in front. Has its own switch, off to start.
    case appOffer
}

/// Why Benji stayed quiet, in the user's words (shown in Settings and the notes, never spoken).
public enum QuietReason: String, Equatable, Sendable {
    case meetingWindow, microphoneInCall, cameraInCall

    public var words: String {
        switch self {
        case .meetingWindow: return "a meeting window is open"
        case .microphoneInCall: return "a call app is using the microphone"
        case .cameraInCall: return "the camera is on while a call app is open"
        }
    }
}

/// What the Mac says right now, as plain values (read by `QuietSignalsReader`, faked in tests).
public struct QuietSignals: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public let owner: String        // the app's bundle id, or its name when the id is not known
        public let title: String        // empty when macOS does not give titles (no Screen Recording grant)
        public init(owner: String, title: String) { self.owner = owner; self.title = title }
    }

    /// Bundle ids of other apps that have the microphone open for input right now.
    public var microphoneUsers: Set<String>
    /// Some app (any) has a camera running. macOS gives no public per-app answer for cameras.
    public var cameraRunning: Bool
    /// Bundle ids of running apps (regular apps, not background helpers).
    public var runningApps: Set<String>
    /// Windows that are on screen.
    public var windows: [Window]

    public init(microphoneUsers: Set<String> = [], cameraRunning: Bool = false,
                runningApps: Set<String> = [], windows: [Window] = []) {
        self.microphoneUsers = microphoneUsers
        self.cameraRunning = cameraRunning
        self.runningApps = runningApps
        self.windows = windows
    }
}

/// The short list of meeting apps, and the titles that say a browser tab is a meeting. A list, not a
/// guess: an app that is not here is not a call, whatever it does with the microphone.
public enum MeetingApps {
    /// Bundle ids of apps whose job is calls and meetings.
    public static let callApps: Set<String> = [
        "us.zoom.xos",                  // Zoom
        "com.apple.FaceTime",           // FaceTime
        "com.microsoft.teams2",         // Microsoft Teams (new)
        "com.microsoft.teams",          // Microsoft Teams (classic)
        "com.cisco.webexmeetingsapp",   // Webex
        "Cisco-Systems.Spark",          // Webex (app)
        "com.tinyspeck.slackmacgap",    // Slack (huddles)
        "com.hnc.Discord",              // Discord (voice channels)
        "com.skype.skype",              // Skype
    ]

    /// Apps that record or play sound and are never a call, kept as a list so a test can say so.
    /// They are not consulted by the rule (an app is a call only if it is in `callApps`); they pin
    /// the promise that microphone use by these never makes Benji quiet.
    public static let neverCalls: Set<String> = [
        "com.apple.garageband10", "com.apple.logic10", "com.apple.QuickTimePlayerX", "com.apple.VoiceMemos",
        "com.apple.Music", "com.spotify.client", "com.apple.dictation", "com.rogueamoeba.audiohijack",
        "com.obsproject.obs-studio", "com.apple.Photobooth", "org.audacityteam.audacity",
    ]

    /// Browsers, whose window title can say a tab is a meeting.
    public static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    /// Is this on-screen window a meeting? By the app's list and the window's title:
    /// Zoom's "Zoom Meeting" and "Zoom Webinar" windows (its home window is not a call), any FaceTime
    /// window, a Teams window titled as a meeting, a Webex meeting window, and a browser tab that is a
    /// Google Meet room ("Meet - abc-defg-hij" or "… - Google Meet").
    public static func isMeeting(_ window: QuietSignals.Window) -> Bool {
        let title = window.title.lowercased()
        switch window.owner {
        case "us.zoom.xos":
            return title.contains("zoom meeting") || title.contains("zoom webinar")
        case "com.apple.FaceTime":
            return true     // FaceTime shows a window only for a call or its list; the list is the less likely case
        case "com.microsoft.teams2", "com.microsoft.teams":
            return title.contains("| microsoft teams") && (title.contains("meeting") || title.contains("call"))
        case "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark":
            return title.contains("meeting")
        default:
            guard browsers.contains(window.owner) else { return false }
            return title.hasPrefix("meet - ") || title.contains("- google meet")
        }
    }
}

public enum QuietCheck {
    /// What this check does not read, and why: said in Settings and the notes.
    public static let notRead: [String: String] = [
        "Focus": "Reading Focus (Do Not Disturb) needs a permission of its own, and Benji does not ask for a "
            + "permission only to stay quiet.",
        "Screen sharing": "macOS gives no way to tell that another app is sharing the screen.",
    ]

    /// Quiet, with the reason, or nil. The rule:
    ///  1. a meeting window on screen, by the list above;
    ///  2. a call app (the list) that has the microphone open;
    ///  3. a camera running while a call app is open.
    /// Microphone use by any app not on the list decides nothing.
    public static func reason(_ s: QuietSignals) -> QuietReason? {
        if s.windows.contains(where: MeetingApps.isMeeting) { return .meetingWindow }
        if !s.microphoneUsers.isDisjoint(with: MeetingApps.callApps) { return .microphoneInCall }
        if s.cameraRunning, !s.runningApps.isDisjoint(with: MeetingApps.callApps) { return .cameraInCall }
        return nil
    }
}

// App offers (`AppOffers.swift`) are the one suggestion nobody asked for, and follow this rule. The
// rule for any other: it is a new case of `UnaskedSurface`, it gets its own Settings switch that
// starts off (as `CueSettings` does), and it goes through `QuietGate` like the cues. The job peek (the
// notch opening for a job the user started) is an answer to their own request, so it has no switch of its
// own, but it is held while `QuietCheck` says the user is on a call.

/// The single gate every unasked surface goes through: its own switch, then the quiet check.
public struct QuietGate: Sendable {
    public enum Verdict: Equatable, Sendable {
        case allowed
        case switchedOff
        case quiet(QuietReason)
    }

    public init() {}

    /// `switchOn`: the user's switch for this surface (cues, or the nudge kind). `signals` are only
    /// read when the switch is on, so a surface that is off costs nothing.
    public func verdict(switchOn: Bool, signals: () -> QuietSignals) -> Verdict {
        guard switchOn else { return .switchedOff }
        if let why = QuietCheck.reason(signals()) { return .quiet(why) }
        return .allowed
    }
}
