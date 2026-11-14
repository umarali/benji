import XCTest
@testable import BenjiCore

/// The rename to Benji, the app's side. Fakes and throwaway folders only: `FakeKeyStore` instead of the
/// Keychain, and every browser folder under a temporary home.
final class RenameMigrationTests: XCTestCase {
    private var home: URL!
    private let dir = "/repo/assistant"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("benji-rename-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    // MARK: the guard

    func testTheGuardRefusesTheRealHomeAndLetsAThrowawayOneThrough() throws {
        let real = home.appendingPathComponent("real").path
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        XCTAssertNotNil(MigrationGuard.violation(paths: [real + "/.chilly"], realHome: real))
        XCTAssertNotNil(MigrationGuard.violation(paths: [real], realHome: real))
        let link = home.appendingPathComponent("innocent").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        XCTAssertNotNil(MigrationGuard.violation(paths: [link + "/.chilly"], realHome: real), "a link into the real home is the real home")
        XCTAssertNil(MigrationGuard.violation(paths: [home.path + "/.chilly"], realHome: real))
        XCTAssertNil(MigrationGuard.violation(paths: [real + "-elsewhere/.chilly"], realHome: real), "a look-alike prefix is not inside it")
        XCTAssertTrue(MigrationGuard.isActive, "XCTest is loaded, so every migration in a test is guarded")
    }

    // MARK: the key file

    private func keyFile(_ name: String, _ text: String) throws -> URL {
        let url = home.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    func testTheKeyFileIsRenamedOnceAndKeepsItsContentsAndMode() throws {
        let old = try keyFile(".chilly.env", "ANTHROPIC_API_KEY=fake\n")
        let inode = try FileManager.default.attributesOfItem(atPath: old.path)[.systemFileNumber] as? Int
        XCTAssertEqual(HomeMigration.moveKeyFile(environment: [:], home: home, others: { _ in [] }), .renamed)
        let new = home.appendingPathComponent(".benji.env")
        let attrs = try FileManager.default.attributesOfItem(atPath: new.path)
        XCTAssertEqual(try String(contentsOf: new, encoding: .utf8), "ANTHROPIC_API_KEY=fake\n")
        XCTAssertEqual((attrs[.posixPermissions] as? Int ?? 0) & 0o777, 0o600)
        XCTAssertEqual(attrs[.systemFileNumber] as? Int, inode, "the same file: no second copy of a key")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(HomeMigration.moveKeyFile(environment: [:], home: home, others: { _ in [] }), .none)
    }

    func testAnExistingNewKeyFileIsNeverReplaced() throws {
        let old = try keyFile(".chilly.env", "A=old\n"), new = try keyFile(".benji.env", "A=new\n")
        XCTAssertEqual(HomeMigration.moveKeyFile(environment: [:], home: home, others: { _ in [] }), .none)
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "A=old\n")
        XCTAssertEqual(try String(contentsOf: new, encoding: .utf8), "A=new\n")
    }

    func testTheKeyFileStaysWhileAnotherCopyRuns() throws {
        let old = try keyFile(".chilly.env", "A=old\n")
        XCTAssertEqual(HomeMigration.moveKeyFile(environment: [:], home: home, others: { _ in [4242] }), .busy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    func testAKeyFileThatIsALinkMovesAsALink() throws {
        let target = try keyFile("elsewhere.env", "A=1\n")
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent(".chilly.env").path, withDestinationPath: target.path)
        XCTAssertEqual(HomeMigration.moveKeyFile(environment: [:], home: home, others: { _ in [] }), .renamed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".benji.env").path), target.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testAWorkingFolderOverrideMovesNoKeyFile() throws {
        let old = try keyFile(".chilly.env", "A=old\n")
        XCTAssertEqual(HomeMigration.moveKeyFile(environment: ["BENJI_WORKDIR": "/tmp/w"], home: home, others: { _ in [] }), .none)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    func testAMoveStoppedHalfwayIsFinished() throws {
        let old = try keyFile(".chilly.env", "A=old\n")
        XCTAssertEqual(link(old.path, home.appendingPathComponent(".benji.env").path), 0)
        XCTAssertEqual(HomeMigration.moveKeyFile(environment: [:], home: home, others: { _ in [] }), .renamed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".benji.env"), encoding: .utf8), "A=old\n")
    }

    func testAFolderOfThatNameIsLeftAlone() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".chilly.env"), withIntermediateDirectories: true)
        XCTAssertEqual(HomeMigration.moveKeyFile(environment: [:], home: home, others: { _ in [] }), .none)
    }

    // MARK: environment names

    func testOlderVariablesGetTheirNewNamesAndNeverWin() {
        let added = LegacyEnvironment.additions(["CHILLY_MODEL": "c", "PAL_MODEL": "p", "PAL_EFFORT": "e", "BENJI_STREAM": "b",
                                                 "CHILLY_STREAM": "old", "CHILLY_DIR": "/old", "ANTHROPIC_API_KEY": "x"])
        XCTAssertEqual(added, ["BENJI_MODEL": "c", "BENJI_EFFORT": "e"], "BENJI over CHILLY over PAL; the code's folder and provider names are left")
    }

    func testTheWorkingFolderOverrideReadsEveryNameNewestFirst() {
        XCTAssertEqual(LegacyEnvironment.workingFolderOverride(["CHILLY_WORKDIR": "/c", "BENJI_WORKDIR": "/b"]), "/b")
        XCTAssertEqual(LegacyEnvironment.workingFolderOverride(["PAL_WORKDIR": "/p", "CHILLY_WORKDIR": "/c"]), "/c")
        XCTAssertEqual(LegacyEnvironment.workingFolderOverride(["PAL_WORKDIR": "/p"]), "/p")
        XCTAssertNil(LegacyEnvironment.workingFolderOverride(["BENJI_WORKDIR": "   "]))
        XCTAssertEqual(WorkingFolder.url(environment: ["CHILLY_WORKDIR": "/tmp/w"], home: home).path, "/tmp/w")
    }

    func testAnOldCodeFolderIsOnlyUsedIfItReallyHoldsBenji() {
        let args: (URL, URL?, String) = (URL(fileURLWithPath: "/repo/companion/Benji.app"), nil, "/nowhere")
        let exists: (String) -> Bool = { $0 == "/repo/benji/__main__.py" || $0 == "/new/benji/__main__.py" }
        XCTAssertEqual(AssistantLocator.resolve(environment: ["CHILLY_DIR": "/old-checkout"], bundleURL: args.0, executableURL: args.1,
                                                currentDirectory: args.2, fileExists: exists), "/repo")
        XCTAssertEqual(AssistantLocator.resolve(environment: ["CHILLY_DIR": "/new"], bundleURL: args.0, executableURL: args.1,
                                                currentDirectory: args.2, fileExists: exists), "/new")
        XCTAssertEqual(AssistantLocator.resolve(environment: ["BENJI_DIR": "/x"], bundleURL: args.0, executableURL: args.1,
                                                currentDirectory: args.2, fileExists: exists), "/x")
    }

    // MARK: the Keychain

    private func stores(new: [String: String] = [:], old: [String: String] = [:]) -> (FakeKeyStore, FakeKeyStore, LegacyAwareKeyStore) {
        let primary = FakeKeyStore(), legacy = FakeKeyStore()
        for (k, v) in new { try? primary.write(v, account: k) }
        for (k, v) in old { try? legacy.write(v, account: k) }
        return (primary, legacy, LegacyAwareKeyStore(primary: primary, legacy: [legacy]))
    }

    func testAKeyInTheOldServiceIsReadCopiedForwardAndKeptAsTheWayBack() throws {
        let (primary, legacy, store) = stores(old: ["ANTHROPIC_API_KEY": "fake-old"])
        XCTAssertEqual(try store.read("ANTHROPIC_API_KEY"), "fake-old")
        XCTAssertEqual(try primary.read("ANTHROPIC_API_KEY"), "fake-old", "copied forward")
        XCTAssertEqual(try legacy.read("ANTHROPIC_API_KEY"), "fake-old", "and the old item stays")
    }

    func testAnOldAccountNameBecomesTheNewOne() throws {
        let (primary, _, store) = stores(old: ["CHILLY_API_KEY": "fake-chilly"])
        XCTAssertEqual(try store.accounts(), ["BENJI_API_KEY"])
        XCTAssertEqual(try store.read("BENJI_API_KEY"), "fake-chilly")
        XCTAssertEqual(try primary.read("BENJI_API_KEY"), "fake-chilly")
        XCTAssertNil(try primary.read("CHILLY_API_KEY"))
    }

    func testANewItemBeatsTheOldOneAndTheOldServiceIsNotRead() throws {
        let (_, legacy, store) = stores(new: ["ANTHROPIC_API_KEY": "fake-new"], old: ["ANTHROPIC_API_KEY": "fake-old"])
        legacy.failOn = .denied
        XCTAssertEqual(try store.read("ANTHROPIC_API_KEY"), "fake-new")
    }

    func testADeniedOldItemStopsTheEngineAndNothingFallsBack() throws {
        let (_, legacy, store) = stores(old: ["ANTHROPIC_API_KEY": "fake-old"])
        legacy.failOn = .denied
        XCTAssertThrowsError(try store.read("ANTHROPIC_API_KEY")) { XCTAssertEqual($0 as? KeyStoreError, .denied) }
        guard case let .failure(failure) = KeyHandoff.environment(keychainMode: true, store: store) else { return XCTFail("the engine must not start") }
        XCTAssertEqual(failure, .keychainUnreadable(.denied))
    }

    func testALockedNewServiceStopsTheEngine() {
        let (primary, _, store) = stores(old: ["ANTHROPIC_API_KEY": "fake-old"])
        primary.failOn = .unavailable
        guard case let .failure(failure) = KeyHandoff.environment(keychainMode: true, store: store) else { return XCTFail("the engine must not start") }
        XCTAssertEqual(failure, .keychainUnreadable(.unavailable))
    }

    func testAKeyThatWontCopyIsStillHandedOverAndABadCopyIsRemoved() throws {
        let (primary, _, store) = stores(old: ["ANTHROPIC_API_KEY": "fake-old"])
        primary.corruptReads = true
        XCTAssertEqual(try store.read("ANTHROPIC_API_KEY"), "fake-old")
        primary.corruptReads = false
        XCTAssertNil(try primary.read("ANTHROPIC_API_KEY"), "read-back failed, so the copy was rolled back")
    }

    func testHandoverInKeychainModeUsesTheNewNames() {
        let (_, _, store) = stores(old: ["CHILLY_API_KEY": "fake-chilly", "ANTHROPIC_API_KEY": "fake-anthropic"])
        guard case let .success(env) = KeyHandoff.environment(keychainMode: true, store: store) else { return XCTFail("should hand over") }
        XCTAssertEqual(env, ["BENJI_KEY_SOURCE": "keychain", "BENJI_API_KEY": "fake-chilly", "ANTHROPIC_API_KEY": "fake-anthropic"])
    }

    func testFileModeNeverTouchesEitherService() {
        let (primary, legacy, store) = stores(old: ["ANTHROPIC_API_KEY": "fake-old"])
        primary.failOn = .denied
        legacy.failOn = .denied
        guard case let .success(env) = KeyHandoff.environment(keychainMode: false, store: store) else { return XCTFail("file mode adds nothing") }
        XCTAssertEqual(env, [:])
    }

    func testADeletedKeyCannotComeBackFromTheOldService() throws {
        let (_, _, store) = stores(new: ["ANTHROPIC_API_KEY": "n"], old: ["ANTHROPIC_API_KEY": "o", "CHILLY_API_KEY": "c"])
        try store.delete("ANTHROPIC_API_KEY")
        try store.delete("BENJI_API_KEY")
        XCTAssertNil(try store.read("ANTHROPIC_API_KEY"))
        XCTAssertNil(try store.read("BENJI_API_KEY"))
    }

    func testMovingKeysFromFilesTakesTheNewestFileAndTheNewName() throws {
        let newest = home.appendingPathComponent(".benji.env"), older = home.appendingPathComponent(".chilly.env")
        try "ANTHROPIC_API_KEY=fake-newest\n".write(to: newest, atomically: true, encoding: .utf8)
        try "ANTHROPIC_API_KEY=fake-newest\nCHILLY_API_KEY=fake-c\n".write(to: older, atomically: true, encoding: .utf8)
        let store = FakeKeyStore()
        let suite = "benji-rename-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(KeyMigration.migrate(files: [newest, older], store: store, defaults: defaults), .moved(count: 2))
        XCTAssertEqual(try store.read("ANTHROPIC_API_KEY"), "fake-newest")
        XCTAssertEqual(try store.read("BENJI_API_KEY"), "fake-c")
        XCTAssertFalse(try String(contentsOf: older, encoding: .utf8).contains("fake-"))
    }

    func testTwoDifferentValuesForOneKeyMoveNothing() throws {
        let newest = home.appendingPathComponent(".benji.env"), older = home.appendingPathComponent(".chilly.env")
        try "BENJI_API_KEY=fake-b\n".write(to: newest, atomically: true, encoding: .utf8)
        try "CHILLY_API_KEY=fake-c\n".write(to: older, atomically: true, encoding: .utf8)
        let store = FakeKeyStore()
        let suite = "benji-rename-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(KeyMigration.migrate(files: [newest, older], store: store, defaults: defaults), .conflictingKeys(names: ["BENJI_API_KEY"]))
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(try String(contentsOf: older, encoding: .utf8), "CHILLY_API_KEY=fake-c\n", "no file is changed")
        XCTAssertFalse(KeyMigration.Outcome.conflictingKeys(names: ["BENJI_API_KEY"]).words.contains("fake"))
    }

    func testADeniedOldItemLeavesTheCurrentKeyInPlace() throws {
        let (primary, legacy, store) = stores(new: ["ANTHROPIC_API_KEY": "n"], old: ["ANTHROPIC_API_KEY": "o"])
        legacy.failOn = .denied
        XCTAssertThrowsError(try store.delete("ANTHROPIC_API_KEY"))
        XCTAssertEqual(try primary.read("ANTHROPIC_API_KEY"), "n")
    }

    func testNothingStartsTheMoveFromAPlainFileByItself() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var callers: [String] = []
        for case let url as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)! where url.pathExtension == "swift" {
            if url.lastPathComponent != "KeyStore.swift", try String(contentsOf: url, encoding: .utf8).contains("KeyMigration.migrate(") { callers.append(url.lastPathComponent) }
        }
        XCTAssertEqual(callers.sorted(), ["ModelSetup.swift", "QuietServices.swift"], "only the explicit setup Save and Settings Move handlers may migrate file keys")
    }

    // MARK: the browser

    private func manifest(_ browser: ChromiumBrowser, launcher: String? = nil) throws -> URL {
        let url = BrowserRenameMigration.oldManifest(home, browser)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = launcher ?? BrowserRenameMigration.oldFolder(home).appendingPathComponent(BrowserRenameMigration.oldLauncherName).path
        let data = try JSONSerialization.data(withJSONObject: ["name": BrowserRenameMigration.oldHostName, "path": path, "type": "stdio",
                                                               "allowed_origins": BrowserExtension.allowedOrigins])
        try data.write(to: url)
        return url
    }

    private func oldFiles() throws {
        let old = BrowserRenameMigration.oldFolder(home)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: old.appendingPathComponent(BrowserRenameMigration.oldLauncherName), atomically: true, encoding: .utf8)
        try "{\"port\": 1, \"token\": \"old-token\"}".write(to: old.appendingPathComponent("link.json"), atomically: true, encoding: .utf8)
    }

    func testAnEnabledBrowserIsRegisteredAnewBeforeTheOldManifestGoes() throws {
        try oldFiles()
        let old = try manifest(.chrome)
        BrowserRenameMigration.reconcile(home: home, assistantDir: dir, browserOn: true, othersRunning: false)
        let reg = BrowserHostRegistration(home: home, assistantDir: dir, browser: .chrome)
        XCTAssertTrue(reg.isRegistered)
        XCTAssertTrue(try String(contentsOf: reg.launcherURL, encoding: .utf8).contains("/repo/assistant/benji/browser_host.py"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        let new = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: reg.manifestURL)) as? [String: Any])
        XCTAssertEqual(new["allowed_origins"] as? [String], BrowserExtension.allowedOrigins, "no wider than before")
        XCTAssertEqual(new["name"] as? String, "com.emerssive.heybenji.browser")
    }

    func testTheOldTokenAndLauncherAreGoneAndTheFolderIsCleared() throws {
        try oldFiles()
        _ = try manifest(.chrome)
        BrowserRenameMigration.reconcile(home: home, assistantDir: dir, browserOn: true, othersRunning: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: BrowserRenameMigration.oldFolder(home).path))
    }

    func testABrowserThatWasntOnStaysOffAndAForeignManifestIsLeft() throws {
        try oldFiles()
        let chrome = try manifest(.chrome)
        let brave = try manifest(ChromiumBrowser.named("brave")!, launcher: "/somewhere/else/host")
        BrowserRenameMigration.reconcile(home: home, assistantDir: dir, browserOn: true, othersRunning: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chrome.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: brave.path), "not the launcher we wrote: not ours to remove")
        XCTAssertFalse(BrowserHostRegistration(home: home, assistantDir: dir, browser: ChromiumBrowser.named("edge")!).isRegistered)
        XCTAssertFalse(BrowserHostRegistration(home: home, assistantDir: dir, browser: ChromiumBrowser.named("brave")!).isRegistered)
    }

    func testBrowserAccessOffMeansNothingIsWrittenAndTheOldOneGoes() throws {
        try oldFiles()
        let old = try manifest(.chrome)
        BrowserRenameMigration.reconcile(home: home, assistantDir: dir, browserOn: false, othersRunning: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: BrowserHostRegistration(home: home, assistantDir: dir).manifestURL.path))
    }

    func testARegistrationThatFailsKeepsTheOldOne() throws {
        try oldFiles()
        let old = try manifest(.chrome)
        BrowserRenameMigration.reconcile(home: home, assistantDir: "relative/not/usable", browserOn: true, othersRunning: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: BrowserRenameMigration.oldFolder(home).appendingPathComponent("link.json").path))
    }

    func testAnOlderAppStillRunningLeavesEverythingAlone() throws {
        try oldFiles()
        let old = try manifest(.chrome)
        BrowserRenameMigration.reconcile(home: home, assistantDir: dir, browserOn: true, othersRunning: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(BrowserHostRegistration(home: home, assistantDir: dir).isRegistered)
    }

    func testRunningTwiceIsSafe() throws {
        try oldFiles()
        _ = try manifest(.chrome)
        for _ in 0..<2 { BrowserRenameMigration.reconcile(home: home, assistantDir: dir, browserOn: true, othersRunning: false) }
        XCTAssertTrue(BrowserHostRegistration(home: home, assistantDir: dir).isRegistered)
    }

    func testTheExtensionsIdentityDidNotChange() {
        XCTAssertEqual(BrowserExtension.ids, ["oifkoajmlonknfkpeecajlncpjbjmfef"])
    }

    // MARK: the name it answers to

    func testTheOldNameNoLongerEndsAConversation() {
        XCTAssertEqual(StopPhrases.match("thanks Benji"), .stopOnly)
        XCTAssertEqual(StopPhrases.match("bye Benjy"), .stopOnly)
        for said in ["thanks Chilly", "bye chilly", "goodbye chili", "thank you chilli"] {
            XCTAssertEqual(StopPhrases.match(said), .none, said)
        }
    }

    func testAnOldGreetingStillGetsAProperTitle() {
        let lines: [SavedLine] = [.init(role: .user, text: "Hey Chilly"), .init(role: .user, text: "How do tides work?")]
        XCTAssertEqual(ConversationTitle.make(lines), "How do tides work?")
    }
}
