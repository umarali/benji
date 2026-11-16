import Foundation

// API keys in the macOS Keychain.
//
// The rules, in order of importance:
//  * Moving keys requires a press in Settings or setup. Nothing here runs by itself:
//    Settings Move and setup Save call the same migration only after an explicit press.
//  * Fail closed. Once the user has moved their keys, the app starts the engine in Keychain mode: it
//    hands over what is in the Keychain and tells the engine (`BENJI_KEY_SOURCE=keychain`) to read no
//    key from `~/.benji.env`. If the Keychain cannot be read, the engine is not started. There is no
//    quiet fallback to the file.
//  * A key's value is never printed, logged, put in an error or an event: types here that can fail do
//    so with a case, not with text, and the values only travel as `String`s into a store or an
//    environment dictionary.
//  * Tests use `FakeKeyStore` (in the tests) only. The real store is `KeychainKeyStore` in the app
//    target; no test constructs it, and a test (KeyStoreGuardTests) fails if a test file names it.

public enum KeyNames {
    /// The Keychain service the app's items use.
    public static let service = "com.emerssive.heybenji.app.keys"
    /// What the engine is told when the Keychain holds the keys (benji/config.py: keys_from_keychain).
    public static let sourceVariable = "BENJI_KEY_SOURCE"
    public static let defaultsKey = "keySource"
    public static let keychainValue = "keychain"

    private static let extra: Set<String> = ["SERPAPI_KEY"]

    /// A variable that holds a key: `*_API_KEY` and the few other names Benji reads. The engine's rule
    /// (benji/config.py `is_secret_name`) is the same; both are tested against companion/Tests/key-name-cases.json.
    public static func isSecret(_ name: String) -> Bool {
        let upper = name.trimmingCharacters(in: .whitespaces).uppercased()
        return upper.hasSuffix("_API_KEY") || extra.contains(upper)
    }
}

public enum KeyStoreError: Error, Equatable, Sendable {
    /// The Keychain can't be used right now (locked, no access, a signature macOS doesn't trust).
    case unavailable
    /// The user said no to a Keychain prompt.
    case denied
    case failed
}

/// Where keys live. The app's real implementation talks to the Keychain; tests use an in-memory fake.
public protocol KeyStore: AnyObject {
    func read(_ account: String) throws -> String?
    func write(_ value: String, account: String) throws
    func delete(_ account: String) throws
    /// The names held (not the values; listing them asks the user for nothing).
    func accounts() throws -> [String]
}

/// A `~/.benji.env`-style file, read for its key lines only.
public enum EnvFile {
    public struct Line: Equatable, Sendable {
        public let name: String
        public let value: String
        public let index: Int
    }

    /// `KEY=value` lines (an `export ` prefix, quotes and spaces around the name tolerated), as the
    /// engine's loader reads them; comments and blank lines are skipped.
    public static func parse(_ text: String) -> [Line] {
        var out: [Line] = []
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let name = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
            }
            if !name.isEmpty { out.append(Line(name: name, value: value, index: index)) }
        }
        return out
    }

    /// The lines holding a key with a value (the last one wins when a name repeats, as in the engine).
    public static func secrets(in text: String) -> [Line] {
        var last: [String: Line] = [:]
        for line in parse(text) where KeyNames.isSecret(line.name) && !line.value.isEmpty { last[line.name] = line }
        return last.values.sorted { $0.name < $1.name }
    }

    /// The text without any line that sets a key (value or not); everything else is kept byte for byte.
    public static func removingKeys(from text: String) -> String {
        let drop = Set(parse(text).filter { KeyNames.isSecret($0.name) }.map(\.index))
        guard !drop.isEmpty else { return text }
        let kept = text.components(separatedBy: "\n").enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        return kept.joined(separator: "\n")
    }
}

public enum KeyMigration {
    public enum Outcome: Equatable, Sendable {
        /// The keys are in the Keychain, read back and equal, and gone from the file(s). `count` keys.
        case moved(count: Int)
        /// No key in any file: nothing to do (and nothing was changed).
        case nothingToMove
        /// The Keychain refused or didn't hold what was written; the files are untouched.
        case keychainFailed(KeyStoreError)
        /// File lines or the Keychain give different values for one key (`names`: which keys).
        /// choosing would lose whichever key wasn't chosen.
        case conflictingKeys(names: [String])
        /// The keys are safe in the Keychain, but a file could not be cleaned, so the switch to
        /// Keychain mode is not made yet; pressing the button again finishes it.
        case fileNotCleaned
    }

