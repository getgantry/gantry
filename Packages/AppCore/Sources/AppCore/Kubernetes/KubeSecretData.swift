import Foundation
import Yams

/// The keys of a Secret and their values. Values stay hidden until the
/// user reveals one; the YAML view never shows them.
public struct KubeSecretEntry: Identifiable, Hashable, Sendable {
    public var key: String
    /// The base64 value from `data`.
    public var encoded: String

    public var id: String { key }

    public init(key: String, encoded: String) {
        self.key = key
        self.encoded = encoded
    }

    /// The decoded value: UTF-8 text, or nil for binary data.
    public var text: String? {
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public var byteCount: Int { Data(base64Encoded: encoded)?.count ?? 0 }
}

public enum KubeSecretData {
    /// What the YAML shows instead of a value.
    public static let mask = "••••••"

    /// The annotation that holds the whole applied manifest, values included.
    static let lastApplied = "kubectl.kubernetes.io/last-applied-configuration"

    /// The `data` entries of a Secret JSON object, sorted by key.
    public static func entries(fromJSON data: Data) throws -> [KubeSecretEntry] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KubeAPIError.unexpectedResponse
        }
        return (root["data"] as? [String: Any] ?? [:])
            .map { KubeSecretEntry(key: $0.key, encoded: $0.value as? String ?? "") }
            .sorted { $0.key < $1.key }
    }

    /// The object with every value in `data` and `stringData` and the
    /// last-applied annotation replaced by ``mask``.
    public static func redacted(_ object: [String: Any]) -> [String: Any] {
        var result = object
        for field in ["data", "stringData"] {
            if let values = object[field] as? [String: Any] {
                result[field] = values.mapValues { _ in mask }
            }
        }
        if var metadata = object["metadata"] as? [String: Any],
           var annotations = metadata["annotations"] as? [String: Any],
           annotations[lastApplied] != nil {
            annotations[lastApplied] = mask
            metadata["annotations"] = annotations
            result["metadata"] = metadata
        }
        return result
    }

    /// YAML of a secret without its values, with sorted keys like kubectl.
    public static func redactedYAML(fromJSON data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KubeAPIError.unexpectedResponse
        }
        return try Yams.dump(object: plain(redacted(root)), allowUnicode: true, sortKeys: true)
    }

    /// Foundation JSON values as Swift values that Yams can write.
    static func plain(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]: return dictionary.mapValues(plain)
        case let array as [Any]: return array.map(plain)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            if CFNumberIsFloatType(number) { return number.doubleValue }
            return number.intValue
        case let string as String: return string
        default: return NSNull()
        }
    }
}
