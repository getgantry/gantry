import Foundation
import MCP

/// A readable error surfaced to MCP clients as a tool error result.
struct ToolError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Convenience accessors over the `[String: Value]` argument bag the SDK hands
/// to a `CallTool` handler.
struct Arguments {
    let raw: [String: Value]

    init(_ raw: [String: Value]?) {
        self.raw = raw ?? [:]
    }

    func string(_ key: String) -> String? {
        raw[key]?.stringValue
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = raw[key]?.stringValue, !value.isEmpty else {
            throw ToolError("Missing required string argument '\(key)'.")
        }
        return value
    }

    func bool(_ key: String, default fallback: Bool) -> Bool {
        raw[key]?.boolValue ?? fallback
    }

    func int(_ key: String, default fallback: Int) -> Int {
        if let i = raw[key]?.intValue { return i }
        if let d = raw[key]?.doubleValue { return Int(d) }
        return fallback
    }

    /// A UUID parsed from a string argument, if present and valid.
    func uuid(_ key: String) throws -> UUID? {
        guard let s = raw[key]?.stringValue, !s.isEmpty else { return nil }
        guard let id = UUID(uuidString: s) else {
            throw ToolError("Argument '\(key)' is not a valid host id (expected a UUID).")
        }
        return id
    }
}

// MARK: - JSON Schema builders

/// Helpers to assemble JSON Schema fragments as MCP `Value`s.
enum Schema {
    static func object(
        properties: [String: Value],
        required: [String] = []
    ) -> Value {
        var obj: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties)
        ]
        if !required.isEmpty {
            obj["required"] = .array(required.map { .string($0) })
        }
        return .object(obj)
    }

    static func string(_ description: String, enumValues: [String]? = nil) -> Value {
        var obj: [String: Value] = [
            "type": .string("string"),
            "description": .string(description)
        ]
        if let enumValues {
            obj["enum"] = .array(enumValues.map { .string($0) })
        }
        return .object(obj)
    }

    static func boolean(_ description: String) -> Value {
        .object([
            "type": .string("boolean"),
            "description": .string(description)
        ])
    }

    static func integer(_ description: String) -> Value {
        .object([
            "type": .string("integer"),
            "description": .string(description)
        ])
    }
}

// MARK: - Result helpers

extension CallTool.Result {
    /// A successful text result.
    static func text(_ string: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: string, annotations: nil, _meta: nil)], isError: false)
    }

    /// An error text result (MCP tool error: `isError == true`).
    static func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}

/// Encodes a `Codable` value as pretty JSON text for a tool result.
func jsonText<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    return String(decoding: data, as: UTF8.self)
}

/// Truncates a string to a byte budget, appending a marker when cut.
func cap(_ text: String, bytes limit: Int) -> String {
    let data = Data(text.utf8)
    guard data.count > limit else { return text }
    let slice = data.prefix(limit)
    let truncated = String(decoding: slice, as: UTF8.self)
    return truncated + "\n…[truncated, output exceeded \(limit) bytes]"
}