    /// Copy every key line of the given files into `store`, check each by reading it back, then take
    /// those lines out of the files (mode 0600 kept). Idempotent. Settings Move and setup Save call it.
    /// `replacing` contains only values the user explicitly chose to save, which win over older copies.
    /// `defaults` gets `keySource = keychain` only when it all worked.
    public static func migrate(files: [URL], store: KeyStore, defaults: UserDefaults, replacing: [String: String] = [:], beforeModeSwitch: () -> Void = {}) -> Outcome {
        var texts: [(url: URL, text: String)] = []
        var secrets: [String: String] = [:]
        var conflicts = Set<String>()
        for url in files {
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { continue }
            texts.append((url, text))
            for line in EnvFile.parse(text) where KeyNames.isSecret(line.name) && !line.value.isEmpty {
                let name = line.name
                if replacing[name] != nil { continue }
                if let held = secrets[name], held != line.value { conflicts.insert(name) }
                secrets[name] = line.value
            }
        }
        secrets.merge(replacing) { _, chosen in chosen }
        guard conflicts.isEmpty else { return .conflictingKeys(names: conflicts.sorted()) }
        // Check every destination before any writes, so a later conflict leaves both sources alone.
        do {
            for (name, value) in secrets where replacing[name] == nil {
                if let held = try store.read(name), held != value { conflicts.insert(name) }
            }
        } catch let error as KeyStoreError { return .keychainFailed(error) }
        catch { return .keychainFailed(.failed) }
        guard conflicts.isEmpty else { return .conflictingKeys(names: conflicts.sorted()) }
        // Keys already in the Keychain from an earlier, half-finished run count too: a file with none left
        // still needs its mode switched, which the caller does by `isUsingKeychain` after `.nothingToMove`.
        guard !secrets.isEmpty else { return .nothingToMove }
        // Newly created keys may remain after any failure; they are harmless while file mode stays selected.
        // Explicit replacements come last, so another key's failure cannot discard a held replacement value.
        let ordered = secrets.sorted {
            let leftReplacing = replacing[$0.key] != nil
            let rightReplacing = replacing[$1.key] != nil
            if leftReplacing != rightReplacing { return !leftReplacing }
            return $0.key < $1.key
        }
        for (name, value) in ordered {
            var previous: String?
            var overwriting = false
            do {
                let held = try store.read(name)
                if replacing[name] == nil, let held, held != value {
                    return .conflictingKeys(names: [name])
                }
                if held != value {
                    previous = held
                    overwriting = held != nil
                    try store.write(value, account: name)
                }
                guard try store.read(name) == value else { throw KeyStoreError.failed }
            } catch {
                // A store may change the item even when its write throws. Restore the held value best effort.
                if overwriting, let previous { try? store.write(previous, account: name) }
                return .keychainFailed((error as? KeyStoreError) ?? .failed)
            }
        }
        for (url, text) in texts where EnvFile.parse(text).contains(where: { KeyNames.isSecret($0.name) }) {
            let cleaned = EnvFile.removingKeys(from: text)
            do {
                try Data(cleaned.utf8).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                return .fileNotCleaned
            }
            guard let back = try? String(contentsOf: url, encoding: .utf8),
                  !EnvFile.parse(back).contains(where: { KeyNames.isSecret($0.name) }) else { return .fileNotCleaned }
        }
        beforeModeSwitch()
        defaults.set(KeyNames.keychainValue, forKey: KeyNames.defaultsKey)
        return .moved(count: secrets.count)
    }

    /// Names only for the disclosure before an explicit source change. Never touches the Keychain.
    public static func fileKeyNames(files: [URL]) -> [String] {
        var names = Set<String>()
        for file in files {
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                names.formUnion(EnvFile.secrets(in: text).map(\.name))
            }
        }
        return names.sorted()
    }

    public static func isUsingKeychain(_ defaults: UserDefaults) -> Bool {
        defaults.string(forKey: KeyNames.defaultsKey) == KeyNames.keychainValue
    }
}

/// What the engine's environment gets for its keys when it starts.
public enum KeyHandoff {
    public enum Failure: Error, Equatable, Sendable {
        /// The Keychain couldn't be read. The engine must not start (no fallback to the file).
        case keychainUnreadable(KeyStoreError)

