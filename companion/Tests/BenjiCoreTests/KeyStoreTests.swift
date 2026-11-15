import XCTest
@testable import BenjiCore

/// An in-memory key store. The only store these tests use: nothing here touches the real Keychain.
final class FakeKeyStore: KeyStore {
    var items: [String: String] = [:]
    var failOn: KeyStoreError?
    var failOnWrite: Int?
    var corruptAfterWrite: Int?
    var corruptReads = false
    private(set) var reads = 0
    private(set) var listings = 0
    private(set) var writes: [String] = []     // account names only
    func read(_ account: String) throws -> String? {
        reads += 1
        if let failOn { throw failOn }
        return (corruptReads || corruptAfterWrite == writes.count) ? (items[account].map { $0 + "x" }) : items[account]
    }
    func write(_ value: String, account: String) throws {
        if let failOn { throw failOn }
        writes.append(account)
        items[account] = value
        if failOnWrite == writes.count { throw KeyStoreError.denied }
    }
    func delete(_ account: String) throws { items[account] = nil }
    func accounts() throws -> [String] {
        listings += 1
        if let failOn { throw failOn }
        return items.keys.sorted()
    }
}

final class KeyStoreTests: XCTestCase {
    let fakeKey = "FAKE-test-key-aaaa1111"
    let fakeKey2 = "FAKE-test-key-bbbb2222"

