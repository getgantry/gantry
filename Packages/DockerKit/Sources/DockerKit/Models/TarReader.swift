import Foundation

/// Minimal read-only TAR parser for container archive directory listings.
///
/// Supports ustar headers and pax/GNU long-name extensions, which is all the
/// Docker archive endpoint emits. Each header is a 512-byte block; file content
/// follows, padded to the next 512-byte boundary. Two consecutive zero blocks
/// terminate the archive.
public enum TarReader {
    /// A parsed TAR member.
    public struct Entry: Hashable, Sendable {
        public var name: String
        public var size: Int64
        /// ustar typeflag: "0"/"\0" regular, "5" directory, "2" symlink, etc.
        public var typeFlag: UInt8
        public var mtime: Date?

        public var isDirectory: Bool { typeFlag == UInt8(ascii: "5") }
        public var isSymlink: Bool { typeFlag == UInt8(ascii: "2") }
    }

    private static let blockSize = 512

    /// Parses every member header in `data`. File payloads are skipped.
    public static func entries(in data: Data) -> [Entry] {
        var entries: [Entry] = []
        var offset = 0
        // A pending long name from a pax ("x") or GNU ("L") extension header.
        var pendingLongName: String?

        let bytes = [UInt8](data)

        while offset + blockSize <= bytes.count {
            let header = Array(bytes[offset ..< offset + blockSize])
            offset += blockSize

            // End-of-archive: an all-zero block.
            if header.allSatisfy({ $0 == 0 }) {
                break
            }

            let size = octal(header, at: 124, length: 12)
            let typeFlag = header[156]

            switch typeFlag {
            case UInt8(ascii: "x"), UInt8(ascii: "g"):
                // PAX extended header: payload is "len key=value\n" records.
                let payload = readPayload(bytes, at: offset, size: size)
                if let path = paxPath(payload) {
                    pendingLongName = path
                }
                offset += paddedLength(size)
                continue
            case UInt8(ascii: "L"):
                // GNU long name: payload is the full name as a C string.
                let payload = readPayload(bytes, at: offset, size: size)
                pendingLongName = cString(payload)
                offset += paddedLength(size)
                continue
            default:
                break
            }

            let name = pendingLongName ?? ustarName(header)
            pendingLongName = nil

            let mtimeSeconds = octal(header, at: 136, length: 12)
            let mtime = mtimeSeconds > 0 ? Date(timeIntervalSince1970: TimeInterval(mtimeSeconds)) : nil

            entries.append(Entry(name: name, size: size, typeFlag: typeFlag, mtime: mtime))
            offset += paddedLength(size)
        }

        return entries
    }

    /// Returns the payload of the first regular file in `data`, or nil if the
    /// archive contains no regular-file member. Long-name/PAX extension headers
    /// are skipped, mirroring `entries(in:)`.
    public static func firstFilePayload(in data: Data) -> Data? {
        let bytes = [UInt8](data)
        var offset = 0

        while offset + blockSize <= bytes.count {
            let header = Array(bytes[offset ..< offset + blockSize])
            offset += blockSize

            if header.allSatisfy({ $0 == 0 }) { break }

            let size = octal(header, at: 124, length: 12)
            let typeFlag = header[156]

            switch typeFlag {
            case UInt8(ascii: "x"), UInt8(ascii: "g"), UInt8(ascii: "L"):
                // Extension header; the real file header follows.
                offset += paddedLength(size)
            case UInt8(ascii: "0"), 0:
                let end = min(offset + Int(size), bytes.count)
                guard offset <= end else { return nil }
                return data.subdata(in: offset ..< end)
            default:
                offset += paddedLength(size)
            }
        }

        return nil
    }

    // MARK: - Field decoding

    /// Reconstructs the member name from the ustar `name` and `prefix` fields.
    private static func ustarName(_ header: [UInt8]) -> String {
        let name = cString(Array(header[0 ..< 100]))
        let prefix = cString(Array(header[345 ..< 500]))
        if prefix.isEmpty {
            return name
        }
        return prefix + "/" + name
    }

    /// Parses an octal numeric field. Leading whitespace/NUL are ignored.
    private static func octal(_ header: [UInt8], at start: Int, length: Int) -> Int64 {
        var value: Int64 = 0
        for index in start ..< start + length {
            let byte = header[index]
            if byte == 0 || byte == UInt8(ascii: " ") {
                // Stop at the first terminator once we have started reading.
                if value != 0 { break } else { continue }
            }
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "7") else { break }
            value = value * 8 + Int64(byte - UInt8(ascii: "0"))
        }
        return value
    }

    /// Rounds a payload size up to the next 512-byte block boundary.
    private static func paddedLength(_ size: Int64) -> Int {
        let blocks = (Int(size) + blockSize - 1) / blockSize
        return blocks * blockSize
    }

    private static func readPayload(_ bytes: [UInt8], at offset: Int, size: Int64) -> [UInt8] {
        let end = min(offset + Int(size), bytes.count)
        guard offset < end else { return [] }
        return Array(bytes[offset ..< end])
    }

    /// Decodes a NUL-terminated UTF-8 string from a fixed-width field.
    private static func cString(_ bytes: [UInt8]) -> String {
        let trimmed = bytes.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    /// Extracts the `path=` value from a PAX extended header payload.
    private static func paxPath(_ payload: [UInt8]) -> String? {
        let text = String(decoding: payload, as: UTF8.self)
        // Records look like "<len> path=value\n".
        for record in text.split(separator: "\n") {
            guard let spaceIndex = record.firstIndex(of: " ") else { continue }
            let keyValue = record[record.index(after: spaceIndex)...]
            if keyValue.hasPrefix("path=") {
                return String(keyValue.dropFirst("path=".count))
            }
        }
        return nil
    }
}
