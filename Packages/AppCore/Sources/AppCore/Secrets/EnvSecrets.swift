import Foundation
import DockerKit

/// The rules for environment variables whose value is a Keychain secret:
/// secret names, the `keychain:NAME` reference text, which variables can
/// hold a secret, and the step that reads the values at create time.
public enum EnvSecrets {
    /// The prefix of a reference in command text: `KEY=keychain:NAME`.
    public static let referencePrefix = "keychain:"
    public static let maxNameLength = 64

    // MARK: - Names

    /// 1–64 characters of letters, digits, `_`, `.` and `-`, starting with a
    /// letter or digit.
    public static func isValidName(_ name: String) -> Bool {
        guard (1...maxNameLength).contains(name.count),
              let first = name.unicodeScalars.first, isAlnum(first) else { return false }
        return name.unicodeScalars.allSatisfy { isAlnum($0) || $0 == "_" || $0 == "." || $0 == "-" }
    }

    private static func isAlnum(_ c: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c)
    }

    static var nameRuleMessage: String {
        String(localized: "Use up to 64 letters, digits, “_”, “.” and “-”, starting with a letter or digit.", bundle: .module)
    }

    /// The inline problem with a typed secret name, or nil when it can be
    /// used. `current` is the name being renamed, which is not a conflict.
    public static func nameIssue(_ text: String, taken: [String], current: String? = nil) -> String? {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        guard isValidName(name) else { return nameRuleMessage }
        if name != current, taken.contains(name) {
            return SecretError.duplicateName(name).errorDescription
        }
        return nil
    }

    // MARK: - Reference text

    /// The secret name of a `keychain:NAME` value, or nil for a plain value.
    public static func secretName(inValue value: String) -> String? {
        guard value.hasPrefix(referencePrefix) else { return nil }
        let name = String(value.dropFirst(referencePrefix.count))
        return isValidName(name) ? name : nil
    }

    /// `keychain:NAME`.
    public static func referenceText(_ name: String) -> String {
        referencePrefix + name
    }

    // MARK: - Variables

    /// True for a portable environment name: `[A-Za-z_][A-Za-z0-9_]*`.
    public static func isPortableVariable(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, first == "_" || isAlpha(first) else { return false }
        return key.unicodeScalars.allSatisfy { $0 == "_" || isAlnum($0) }
    }

    private static func isAlpha(_ c: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(c) || ("A"..."Z").contains(c)
    }

    /// The problem with a secret row, or nil when it can be used.
    public static func variableIssue(key: String, isAppleHost: Bool) -> SecretError? {
        let key = key.trimmingCharacters(in: .whitespaces)
        guard isPortableVariable(key) else { return .invalidVariable(key) }
        if isAppleHost, SecretEnvRedaction.isReservedForCLI(key) { return .reservedVariable(key) }
        return nil
    }

    /// The issue for each secret row by index. Plain rows have none.
    public static func issues(_ env: [ContainerRecipe.EnvVar], isAppleHost: Bool) -> [Int: SecretError] {
        var result: [Int: SecretError] = [:]
        for (index, row) in env.enumerated() where row.secret != nil {
            if let issue = variableIssue(key: row.key, isAppleHost: isAppleHost) { result[index] = issue }
        }
        return result
    }

    // MARK: - Create time

    /// Reads the values of all secret rows, keyed by secret name. Asks
    /// `authorize` once, before the first read, when there is a secret row.
    /// Fails the whole step on the first problem; errors carry names only.
    public static func resolve(
        _ env: [ContainerRecipe.EnvVar],
        isAppleHost: Bool,
        store: any SecretStore,
        authorize: (@Sendable () async -> Bool)? = nil
    ) async throws -> [String: String] {
        let rows = env.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty && $0.secret != nil }
        guard !rows.isEmpty else { return [:] }
        for row in rows {
            if let issue = variableIssue(key: row.key, isAppleHost: isAppleHost) { throw issue }
        }
        if let authorize, !(await authorize()) { throw SecretError.authenticationFailed }
        var values: [String: String] = [:]
        for name in Set(rows.compactMap(\.secret)).sorted() {
            values[name] = try store.value(for: name)
        }
        return values
    }

    /// Sets the environment of `request` from `env`: plain rows as typed,
    /// secret rows with their resolved value. Adds the ``SecretEnvLabel`` and,
    /// on an apple host, the keys that must stay out of the CLI arguments.
    /// A secret row without a value in `values` is left out.
    public static func apply(
        _ env: [ContainerRecipe.EnvVar],
        values: [String: String],
        to request: inout ContainerCreateRequest,
        isAppleHost: Bool
    ) {
        var entries: [String] = []
        var references: [String: String] = [:]
        for row in env {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if let name = row.secret {
                guard let value = values[name] else { continue }
                entries.append("\(key)=\(value)")
                references[key] = name
            } else {
                entries.append("\(row.key)=\(row.value)")
            }
        }
        request.env = entries
        request.labels[SecretEnvLabel.key] = SecretEnvLabel.encode(references)
        if isAppleHost, !references.isEmpty {
            var options = request.appleOptions ?? .init()
            options.secretEnvKeys = references.keys.sorted()
            request.appleOptions = options
        }
    }

    // MARK: - Display

    /// One environment line of a container as the inspector shows it.
    public struct DisplayLine: Equatable, Sendable, Identifiable {
        public var key: String
        /// The value, or nil when it is a secret.
        public var value: String?
        /// The secret name, for a secret line.
        public var secret: String?
        public var id: String { key }
    }

    /// The environment of a container with the values of secret variables
    /// hidden. `labels` are the container labels.
    public static func displayLines(env: [String], labels: [String: String]?) -> [DisplayLine] {
        let references = SecretEnvLabel.references(in: labels)
        return env.map { entry in
            let eq = entry.firstIndex(of: "=")
            let key = eq.map { String(entry[..<$0]) } ?? entry
            if let name = references[key] {
                return DisplayLine(key: key, value: nil, secret: name)
            }
            let value = eq.map { String(entry[entry.index(after: $0)...]) } ?? ""
            return DisplayLine(key: key, value: value, secret: nil)
        }
    }
}
