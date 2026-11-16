import Foundation

/// Phone control (docs/remote-control.md): a phone browser sends text tasks to this Mac through a
/// listener on 127.0.0.1 (`benji/remote.py`), reached over private Tailscale Serve.
public enum PhoneControl {
    /// The listener's port: `tailscale serve --bg 8765` points at it.
    public static let port = 8765

    /// The longest task the phone may send, in characters; the listener refuses longer ones too.
    public static let maxTask = 6000
    /// Lines of the phone task the phone is shown, and how long each may be (Unicode scalars).
    public static let shownLines = 20
    public static let shownScalars = 2000
    /// An approval whose action and target together are longer than this (UTF-8 bytes) is answered on the Mac.
    public static let maxApprovalBytes = 16000

    public static func loopback(port: Int = port) -> String { "http://127.0.0.1:\(port)" }

    /// The address as pasted, if the listener can serve it: an `https://<name>.ts.net` address with
    /// no path, port or user (one trailing slash is dropped), or the exact loopback address. Nil otherwise.
    public static func normalizedAddress(_ raw: String, port: Int = port) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("/") { value.removeLast() }
        guard value == loopback(port: port) || value.range(
            of: #"^https://[a-z0-9-]+(?:\.[a-z0-9-]+)+\.ts\.net$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    /// `text` cut to `shownScalars`, with a note that the rest is on the Mac.
    public static func shown(_ text: String) -> String {
        guard text.unicodeScalars.count > shownScalars else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(shownScalars))) + "\n[Shortened. The full result is on the Mac.]"
    }
}

/// Settings › Phone › "Answer approvals from the phone". On by default: an ordinary approval of the
/// phone's task can be answered once, on the Mac or the phone. Off: only the Mac's card answers it.
public enum PhoneApprovals {
    public static let defaultsKey = "phoneAnswersApprovals"

    public static func isOn(_ stored: Any?) -> Bool { (stored as? Bool) ?? true }
}

/// The words Settings › Phone uses for its approvals switch.
public enum PhoneCopy {
    public static let approvalsTitle = "Answer approvals from the phone"
    public static let approvalsDetail = "On: an approval of the phone's task can be answered once, here or on the phone. Off: the phone shows it, and only this Mac can answer it."
    public static let approvalsFooter = "A background job's approvals are always answered on this Mac. A change applies to the next approval."
}
