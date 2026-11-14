import Foundation

/// The settings page's sidebar: the sections, with Memory (saved conversations and what Benji
/// remembers about you) between Browser and Shortcuts.
public enum SettingsPane: Hashable, Identifiable, Sendable {
    case section(SettingsSection)
    case memory

    public static let all: [SettingsPane] = [.section(.general), .section(.voice), .section(.screen), .section(.browser),
                                             .memory, .section(.shortcuts), .section(.permissions)]

    public var id: String {
        switch self {
        case .section(let s): return s.rawValue
        case .memory: return "memory"
        }
    }

    public var title: String {
        switch self {
        case .section(let s): return s.title
        case .memory: return "Memory"
        }
    }

    public var subtitle: String {
        switch self {
        case .section(let s): return s.subtitle
        case .memory: return "What Benji keeps about you and your conversations."
        }
    }

    public var symbol: String {
        switch self {
        case .section(let s): return s.symbol
        case .memory: return "clock.arrow.circlepath"
        }
    }
}

/// Words of the Memory page and the switch behind "Save conversations".
public enum MemorySettings {
    /// User defaults key; saving is on unless the user turned it off.
    public static let saveKey = "saveConversations"

    public static func savesConversations(_ stored: Any?) -> Bool { (stored as? Bool) ?? true }

    /// "No conversations saved", "1 conversation", "12 conversations".
    public static func count(_ n: Int) -> String {
        switch n {
        case 0: return "No conversations saved"
        case 1: return "1 conversation"
        default: return "\(n) conversations"
        }
    }

    /// The confirmation before every saved conversation goes.
    public static func deleteAllQuestion(_ n: Int) -> String {
        n == 1 ? "Delete the saved conversation? This can't be undone."
               : "Delete all \(n) saved conversations? This can't be undone."
    }

    public static func deleteOneQuestion(_ title: String) -> String {
        "Delete “\(title)”? This can't be undone."
    }

    public static let forgetAllQuestion = "Forget everything Benji remembers about you? This can't be undone."
    public static let noFacts = "Nothing yet. Say “remember that …” and Benji keeps it here."
    public static let factsFooter = "Things you asked Benji to keep, on this Mac. Benji reads them as background with each message, never as instructions."
    public static let conversationsFooter = "Kept in ~/.benji/conversations on this Mac, readable only by you. Recent titles are background for Benji's answers."
}
