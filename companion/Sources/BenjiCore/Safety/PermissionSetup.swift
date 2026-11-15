import Foundation

/// What the system says about one permission. "Denied" only when macOS reports it
/// (Microphone, Speech); Accessibility and Screen Recording can only be granted or not yet.
public enum PermissionStatus: String, Equatable, Sendable {
    case granted, notYet, denied

    public var word: String {
        switch self {
        case .granted: return "Granted"
        case .notYet: return "Not yet"
        case .denied: return "Denied"
        }
    }
}

/// The guided setup's steps, in the order the window walks through them.
public enum SetupStep: String, CaseIterable, Sendable {
    case accessibility, voice, screenRecording, automation, model

    /// The permissions this step covers. Automation has none Benji can read: macOS asks
    /// per target app the first time a task scripts it.
    public var permissions: [CompanionPermission] {
        switch self {
        case .accessibility: return [.accessibility]
        case .voice: return [.microphone, .speechRecognition]
        case .screenRecording: return [.screenRecording]
        case .automation, .model: return []
        }
    }

    /// Steps that must be granted before setup counts as done.
    public var isRequired: Bool { self != .automation }

    public var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .voice: return "Microphone and Speech Recognition"
        case .screenRecording: return "Screen Recording"
        case .automation: return "Automation"
        case .model: return "Model"
        }
    }

    /// Why Benji asks, in the user's terms.
    public var purpose: String {
        switch self {
        case .accessibility: return "So I can hear the Right Option talk key."
        case .voice: return "So I can hear you and turn your voice into text, on this Mac."
        case .screenRecording: return "So I can see your screen and point at things, only when you include it with a message."
        case .automation: return "So I can run AppleScript tasks. macOS asks per app, the first time a task needs it."
        case .model: return "So I can answer your first message."
        }
    }

    /// The `x-apple.systempreferences:com.apple.preference.security?…` anchor for the step's pane.
    public var settingsAnchor: String {
        switch self {
        case .accessibility: return "Privacy_Accessibility"
        case .voice: return "Privacy_Microphone"
        case .screenRecording: return "Privacy_ScreenCapture"
        case .automation: return "Privacy_Automation"
        case .model: return ""
        }
    }

    /// Where to fix a denial by hand.
    public var fixHint: String {
        switch self {
        case .accessibility:
            return "Open System Settings › Privacy & Security › Accessibility and switch Benji on."
        case .voice:
            return "Open System Settings › Privacy & Security, then switch Benji on under Microphone and under Speech Recognition."
        case .screenRecording:
            return "Open System Settings › Privacy & Security › Screen & System Audio Recording and switch Benji on."
        case .model:
            return "Add a model source and test it here."
        case .automation:
            return "Open System Settings › Privacy & Security › Automation to review which apps Benji may control."
        }
    }

    /// One step's status from its permissions: granted when all are, denied when any is.
    public func status(_ of: [CompanionPermission: PermissionStatus]) -> PermissionStatus {
        let parts = permissions.map { of[$0] ?? .notYet }
        if parts.isEmpty { return .notYet }
        if parts.allSatisfy({ $0 == .granted }) { return .granted }
        if parts.contains(.denied) { return .denied }
        return .notYet
    }
}

/// Where the guided setup stands, from the live permission statuses.
public struct SetupProgress: Equatable, Sendable {
    public let statuses: [SetupStep: PermissionStatus]

    public init(permissions: [CompanionPermission: PermissionStatus], modelDone: Bool = false) {
        var s: [SetupStep: PermissionStatus] = [:]
        for step in SetupStep.allCases { s[step] = step.status(permissions) }
        s[.model] = modelDone ? .granted : .notYet
        statuses = s
    }

    public func status(of step: SetupStep) -> PermissionStatus { statuses[step] ?? .notYet }

    /// The step to highlight: the first required one not granted yet. Denied steps are
    /// passed over (they show how to fix them instead of asking again), so a denial never
    /// blocks the rest of the flow.
    public var current: SetupStep? {
        SetupStep.allCases.first { $0.isRequired && status(of: $0) == .notYet }
    }

    /// The steps setup counts, in order (Automation is asked per app when a task needs it).
    public static let requiredSteps = SetupStep.allCases.filter(\.isRequired)

    /// The current step's place among the required ones (1-based), for "Step 2 of 4"; nil when
    /// nothing is left to ask.
    public var stepNumber: Int? {
        current.flatMap { Self.requiredSteps.firstIndex(of: $0) }.map { $0 + 1 }
    }

    /// Required steps that were denied: they are passed over and fixed by hand in System Settings.
    public var deniedSteps: [SetupStep] {
        Self.requiredSteps.filter { status(of: $0) == .denied }
    }

    /// Every required step granted.
    public var isComplete: Bool {
        SetupStep.allCases.filter(\.isRequired).allSatisfy { status(of: $0) == .granted }
    }

    /// Nothing left to ask for, but something required was denied: setup can end and
    /// the matching features stay off.
    public var endedWithGaps: Bool { current == nil && !isComplete }

    /// Steps that became granted between two readings, in step order (for announcements).
    public func newlyGranted(since old: SetupProgress) -> [SetupStep] {
        SetupStep.allCases.filter { status(of: $0) == .granted && old.status(of: $0) != .granted }
    }

    /// What VoiceOver should say after a change, or nil when nothing was granted.
    public func announcement(since old: SetupProgress) -> String? {
        let granted = newlyGranted(since: old)
        guard !granted.isEmpty else { return nil }
        let names = granted.map { $0 == .model ? "Model ready" : "\($0.title) granted" }.joined(separator: " and ")
        if isComplete { return "\(names). All set." }
        if let next = current { return "\(names). Next: \(next.title)." }
        return "\(names)."
    }
}

/// When the setup window opens on its own. Once, on first launch, and only if something
/// required is missing; afterwards only from the status-bar menu. Also reopens after a relaunch the
/// window itself asked for (Screen Recording).
public enum SetupAutoOpen {
    public static func shouldOpen(alreadyShown: Bool, resumeAfterRelaunch: Bool, isComplete: Bool) -> Bool {
        if resumeAfterRelaunch { return true }
        return !alreadyShown && !isComplete
    }
}
