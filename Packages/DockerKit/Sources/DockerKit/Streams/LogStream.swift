import Foundation

/// Which standard stream a log line came from.
public enum LogStreamType: UInt8, Sendable {
    case stdin = 0
    case stdout = 1
    case stderr = 2
}

/// A single, newline-delimited log line emitted by a container.
public struct LogEntry: Identifiable, Sendable, Hashable {
    /// Monotonic sequence number assigned by the parser, unique within a stream.
    public let id: UInt64
    public let stream: LogStreamType
    /// One line of output with any trailing newline / carriage return stripped.
    public let text: String
    /// Parsed only when the caller requested timestamps (RFC3339Nano prefix).
    public let timestamp: Date?

    public init(id: UInt64, stream: LogStreamType, text: String, timestamp: Date?) {
        self.id = id
        self.stream = stream
        self.text = text
        self.timestamp = timestamp
    }
}

// MARK: - Demultiplexer

/// Stateful parser for Docker's multiplexed log stream (non-TTY containers).
///
/// The wire format is a sequence of frames, each an 8-byte header
/// `[streamType, 0, 0, 0, big-endian UInt32 payloadSize]` followed by
/// `payloadSize` bytes of payload. Frames and their payloads may be split
/// across arbitrary `Data` chunk boundaries, so the parser buffers partial
/// headers and partial payloads, and buffers partial lines per stream type
/// (a payload need not end on a line boundary).
public struct DockerLogDemuxer: Sendable {
    /// Bytes received but not yet consumed into a header / payload.
    private var buffer = Data()
    /// Per-stream partial line accumulators, keyed by raw stream type byte.
    private var partialLines: [UInt8: Data] = [:]
    private var sequence: UInt64 = 0
    private let parseTimestamps: Bool

    public init(parseTimestamps: Bool = false) {
        self.parseTimestamps = parseTimestamps
    }

    /// Feeds a new chunk of bytes and returns any complete lines it unlocked.
    public mutating func ingest(_ data: Data) -> [LogEntry] {
        buffer.append(data)
        var entries: [LogEntry] = []

        while true {
            guard buffer.count >= 8 else { break }
            let header = buffer.prefix(8)
            let base = header.startIndex
            let typeByte = header[base]
            let size = (UInt32(header[base + 4]) << 24)
                | (UInt32(header[base + 5]) << 16)
                | (UInt32(header[base + 6]) << 8)
                | UInt32(header[base + 7])
            let payloadSize = Int(size)

            guard buffer.count >= 8 + payloadSize else { break }

            let payloadStart = base + 8
            let payload = buffer[payloadStart ..< payloadStart + payloadSize]
            buffer.removeSubrange(buffer.startIndex ..< payloadStart + payloadSize)

            let stream = LogStreamType(rawValue: typeByte) ?? .stdout
            entries.append(contentsOf: appendPayload(Data(payload), typeByte: typeByte, stream: stream))
        }

        return entries
    }

    /// Flushes any buffered trailing partial lines (input has ended).
    public mutating func finish() -> [LogEntry] {
        var entries: [LogEntry] = []
        for typeByte in partialLines.keys.sorted() {
            guard let remainder = partialLines[typeByte], !remainder.isEmpty else { continue }
            let stream = LogStreamType(rawValue: typeByte) ?? .stdout
            entries.append(makeEntry(from: remainder, stream: stream))
        }
        partialLines.removeAll()
        return entries
    }

    /// Appends payload bytes to the per-stream accumulator and emits whole lines.
    private mutating func appendPayload(_ payload: Data, typeByte: UInt8, stream: LogStreamType) -> [LogEntry] {
        var accumulator = partialLines[typeByte] ?? Data()
        accumulator.append(payload)

        var entries: [LogEntry] = []
        let newline = UInt8(ascii: "\n")
        while let index = accumulator.firstIndex(of: newline) {
            let line = accumulator[accumulator.startIndex ..< index]
            entries.append(makeEntry(from: Data(line), stream: stream))
            accumulator.removeSubrange(accumulator.startIndex ... index)
        }
        partialLines[typeByte] = accumulator
        return entries
    }

