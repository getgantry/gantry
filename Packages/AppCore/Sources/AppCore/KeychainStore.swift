import Foundation
import Security

/// Thin wrapper over the macOS Keychain for the app's secrets (SSH passwords
/// and key passphrases). Items are stored as generic passwords under a single
/// service; the `account` distinguishes individual secrets.
public enum KeychainStore {
    /// Service identifier shared by all Gantry secrets.
    public static let service = "com.andrewkomkov.Gantry"

    // MARK: - Account name helpers

    public static func sshPasswordAccount(hostID: UUID) -> String {
        "ssh-password-\(hostID.uuidString)"
    }

    public static func keyPassphraseAccount(hostID: UUID) -> String {
        "key-passphrase-\(hostID.uuidString)"
    }

    // MARK: - CRUD

    /// Returns the stored secret for `account`, or nil if absent / unreadable.
    public static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Stores (or replaces) the secret for `account`. Returns true on success.
    @discardableResult
    public static func set(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Update if present, otherwise add.
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    /// Deletes the secret for `account` if present.
    @discardableResult
    public static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
