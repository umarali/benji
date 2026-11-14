import XCTest
@testable import BenjiCore

final class ModelSetupTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "benji-model-setup-\(UUID().uuidString)")! }

    func testPasteWithoutFileKeysSelectsKeychainAndSettingsAgrees() throws {
        let store = FakeKeyStore(), prefs = defaults(), key = "fake-model-key-for-tests"
        try ModelSetupPreferences.saveAnthropic("  \(key)\n", store: store, defaults: prefs, files: [])
        XCTAssertEqual(store.writes, ["ANTHROPIC_API_KEY"])
        XCTAssertEqual(try store.read("ANTHROPIC_API_KEY"), key)
        XCTAssertEqual(prefs.string(forKey: KeyNames.defaultsKey), "keychain")
        XCTAssertTrue(prefs.bool(forKey: ModelSetupPreferences.needsTestKey))
        XCTAssertFalse(String(describing: prefs.dictionaryRepresentation()).contains(key))
        XCTAssertEqual(ModelSetupPreferences.environment(prefs)["BENJI_PROVIDER"], "claude")
        let handoff = try ModelSetupPreferences.keyEnvironment(prefs, store: store).get()
        XCTAssertEqual(handoff["ANTHROPIC_API_KEY"], key)
        XCTAssertEqual(KeyStorageStatus.current(defaults: prefs, store: store, files: []), .inKeychain(count: 1))
    }

    func testFailedOrCorruptStoreDoesNotSelectSource() {
        for corrupt in [false, true] {
            let store = FakeKeyStore(), prefs = defaults()
            if corrupt { store.corruptReads = true } else { store.failOn = .denied }
            XCTAssertThrowsError(try ModelSetupPreferences.saveAnthropic("fake-model-key-for-tests", store: store, defaults: prefs, files: []))
            XCTAssertNil(prefs.object(forKey: KeyNames.defaultsKey))
            XCTAssertNil(prefs.object(forKey: ModelSetupPreferences.providerKey))
            XCTAssertNil(prefs.object(forKey: ModelSetupPreferences.needsTestKey))
        }
    }

    func testBlankOrControlCharactersNeverReachStore() {
        for input in [" \n", "fake-model-key-for-tests\nother", "fake-model-key-\u{0}for-tests"] {
            let store = FakeKeyStore()
            XCTAssertThrowsError(try ModelSetupPreferences.saveAnthropic(input, store: store, defaults: defaults(), files: []))
            XCTAssertTrue(store.writes.isEmpty)
        }
    }

    func testLocalSettingsReuseEngineVariablesAndRequireLoopback() {
        for provider in ["ollama", "lmstudio"] {
            let prefs = defaults()
            XCTAssertTrue(ModelSetupPreferences.saveLocal(provider: provider, model: "test-local-model", endpoint: "http://localhost:11434/v1", defaults: prefs))
            let env = ModelSetupPreferences.environment(prefs)
            XCTAssertEqual(env["BENJI_PROVIDER"], provider)
            XCTAssertEqual(env["BENJI_MODEL"], "test-local-model")
            XCTAssertEqual(env["BENJI_BASE_URL"], "http://localhost:11434/v1")
            XCTAssertEqual(env["BENJI_API_KEY"], "")
            XCTAssertNil(env[KeyNames.sourceVariable], "local model selection preserves the key-file source")
            XCTAssertTrue(prefs.bool(forKey: ModelSetupPreferences.needsTestKey))
        }
        for endpoint in ["https://example.com/v1", "http://localhost.evil/v1", "file:///tmp/model", "http://user:pass@localhost/v1", "http://localhost/v1?key=x", "http://localhost:0/v1", "http://%6cocalhost:11434/v1"] {
            XCTAssertFalse(ModelSetupPreferences.saveLocal(provider: "ollama", model: "test", endpoint: endpoint, defaults: defaults()), endpoint)
        }
        XCTAssertFalse(ModelSetupPreferences.saveLocal(provider: "openai", model: "test", endpoint: "http://localhost/v1", defaults: defaults()))
        XCTAssertFalse(ModelSetupPreferences.saveLocal(provider: "ollama", model: "  ", endpoint: "http://localhost/v1", defaults: defaults()))
    }

    func testNoSetupChoicesLeaveEngineConfigurationAlone() {
        XCTAssertEqual(ModelSetupPreferences.environment(defaults()), [:])
    }

    func testLocalSelectionKeepsEveryKeychainToolKeyAndTheSelectedSource() throws {
        for keychainMode in [false, true] {
            let store = FakeKeyStore(), prefs = defaults()
            try store.write("fake-search-value", account: "SERPAPI_KEY")
            if keychainMode { prefs.set("keychain", forKey: KeyNames.defaultsKey) }
            XCTAssertTrue(ModelSetupPreferences.saveLocal(provider: "ollama", model: "test", endpoint: "http://[::1]:11434/v1", defaults: prefs))
            let env = try ModelSetupPreferences.keyEnvironment(prefs, store: store).get()
            XCTAssertEqual(prefs.string(forKey: KeyNames.defaultsKey), keychainMode ? "keychain" : nil)
            XCTAssertEqual(env[KeyNames.sourceVariable], keychainMode ? "keychain" : nil)
            XCTAssertEqual(env["SERPAPI_KEY"], keychainMode ? "fake-search-value" : nil)
        }
    }

    private func scratch(_ text: String) throws -> (URL, URL) {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("benji-setup-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("fixture.env")
        try Data(text.utf8).write(to: file)
        return (dir, file)
    }

    func testSaveMovesOtherFileKeysAndPastedAnthropicWins() throws {
        let (dir, file) = try scratch("ANTHROPIC_API_KEY=fake-old-anthropic\nOPENAI_API_KEY=fake-openai\nSERPAPI_KEY=fake-search\nBENJI_MODEL=test-model\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeKeyStore(), prefs = defaults()
        store.items["ANTHROPIC_API_KEY"] = "fake-previous-keychain"
        let names = KeyMigration.fileKeyNames(files: [file])
        let words = ModelSetupPreferences.saveDisclosure(names: names)
        XCTAssertTrue(words.contains("Saving also moves OPENAI_API_KEY and SERPAPI_KEY"))
        XCTAssertTrue(words.contains("The file's ANTHROPIC_API_KEY will be replaced"))
        XCTAssertFalse(words.contains("fake-"))
        try ModelSetupPreferences.saveAnthropic("fake-pasted-anthropic", store: store, defaults: prefs, files: [file])
        XCTAssertEqual(store.items, ["ANTHROPIC_API_KEY": "fake-pasted-anthropic", "OPENAI_API_KEY": "fake-openai", "SERPAPI_KEY": "fake-search"])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "BENJI_MODEL=test-model\n")
        XCTAssertEqual(KeyStorageStatus.current(defaults: prefs, store: store, files: [file]), .inKeychain(count: 3))
        let env = try ModelSetupPreferences.keyEnvironment(prefs, store: store).get()
        XCTAssertEqual(env[KeyNames.sourceVariable], "keychain")
        XCTAssertEqual(env["SERPAPI_KEY"], "fake-search")
    }

    func testSetupRefusesOtherKeyConflictBeforeWritingPastedKey() throws {
        let (dir, file) = try scratch("SERPAPI_KEY=fake-file-search\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeKeyStore(), prefs = defaults()
        store.items = ["ANTHROPIC_API_KEY": "fake-held-anthropic", "SERPAPI_KEY": "fake-held-search"]
        XCTAssertThrowsError(try ModelSetupPreferences.saveAnthropic("fake-paste", store: store, defaults: prefs, files: [file])) { error in
            XCTAssertEqual((error as? ModelSetupPreferences.SaveFailure)?.outcome, .conflictingKeys(names: ["SERPAPI_KEY"]))
        }
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertNil(prefs.object(forKey: ModelSetupPreferences.needsTestKey))
        XCTAssertEqual(store.items["ANTHROPIC_API_KEY"], "fake-held-anthropic")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "SERPAPI_KEY=fake-file-search\n")
        XCTAssertEqual(KeyStorageStatus.current(defaults: prefs, store: store, files: [file]), .inFile(count: 1))
    }

    func testSaveInKeychainModeReplacesOnlyAnthropicAndLeavesIgnoredFilesAlone() throws {
        let (dir, file) = try scratch("SERPAPI_KEY=fake-unused-file-search\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeKeyStore(), prefs = defaults()
        prefs.set("keychain", forKey: KeyNames.defaultsKey)
        store.items = ["ANTHROPIC_API_KEY": "fake-old", "SERPAPI_KEY": "fake-held-search"]
        try ModelSetupPreferences.saveAnthropic("fake-new", store: store, defaults: prefs, files: [file])
        XCTAssertEqual(store.items, ["ANTHROPIC_API_KEY": "fake-new", "SERPAPI_KEY": "fake-held-search"])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "SERPAPI_KEY=fake-unused-file-search\n")
        XCTAssertEqual(KeyStorageStatus.current(defaults: prefs, store: store, files: [file]), .inKeychain(count: 2))
    }

    func testFileModeEnvironmentNeverReadsDormantKeychain() throws {
        let store = FakeKeyStore(), prefs = defaults()
        store.failOn = .denied
        XCTAssertEqual(try ModelSetupPreferences.keyEnvironment(prefs, store: store).get(), [:])
    }

    func testKeylessCustomServerDisclosureDoesNotClaimToUseAKey() {
        let source = ModelSetupSource(provider: "openai", model: "test", destination: "server", host: "server.example",
                                      origin: "server settings", local: false, usesKey: false)
        XCTAssertFalse(source.disclosure.contains("using your key"))
    }

    func testPermissionGapsStillPreventCompletionWithModel() {
        XCTAssertFalse(SetupProgress(permissions: [:], modelDone: true).isComplete)
    }
}
