import Foundation

/// Non-secret choices made in setup. Keys go only through KeyStore and KeyHandoff.
public enum ModelSetupPreferences {
    public static let providerKey = "setupModelProvider"
    public static let modelKey = "setupLocalModel"
    public static let endpointKey = "setupLocalEndpoint"
    public static let needsTestKey = "setupModelNeedsTest"

    public static func environment(_ defaults: UserDefaults) -> [String: String] {
        let provider = defaults.string(forKey: providerKey)
        switch provider {
        case "claude":
            // Let the existing Settings model choice win, otherwise use the engine's default.
            return ["BENJI_PROVIDER": "claude", "BENJI_BASE_URL": "",
                    "BENJI_MODEL": ModelChoice.from(defaults.object(forKey: ModelChoice.defaultsKey)).engineModel ?? ""]
        case "ollama", "lmstudio":
            return ["BENJI_PROVIDER": provider ?? "",
                    "BENJI_MODEL": defaults.string(forKey: modelKey) ?? "",
                    "BENJI_BASE_URL": defaults.string(forKey: endpointKey) ?? "",
                    "BENJI_API_KEY": ""]
        default: return [:]
        }
    }

    public struct SaveFailure: Error {
        public let outcome: KeyMigration.Outcome
    }

    /// A pasted key replaces the stored Anthropic key outright. Any other key in the key files moves to
    /// the Keychain through `KeyMigration`, the same checked move Settings uses.
    public static func saveAnthropic(_ pasted: String, store: KeyStore, defaults: UserDefaults, files: [URL]) throws {
        let value = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw KeyStoreError.failed
        }
        if KeyMigration.isUsingKeychain(defaults) {
            try store.write(value, account: "ANTHROPIC_API_KEY")
            guard try store.read("ANTHROPIC_API_KEY") == value else { throw KeyStoreError.failed }
            defaults.set(true, forKey: needsTestKey)
        } else {
            let outcome = KeyMigration.migrate(files: files, store: store, defaults: defaults,
                                               replacing: ["ANTHROPIC_API_KEY": value]) {
                // Mark the verified save before selecting it, so interruption cannot bypass testing.
                defaults.set(true, forKey: needsTestKey)
            }
            guard case .moved = outcome else { throw SaveFailure(outcome: outcome) }
        }
        defaults.set(KeyNames.keychainValue, forKey: KeyNames.defaultsKey)
        defaults.set("claude", forKey: providerKey)
    }

    /// Settings and setup use the same single source. File mode never touches the Keychain.
    public static func keyEnvironment(_ defaults: UserDefaults, store: KeyStore) -> Result<[String: String], KeyHandoff.Failure> {
        KeyHandoff.environment(keychainMode: KeyMigration.isUsingKeychain(defaults), store: store)
            .map { $0.merging(environment(defaults)) { _, new in new } }
    }

    /// The complete file-key effect, disclosed by name only before the user presses a button.
    public static func saveDisclosure(names: [String], action: String = "Saving") -> String {
        var words = "Kept in the macOS Keychain on this Mac, never in a key file. Benji will use the Keychain for all keys."
        let others = names.filter { $0 != "ANTHROPIC_API_KEY" }
        if !others.isEmpty {
            words += " \(action) also moves " + others.joined(separator: " and ") + " from ~/.benji.env to the Keychain."
        }
        if names.contains("ANTHROPIC_API_KEY") {
            words += " The file's ANTHROPIC_API_KEY will be replaced by the key you choose here."
        }
        return words
    }

    /// Setup's local option always stays on this Mac. The engine still validates its own settings.
    public static func saveLocal(provider: String, model: String, endpoint: String, defaults: UserDefaults) -> Bool {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["ollama", "lmstudio"].contains(provider), !name.isEmpty,
              let url = URLComponents(string: endpoint), ["http", "https"].contains(url.scheme ?? ""),
              url.percentEncodedHost?.contains("%") == false,
              ["localhost", "127.0.0.1", "[::1]", "::1"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else { return false }
        defaults.set(true, forKey: needsTestKey)
        defaults.set(provider, forKey: providerKey)
        defaults.set(name, forKey: modelKey)
        defaults.set(endpoint, forKey: endpointKey)
        return true
    }
}

/// Only metadata comes back from the engine. This also pins the destination the Test button disclosed.
public struct ModelSetupSource: Codable, Equatable, Sendable {
    public let provider: String
    public let model: String
    public let destination: String
    public let host: String
    public let origin: String
    public let local: Bool
    public let usesKey: Bool
    public let keyVariable: String?

    public init(provider: String, model: String, destination: String, host: String, origin: String, local: Bool, usesKey: Bool = true, keyVariable: String? = nil) {
        self.provider = provider; self.model = model; self.destination = destination
        self.host = host; self.origin = origin; self.local = local
        self.usesKey = usesKey; self.keyVariable = keyVariable
    }

    public var disclosure: String {
        let keyWords = usesKey ? ", using your key" : ""
        if local {
            return "Sends \"Reply OK.\" with the instruction \"This is a connection test. Reply OK.\" to \(destination) at \(host) on this Mac\(keyWords). No screen, files or conversation are included."
        }
        return "Sends \"Reply OK.\" with the instruction \"This is a connection test. Reply OK.\" to \(destination) at \(host)\(keyWords). No screen, files or conversation are included."
    }
}
