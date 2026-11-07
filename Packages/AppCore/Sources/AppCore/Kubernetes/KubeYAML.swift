import Foundation
import Yams

/// Renders an API object (JSON) as YAML for the YAML tab.
public enum KubeYAML {
    /// The top-level keys in kubectl order; other keys follow sorted, and
    /// `status` is last.
    static let leadingKeys = ["apiVersion", "kind", "metadata", "spec", "type", "data", "stringData", "binaryData"]

    /// YAML of the object without `metadata.managedFields` (kubectl hides
    /// them too). With `redactSecret`, values of a Secret are masked.
    public static func render(json: Data, redactSecret: Bool) throws -> String {
        guard var object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw KubeAPIError.unexpectedResponse
        }
        if var metadata = object["metadata"] as? [String: Any] {
            metadata["managedFields"] = nil
            object["metadata"] = metadata
        }
        if redactSecret { object = KubeSecretData.redacted(object) }
        return try Yams.serialize(node: node(object, topLevel: true), allowUnicode: true)
    }

    static func orderedKeys(_ keys: [String], topLevel: Bool) -> [String] {
        let sorted = keys.sorted()
        guard topLevel else { return sorted }
        let leading = leadingKeys.filter(keys.contains)
        let rest = sorted.filter { !leadingKeys.contains($0) && $0 != "status" }
        return leading + rest + (keys.contains("status") ? ["status"] : [])
    }

    static func node(_ value: Any, topLevel: Bool = false) -> Node {
        switch value {
        case let dictionary as [String: Any]:
            let pairs = orderedKeys(Array(dictionary.keys), topLevel: topLevel).map { key in
                (Node(key), node(dictionary[key]!))
            }
            return .mapping(Node.Mapping(pairs))
        case let array as [Any]:
            return .sequence(Node.Sequence(array.map { node($0) }))
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return Node(number.boolValue ? "true" : "false", Tag(.bool)) }
            if CFNumberIsFloatType(number) { return Node(String(number.doubleValue), Tag(.float)) }
            return Node(String(number.int64Value), Tag(.int))
        case let string as String:
            return stringNode(string)
        default:
            return Node("null", Tag(.null))
        }
    }

    /// A string scalar; quoted when plain YAML would read it as another type.
    static func stringNode(_ string: String) -> Node {
        if string.contains("\n") { return Node(string, Tag(.str), .literal) }
        let resolved = Resolver.default.resolveTag(of: Node(string))
        let needsQuotes = resolved != .str || string.isEmpty || string.hasPrefix(" ") || string.hasSuffix(" ")
        return Node(string, Tag(.str), needsQuotes ? .doubleQuoted : .any)
    }
}
