import Foundation
import Security
import BenjiCore

/// The macOS Keychain behind `KeyStore` (D-173). One generic-password item per key, service
/// `com.emerssive.heybenji.app.keys`, account = the variable's name (ANTHROPIC_API_KEY…), readable only while the
/// Mac is unlocked and never synced to iCloud. Nothing in the tests constructs this type (a test
/// checks that); the app builds it once and uses it from the Settings button and the engine launch.
///
/// A rebuilt app with a different signature may make macOS ask once whether Benji may use an item it
/// created before; "Always Allow" ends that. No key value ever appears in an error from here.
final class KeychainKeyStore: KeyStore {
    private let service: String

    init(service: String = KeyNames.service) { self.service = service }

    private func base(_ account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    private func failure(_ status: OSStatus) -> KeyStoreError {
        switch status {
        case errSecUserCanceled, errSecAuthFailed: return .denied
        case errSecInteractionNotAllowed, errSecNotAvailable, errSecNoSuchKeychain: return .unavailable
        default: return .failed
        }
    }

    func read(_ account: String) throws -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw failure(status) }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw failure(update) }
        var add = base(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw failure(status) }
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    /// The names only (attributes, not data), which macOS lists without a prompt.
    func accounts() throws -> [String] {
        var q = base()
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = out as? [[String: Any]] else { throw failure(status) }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
}
