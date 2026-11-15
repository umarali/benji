import Foundation

// Browser reach: the app's side of the browser channel for background jobs.
// The engine owns the rules (which sites a job may read or act on, what is asked, what taints) and the
// link to the extension; the app owns the user's switch and, only when the user turns a browser on,
// the two files that let that browser start Benji's host: a native-messaging manifest and the
// launcher it names. Pure file and string work with the home folder passed in, so tests run in a
// temporary folder and never touch a real browser's folders.

/// Settings › Browser › "Let background jobs read pages in Chrome": off until the user turns it on.
public enum BrowserSetting {
    public static let defaultsKey = "browserForJobs"

    public static func isOn(_ stored: Any?) -> Bool { (stored as? Bool) ?? false }
}

/// What the engine says about the link to the extension, in its `browser` events.
public enum BrowserStatus: String, Equatable, Sendable {
    /// The engine isn't listening (the switch is off, or the engine hasn't been told).
    case off
    /// Listening; no extension has connected (Chrome closed, extension missing or not allowed yet).
    case waiting
    case connected

    /// Nil for a state this build doesn't know.
    public static func decode(_ raw: Any?) -> BrowserStatus? { (raw as? String).flatMap(BrowserStatus.init(rawValue:)) }

    public var word: String {
        switch self {
        case .off: return "Off"
        case .waiting: return "Waiting for Chrome"
        case .connected: return "Connected"
        }
    }
}

/// The extension builds the app trusts: the id a Chromium browser derives from the `key` in
/// `browser-extension/manifest.json` (a test recomputes it). Today that is one id. A Web Store build
/// would be a second id, which this list leaves room for: add it to `ids` here, to
/// `EXTENSION_IDS` in `benji/browser_link.py` and to `ALLOWED_EXTENSION_IDS` in
/// `benji/browser_host.py`; a test checks that all three lists agree.
public enum BrowserExtension {
    public static let id = "oifkoajmlonknfkpeecajlncpjbjmfef"
    public static let ids = [id]
    public static let hostName = "com.emerssive.heybenji.browser"
    public static let allowedOrigin = "chrome-extension://\(id)/"
    public static let allowedOrigins = ids.map { "chrome-extension://\($0)/" }
    /// Where the unpacked extension sits, under the folder that holds the `benji` package.
    public static let folderName = "browser-extension"
}

/// What a job may use, as a short line for the row ("example.com, other.org").
public enum BrowserSites {
    public static func line(_ origins: [String]) -> String {
        origins.map { $0.hasPrefix("https://") ? String($0.dropFirst("https://".count)) : $0 }.joined(separator: ", ")
    }
}

/// A Chromium-based browser Benji can register its host with. One row per browser:
/// where it keeps native-messaging manifests, what its extensions page is called, and what Benji has
/// not checked. Opt-in per browser: nothing is written for a browser until the user turns it on.
public struct ChromiumBrowser: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// The app's name in /Applications (or ~/Applications), to tell whether it is installed.
    public let appName: String
    /// Its profile root under ~/Library/Application Support; `NativeMessagingHosts` sits inside.
    public let supportFolder: String
    /// What the user types to reach its extensions page.
    public let extensionsPage: String
    /// Said under its switch when Benji has reason to expect trouble; nil for none.
    public let caveat: String?

    public static let chrome = ChromiumBrowser(id: "chrome", name: "Google Chrome", appName: "Google Chrome.app",
        supportFolder: "Google/Chrome", extensionsPage: "chrome://extensions", caveat: nil)
    public static let all: [ChromiumBrowser] = [
        .chrome,
        ChromiumBrowser(id: "chrome-beta", name: "Chrome Beta", appName: "Google Chrome Beta.app",
                        supportFolder: "Google/Chrome Beta", extensionsPage: "chrome://extensions", caveat: nil),
        ChromiumBrowser(id: "brave", name: "Brave", appName: "Brave Browser.app",
                        supportFolder: "BraveSoftware/Brave-Browser", extensionsPage: "brave://extensions", caveat: nil),
        ChromiumBrowser(id: "edge", name: "Microsoft Edge", appName: "Microsoft Edge.app",
                        supportFolder: "Microsoft Edge", extensionsPage: "edge://extensions", caveat: nil),
        ChromiumBrowser(id: "arc", name: "Arc", appName: "Arc.app",
                        supportFolder: "Arc/User Data", extensionsPage: "arc://extensions",
                        caveat: "Arc manages tabs its own way. If it has no tab groups the extension, which refuses to work without them, will say so."),
    ]

    public static func named(_ id: String) -> ChromiumBrowser? { all.first { $0.id == id } }

    /// The browsers of the table that are installed on this Mac. `exists` takes a path.
    public static func installed(home: URL, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [ChromiumBrowser] {
        all.filter { b in
            exists("/Applications/\(b.appName)") || exists(home.appendingPathComponent("Applications/\(b.appName)").path)
        }
    }
}

