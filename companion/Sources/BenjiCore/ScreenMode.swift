import Foundation

/// Whether Benji may see the screen (the user's three-way setting, in Settings › Screen).
/// Off never captures. Ask shows the send-time card (D-89). On sends one picture of the display
/// the user is working on with every message, and lets Benji draw on it.
public enum ScreenMode: String, CaseIterable, Sendable {
    case off, ask, on

    public var title: String {
        switch self {
        case .off: return "Off"
        case .ask: return "Ask"
        case .on: return "On"
        }
    }
}

/// The screen mode as saved (D-133): a fresh install starts On, a saved choice is kept, and On
/// stays On (it no longer lapses to Ask after an idle spell, a lock or sleep).
public struct ScreenModeState: Equatable, Sendable {
    /// The UserDefaults key the app saves the mode under.
    public static let defaultsKey = "screenMode"
    /// What a fresh install (or an unreadable saved value) starts in.
    public static let fresh: ScreenMode = .on

    public private(set) var mode: ScreenMode

    /// `saved` is the stored raw value: Off, Ask and On are kept; nothing or anything unknown is On.
    public init(saved: String?) {
        mode = saved.flatMap(ScreenMode.init(rawValue:)) ?? Self.fresh
    }

    public mutating func choose(_ mode: ScreenMode) {
        self.mode = mode
    }
}

/// Windows left out of every capture (ScreenCaptureKit excludes them from the image itself,
/// so they are never seen, sent or stored). What can't be detected isn't promised: Safari's
/// private windows and Chrome's Incognito windows carry no marker in their titles on macOS,
/// so they are not excluded.
public enum CaptureExclusions {
    public enum Reason: Equatable, Sendable {
        case benji, passwordManager, notification, privateBrowsing
    }

    /// 1Password (8 and 7), Bitwarden, Keychain Access, Passwords.
    public static let passwordManagers: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords",
    ]
    /// Notification banners and alerts, and the Notification Center they live in.
    public static let notifications: Set<String> = ["com.apple.notificationcenterui"]

    /// Title markers of a private window, where the browser puts one (Firefox and Tor Browser
    /// "Private Browsing", Edge "InPrivate", Chromium builds that add "Incognito").
    static let privateMarkers = ["Private Browsing", "InPrivate", "Incognito"]

    public static func reason(bundleID: String?, pid: Int32, ownPID: Int32, title: String?) -> Reason? {
        if pid == ownPID { return .benji }
        if let id = bundleID {
            if passwordManagers.contains(id) { return .passwordManager }
            if notifications.contains(id) { return .notification }
        }
        if let title, privateMarkers.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
            return .privateBrowsing
        }
        return nil
    }
}
