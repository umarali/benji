import Foundation

/// What is taken out of a line before it is kept in `engine.log`. Swift twin of
/// `audit.redact` in `benji/audit.py`: a URL is cut to its host, key-shaped strings, bearer tokens,
/// `KEY=value` assignments and long opaque runs become placeholders, and the home folder becomes `~`.
/// `Tests/redaction-cases.json` holds the cases both sides must agree on.
public enum LogRedaction {
    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let url = regex(#"\b(?:https?|wss?)://[^\s"'<>]+"#, .caseInsensitive)
    private static let keys = [
        regex(#"\bsk-[A-Za-z0-9_-]{12,}"#),
        regex(#"\bgh[pousr]_[A-Za-z0-9]{20,}"#),
        regex(#"\bAKIA[0-9A-Z]{16}\b"#),
        regex(#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#),
        regex(#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]*"#),
        regex(#"\b[0-9a-fA-F]{32}\.[A-Za-z0-9_-]{8,}"#),      // an id.secret key
    ]
    private static let bearer = regex(#"\b[Bb]earer\s+[A-Za-z0-9._~+/=-]{8,}"#)
    private static let assigned = regex(
        #"(?i)\b([A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|AUTH|AUTHORIZATION)[A-Z0-9_]*)\s*[=:]\s*(?:[Bb]earer\s+)?("[^"]*"|'[^']*'|\S+)"#)
    private static let home = regex(#"/Users/[^/\s]+"#)
    private static let opaque = regex(#"[A-Za-z0-9+/_=]{32,}"#)

    public static func redact(_ text: String) -> String {
        var out = hostOnly(text)
        for rx in keys { out = replace(rx, in: out, with: "[key]") }
        out = replace(bearer, in: out, with: "Bearer [key]")
        out = replace(assigned, in: out, with: "$1=[redacted]")
        out = replace(home, in: out, with: "~")
        return replace(opaque, in: out, with: "[redacted]")
    }

    private static func replace(_ rx: NSRegularExpression, in text: String, with template: String) -> String {
        rx.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// `https://user:pw@host:8443/path?q` becomes `https://host:8443/…`; with no path, `https://host`.
    private static func hostOnly(_ text: String) -> String {
        var out = text
        let matches = url.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for m in matches.reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            let found = String(out[r])
            guard let sep = found.range(of: "://") else { continue }
            let scheme = found[..<sep.lowerBound].lowercased()
            let rest = found[sep.upperBound...]
            let authorityEnd = rest.firstIndex(where: { "/?#".contains($0) }) ?? rest.endIndex
            let authority = rest[..<authorityEnd]
            let host = authority.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? String(authority)
            out.replaceSubrange(r, with: "\(scheme)://\(host)" + (authorityEnd < rest.endIndex ? "/…" : ""))
        }
        return out
    }
}