/// The native-messaging registration for one Chromium browser: a manifest in that browser's own
/// `NativeMessagingHosts` folder that names the launcher and, in `allowed_origins`, only our
/// extension's id; and the launcher itself, a three-line script that runs `benji/browser_host.py`.
/// Written only by `register()`, which the app calls only when the user turns that browser on;
/// `unregister()` removes the manifest, and the launcher once no browser still uses it.
public struct BrowserHostRegistration {
    public enum RegistrationError: Error, Equatable {
        case unusablePath
    }

    public let home: URL
    public let assistantDir: String
    public let browser: ChromiumBrowser

    public init(home: URL, assistantDir: String, browser: ChromiumBrowser = .chrome) {
        self.home = home
        self.assistantDir = assistantDir
        self.browser = browser
    }

    private var support: URL { home.appendingPathComponent("Library/Application Support", isDirectory: true) }

    /// The browser's per-user folder for host manifests.
    public var manifestURL: URL {
        support.appendingPathComponent("\(browser.supportFolder)/NativeMessagingHosts/\(BrowserExtension.hostName).json")
    }

    /// The script the manifest names. In Benji's own private folder, beside the engine's link file;
    /// shared by every browser's manifest.
    public var launcherURL: URL {
        support.appendingPathComponent("Benji/Browser/benji-browser-host")
    }

    public var hostScript: String { assistantDir + "/benji/browser_host.py" }

