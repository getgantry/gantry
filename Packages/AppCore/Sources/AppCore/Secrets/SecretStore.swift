import Foundation

/// One Gantry secret as the list shows it. The value is never a field: it is
/// read with ``SecretStore/value(for:)`` only while a container is created.
public struct SecretInfo: Identifiable, Equatable, Sendable {
    public var name: String
    public var created: Date?
    public var modified: Date?

    public var id: String { name }

    public init(name: String, created: Date? = nil, modified: Date? = nil) {
        self.name = name
        self.created = created
        self.modified = modified
    }
}

/// Why a secret operation failed. Every description holds names only, never
/// a value, so the text is safe for the UI, logs and crash reports.
public enum SecretError: Error, Equatable, Sendable, LocalizedError {
    case notFound(String)
    case invalidName(String)
    case duplicateName(String)
    case emptyValue
    case authenticationFailed
    case keychain(Int32)
    case invalidVariable(String)
    case reservedVariable(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let name):
            String(localized: "The Keychain secret “\(name)” does not exist.", bundle: .module)
        case .invalidName:
            EnvSecrets.nameRuleMessage
        case .duplicateName(let name):
            String(localized: "A secret named “\(name)” already exists.", bundle: .module)
        case .emptyValue:
            String(localized: "Enter a value for the secret.", bundle: .module)
        case .authenticationFailed:
            String(localized: "Gantry could not read the Keychain secrets: authentication was cancelled.", bundle: .module)
        case .keychain(let status):
            String(localized: "The Keychain returned error \(Int(status)).", bundle: .module)
        case .invalidVariable(let key):
            String(localized: "The variable “\(key)” cannot hold a secret. Use letters, digits and “_”, starting with a letter or “_”.", bundle: .module)
        case .reservedVariable(let key):
            String(localized: "The variable “\(key)” cannot hold a secret on apple/container hosts, because the container tool uses this name itself.", bundle: .module)
        }
    }
}

/// Where Gantry keeps environment secrets. The app uses
/// ``KeychainSecretStore``; tests use ``InMemorySecretStore``.
public protocol SecretStore: Sendable {
    /// The secrets, sorted by name. Never reads a value.
    func list() throws -> [SecretInfo]
    /// The value of `name`; throws ``SecretError/notFound(_:)`` when absent.
    func value(for name: String) throws -> String
    /// Adds a new secret, or replaces the value of an existing one.
    func save(name: String, value: String) throws
    /// Gives a secret another name. The value does not change.
    func rename(from old: String, to new: String) throws
    /// Deletes a secret. Deleting an absent secret is not an error.
    func delete(name: String) throws
}

extension SecretStore {
    public func contains(_ name: String) -> Bool {
        ((try? list()) ?? []).contains { $0.name == name }
    }
}

/// A store in memory, for tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var dates: [String: Date] = [:]
    /// How many values were read, so tests can check that a path reads none.
    public private(set) var reads = 0

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public func list() throws -> [SecretInfo] {
        lock.withLock {
            values.keys.sorted().map { SecretInfo(name: $0, created: dates[$0], modified: dates[$0]) }
        }
    }

    public func value(for name: String) throws -> String {
        try lock.withLock {
            reads += 1
            guard let value = values[name] else { throw SecretError.notFound(name) }
            return value
        }
    }

    public func save(name: String, value: String) throws {
        lock.withLock {
            values[name] = value
            dates[name] = Date()
        }
    }

    public func rename(from old: String, to new: String) throws {
        try lock.withLock {
            guard let value = values[old] else { throw SecretError.notFound(old) }
            guard values[new] == nil else { throw SecretError.duplicateName(new) }
            values[old] = nil
            values[new] = value
            dates[new] = Date()
        }
    }

    public func delete(name: String) throws {
        _ = lock.withLock { values.removeValue(forKey: name) }
    }
}
