import Foundation

/// Stateful decoder for newline-delimited JSON streams (stats, events).
///
/// Buffers partial lines across `Data` chunk boundaries, decoding each complete
/// line independently. Lines that fail to decode are silently skipped — Docker
/// occasionally emits empty lines or keep-alive whitespace.
public struct JSONLinesDecoder<T: Decodable & Sendable>: Sendable {
    private var buffer = Data()
    private let decoder: JSONDecoder

    public init(decoder: JSONDecoder = JSONDecoder()) {
        self.decoder = decoder
    }

    public mutating func ingest(_ data: Data) -> [T] {
        buffer.append(data)
        var results: [T] = []
        let newline = UInt8(ascii: "\n")

        while let index = buffer.firstIndex(of: newline) {
            let line = buffer[buffer.startIndex ..< index]
            buffer.removeSubrange(buffer.startIndex ... index)
            if let value = decode(Data(line)) {
                results.append(value)
            }
        }
        return results
    }

    private func decode(_ line: Data) -> T? {
        let trimmed = line.trimmedWhitespace()
        guard !trimmed.isEmpty else { return nil }
        return try? decoder.decode(T.self, from: trimmed)
    }
}

private extension Data {
    /// Trims leading/trailing ASCII whitespace (space, tab, CR, LF).
    func trimmedWhitespace() -> Data {
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0D, 0x0A]
        guard let first = firstIndex(where: { !whitespace.contains($0) }),
              let last = lastIndex(where: { !whitespace.contains($0) }) else {
            return Data()
        }
        return self[first ... last]
    }
}
