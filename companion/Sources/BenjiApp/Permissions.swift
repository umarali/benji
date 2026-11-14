import AppKit
import ApplicationServices
import AVFoundation
import Speech
import BenjiCore

/// Checks and requests the companion's macOS permissions. Status is always read
/// live from the system; nothing here assumes a grant it can't see (except the
/// remembered Screen Recording grant, see `ScreenRecordingGrant`).
enum Permissions {
    private static var promptedThisLaunch = Set<CompanionPermission>()
    private static let screenConfirmedKey = "screenRecordingConfirmed"

    static func isGranted(_ p: CompanionPermission) -> Bool {
        switch p {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .speechRecognition: return SFSpeechRecognizer.authorizationStatus() == .authorized
        case .accessibility: return AXIsProcessTrusted()
        case .screenRecording:
            let now = CGPreflightScreenCaptureAccess()
            if now { UserDefaults.standard.set(true, forKey: screenConfirmedKey) }
            return ScreenRecordingGrant.treatAsGranted(
                preflight: now, previouslyConfirmed: UserDefaults.standard.bool(forKey: screenConfirmedKey))
        }
    }

    /// Granted, not yet, or denied, as far as macOS lets Benji tell. Reads only; never prompts.
    static func status(_ p: CompanionPermission) -> PermissionStatus {
        switch p {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            default: return .notYet
            }
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            default: return .notYet
            }
        case .accessibility, .screenRecording:
            return isGranted(p) ? .granted : .notYet
        }
    }

    static func statuses() -> [CompanionPermission: PermissionStatus] {
        Dictionary(uniqueKeysWithValues: CompanionPermission.allCases.map { ($0, status($0)) })
    }

    /// Call when a capture fails for lack of permission, so the remembered grant stops counting.
    static func forgetScreenRecordingGrant() {
        UserDefaults.standard.removeObject(forKey: screenConfirmedKey)
    }

    /// Shows the system prompt if macOS still will, otherwise opens the right Settings pane.
    static func request(_ p: CompanionPermission, completion: (() -> Void)? = nil) {
        let route = PermissionRequestRoute.route(
            granted: isGranted(p), canPrompt: canPrompt(p), promptedThisLaunch: promptedThisLaunch.contains(p))
        switch route {
        case .alreadyGranted:
            completion?()
        case .systemPrompt:
            promptedThisLaunch.insert(p)
            switch p {
            case .microphone:
                AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { completion?() } }
            case .speechRecognition:
                SFSpeechRecognizer.requestAuthorization { _ in DispatchQueue.main.async { completion?() } }
            case .accessibility:
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                completion?()
            case .screenRecording:
                _ = CGRequestScreenCaptureAccess()
                completion?()
            }
        case .systemSettings:
            openSettings(p)
            completion?()
        }
    }

    static func openSettings(_ p: CompanionPermission) {
        let anchor: String
        switch p {
        case .microphone: anchor = "Privacy_Microphone"
        case .speechRecognition: anchor = "Privacy_SpeechRecognition"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        }
        openSettings(anchor: anchor)
    }

    static func openSettings(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func canPrompt(_ p: CompanionPermission) -> Bool {
        switch p {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        case .speechRecognition: return SFSpeechRecognizer.authorizationStatus() == .notDetermined
        // These two have no "not determined" state we can read; their prompt can show again.
        case .accessibility, .screenRecording: return true
        }
    }
}