    private func scratch(_ text: String? = nil) throws -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("benji-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(".benji.env")
        if let text { try Data(text.utf8).write(to: file) }
        return (dir, file)
    }

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "benji-keys-\(UUID().uuidString)")! }

    func testKeyNamesFollowTheSharedTable() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("key-name-cases.json")
        let table = try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(table.count, 10)
        for (name, want) in table { XCTAssertEqual(KeyNames.isSecret(name), want, "'\(name)'") }
    }

    func testTheEnvFileIsReadLikeTheEnginesLoader() {
        let text = """
        # comment
        ANTHROPIC_API_KEY="\(fakeKey)"
        export OPENAI_API_KEY = '\(fakeKey2)'
        BENJI_MODEL=claude-sonnet-5-5

        EMPTY_API_KEY=
        bad line
        ANTHROPIC_API_KEY=\(fakeKey2)
        """
        let secrets = EnvFile.secrets(in: text)
        XCTAssertEqual(secrets.map(\.name), ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"])
        XCTAssertEqual(secrets.first?.value, fakeKey2, "the last line for a name wins, as in the engine")
        XCTAssertEqual(secrets.last?.value, fakeKey2)
        let cleaned = EnvFile.removingKeys(from: text)
        XCTAssertFalse(cleaned.contains("API_KEY"))
        XCTAssertTrue(cleaned.contains("BENJI_MODEL=claude-sonnet-5-5") && cleaned.contains("# comment") && cleaned.contains("bad line"))
    }

    func testMigrationMovesKeysChecksThemAndCleansTheFile() throws {
        let (dir, file) = try scratch("ANTHROPIC_API_KEY=\(fakeKey)\nBENJI_MODEL=claude-haiku-5-5\nBRAVE_API_KEY=\(fakeKey2)\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeKeyStore(), d = defaults()
        XCTAssertFalse(KeyMigration.isUsingKeychain(d))
        let out = KeyMigration.migrate(files: [file], store: store, defaults: d)
        XCTAssertEqual(out, .moved(count: 2))
        XCTAssertEqual(store.items, ["ANTHROPIC_API_KEY": fakeKey, "BRAVE_API_KEY": fakeKey2])
        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(after, "BENJI_MODEL=claude-haiku-5-5\n")
        XCTAssertFalse(after.contains(fakeKey) || after.contains("API_KEY"))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertTrue(KeyMigration.isUsingKeychain(d))
        XCTAssertEqual(KeyMigration.migrate(files: [file], store: store, defaults: d), .nothingToMove, "idempotent")
    }

    func testAKeychainFailureLeavesTheFileAndTheModeAlone() throws {
        for failure in [KeyStoreError.denied, .unavailable, .failed] {
            let (dir, file) = try scratch("ANTHROPIC_API_KEY=\(fakeKey)\n")
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = FakeKeyStore(), d = defaults()
            store.failOn = failure
            XCTAssertEqual(KeyMigration.migrate(files: [file], store: store, defaults: d), .keychainFailed(failure))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "ANTHROPIC_API_KEY=\(fakeKey)\n")
            XCTAssertFalse(KeyMigration.isUsingKeychain(d))
        }
    }

    func testAReadBackThatDoesNotMatchIsAFailureAndTheFileKeepsItsKey() throws {
        let (dir, file) = try scratch("ANTHROPIC_API_KEY=\(fakeKey)\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeKeyStore(), d = defaults()
        store.corruptReads = true
        XCTAssertEqual(KeyMigration.migrate(files: [file], store: store, defaults: d), .keychainFailed(.failed))
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains(fakeKey))
        XCTAssertFalse(KeyMigration.isUsingKeychain(d))
    }

    func testMigrationRefusesDifferentKeychainValueWithoutLosingEitherKey() throws {
        let (dir, file) = try scratch("ANTHROPIC_API_KEY=\(fakeKey)\nSERPAPI_KEY=\(fakeKey2)\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeKeyStore(), d = defaults()
        store.items["ANTHROPIC_API_KEY"] = fakeKey2
        let original = try Data(contentsOf: file)
        let outcome = KeyMigration.migrate(files: [file], store: store, defaults: d)
        XCTAssertEqual(outcome, .conflictingKeys(names: ["ANTHROPIC_API_KEY"]))
        XCTAssertEqual(store.items, ["ANTHROPIC_API_KEY": fakeKey2])
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertFalse(KeyMigration.isUsingKeychain(d))
        XCTAssertTrue(outcome.words.contains("ANTHROPIC_API_KEY"))
        XCTAssertFalse(outcome.words.contains(fakeKey))
    }

    func testReplacementWaitsForOtherWritesAndRestoresHeldValueOnFailure() throws {
        for failure in ["earlier-write", "replacement-write", "replacement-readback"] {
            let text = "OPENAI_API_KEY=fake-file-openai\nSERPAPI_KEY=fake-file-search\n"
            let (dir, file) = try scratch(text)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = FakeKeyStore(), d = defaults()
            store.items["ANTHROPIC_API_KEY"] = "fake-held-anthropic"
            if failure == "earlier-write" { store.failOnWrite = 2 }
            if failure == "replacement-write" { store.failOnWrite = 3 }
            if failure == "replacement-readback" { store.corruptAfterWrite = 3 }
            let outcome = KeyMigration.migrate(files: [file], store: store, defaults: d,
                                               replacing: ["ANTHROPIC_API_KEY": "fake-pasted-anthropic"])
            XCTAssertEqual(outcome, .keychainFailed(failure == "replacement-readback" ? .failed : .denied))
            XCTAssertEqual(store.items["ANTHROPIC_API_KEY"], "fake-held-anthropic", failure)
            XCTAssertEqual(Array(store.writes.prefix(2)), ["OPENAI_API_KEY", "SERPAPI_KEY"])
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
            XCTAssertFalse(KeyMigration.isUsingKeychain(d))
        }
    }

    func testNothingToMoveChangesNothing() throws {
        let (dir, file) = try scratch("BENJI_MODEL=x\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeKeyStore(), d = defaults()
        XCTAssertEqual(KeyMigration.migrate(files: [file], store: store, defaults: d), .nothingToMove)
        XCTAssertEqual(KeyMigration.migrate(files: [dir.appendingPathComponent("missing.env")], store: store, defaults: d), .nothingToMove)
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertFalse(KeyMigration.isUsingKeychain(d))
    }

    func testMigrationNeverRunsByItself() throws {
        // Reading the status, building the handoff and listing accounts never write a key or switch the mode.
        let (dir, file) = try scratch("ANTHROPIC_API_KEY=\(fakeKey)\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeKeyStore(), d = defaults()
        XCTAssertEqual(KeyStorageStatus.current(defaults: d, store: store, files: [file]), .inFile(count: 1))
        _ = KeyHandoff.environment(keychainMode: false, store: store)
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertFalse(KeyMigration.isUsingKeychain(d))
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains(fakeKey))
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

    func testFileModeHandsTheEngineNothing() {
        let store = FakeKeyStore()
        store.items["ANTHROPIC_API_KEY"] = fakeKey
        XCTAssertEqual(try KeyHandoff.environment(keychainMode: false, store: store).get(), [:])
        XCTAssertEqual(store.reads, 0)
        XCTAssertEqual(store.listings, 0)
    }

    func testKeychainModeHandsOverTheKeysAndTellsTheEngineToReadNoFile() throws {
        let store = FakeKeyStore()
        store.items = ["ANTHROPIC_API_KEY": fakeKey, "NOT_A_SECRET": "x", "BRAVE_API_KEY": fakeKey2]
        let env = try KeyHandoff.environment(keychainMode: true, store: store).get()
        XCTAssertEqual(env["BENJI_KEY_SOURCE"], "keychain")
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], fakeKey)
        XCTAssertEqual(env["BRAVE_API_KEY"], fakeKey2)
        XCTAssertNil(env["NOT_A_SECRET"])
    }

    func testAnUnreadableKeychainStopsTheEngineStartInsteadOfFallingBack() {
        for failure in [KeyStoreError.denied, .unavailable, .failed] {
            let store = FakeKeyStore()
            store.items["ANTHROPIC_API_KEY"] = fakeKey
            store.failOn = failure
            let result = KeyHandoff.environment(keychainMode: true, store: store)
            guard case let .failure(error) = result else { return XCTFail("must fail closed") }
            XCTAssertEqual(error, .keychainUnreadable(failure))
            XCTAssertFalse(error.words.contains(fakeKey))
            XCTAssertTrue(error.words.contains("won't fall back"))
        }
    }

    func testMatchingKeychainValueIsSafeAndNeverRewritten() throws {
        let (dir, file) = try scratch("ANTHROPIC_API_KEY=\(fakeKey)\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeKeyStore(), d = defaults()
        store.items["ANTHROPIC_API_KEY"] = fakeKey
        XCTAssertEqual(KeyMigration.migrate(files: [file], store: store, defaults: d), .moved(count: 1))
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "")
        XCTAssertEqual(KeyStorageStatus.current(defaults: d, store: store, files: [file]), .inKeychain(count: 1))
    }

    func testStatusUsesOnlyTheSelectedSourceAndRequiresReadableNonemptyKeychainValues() throws {
        let (dir, file) = try scratch("SERPAPI_KEY=\(fakeKey)\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeKeyStore(), d = defaults()
        store.failOn = .denied
        XCTAssertEqual(KeyStorageStatus.current(defaults: d, store: store, files: [file]), .inFile(count: 1))
        XCTAssertEqual(KeyStorageStatus.current(defaults: d, store: store, files: []), .none)
        XCTAssertEqual(store.reads, 0)
        XCTAssertEqual(store.listings, 0)
        d.set("keychain", forKey: KeyNames.defaultsKey)
        XCTAssertEqual(KeyStorageStatus.current(defaults: d, store: store, files: [file]), .keychainProblem)
        store.failOn = nil
        store.items["ANTHROPIC_API_KEY"] = ""
        XCTAssertEqual(KeyStorageStatus.current(defaults: d, store: store, files: [file]), .keychainProblem)
        store.items["ANTHROPIC_API_KEY"] = fakeKey
        XCTAssertEqual(KeyStorageStatus.current(defaults: d, store: store, files: [file]), .inKeychain(count: 1))
    }

    func testNoValueEverReachesAMessage() throws {
        let (dir, file) = try scratch("ANTHROPIC_API_KEY=\(fakeKey)\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeKeyStore()
        store.failOn = .denied
        let outcome = KeyMigration.migrate(files: [file], store: store, defaults: defaults())
        XCTAssertFalse(String(describing: outcome).contains(fakeKey))
        for status in [KeyStorageStatus.inFile(count: 2), .inKeychain(count: 1), .keychainProblem, .none] {
            XCTAssertFalse(status.line.contains("FAKE"))
        }
    }

    func testTheStatusLinesAndWhenTheButtonShows() throws {
        let (dir, file) = try scratch("ANTHROPIC_API_KEY=\(fakeKey)\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = defaults(), store = FakeKeyStore()
        XCTAssertTrue(KeyStorageStatus.current(defaults: d, store: store, files: [file]).offersMove)
        XCTAssertEqual(KeyStorageStatus.current(defaults: d, store: store, files: [dir.appendingPathComponent("none")]), .none)
        d.set("keychain", forKey: KeyNames.defaultsKey)
        XCTAssertEqual(KeyStorageStatus.current(defaults: d, store: store, files: []), .keychainProblem)
        store.items["ANTHROPIC_API_KEY"] = fakeKey
        XCTAssertEqual(KeyStorageStatus.current(defaults: d, store: store, files: []), .inKeychain(count: 1))
        XCTAssertFalse(KeyStorageStatus.inKeychain(count: 1).offersMove)
    }
}

/// The real Keychain is never touched by a test: no test file may name it.
final class KeyStoreGuardTests: XCTestCase {
    func testNoTestNamesTheRealKeychainStore() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let forbidden = ["KeychainKeyStore", "SecItemAdd", "SecItemCopyMatching", "SecItemUpdate", "SecItemDelete", "SMAppService"]
        let files = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "KeyStoreTests.swift" } ?? []
        XCTAssertGreaterThan(files.count, 20)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in forbidden { XCTAssertFalse(text.contains(word), "\(file.lastPathComponent) names \(word)") }
        }
    }
}
