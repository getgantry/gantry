import Foundation

/// The container label that records which environment variables Gantry filled
/// from Keychain secrets: `KEY:NAME` pairs joined with `,`, sorted by key. It
/// holds names only, never values. Inspect, recreate and the MCP server read it
/// to hide the values again.
public enum SecretEnvLabel {
    public static let key = "com.gantry.secret-env"

    /// The label value for `references` (variable → secret name), or nil when
    /// there are none.
    public static func encode(_ references: [String: String]) -> String? {
        guard !references.isEmpty else { return nil }
        return references.sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
    }

    /// Variable → secret name from a label value. Malformed parts are skipped.
    public static func decode(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in value.split(separator: ",") {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let variable = String(part[..<colon]).trimmingCharacters(in: .whitespaces)
            let name = String(part[part.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !variable.isEmpty, !name.isEmpty else { continue }
            result[variable] = name
        }
        return result
    }

    /// Variable → secret name from a container's labels.
    public static func references(in labels: [String: String]?) -> [String: String] {
        labels?[key].map(decode) ?? [:]
    }
}

/// Hides the values of secret variables in output that leaves Gantry.
public enum SecretEnvRedaction {
    public static let placeholder = "[REDACTED]"

    /// True when the `container` CLI reads `name` from its own environment.
    /// A secret goes to the CLI through that environment (`--env KEY`), so a
    /// variable with such a name cannot hold a secret on an apple host.
    public static func isReservedForCLI(_ name: String) -> Bool {
        let exact: Set<String> = ["PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "SHELL", "NO_COLOR", "LANG", "PWD", "TERM"]
        if exact.contains(name) { return true }
        let prefixes = ["CONTAINER_", "DYLD_", "LC_", "__CF", "XPC_", "GANTRY_", "MallocStack", "NSZombie"]
        return prefixes.contains { name.hasPrefix($0) }
    }

    /// The JSON of a container inspect (Docker or apple/container) with every
    /// `KEY=value` string of a secret variable changed to `KEY=[REDACTED]`. The
    /// secret variables come from ``SecretEnvLabel`` anywhere in the JSON.
    /// Data that is not JSON, or has no such label, comes back unchanged.
    public static func redactInspectJSON(_ data: Data) -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return data
        }
        var keys: Set<String> = []
        collectKeys(root, into: &keys)
        guard !keys.isEmpty else { return data }
        let redacted = redact(root, keys: keys)
        return (try? JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])) ?? data
    }

    /// `KEY=[REDACTED]` when `entry` is `KEY=…` for one of `keys`, else nil.
    public static func redactedEntry(_ entry: String, keys: Set<String>) -> String? {
        guard let eq = entry.firstIndex(of: "=") else { return nil }
        let key = String(entry[..<eq])
        return keys.contains(key) ? "\(key)=\(placeholder)" : nil
    }

    private static func collectKeys(_ value: Any, into keys: inout Set<String>) {
        if let dict = value as? [String: Any] {
            for (key, child) in dict {
                if key == SecretEnvLabel.key, let text = child as? String {
                    keys.formUnion(SecretEnvLabel.decode(text).keys)
                } else {
                    collectKeys(child, into: &keys)
                }
            }
        } else if let array = value as? [Any] {
            for child in array { collectKeys(child, into: &keys) }
        }
    }

    private static func redact(_ value: Any, keys: Set<String>) -> Any {
        if let dict = value as? [String: Any] {
            return dict.mapValues { redact($0, keys: keys) }
        }
        if let array = value as? [Any] {
            return array.map { redact($0, keys: keys) }
        }
        if let text = value as? String {
            return redactedEntry(text, keys: keys) ?? text
        }
        return value
    }
}
