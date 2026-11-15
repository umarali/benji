import XCTest
import CryptoKit
@testable import BenjiCore

/// Browser reach, the app's side. Nothing here touches a real browser's folders:
/// registration runs against a temporary home.
final class BrowserTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("benji-browser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    private func registration(_ dir: String = "/Users/someone/Benji/assistant") -> BrowserHostRegistration {
        BrowserHostRegistration(home: home, assistantDir: dir)
    }

    private func files(under root: URL) -> [String] {
        let base = root.resolvingSymlinksInPath()
        let it = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey])
        return (it?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.map { String($0.resolvingSymlinksInPath().path.dropFirst(base.path.count)) }.sorted()
    }

    // MARK: the switch

    func testBrowserReachIsOffUntilTheUserTurnsItOn() {
        XCTAssertFalse(BrowserSetting.isOn(nil))
        XCTAssertFalse(BrowserSetting.isOn("yes"))
        XCTAssertTrue(BrowserSetting.isOn(true))
        XCTAssertFalse(SettingsSnapshot().browserOn)
        XCTAssertEqual(SettingsSnapshot().browserStatus, .off)
    }

    func testNothingIsWrittenUntilRegisterIsCalled() {
        _ = registration()
        _ = registration().manifestData()
        XCTAssertEqual(files(under: home), [])
        XCTAssertFalse(registration().isRegistered)
    }

    // MARK: registration

    func testRegisterWritesTheManifestForChromeAndTheLauncherAndNothingElse() throws {
        let reg = registration()
        try reg.register()
        XCTAssertEqual(files(under: home), [
            "/Library/Application Support/Benji/Browser/benji-browser-host",
            "/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.emerssive.heybenji.browser.json",
        ])
        XCTAssertTrue(reg.isRegistered)
    }

    func testTheManifestNamesOnlyOurExtensionAndOurLauncher() throws {
        let reg = registration()
        try reg.register()
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: reg.manifestURL)) as? [String: Any])
        XCTAssertEqual(o["name"] as? String, "com.emerssive.heybenji.browser")
        XCTAssertEqual(o["type"] as? String, "stdio")
        XCTAssertEqual(o["path"] as? String, reg.launcherURL.path)
        XCTAssertEqual(o["allowed_origins"] as? [String], ["chrome-extension://\(BrowserExtension.id)/"])
        XCTAssertEqual(Set(o.keys), ["name", "description", "path", "type", "allowed_origins"])
        XCTAssertFalse(String(decoding: reg.manifestData(), as: UTF8.self).contains("*"), "no wildcard origin")
    }

    func testTheLauncherIsPrivateAndRunsTheHostIsolated() throws {
        let reg = registration()
        try reg.register()
        let mode = try FileManager.default.attributesOfItem(atPath: reg.launcherURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
        let dirMode = try FileManager.default.attributesOfItem(atPath: reg.launcherURL.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(dirMode, 0o700)
        let script = try String(contentsOf: reg.launcherURL, encoding: .utf8)
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"), "a login shell's startup files could print into Chrome's channel")
        XCTAssertTrue(script.contains("exec python3 -I '/Users/someone/Benji/assistant/benji/browser_host.py' \"$@\""))
    }

    func testTheLauncherRunsTheHostFromAnEmptyEnvironment() throws {
        // The real chain, as Chrome starts it: the launcher with a bare environment reaches python3 and the
        // host, which refuses a caller that isn't our extension, in Chrome's framing, and exits 2.
        let assistant = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let reg = registration(assistant)
        try reg.register()
        let p = Process()
        p.executableURL = reg.launcherURL
        p.arguments = ["chrome-extension://" + String(repeating: "a", count: 32) + "/"]
        p.environment = [:]
        let out = Pipe()
        p.standardOutput = out
        p.standardInput = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 2)
        XCTAssertEqual(data.count >= 4 ? Int(data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }) : -1, data.count - 4)
        XCTAssertTrue(String(decoding: data.dropFirst(4), as: UTF8.self).contains("unavailable"))
    }

    func testTheLauncherQuotesAFolderWithSpacesAndApostrophes() throws {
        let dir = "/Volumes/o'brien/My Benji/assistant"
        let reg = registration(dir)
        try reg.register()
        // zsh itself reads the launcher: the quoted path must come back as one word, unchanged.
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let script = try String(contentsOf: reg.launcherURL, encoding: .utf8)
        let line = try XCTUnwrap(script.split(separator: "\n").last)
        let words = line.replacingOccurrences(of: "exec python3 -I ", with: "printf '%s' ").replacingOccurrences(of: " \"$@\"", with: "")
        check.arguments = ["-c", words]
        let out = Pipe()
        check.standardOutput = out
        try check.run()
        check.waitUntilExit()
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), dir + "/benji/browser_host.py")
    }

    func testAnUnusableFolderWritesNothing() {
        for dir in ["", "relative/path", "/tmp/x\ny", "/tmp/x\0y"] {
            XCTAssertThrowsError(try registration(dir).register(), dir)
        }
        XCTAssertEqual(files(under: home), [])
    }

    func testUnregisterRemovesBothAndIsSafeToRepeat() throws {
        let reg = registration()
        try reg.register()
        reg.unregister()
        XCTAssertEqual(files(under: home), [])
        XCTAssertFalse(reg.isRegistered)
        reg.unregister()
    }

    func testAManifestForAnotherExtensionIsNotOurRegistration() throws {
        let reg = registration()
        try reg.register()
        try Data(#"{"name":"com.emerssive.heybenji.browser","allowed_origins":["chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/"]}"#.utf8)
            .write(to: reg.manifestURL)
        XCTAssertFalse(reg.isRegistered)
    }

    // MARK: the id is the one in the extension's manifest

    func testTheTrustedIdIsTheOneChromeDerivesFromTheManifestKey() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("browser-extension/manifest.json")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let der = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(manifest["key"] as? String)))
        let hex = SHA256.hash(data: der).prefix(16).map { String(format: "%02x", $0) }.joined()
        let id = String(hex.map { Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(String($0), radix: 16)!)) })
        XCTAssertEqual(id, BrowserExtension.id)
        XCTAssertEqual((manifest["permissions"] as? [String]).map(Set.init),
                       ["nativeMessaging", "tabGroups", "scripting", "storage", "alarms", "debugger"])
        XCTAssertEqual(manifest["optional_host_permissions"] as? [String], ["https://*/*"])
        XCTAssertNil(manifest["host_permissions"])
        XCTAssertNil(manifest["content_scripts"])
    }

    // MARK: protocol

    func testBrowserSetRequestLine() {
        XCTAssertEqual(String(decoding: ServeRequest.browserSet(enabled: true).line(), as: UTF8.self),
                       #"{"enabled":true,"type":"browser_set"}"# + "\n")
        XCTAssertEqual(String(decoding: ServeRequest.browserSet(enabled: false).line(), as: UTF8.self),
                       #"{"enabled":false,"type":"browser_set"}"# + "\n")
    }

    func testReadySaysWhetherTheEngineHasABrowserLink() {
        guard case let .ready(info)? = ServeEvent.decode(#"{"type":"ready","protocol":1,"version":"1","provider":"p","model":"m","destination":"d","jobs":true,"browser":true}"#) else { return XCTFail() }
        XCTAssertTrue(info.browser)
        guard case let .ready(older)? = ServeEvent.decode(#"{"type":"ready","protocol":1,"version":"1","provider":"p","model":"m","destination":"d"}"#) else { return XCTFail() }
        XCTAssertFalse(older.browser)
    }

    func testBrowserEventsDecodeAndUnknownStatesAreNotGuessed() {
        for status in [BrowserStatus.off, .waiting, .connected] {
            XCTAssertEqual(ServeEvent.decode(#"{"type":"browser","state":"\#(status.rawValue)"}"#), .browser(status))
        }
        XCTAssertEqual(ServeEvent.decode(#"{"type":"browser","state":"on"}"#), .unknown(type: "browser"))
        XCTAssertEqual(ServeEvent.decode(#"{"type":"browser"}"#), .unknown(type: "browser"))
        XCTAssertEqual(ServeEvent.decode(#"{"type":"browser","state":5}"#), .unknown(type: "browser"))
        XCTAssertEqual(ServeEvent.decode(#"{"type":"browser_grant","origin":"https://x.com"}"#), .unknown(type: "browser_grant"))
    }

    func testAJobShowsTheSitesItMayUse() throws {
        let job = try XCTUnwrap(JobSnapshot.decode(["id": "j", "state": "working", "title": "Inbox",
                                                    "sites": ["https://example.com", "https://other.org:8443", "http://nope.com", "javascript:1"]]))
        XCTAssertEqual(job.sites, ["https://example.com", "https://other.org:8443"])
        XCTAssertEqual(job.sitesLine, "Can read in your Chrome: example.com, other.org:8443")
        let none = try XCTUnwrap(JobSnapshot.decode(["id": "j", "state": "working", "title": "x"]))
        XCTAssertEqual(none.sites, [])
        XCTAssertNil(none.sitesLine)
    }

    // MARK: settings and words

    func testBrowserIsASettingsSectionBeforeMemory() {
        XCTAssertTrue(SettingsSection.allCases.contains(.browser))
        XCTAssertEqual(SettingsSection.browser.title, "Browser")
        let titles = SettingsPane.all.map(\.title)
        XCTAssertEqual(titles.firstIndex(of: "Browser"), titles.firstIndex(of: "Memory").map { $0 - 1 })
    }

    func testTheWordsSayWhatThisStepDoes() {
        XCTAssertTrue(BrowserCopy.switchDetail.contains("second yes for each site"))
        XCTAssertTrue(BrowserCopy.switchDetail.contains("uploads asks you every time"))
        XCTAssertTrue(BrowserCopy.footer.hasPrefix("Off by default."))
        XCTAssertTrue(BrowserCopy.footer.contains("Cancel on that bar stops the job"))
        XCTAssertTrue(BrowserCopy.alwaysDetail.contains("Reading only"))
        XCTAssertEqual(BrowserStatus.allWords, ["Off", "Waiting for Chrome", "Connected"])
        XCTAssertEqual(Set([BrowserStatus.off, .waiting, .connected].map(BrowserCopy.connectionDetail)).count, 3)
    }
}

// MARK: each browser on its own, and always-allowed sites

extension BrowserTests {
    private func registration(_ browser: ChromiumBrowser) -> BrowserHostRegistration {
        BrowserHostRegistration(home: home, assistantDir: "/Users/someone/Benji/assistant", browser: browser)
    }

    func testTheTableHoldsTheFiveBrowsersWithTheirOwnFolders() {
        XCTAssertEqual(ChromiumBrowser.all.map(\.id), ["chrome", "chrome-beta", "brave", "edge", "arc"])
        XCTAssertEqual(Set(ChromiumBrowser.all.map(\.supportFolder)).count, 5)
        XCTAssertEqual(ChromiumBrowser.named("brave")?.supportFolder, "BraveSoftware/Brave-Browser")
        XCTAssertEqual(ChromiumBrowser.named("arc")?.supportFolder, "Arc/User Data")
        XCTAssertNil(ChromiumBrowser.named("firefox"))
        XCTAssertNotNil(ChromiumBrowser.named("arc")?.caveat)
        XCTAssertNil(ChromiumBrowser.chrome.caveat)
    }

    func testInstalledBrowsersAreFoundByTheirApps() {
        let found = ChromiumBrowser.installed(home: home) { $0 == "/Applications/Brave Browser.app" || $0 == "/Applications/Google Chrome.app" }
        XCTAssertEqual(found.map(\.id), ["chrome", "brave"])
        XCTAssertEqual(ChromiumBrowser.installed(home: home) { _ in false }, [])
        let inHome = ChromiumBrowser.installed(home: home) { $0 == home.appendingPathComponent("Applications/Arc.app").path }
        XCTAssertEqual(inHome.map(\.id), ["arc"])
    }

    func testEachBrowserIsItsOwnOptInAndWritesOnlyItsOwnFolder() throws {
        try registration(.named("brave")!).register()
        XCTAssertEqual(files(under: home), [
            "/Library/Application Support/Benji/Browser/benji-browser-host",
            "/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.emerssive.heybenji.browser.json",
        ])
        XCTAssertTrue(registration(.named("brave")!).isRegistered)
        for other in ChromiumBrowser.all where other.id != "brave" { XCTAssertFalse(registration(other).isRegistered, other.id) }
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: registration(.named("brave")!).manifestURL)) as? [String: Any])
        XCTAssertEqual(o["allowed_origins"] as? [String], BrowserExtension.allowedOrigins)
        XCTAssertEqual(o["path"] as? String, registration(.named("brave")!).launcherURL.path)
    }

    func testTheLauncherStaysUntilTheLastBrowserLetsGo() throws {
        let brave = registration(.named("brave")!), edge = registration(.named("edge")!)
        try brave.register()
        try edge.register()
        XCTAssertEqual(BrowserHostRegistration.registered(home: home, assistantDir: "/Users/someone/Benji/assistant").map(\.id), ["brave", "edge"])
        brave.unregister()
        XCTAssertFalse(brave.isRegistered)
        XCTAssertTrue(edge.isRegistered, "turning one browser off leaves another's connection working")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: edge.launcherURL.path))
        edge.unregister()
        XCTAssertEqual(files(under: home), [])
    }

    func testTurningTheMasterSwitchOffRemovesEveryBrowser() throws {
        for b in ChromiumBrowser.all { try registration(b).register() }
        BrowserHostRegistration.unregisterAll(home: home, assistantDir: "/Users/someone/Benji/assistant")
        XCTAssertEqual(files(under: home), [])
    }

    func testNothingIsWrittenForABrowserNobodyTurnedOn() {
        for b in ChromiumBrowser.all { _ = registration(b).manifestData() }
        XCTAssertEqual(files(under: home), [])
    }

    func testTheExtensionIdsAreTheSameInThePythonEngineAndHost() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let link = try String(contentsOf: root.appendingPathComponent("benji/browser_link.py"), encoding: .utf8)
        let host = try String(contentsOf: root.appendingPathComponent("benji/browser_host.py"), encoding: .utf8)
        XCTAssertEqual(BrowserExtension.ids.count, 1, "a second (Web Store) id is a decision of its own")
        for id in BrowserExtension.ids {
            XCTAssertTrue(link.contains("\"\(id)\""))
            XCTAssertTrue(host.contains("\"\(id)\""))
        }
    }

    func testTheSetupWordsTellTheUserWhatToClickPerBrowser() {
        let brave = BrowserSetup.steps(for: .named("brave")!)
        XCTAssertTrue(brave.contains("brave://extensions") && brave.contains("Developer mode") && brave.contains("Load unpacked"))
        XCTAssertTrue(brave.contains("debugger permission"))
        XCTAssertTrue(BrowserSetup.steps(for: .named("edge")!).contains("edge://extensions"))
        XCTAssertTrue(BrowserCopy.browsersFooter.contains("never changes a browser's own settings"))
    }

    func testAlwaysAllowTakesExactHttpsSitesOnly() {
        XCTAssertEqual(BrowserAlways.origin(from: "example.com"), "https://example.com")
        XCTAssertEqual(BrowserAlways.origin(from: "  https://Example.com/inbox?x=1 "), "https://example.com")
        XCTAssertEqual(BrowserAlways.origin(from: "example.com:8443"), "https://example.com:8443")
        XCTAssertEqual(BrowserAlways.origin(from: "https://www.example.com"), "https://www.example.com")
        for bad in ["", "http://example.com", "ftp://example.com", "user@example.com", "https://user:pw@example.com", "localhost", "127.0.0.1",
                    "10.0.0.1", "exa mple.com", "example", "https://", "javascript:alert(1)", "例え.jp", "-x.example.com"] {
            XCTAssertNil(BrowserAlways.origin(from: bad), bad)
        }
        XCTAssertEqual(BrowserAlways.adding("a.example.com", to: []), ["https://a.example.com"])
        XCTAssertEqual(BrowserAlways.adding("a.example.com", to: ["https://a.example.com"]), ["https://a.example.com"])
        XCTAssertNil(BrowserAlways.adding("nope", to: []))
        let full = (0..<BrowserAlways.maxSites).map { "https://s\($0).example.com" }
        XCTAssertNil(BrowserAlways.adding("another.example.com", to: full))
        XCTAssertEqual(BrowserAlways.decode(["https://a.example.com", "a.example.com", "http://bad.com", 5, "b.example.com"] as [Any]),
                       [])  // a stored value that isn't a list of strings is ignored
        XCTAssertEqual(BrowserAlways.decode(["https://a.example.com", "a.example.com", "http://bad.com", "b.example.com"]),
                       ["https://a.example.com", "https://b.example.com"])
    }

    func testTheAlwaysListHasNoWayToAllowActingOrUploads() {
        let changes: [SettingsChange] = [.browserAlwaysAdd("x.example.com"), .browserAlwaysRemove("https://x.example.com")]
        XCTAssertEqual(changes.count, 2)
        let line = String(decoding: ServeRequest.browserAlways(sites: ["https://a.example.com"]).line(), as: UTF8.self)
        XCTAssertEqual(line, #"{"sites":["https://a.example.com"],"type":"browser_always"}"# + "\n")
        XCTAssertFalse(line.contains("act") && line.contains("upload"))
    }

    func testBrowserAlwaysEventDecodesAndKeepsHttpsOnly() {
        XCTAssertEqual(ServeEvent.decode(#"{"type":"browser_always","sites":["https://a.example.com","javascript:1"]}"#),
                       .browserAlways(["https://a.example.com"]))
        XCTAssertEqual(ServeEvent.decode(#"{"type":"browser_always"}"#), .unknown(type: "browser_always"))
    }

    func testAJobShowsTheSitesItMayClickAndTypeOn() throws {
        let job = try XCTUnwrap(JobSnapshot.decode(["id": "j", "state": "working", "title": "Inbox",
                                                    "sites": ["https://example.com"], "act_sites": ["https://example.com", "http://no.com"]]))
        XCTAssertEqual(job.actSites, ["https://example.com"])
        XCTAssertEqual(job.actSitesLine, "Can click and type on: example.com")
        let older = try XCTUnwrap(JobSnapshot.decode(["id": "j", "state": "working", "title": "x"]))
        XCTAssertEqual(older.actSites, [])
        XCTAssertNil(older.actSitesLine)
    }

    func testHelloListsTheBrowserActingToolsOnlyWithTheBrowserAndJobs() {
        let on = AppCapabilities.list(screenActions: true)
        XCTAssertTrue(on.contains("browser_act") && on.contains("browser_upload"))
        XCTAssertFalse(AppCapabilities.list(screenActions: true, browserActing: false).contains("browser_act"))
        XCTAssertFalse(AppCapabilities.list(screenActions: true, browserActing: false).contains("browser_upload"))
        XCTAssertFalse(AppCapabilities.list(screenActions: true, jobs: false).contains("browser_act"), "acting is for jobs")
        XCTAssertFalse(AppCapabilities.list(screenActions: true, browser: false).contains("browser_upload"))
        XCTAssertEqual(on.filter { $0 == "browser_upload" }.count, 1)
    }

    func testTheSnapshotStartsWithNoBrowsersAndNoAlwaysSites() {
        XCTAssertEqual(SettingsSnapshot().browsers, [])
        XCTAssertEqual(SettingsSnapshot().browserAlways, [])
    }
}

extension BrowserStatus {
    static var allWords: [String] { [BrowserStatus.off, .waiting, .connected].map(\.word) }
}
