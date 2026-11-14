import XCTest
@testable import BenjiApp
import BenjiCore

private final class SetupMemoryKeyStore: KeyStore {
    var items: [String: String] = [:]
    var reads = 0
    var writes = 0
    var fail = false
    func read(_ account: String) throws -> String? { reads += 1; if fail { throw KeyStoreError.denied }; return items[account] }
    func write(_ value: String, account: String) throws { if fail { throw KeyStoreError.denied }; writes += 1; items[account] = value }
    func delete(_ account: String) throws { items[account] = nil }
    func accounts() throws -> [String] { Array(items.keys) }
}

@MainActor private final class SetupFakeBackend: ModelSetupBackend {
    var requests: [ModelSetupSource?] = []
    var callbacks: [(Result<ModelSetupSource, ModelSetupFailure>) -> Void] = []
    func run(test source: ModelSetupSource?, completion: @escaping (Result<ModelSetupSource, ModelSetupFailure>) -> Void) {
        requests.append(source); callbacks.append(completion)
    }
    func finish(_ result: Result<ModelSetupSource, ModelSetupFailure>) { callbacks.removeFirst()(result) }
}

final class ModelSetupModelTests: XCTestCase {
    private let source = ModelSetupSource(provider: "claude", model: "test-model", destination: "Anthropic",
                                          host: "api.anthropic.com", origin: "Keychain", local: false)
    private let granted: [CompanionPermission: PermissionStatus] = [
        .accessibility: .granted, .microphone: .granted, .speechRecognition: .granted, .screenRecording: .granted,
    ]

    @MainActor private func make(files: [URL] = []) -> (ModelSetupModel, SetupFakeBackend, SetupMemoryKeyStore, UserDefaults) {
        let backend = SetupFakeBackend(), store = SetupMemoryKeyStore()
        let prefs = UserDefaults(suiteName: "benji-model-setup-\(UUID().uuidString)")!
        return (ModelSetupModel(store: store, defaults: prefs, backend: backend, files: files), backend, store, prefs)
    }

    @MainActor func testMissingSourceNeverCompletesOrTestsAutomatically() {
        let (model, backend, _, _) = make()
        let setup = PermissionSetupModel(probe: { self.granted }, actions: PermissionSetupActions(), modelSetup: model)
        XCTAssertFalse(setup.progress.isComplete)
        XCTAssertEqual(setup.progress.current, .model)
        model.test()
        XCTAssertTrue(backend.requests.isEmpty)
        model.checkExisting()
        XCTAssertNil(backend.requests[0])
        backend.finish(.failure(ModelSetupFailure(words: "No model source found.")))
        XCTAssertFalse(setup.progress.isComplete)
        XCTAssertFalse(model.canTest)
        XCTAssertEqual(model.note, "No model source found.")
    }

    @MainActor func testPasteSaveAndExplicitTestCallBackendOnceAndFinishOnlyOnResult() {
        let (model, backend, store, prefs) = make()
        let setup = PermissionSetupModel(probe: { self.granted }, actions: PermissionSetupActions(), modelSetup: model)
        var completes = 0
        setup.onComplete = { completes += 1 }
        model.pastedKey = "fake-model-key-for-tests"; model.saveKey()
        XCTAssertEqual(store.writes, 1)
        XCTAssertEqual(store.items["ANTHROPIC_API_KEY"], "fake-model-key-for-tests")
        XCTAssertEqual(model.pastedKey, "")
        XCTAssertNil(backend.requests[0], "saving only probes, never calls a model")
        backend.finish(.success(source))
        XCTAssertEqual(model.phase, .saved)
        XCTAssertFalse(setup.progress.isComplete)
        XCTAssertFalse(String(describing: prefs.dictionaryRepresentation()).contains("fake-model-key-for-tests"))
        model.test(); model.test()
        XCTAssertEqual(backend.requests.compactMap { $0 }, [source], "one explicit Test, double-click ignored")
        XCTAssertEqual(model.phase, .testing)
        XCTAssertEqual(completes, 0)
        backend.finish(.success(source))
        XCTAssertEqual(model.phase, .passed)
        XCTAssertTrue(setup.progress.isComplete)
        XCTAssertEqual(completes, 1)
        XCTAssertFalse(prefs.bool(forKey: ModelSetupPreferences.needsTestKey))
    }

