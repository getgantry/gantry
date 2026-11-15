import Foundation
import Security

/// Environment secrets as generic password items in the login keychain:
/// service ``service``, account = secret name. A service of its own keeps
/// these apart from SSH passwords (``KeychainStore``). The list reads only
/// attributes, so it never asks for access to a value.
public struct KeychainSecretStore: SecretStore {
    public static let service = "com.andrewkomkov.Gantry.env-secret"

    public init() {}

    private func baseQuery(_ name: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service
        ]
        if let name { query[kSecAttrAccount as String] = name }
        return query
    }

    public func list() throws -> [SecretInfo] {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw SecretError.keychain(status) }
        let items = (result as? [[String: Any]]) ?? []
        return items.compactMap { item -> SecretInfo? in
            guard let name = item[kSecAttrAccount as String] as? String else { return nil }
            return SecretInfo(
                name: name,
                created: item[kSecAttrCreationDate as String] as? Date,
                modified: item[kSecAttrModificationDate as String] as? Date
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func value(for name: String) throws -> String {
        var query = baseQuery(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { throw SecretError.notFound(name) }
        if status == errSecUserCanceled || status == errSecAuthFailed { throw SecretError.authenticationFailed }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw SecretError.keychain(status)
        }
        return value
    }

    public func save(name: String, value: String) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(baseQuery(name) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecretError.keychain(update) }
        var add = baseQuery(name)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Gantry secret \(name)"
        add[kSecAttrDescription as String] = "Gantry environment secret"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretError.keychain(status) }
    }

    public func rename(from old: String, to new: String) throws {
        let attributes: [String: Any] = [
            kSecAttrAccount as String: new,
            kSecAttrLabel as String: "Gantry secret \(new)"
        ]
        let status = SecItemUpdate(baseQuery(old) as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound: throw SecretError.notFound(old)
        case errSecDuplicateItem: throw SecretError.duplicateName(new)
        default: throw SecretError.keychain(status)
        }
    }

    public func delete(name: String) throws {
        let status = SecItemDelete(baseQuery(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretError.keychain(status) }
    }
}
