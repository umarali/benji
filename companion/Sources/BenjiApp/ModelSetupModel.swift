import Foundation
import BenjiCore

struct ModelSetupFailure: Error { let words: String }

@MainActor
protocol ModelSetupBackend: AnyObject {
    /// nil probes configuration only; a source explicitly requests a test of that exact destination.
    func run(test source: ModelSetupSource?, completion: @escaping (Result<ModelSetupSource, ModelSetupFailure>) -> Void)
}

@MainActor
final class ModelSetupModel: ObservableObject {
    enum Phase { case checking, missing, existing, saved, testing, passed, failed }
    @Published private(set) var phase: Phase = .missing
    @Published private(set) var source: ModelSetupSource?
    @Published private(set) var note = "Add an API key or use a local model."
    @Published private(set) var canUseKeychainKey = false
    @Published private(set) var fileKeyNames: [String] = []
    @Published var pastedKey = ""
    private let store: KeyStore
    private let defaults: UserDefaults
    private let backend: ModelSetupBackend
    private let files: [URL]
    private var generation = 0
    private var doneBeforeProbe = false
    private var probeWaiters: [() -> Void] = []
    var onChange: () -> Void = {}
    /// Restarts the conversation engine on its next message and refreshes provider metadata.
    var onConfigurationChanged: () -> Void = {}

    init(store: KeyStore, defaults: UserDefaults, backend: ModelSetupBackend, files: [URL] = []) {
        self.store = store; self.defaults = defaults; self.backend = backend; self.files = files
        refreshFileNames()
    }

    var isDone: Bool { source != nil && (phase == .existing || phase == .passed || (phase == .checking && doneBeforeProbe)) }
    var isBusy: Bool { phase == .checking || phase == .testing }
    var canTest: Bool { source != nil && !isBusy }

    var canLookInKeychain: Bool { !KeyMigration.isUsingKeychain(defaults) && !isBusy && !canUseKeychainKey }
    var saveDisclosure: String { ModelSetupPreferences.saveDisclosure(names: fileKeyNames) }
    var useDisclosure: String { ModelSetupPreferences.saveDisclosure(names: fileKeyNames, action: "Using this key") }

    private func refreshFileNames() {
        fileKeyNames = KeyMigration.isUsingKeychain(defaults) ? [] : KeyMigration.fileKeyNames(files: files)
    }

    /// Do not migrate a newly added name that the user has not yet seen in the disclosure.
    private func consentIsCurrent() -> Bool {
        let before = fileKeyNames
        refreshFileNames()
        guard before == fileKeyNames else {
            note = "The keys in your file changed. Review the names below, then press the button again."
            onChange(); return false
        }
        return true
    }

    func lookInKeychain() {
        guard canLookInKeychain else { return }
        do {
            if let key = try store.read("ANTHROPIC_API_KEY"), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                canUseKeychainKey = true
                refreshFileNames()
                note = "An Anthropic key is saved in the Keychain. Benji is still set to use the key file."
            } else { note = "No Anthropic key was found in the Keychain. Benji is still set to use the key file." }
        } catch {
            note = "Benji couldn't read the Keychain. Check that it is unlocked and allow Benji if macOS asks. Benji is still set to use the key file."
        }
        onChange()
    }

    func checkExisting(completion: (() -> Void)? = nil) {
        if let completion { probeWaiters.append(completion) }
        guard !isBusy else { return }
        probe()
    }

    private func probe() {
        generation += 1
        let token = generation
        canUseKeychainKey = false
        refreshFileNames()
        doneBeforeProbe = isDone
        phase = .checking; note = "Checking model settings…"; onChange()
        backend.run(test: nil) { [weak self] result in
            guard let self, self.generation == token else { return }
            switch result {
            case let .success(source):
                self.source = source
                let pending = self.defaults.bool(forKey: ModelSetupPreferences.needsTestKey)
                self.phase = pending ? .saved : .existing
                self.note = pending ? "Saved. Test this model before finishing setup."
                    : "Using \(source.origin) · \(source.destination). Not tested here."
            case let .failure(error):
                self.source = nil; self.phase = .missing; self.note = error.words
            }
            self.onChange()
            let waiters = self.probeWaiters
            self.probeWaiters.removeAll()
            waiters.forEach { $0() }
        }
    }

    func useKeychainKey() {
        guard canUseKeychainKey, !isBusy, consentIsCurrent() else { return }
        do {
            guard let key = try store.read("ANTHROPIC_API_KEY"), !key.isEmpty else { throw KeyStoreError.failed }
            try save(key)
        } catch { saveFailed(error) }
    }

    func saveKey() {
        guard !isBusy, consentIsCurrent() else { return }
        defer { pastedKey = "" }
        do { try save(pastedKey) }
        catch { saveFailed(error) }
    }

    private func save(_ key: String) throws {
        try ModelSetupPreferences.saveAnthropic(key, store: store, defaults: defaults, files: files)
        pastedKey = ""; source = nil
        onConfigurationChanged()
        probe()
    }

    private func saveFailed(_ error: Error) {
        source = nil; phase = .failed
        note = "Benji couldn't save and read back the key in the Keychain. Check that it is unlocked and allow Benji if macOS asks, then paste the key again."
        if let failure = error as? ModelSetupPreferences.SaveFailure {
            switch failure.outcome {
            case .conflictingKeys, .fileNotCleaned: note = failure.outcome.words
            default: break // A newly pasted key may never have existed in a key file.
            }
        }
        onChange()
    }

    func useLocal(provider: String, model: String, endpoint: String) {
        guard !isBusy else { return }
        guard ModelSetupPreferences.saveLocal(provider: provider, model: model, endpoint: endpoint, defaults: defaults) else {
            phase = .failed; source = nil
            note = "Name the model loaded in your local server and use an http or https endpoint on localhost, 127.0.0.1 or ::1."
            onChange(); return
        }
        pastedKey = ""; source = nil
        onConfigurationChanged()
        probe()
    }

    func test() {
        guard canTest, let source else { return }
        generation += 1
        let token = generation
        phase = .testing; note = "Testing model…"; onChange()
        backend.run(test: source) { [weak self] result in
            guard let self, self.generation == token else { return }
            switch result {
            case let .success(tested) where tested == source:
                self.phase = .passed
                self.note = "Test passed. \(tested.destination) answered."
                self.defaults.set(false, forKey: ModelSetupPreferences.needsTestKey)
            case .success:
                self.phase = .failed
                self.note = "Model settings changed. Check the source again before testing."
            case let .failure(error):
                self.phase = .failed; self.note = error.words
            }
            self.onChange()
        }
    }

    func clearPaste() { pastedKey = "" }
}