    @MainActor func testFailureMapsRealErrorAndRemainsPendingAcrossReopen() {
        let (model, backend, _, prefs) = make()
        model.checkExisting(); backend.finish(.success(source))
        XCTAssertTrue(model.isDone)
        model.test()
        let words = "api.anthropic.com didn't accept the API key (HTTP 401)."
        backend.finish(.failure(ModelSetupFailure(words: words)))
        XCTAssertEqual(model.note, words)
        XCTAssertEqual(model.phase, .failed)
        XCTAssertFalse(model.isDone)
        XCTAssertFalse(prefs.bool(forKey: ModelSetupPreferences.needsTestKey), "testing an existing source did not save it")
        model.checkExisting(); backend.finish(.success(source))
        XCTAssertEqual(model.phase, .existing)
        XCTAssertFalse(model.note.contains("Saved."))
        model.test(); backend.finish(.success(source))
        XCTAssertTrue(model.isDone)
    }

    @MainActor func testExistingSourceCompletesWithoutClaimingTested() {
        let (model, backend, store, _) = make()
        let setup = PermissionSetupModel(probe: { self.granted }, actions: PermissionSetupActions(), modelSetup: model)
        model.checkExisting(); backend.finish(.success(source))
        XCTAssertTrue(setup.progress.isComplete)
        XCTAssertEqual(model.phase, .existing)
        XCTAssertTrue(model.note.contains("Keychain"))
        XCTAssertTrue(model.note.contains("Not tested here."))
        XCTAssertEqual(backend.requests.count, 1)
        XCTAssertNil(backend.requests[0])
        XCTAssertEqual(store.writes, 0)
    }

    @MainActor func testFileModeProbeDoesNotReadTheKeychain() {
        let (model, backend, store, _) = make()
        store.items["ANTHROPIC_API_KEY"] = "fake-dormant-key"
        model.checkExisting(); backend.finish(.failure(ModelSetupFailure(words: "No API key found.")))
        XCTAssertEqual(store.reads, 0)
        XCTAssertFalse(model.canUseKeychainKey)
    }

    @MainActor func testDormantKeychainEntryRequiresExplicitSelectionBeforeProbing() {
        for account in ["ANTHROPIC_API_KEY"] {
            let (model, backend, store, prefs) = make()
            store.items[account] = "fake-model-key-for-tests"
            var changes = 0
            model.onConfigurationChanged = { changes += 1 }
            for _ in 0..<2 {
                model.checkExisting(); backend.finish(.failure(ModelSetupFailure(words: "No API key found.")))
                XCTAssertNil(prefs.object(forKey: KeyNames.defaultsKey))
                XCTAssertEqual(changes, 0)
                XCTAssertFalse(model.canUseKeychainKey)
                XCTAssertEqual(store.reads, 0)
                XCTAssertTrue(model.canLookInKeychain)
                XCTAssertFalse(model.isDone)
                XCTAssertTrue(backend.callbacks.isEmpty, "probing must not automatically retry with another source")
            }
            XCTAssertEqual(backend.requests.count, 2)
            model.lookInKeychain()
            XCTAssertEqual(store.reads, 1)
            XCTAssertTrue(model.canUseKeychainKey)
            XCTAssertTrue(model.note.contains("Benji is still set to use the key file."))
            XCTAssertNil(prefs.string(forKey: KeyNames.defaultsKey))
            model.useKeychainKey(); model.useKeychainKey()
            XCTAssertEqual(prefs.string(forKey: KeyNames.defaultsKey), "keychain")
            XCTAssertEqual(changes, 1)
            XCTAssertFalse(model.canUseKeychainKey)
            XCTAssertEqual(backend.requests.count, 3)
            XCTAssertTrue(backend.requests.allSatisfy { $0 == nil })
            backend.finish(.success(source))
            XCTAssertFalse(model.isDone, "explicit source selection still requires Test")
            XCTAssertEqual(model.phase, .saved)
            XCTAssertEqual(prefs.string(forKey: ModelSetupPreferences.providerKey), "claude")
        }
    }

