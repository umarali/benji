import Foundation

// Lifecycle: open at login, a one-line ask at the moment a permission is
// needed, one line at launch when macOS took a grant away, and a relaunch that waits for the old
// process to exit. Pure logic with seams; the system parts live in the app target.
//
// What none of this does: change a macOS permission or setting, request anything at launch, or
// register a login item without the user's switch: Benji's login item is off until the user turns
// it on.

// MARK: - Open at login

public enum LoginItemStatus: Equatable, Sendable {
    case enabled, disabled
    /// Registered, but macOS wants the user to allow it in System Settings › General › Login Items.
    case needsApproval
    /// Not available (the app isn't in a place macOS can register from, or the system refused).
    case unavailable
}

/// The system's login-item service (`SMAppService.mainApp` in the app target). Tests use a fake.
public protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

public enum OpenAtLogin {
    /// The switch shows what the system says, not what Benji last wrote down.
    public static func isOn(_ status: LoginItemStatus) -> Bool { status == .enabled || status == .needsApproval }

    /// The line under the switch.
    public static func caption(_ status: LoginItemStatus, failed: Bool = false) -> String {
        if failed { return "macOS wouldn't change this. You can set it in System Settings › General › Login Items." }
        switch status {
        case .enabled: return "Benji opens when you log in."
        case .disabled: return "Benji opens only when you open it."
        case .needsApproval: return "Allow Benji in System Settings › General › Login Items, then it will open when you log in."
        case .unavailable: return "macOS can't register this copy of Benji. Move it to the Applications folder first."
        }
    }

    /// Apply the user's switch. Only ever called from the switch itself, never at launch.
    /// Returns the status afterwards and whether the system refused.
    @discardableResult
    public static func set(_ on: Bool, service: LoginItemService) -> (status: LoginItemStatus, failed: Bool) {
        do {
            if on {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled || service.status == .needsApproval {
                try service.unregister()
            }
            return (service.status, false)
        } catch {
            return (service.status, true)
        }
    }
}

// MARK: - Permissions: the ask at the moment of need, and what changed since last launch

/// A moment when Benji wants something macOS hasn't given. The line is one sentence, shown in the
/// panel, with a button that opens the right Settings pane; nothing modal, nothing repeated.
public enum PermissionNeed: Equatable, Sendable {
    /// The user asked to include their screen and Screen Recording isn't on.
    case screenToLook
    /// The user pressed the talk key and the microphone isn't allowed.
    case microphoneToHear
    /// The user spoke and Speech Recognition isn't allowed.
    case speechToTranscribe

    public var permission: CompanionPermission {
        switch self {
        case .screenToLook: return .screenRecording
        case .microphoneToHear: return .microphone
        case .speechToTranscribe: return .speechRecognition
        }
    }

    /// What Benji says, and what it does instead.
    public var line: String {
        switch self {
        case .screenToLook:
            return "I can't see your screen yet: Screen Recording is off for Benji. Your message wasn't sent."
        case .microphoneToHear:
            return "I can't hear you yet: the Microphone is off for Benji. You can still type."
        case .speechToTranscribe:
            return "I can't turn your voice into text yet: Speech Recognition is off for Benji. You can still type."
        }
    }

    public var buttonTitle: String { "Open \(permission.title) settings" }
}

/// One note per need per launch: asked once, not on every message.
public struct PermissionAsks: Sendable {
    private var shown: Set<CompanionPermission> = []

    public init() {}

    /// The need's line the first time it comes up this launch (when `granted` is false); nil after.
    public mutating func ask(_ need: PermissionNeed, granted: Bool) -> PermissionNeed? {
        guard !granted, shown.insert(need.permission).inserted else { return nil }
        return need
    }
}

public enum GrantChanges {
    public static let defaultsKey = "lastLaunchGrants"

    /// The grants as stored for the next launch: permission id → granted.
    public static func encode(_ now: [CompanionPermission: Bool]) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: now.map { ($0.key.rawValue, $0.value) })
    }

    /// Grants that were on at the last launch and are off now, in the order of `CompanionPermission`.
    /// Nothing is said on a first launch (no earlier record), or for a grant that was never on, or for
    /// one that came on.
    public static func lost(previous: [String: Bool]?, now: [CompanionPermission: Bool]) -> [CompanionPermission] {
        guard let previous else { return [] }
        return CompanionPermission.allCases.filter { previous[$0.rawValue] == true && now[$0] == false }
    }

    /// The one launch line, or nil when macOS changed nothing Benji depended on.
    public static func launchLine(lost: [CompanionPermission]) -> String? {
        guard !lost.isEmpty else { return nil }
        let names = lost.map(\.title)
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "macOS turned off \(list) for Benji since last time. Switch it back on in System Settings › Privacy & Security, or open Finish Setup."
    }
}

// MARK: - Relaunch

public enum RelaunchHelper {
    /// The shell the relaunch helper runs: wait until process `pid` has exited (checked every 0.2 s, for
    /// at most `waitSeconds`), then open `target` with `opener`. Arguments for `/bin/sh -c`; the
    /// values are passed as positional parameters, never spliced into the script, so a path with
    /// spaces or quotes is safe.
    public static func arguments(pid: Int32, target: String, opener: String = "/usr/bin/open",
                                 waitSeconds: Int = 20) -> [String] {
        let script = "i=0; while kill -0 \"$1\" 2>/dev/null && [ \"$i\" -lt \"$4\" ]; do sleep 0.2; i=$((i+1)); done; exec \"$3\" \"$2\""
        return ["-c", script, "benji-relaunch", String(pid), target, opener, String(waitSeconds * 5)]
    }
}