    public func manifestData() -> Data {
        let manifest: [String: Any] = [
            "name": BrowserExtension.hostName,
            "description": "Benji's connection to its browser extension",
            "path": launcherURL.path,
            "type": "stdio",
            "allowed_origins": BrowserExtension.allowedOrigins,
        ]
        return (try? JSONSerialization.data(withJSONObject: manifest,
                                            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// A plain `/bin/sh` script, not a login shell: Chrome's channel is the host's standard output, and
    /// anything a user's shell startup files print would corrupt it. Chrome starts it with a bare
    /// environment, so the PATH names the usual homes of `python3`; `-I` so no folder or variable of the
    /// user's can put other code in front of the host.
    public func launcherScript() throws -> String {
        guard !assistantDir.isEmpty, !assistantDir.contains("\n"), !assistantDir.contains("\0"),
              assistantDir.hasPrefix("/") else { throw RegistrationError.unusablePath }
        let quoted = "'" + hostScript.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        #!/bin/sh
        # Written by Benji when you turned on a browser in Settings > Browser. The browser starts it for Benji's extension.
        PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
        export PATH
        exec python3 -I \(quoted) "$@"

        """
    }

    public var isRegistered: Bool {
        guard let data = try? Data(contentsOf: manifestURL),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (o["allowed_origins"] as? [String]) == BrowserExtension.allowedOrigins
            && FileManager.default.isExecutableFile(atPath: launcherURL.path)
    }

    /// The launcher first, then the manifest, so the manifest never names something that isn't there.
    public func register() throws {
        let script = try launcherScript()
        let fm = FileManager.default
        try fm.createDirectory(at: launcherURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcherURL.deletingLastPathComponent().path)
        try Data(script.utf8).write(to: launcherURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcherURL.path)
        try fm.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manifestData().write(to: manifestURL, options: .atomic)
    }

    /// Removes this browser's manifest, and the launcher when no other browser still has one of ours
    /// (not the engine's link file, which the engine owns).
    public func unregister() {
        let fm = FileManager.default
        try? fm.removeItem(at: manifestURL)
        let others = Self.registered(home: home, assistantDir: assistantDir)
        if others.isEmpty { try? fm.removeItem(at: launcherURL) }
    }

    /// The browsers that have our manifest right now.
    public static func registered(home: URL, assistantDir: String) -> [ChromiumBrowser] {
        ChromiumBrowser.all.filter { BrowserHostRegistration(home: home, assistantDir: assistantDir, browser: $0).isRegistered }
    }

    /// The master switch went off: every browser's manifest and the launcher, and nothing else.
    public static func unregisterAll(home: URL, assistantDir: String) {
        for b in ChromiumBrowser.all { BrowserHostRegistration(home: home, assistantDir: assistantDir, browser: b).unregister() }
        let reg = BrowserHostRegistration(home: home, assistantDir: assistantDir)
        try? FileManager.default.removeItem(at: reg.launcherURL)
    }
}

/// The user's "always allow reading" sites, kept in the app's defaults and passed to the
/// engine, which checks them again. Reading only: nothing here ever lets a job click, type, upload or
/// send, and a site on this list still needs the acting card for acting.
public enum BrowserAlways {
    public static let defaultsKey = "browserAlwaysRead"
    public static let maxSites = 50

    /// What the user typed as the exact https origin it names, or nil: "example.com" and
    /// "https://Example.com/inbox" both give "https://example.com". Only https, a plain ASCII
    /// host name with a dot, no user name or password. The engine applies the full rules.
    public static func origin(from text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 253, !t.contains(where: { $0.isWhitespace }) else { return nil }
        if !t.lowercased().hasPrefix("https://") {
            if t.contains("://") { return nil }
            t = "https://" + t
        }
        guard let c = URLComponents(string: t), c.scheme?.lowercased() == "https", c.user == nil, c.password == nil,
              let host = c.host?.lowercased(), host.contains("."), host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }),
              !host.hasPrefix("."), !host.hasSuffix("."), !host.hasPrefix("-"),
              !host.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        if let port = c.port, port != 443 { return "https://\(host):\(port)" }
        return "https://\(host)"
    }

    public static func decode(_ stored: Any?) -> [String] {
        ((stored as? [String]) ?? []).compactMap(origin(from:)).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    /// `list` with `text` added, if it is a site; nil when it isn't one or the list is full.
    public static func adding(_ text: String, to list: [String]) -> [String]? {
        guard let o = origin(from: text) else { return nil }
        if list.contains(o) { return list }
        return list.count < maxSites ? list + [o] : nil
    }

    public static func line(_ origin: String) -> String { BrowserSites.line([origin]) }
}

/// What the user must click, in plain words, for each browser (Benji never changes a browser's
/// settings itself: Developer mode and Load unpacked are the user's).
public enum BrowserSetup {
    public static func steps(for browser: ChromiumBrowser) -> String {
        "In \(browser.name), open \(browser.extensionsPage), turn on Developer mode (top right), choose Load unpacked and pick the Benji extension folder, then open the extension and choose Allow. If the browser says the extension needs new permissions, choose to enable it again: the version that clicks and types needs the debugger permission."
    }
}

/// The words Settings › Browser uses, in one place so tests can hold them to what the code does.
public enum BrowserCopy {
    public static let switchDetail = "A job you start can read pages in your own browser, signed in as you, on the sites you approve for that job on a card. With a second yes for each site, it can click and type there; anything that sends, pays, posts, deletes or uploads asks you every time."
    public static let footer = "Off by default. Benji asks again for any other site. Everything stays on this Mac, except what the job reads, which goes to the model like any page it reads. While a job acts, the browser shows a bar saying it is being debugged: Cancel on that bar stops the job."
    public static let setupDetail = "Choose a browser below to let it start Benji's connection, then add the extension to it: Developer mode, Load unpacked, pick this folder, then open the extension and choose Allow."
    public static let browsersFooter = "Nothing is written to a browser until you turn it on here. Benji never changes a browser's own settings: you turn on Developer mode and load the extension yourself."
    public static let alwaysTitle = "Always allow reading"
    public static let alwaysDetail = "Sites whose pages Benji may read without asking, when you ask about the page in front of you or a job opens them. Reading only: clicking, typing, uploading and sending still ask."
    public static let alwaysFooter = "Only exact sites: example.com is not www.example.com. Remove a site to be asked again."

    public static func connectionDetail(_ status: BrowserStatus) -> String {
        switch status {
        case .off: return "Benji isn't listening for the extension."
        case .waiting: return "Benji is ready. Open a browser that has the extension added and allowed."
        case .connected: return "The extension is connected."
        }
    }
}