    @MainActor func testExplicitLookupMissingAndDeniedDoNotSwitchSources() {
        let (model, backend, store, prefs) = make()
        model.lookInKeychain()
        XCTAssertEqual(model.note, "No Anthropic key was found in the Keychain. Benji is still set to use the key file.")
        XCTAssertFalse(model.canUseKeychainKey)
        store.fail = true
        model.lookInKeychain()
        XCTAssertTrue(model.note.contains("couldn't read the Keychain"))
        XCTAssertFalse(model.canUseKeychainKey)
        XCTAssertNil(prefs.string(forKey: KeyNames.defaultsKey))
        XCTAssertTrue(backend.requests.isEmpty)
    }

    @MainActor func testSaveDisclosesFileNamesAndRequiresAnotherPressIfNamesChanged() throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("benji-setup-disclosure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("fixture.env")
        try Data("SERPAPI_KEY=fake-search\n".utf8).write(to: file)
        let (model, backend, store, prefs) = make(files: [file])
        XCTAssertTrue(model.saveDisclosure.contains("Saving also moves SERPAPI_KEY"))
        XCTAssertFalse(model.saveDisclosure.contains("fake-search"))
        try Data("SERPAPI_KEY=fake-search\nOPENAI_API_KEY=fake-openai\n".utf8).write(to: file)
        model.pastedKey = "fake-paste"; model.saveKey()
        XCTAssertEqual(store.writes, 0)
        XCTAssertTrue(backend.requests.isEmpty)
        XCTAssertTrue(model.note.contains("Review the names below"))
        XCTAssertTrue(model.saveDisclosure.contains("OPENAI_API_KEY and SERPAPI_KEY"))
        model.saveKey()
        XCTAssertEqual(store.writes, 3)
        XCTAssertEqual(KeyStorageStatus.current(defaults: prefs, store: store, files: [file]), .inKeychain(count: 3))
        backend.finish(.success(source))
        XCTAssertEqual(model.phase, .saved)
    }

