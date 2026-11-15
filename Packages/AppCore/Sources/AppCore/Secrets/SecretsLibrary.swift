import Foundation
import Observation

/// The list of Gantry secrets for the UI: Settings ▸ Secrets and the key
/// menu of an environment row. It never holds a value; ``save(name:value:)``
/// passes one straight to the store.
@MainActor
@Observable
public final class SecretsLibrary {
    public private(set) var secrets: [SecretInfo] = []
    /// The last failure, as text with names only.
    public private(set) var lastError: String?

    public let store: any SecretStore

    public init(store: any SecretStore) {
        self.store = store
        reload()
    }

    public static let shared = SecretsLibrary(store: KeychainSecretStore())

    public var names: [String] { secrets.map(\.name) }

    public func contains(_ name: String) -> Bool { names.contains(name) }

    public func reload() {
        do {
            secrets = try store.list()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Adds a new secret. Fails for a bad or taken name and an empty value.
    @discardableResult
    public func add(name rawName: String, value: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard EnvSecrets.isValidName(name) else { return fail(SecretError.invalidName(name)) }
        guard !contains(name) else { return fail(SecretError.duplicateName(name)) }
        return save(name: name, value: value)
    }

    /// Replaces the value of a secret.
    @discardableResult
    public func save(name: String, value: String) -> Bool {
        guard !value.isEmpty else { return fail(SecretError.emptyValue) }
        return perform { try store.save(name: name, value: value) }
    }

    @discardableResult
    public func rename(_ old: String, to rawNew: String) -> Bool {
        let new = rawNew.trimmingCharacters(in: .whitespaces)
        guard new != old else { return true }
        guard EnvSecrets.isValidName(new) else { return fail(SecretError.invalidName(new)) }
        guard !contains(new) else { return fail(SecretError.duplicateName(new)) }
        return perform { try store.rename(from: old, to: new) }
    }

    @discardableResult
    public func delete(_ names: [String]) -> Bool {
        perform { for name in names { try store.delete(name: name) } }
    }

    public func clearError() { lastError = nil }

    private func perform(_ work: () throws -> Void) -> Bool {
        do {
            try work()
            reload()
            return true
        } catch {
            reload()
            return fail(error)
        }
    }

    private func fail(_ error: Error) -> Bool {
        lastError = error.localizedDescription
        return false
    }
}
