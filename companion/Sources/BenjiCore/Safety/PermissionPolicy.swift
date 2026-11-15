import Foundation

/// The macOS permissions the app uses, and how asking for each one behaves.
/// Pattern credited in THIRD_PARTY_NOTICES.md: show the system prompt
/// once per launch, then send the user to System Settings, never both at once.
public enum CompanionPermission: String, CaseIterable, Sendable {
    case microphone, speechRecognition, accessibility, screenRecording

    public var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        }
    }

    /// Why the app asks, in the user's terms.
    public var purpose: String {
        switch self {
        case .microphone: return "to hear you when you talk"
        case .speechRecognition: return "to turn your voice into text on this Mac"
        case .accessibility: return "for the Right ⌥ talk key"
        case .screenRecording: return "only when you include your screen with a message"
        }
    }
}

public enum PermissionRequestRoute: Equatable, Sendable {
    case alreadyGranted, systemPrompt, systemSettings

    /// `canPrompt`: macOS will still show its own dialog (status not yet determined, or a
    /// permission whose prompt can repeat). After one prompt this launch, go to Settings.
    public static func route(granted: Bool, canPrompt: Bool, promptedThisLaunch: Bool) -> PermissionRequestRoute {
        if granted { return .alreadyGranted }
        return canPrompt && !promptedThisLaunch ? .systemPrompt : .systemSettings
    }
}

/// `CGPreflightScreenCaptureAccess()` can report false for an app the user already
/// allowed, so a grant confirmed earlier counts until a capture actually fails.
public enum ScreenRecordingGrant {
    public static func treatAsGranted(preflight: Bool, previouslyConfirmed: Bool) -> Bool {
        preflight || previouslyConfirmed
    }
}