        /// One line for the panel; no value in it.
        public var words: String {
            "Benji couldn't read your API key from the Keychain, so it didn't start. Open Settings › General to check, or allow Benji in the Keychain prompt if one appeared. Benji won't fall back to the key file."
        }
    }

    /// The variables to add to the engine's environment. File mode: none (the engine reads its file).
    /// Keychain mode: every key held, plus `BENJI_KEY_SOURCE=keychain` so the engine reads no key from a file.
    public static func environment(keychainMode: Bool, store: KeyStore) -> Result<[String: String], Failure> {
        guard keychainMode else { return .success([:]) }
        var env = [KeyNames.sourceVariable: KeyNames.keychainValue]
        do {
            for account in try store.accounts() where KeyNames.isSecret(account) {
                if let value = try store.read(account), !value.isEmpty { env[account] = value }
            }
        } catch let error as KeyStoreError {
            return .failure(.keychainUnreadable(error))
        } catch {
            return .failure(.keychainUnreadable(.failed))
        }
        return .success(env)
    }
}

/// What Settings says about where the key is.
public enum KeyStorageStatus: Equatable, Sendable {
    /// Keys are in a file (`count` of them); the Keychain isn't used. The button is offered.
    case inFile(count: Int)
    /// Keychain mode, `count` keys held.
    case inKeychain(count: Int)
    /// Keychain mode but no key held or the Keychain can't be listed.
    case keychainProblem
    /// No key anywhere Benji looks (it may come from the environment).
    case none

    public var line: String {
        switch self {
        case let .inFile(count): return count == 1 ? "Your key is in ~/.benji.env in your home folder, as plain text." : "Your \(count) keys are in ~/.benji.env in your home folder, as plain text."
        case let .inKeychain(count): return count == 1 ? "Your key is in the macOS Keychain." : "Your \(count) keys are in the macOS Keychain."
        case .keychainProblem: return "Benji is set to use the Keychain, but its keys are missing or couldn't be read. Check Keychain access, or add one to ~/.benji.env and press Move again."
        case .none: return "No key found in ~/.benji.env."
        }
    }

    public var offersMove: Bool {
        if case .inFile = self { return true }
        return self == .keychainProblem
    }

    public static func current(defaults: UserDefaults, store: KeyStore?, files: [URL]) -> KeyStorageStatus {
        if KeyMigration.isUsingKeychain(defaults) {
            guard let store else { return .keychainProblem }
            // Names only: Settings refreshes often, and reading a value can make macOS ask for the
            // keychain password each time. The engine's start reads the values and reports a failure.
            do {
                let held = try store.accounts().filter(KeyNames.isSecret).count
                return held > 0 ? .inKeychain(count: held) : .keychainProblem
            } catch { return .keychainProblem }
        }
        var names = Set<String>()
        for url in files {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                names.formUnion(EnvFile.secrets(in: text).map(\.name))
            }
        }
        return names.isEmpty ? .none : .inFile(count: names.count)
    }
}

extension KeyMigration.Outcome {
    /// What Settings says after the button: plain words, no key and no path beyond the file's name.
    public var words: String {
        switch self {
        case let .moved(count):
            return (count == 1 ? "Moved your key" : "Moved your \(count) keys")
                + " to the Keychain and took " + (count == 1 ? "it" : "them")
                + " out of your key file. Benji's helper restarts with your next message."
        case .nothingToMove:
            return "There was no key in ~/.benji.env to move."
        case .keychainFailed(.denied):
            return "The Keychain asked and the answer was no, so nothing was moved. Your key is still in your key file."
        case .keychainFailed(.unavailable):
            return "The Keychain isn't available right now (is the Mac locked?). Nothing was moved."
        case .keychainFailed(.failed):
            return "Benji couldn't store the key in the Keychain. Nothing was moved."
        case let .conflictingKeys(names):
            return "Different values were found for " + names.joined(separator: ", ") + " in your key files or the Keychain. Benji did not replace them or switch key sources. Keep the value you want in each source, then try again."
        case .fileNotCleaned:
            return "Your key is in the Keychain, but Benji couldn't take it out of your key file, so it isn't switched over yet. Press the button again, or delete the key line yourself."
        }
    }
}
