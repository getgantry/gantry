import Foundation
import MCP
import DockerKit
@testable import gantry_mcp

/// Shared helpers for the GantryMCP test suite.

/// Extracts the concatenated text from a `CallTool.Result`.
func resultText(_ result: CallTool.Result) -> String {
    var pieces: [String] = []
    for content in result.content {
        if case let .text(text, _, _) = content {
            pieces.append(text)
        }
    }
    return pieces.joined()
}

extension CallTool.Result {
    var isErrorResult: Bool { isError == true }
    var text: String { resultText(self) }
}

/// Decodes a value of type `T` from a JSON string literal.
func decodeJSON<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

/// A live local socket path, or nil when no Docker daemon is reachable.
let liveSocket: String? = DockerSocketDiscovery.discover()
