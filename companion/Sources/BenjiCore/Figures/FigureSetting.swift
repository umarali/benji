import Foundation

/// The Settings switch "Draw things in 3D", on by default. On, the engine's prompt has the
/// figure section on every turn and the model builds a 3D figure only when the ask plainly
/// expects one (a thing with a real shape or a mechanism, or the words 3D, model, turn it
/// around); off, there is no 3D at all. A change applies from the next
/// message, without relaunching the app.
public enum FigureSetting {
    public static let defaultsKey = "figureStage"

    /// The stored setting, read the way `UserDefaults.bool(forKey:)` reads it (a value written with
    /// `defaults write com.emerssive.heybenji.app figureStage -bool false`, 0 or "NO" all count): on unless it
    /// was explicitly turned off.
    public static func isOn(from raw: Any?) -> Bool {
        switch raw {
        case let number as NSNumber: return number.boolValue
        case let text as String:
            let t = text.trimmingCharacters(in: .whitespaces).lowercased()
            if t == "yes" || t == "true" || (Int(t) ?? 0) > 0 { return true }
            return !(t == "no" || t == "false" || Int(t) == 0)
        default: return true
        }
    }

    /// The status line after the switch is flipped.
    public static func notice(on: Bool) -> String {
        on ? "3D drawings are on from your next message: Benji builds a 3D model when you ask for a real thing."
           : "3D drawings are off from your next message."
    }
}