    private mutating func makeEntry(from lineData: Data, stream: LogStreamType) -> LogEntry {
        let entry = LogLineFormatting.makeEntry(
            from: lineData,
            stream: stream,
            sequence: sequence,
            parseTimestamps: parseTimestamps
        )
        sequence &+= 1
        return entry
    }
}

// MARK: - Raw (TTY) parser

/// Stateful line splitter for TTY containers, whose log stream has no frame
/// headers — every byte is stdout. Buffers partial lines across chunks.
public struct RawLogLineParser: Sendable {
    private var accumulator = Data()
    private var sequence: UInt64 = 0
    private let parseTimestamps: Bool

    public init(parseTimestamps: Bool = false) {
        self.parseTimestamps = parseTimestamps
    }

    public mutating func ingest(_ data: Data) -> [LogEntry] {
        accumulator.append(data)
        var entries: [LogEntry] = []
        let newline = UInt8(ascii: "\n")
        while let index = accumulator.firstIndex(of: newline) {
            let line = accumulator[accumulator.startIndex ..< index]
            entries.append(emit(Data(line)))
            accumulator.removeSubrange(accumulator.startIndex ... index)
        }
        return entries
    }

    public mutating func finish() -> [LogEntry] {
        guard !accumulator.isEmpty else { return [] }
        let entry = emit(accumulator)
        accumulator.removeAll()
        return [entry]
    }

    private mutating func emit(_ lineData: Data) -> LogEntry {
        let entry = LogLineFormatting.makeEntry(
            from: lineData,
            stream: .stdout,
            sequence: sequence,
            parseTimestamps: parseTimestamps
        )
        sequence &+= 1
        return entry
    }
}

// MARK: - Shared line formatting

enum LogLineFormatting {
    /// RFC3339Nano timestamps prefix the line and end at the first space.
    static func makeEntry(
        from lineData: Data,
        stream: LogStreamType,
        sequence: UInt64,
        parseTimestamps: Bool
    ) -> LogEntry {
        var bytes = lineData
        // Strip a single trailing carriage return (CRLF terminators).
        if bytes.last == UInt8(ascii: "\r") {
            bytes.removeLast()
        }

        var text = strippingANSI(String(decoding: bytes, as: UTF8.self))
        var timestamp: Date?

        if parseTimestamps, let spaceIndex = text.firstIndex(of: " ") {
            let prefix = String(text[text.startIndex ..< spaceIndex])
            if let date = RFC3339Nano.date(from: prefix) {
                timestamp = date
                text = String(text[text.index(after: spaceIndex)...])
            }
        }

        return LogEntry(id: sequence, stream: stream, text: text, timestamp: timestamp)
    }

    /// Removes ANSI escape sequences (SGR colors, cursor control, OSC titles)
    /// so log lines render, search, and copy as plain text.
    static func strippingANSI(_ text: String) -> String {
        guard text.utf8.contains(0x1B) else { return text }

        var result = String.UnicodeScalarView()
        var scalars = text.unicodeScalars[...]
        while let esc = scalars.firstIndex(of: "\u{1B}") {
            result.append(contentsOf: scalars[..<esc])
            var rest = scalars[scalars.index(after: esc)...]
            switch rest.first {
            case "[":
                // CSI: parameter bytes 0x30–0x3F, intermediates 0x20–0x2F,
                // one final byte 0x40–0x7E.
                rest = rest.dropFirst()
                while let c = rest.first, (0x20...0x3F).contains(c.value) {
                    rest = rest.dropFirst()
                }
                rest = rest.dropFirst()
            case "]":
                // OSC: runs to BEL or ESC-backslash.
                while let c = rest.first, c != "\u{07}", c != "\u{1B}" {
                    rest = rest.dropFirst()
                }
                rest = rest.dropFirst(rest.first == "\u{1B}" ? 2 : 1)
            default:
                // Lone ESC plus a single command character.
                rest = rest.dropFirst()
            }
            scalars = rest
        }
        result.append(contentsOf: scalars)
        return String(result)
    }
}

/// Parses Docker's RFC3339 timestamps with optional nanosecond fractions.
enum RFC3339Nano {
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(from string: String) -> Date? {
        formatter.date(from: string) ?? plainFormatter.date(from: string)
    }
}