    @MainActor func testUseKeychainKeyDisclosesAndMigratesOtherFileKeys() throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("benji-setup-use-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("fixture.env")
        try Data("SERPAPI_KEY=fake-search\nANTHROPIC_API_KEY=fake-old-file\n".utf8).write(to: file)
        let (model, backend, store, prefs) = make(files: [file])
        store.items["ANTHROPIC_API_KEY"] = "fake-chosen-keychain"
        model.lookInKeychain()
        XCTAssertTrue(model.useDisclosure.contains("Using this key also moves SERPAPI_KEY"))
        XCTAssertTrue(model.useDisclosure.contains("ANTHROPIC_API_KEY will be replaced"))
        model.useKeychainKey()
        XCTAssertEqual(store.items, ["ANTHROPIC_API_KEY": "fake-chosen-keychain", "SERPAPI_KEY": "fake-search"])
        XCTAssertEqual(KeyStorageStatus.current(defaults: prefs, store: store, files: [file]), .inKeychain(count: 2))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "")
        backend.finish(.success(source))
        XCTAssertEqual(model.phase, .saved)
    }

    @MainActor func testFailedStoreClearsPasteWithoutStartingBackend() {
        let (model, backend, store, _) = make()
        store.fail = true; model.pastedKey = "fake-model-key-for-tests"; model.saveKey()
        XCTAssertEqual(model.pastedKey, "")
        XCTAssertEqual(model.phase, .failed)
        XCTAssertFalse(model.isDone)
        XCTAssertTrue(backend.requests.isEmpty)
        XCTAssertEqual(model.note, "Benji couldn't save and read back the key in the Keychain. Check that it is unlocked and allow Benji if macOS asks, then paste the key again.")
        XCTAssertFalse(model.note.contains("still in your key file"))
        XCTAssertFalse(model.note.contains("fake-model-key-for-tests"))
    }

    @MainActor func testLocalSourceRequiresTestAndDisclosesLocalEndpoint() {
        let (model, backend, store, _) = make()
        let local = ModelSetupSource(provider: "ollama", model: "test-local", destination: "Ollama on this computer",
                                     host: "localhost:11434", origin: "engine environment or key file", local: true)
        model.useLocal(provider: "ollama", model: "test-local", endpoint: "http://localhost:11434/v1")
        backend.finish(.success(local))
        XCTAssertFalse(model.isDone)
        XCTAssertTrue(local.disclosure.contains("on this Mac"))
        XCTAssertTrue(local.disclosure.contains("localhost:11434"))
        model.test(); backend.finish(.success(local))
        XCTAssertTrue(model.isDone)
        XCTAssertEqual(store.writes, 0)
    }

    @MainActor func testTestingAnExistingSourceCancelsCompletionUntilTheRealResult() {
        let (model, backend, _, _) = make()
        let setup = PermissionSetupModel(probe: { self.granted }, actions: PermissionSetupActions(), modelSetup: model)
        var becameIncomplete = 0
        setup.onIncomplete = { becameIncomplete += 1 }
        model.checkExisting(); backend.finish(.success(source))
        XCTAssertTrue(setup.progress.isComplete)
        model.test()
        XCTAssertEqual(becameIncomplete, 1)
        XCTAssertFalse(setup.progress.isComplete)
        backend.finish(.failure(ModelSetupFailure(words: "Connection refused.")))
        XCTAssertFalse(setup.progress.isComplete)
    }

    @MainActor func testRecheckingCompletedSetupDoesNotAnnounceOrCompleteAgain() {
        let (model, backend, _, _) = make()
        model.checkExisting(); backend.finish(.success(source))
        let setup = PermissionSetupModel(probe: { self.granted }, actions: PermissionSetupActions(), modelSetup: model)
        var announcements: [String] = []
        var completions = 0
        setup.onAnnounce = { announcements.append($0) }
        setup.onComplete = { completions += 1 }
        model.checkExisting()
        XCTAssertTrue(setup.progress.isComplete, "a refresh is not a new incomplete step")
        backend.finish(.success(source))
        XCTAssertTrue(announcements.isEmpty)
        XCTAssertEqual(completions, 0)
    }

    @MainActor func testLaunchDecisionWaitsForTheFirstModelProbe() {
        let (model, backend, _, _) = make()
        var shouldOpen: Bool?
        model.checkExisting {
            shouldOpen = SetupAutoOpen.shouldOpen(alreadyShown: false, resumeAfterRelaunch: false,
                                                  isComplete: SetupProgress(permissions: self.granted, modelDone: model.isDone).isComplete)
        }
        XCTAssertNil(shouldOpen)
        backend.finish(.success(source))
        XCTAssertEqual(shouldOpen, false)
    }

    @MainActor func testDifferentTestSourceNeverMarksDone() {
        let (model, backend, _, _) = make()
        model.checkExisting(); backend.finish(.success(source)); model.test()
        let other = ModelSetupSource(provider: "openai", model: "test", destination: "OpenAI", host: "api.openai.com", origin: "engine environment or key file", local: false)
        backend.finish(.success(other))
        XCTAssertFalse(model.isDone)
        XCTAssertEqual(model.phase, .failed)
    }
}
