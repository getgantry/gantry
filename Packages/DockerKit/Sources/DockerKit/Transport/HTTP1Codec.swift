import Foundation

/// Errors raised while parsing an HTTP/1.1 response byte stream.
public enum HTTP1ParseError: Error, Sendable {
    case malformedStatusLine(String)
    case malformedHeader(String)
    case malformedChunk
    case unexpectedEOF
}

/// Serializes a `DockerRequest` into raw HTTP/1.1 request bytes.
///
/// The request path arrives already version-prefixed by `DockerClient`; the
/// path + query are assembled with `URLComponents` exactly like
/// `UnixSocketTransport` does.
public enum HTTP1RequestSerializer {
    public static func serialize(_ request: DockerRequest) -> Data {
        var components = URLComponents()
        components.path = request.path
        components.queryItems = request.query.isEmpty ? nil : request.query
        // `URLComponents.string` should always succeed for a sane path; fall
        // back to the raw path if it somehow does not.
        let requestTarget = components.string ?? request.path

        var head = "\(request.method.rawValue) \(requestTarget) HTTP/1.1\r\n"
        head += "Host: docker\r\n"
        head += "Connection: keep-alive\r\n"

        // User-supplied headers, preserving their casing. Track whether the
        // caller already set a Content-Type so we do not override it.
        var hasContentType = false
        for (name, value) in request.headers {
            if name.caseInsensitiveCompare("Content-Type") == .orderedSame {
                hasContentType = true
            }
            head += "\(name): \(value)\r\n"
        }

        if let body = request.body {
            head += "Content-Length: \(body.count)\r\n"
            if !hasContentType {
                head += "Content-Type: application/json\r\n"
            }
        } else if methodImpliesBody(request.method) {
            head += "Content-Length: 0\r\n"
        }

        head += "\r\n"

        var data = Data(head.utf8)
        if let body = request.body {
            data.append(body)
        }
        return data
    }

    /// POST/PUT/DELETE without a body still carry an explicit `Content-Length: 0`.
    private static func methodImpliesBody(_ method: DockerRequest.Method) -> Bool {
        switch method {
        case .post, .put, .delete:
            return true
        case .get, .head:
            return false
        }
    }
}

/// Incremental, stateful push parser for HTTP/1.1 responses.
///
/// Feed arbitrary byte slices via `ingest`; it emits `Event`s as soon as
/// enough bytes are available, tolerating splits at any boundary. After a
/// response completes (`.end`) on a keep-alive connection, the parser resets to
/// expect the next pipelined response.
public struct HTTP1ResponseParser: Sendable {
    public enum Event: Sendable {
        case head(status: Int, headers: [String: String])
        case body(Data)
        case end
    }

    private enum State: Sendable {
        case statusLine
        case headers
        case fixedLengthBody(remaining: Int)
        case chunkSize
        case chunkData(remaining: Int)
        case chunkDataTrailingCRLF
        case chunkTrailers
        case readUntilClose
        case passthrough
        case complete
    }

    private var state: State = .statusLine
    private var buffer: Data = Data()
    private var status: Int = 0
    private var headers: [String: String] = [:]

    public init() {}

    public mutating func ingest(_ data: Data) throws -> [Event] {
        buffer.append(data)
        var events: [Event] = []
        try drain(into: &events)
        return events
    }

    /// Flushes a read-until-close response with `.end`. Errors if the stream
    /// ends mid status line, mid headers, or mid chunked body.
    public mutating func finish() throws -> [Event] {
        switch state {
        case .readUntilClose:
            state = .complete
            return [.end]
        case .passthrough:
            // Passthrough (101) never produces `.end`; closing is acceptable.
            return []
        case .complete:
            return []
        case .statusLine:
            // Nothing parsed yet at all is a clean idle close.
            if buffer.isEmpty {
                return []
            }
            throw HTTP1ParseError.unexpectedEOF
        case .headers, .fixedLengthBody, .chunkSize, .chunkData, .chunkDataTrailingCRLF, .chunkTrailers:
            throw HTTP1ParseError.unexpectedEOF
        }
    }

    // MARK: - Core loop

    private mutating func drain(into events: inout [Event]) throws {
        while true {
            switch state {
            case .statusLine:
                guard let line = takeLine() else { return }
                try parseStatusLine(line)
                state = .headers

            case .headers:
                guard let line = takeLine() else { return }
                if line.isEmpty {
                    events.append(.head(status: status, headers: headers))
                    try beginBody(into: &events)
                } else {
                    try parseHeaderLine(line)
                }

            case .fixedLengthBody(let remaining):
                if remaining == 0 {
                    events.append(.end)
                    reset()
                    continue
                }
                if buffer.isEmpty { return }
                let take = min(remaining, buffer.count)
                events.append(.body(buffer.prefix(take)))
                buffer.removeFirst(take)
                let left = remaining - take
                if left == 0 {
                    events.append(.end)
                    reset()
                } else {
                    state = .fixedLengthBody(remaining: left)
                }

            case .chunkSize:
                guard let line = takeLine() else { return }
                let size = try parseChunkSize(line)
                if size == 0 {
                    state = .chunkTrailers
                } else {
                    state = .chunkData(remaining: size)
                }

            case .chunkData(let remaining):
                if buffer.isEmpty { return }
                let take = min(remaining, buffer.count)
                events.append(.body(buffer.prefix(take)))
                buffer.removeFirst(take)
                let left = remaining - take
                if left == 0 {
                    state = .chunkDataTrailingCRLF
                } else {
                    state = .chunkData(remaining: left)
                }

            case .chunkDataTrailingCRLF:
                guard let line = takeLine() else { return }
                guard line.isEmpty else { throw HTTP1ParseError.malformedChunk }
                state = .chunkSize

            case .chunkTrailers:
                guard let line = takeLine() else { return }
                if line.isEmpty {
                    events.append(.end)
                    reset()
                }
                // Non-empty trailer lines are simply consumed and ignored.

            case .readUntilClose:
                if buffer.isEmpty { return }
                events.append(.body(buffer))
                buffer.removeAll(keepingCapacity: true)

            case .passthrough:
                if buffer.isEmpty { return }
                events.append(.body(buffer))
                buffer.removeAll(keepingCapacity: true)

            case .complete:
                return
            }
        }
    }

    // MARK: - Body framing decision

    private mutating func beginBody(into events: inout [Event]) throws {
        if status == 101 {
            state = .passthrough
            return
        }

        if status == 204 || status == 304 || (status >= 100 && status < 200) {
            events.append(.end)
            reset()
            return
        }

        if let te = headers["transfer-encoding"], te.lowercased().contains("chunked") {
            state = .chunkSize
            return
        }

        if let lengthValue = headers["content-length"], let length = Int(lengthValue.trimmingCharacters(in: .whitespaces)) {
            if length == 0 {
                events.append(.end)
                reset()
            } else {
                state = .fixedLengthBody(remaining: length)
            }
            return
        }

        // No framing information: read until the connection closes.
        state = .readUntilClose
    }

    // MARK: - Line / token parsing

    /// Pops one CRLF-terminated line from `buffer`, returning its bytes without
    /// the terminator. Returns nil when a full line is not yet available. A bare
    /// LF is also accepted as a terminator for robustness.
    private mutating func takeLine() -> Data? {
        guard let lfIndex = buffer.firstIndex(of: 0x0A) else { return nil }
        // `buffer` may have a non-zero startIndex after removeFirst; normalise.
        let start = buffer.startIndex
        let lineEnd: Data.Index
        if lfIndex > start, buffer[buffer.index(before: lfIndex)] == 0x0D {
            lineEnd = buffer.index(before: lfIndex)
        } else {
            lineEnd = lfIndex
        }
        let line = buffer[start..<lineEnd]
        buffer.removeSubrange(start...lfIndex)
        return Data(line)
    }

    private mutating func parseStatusLine(_ line: Data) throws {
        guard let text = String(data: line, encoding: .utf8) else {
            throw HTTP1ParseError.malformedStatusLine("<non-utf8>")
        }
        // "HTTP/1.1 200 OK" — version, status code, optional reason phrase.
        let parts = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let code = Int(parts[1]) else {
            throw HTTP1ParseError.malformedStatusLine(text)
        }
        status = code
        headers = [:]
    }

    private mutating func parseHeaderLine(_ line: Data) throws {
        guard let text = String(data: line, encoding: .utf8) else {
            throw HTTP1ParseError.malformedHeader("<non-utf8>")
        }
        guard let colon = text.firstIndex(of: ":") else {
            throw HTTP1ParseError.malformedHeader(text)
        }
        let name = text[text.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else {
            throw HTTP1ParseError.malformedHeader(text)
        }
        let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        headers[name] = value
    }

    private func parseChunkSize(_ line: Data) throws -> Int {
        guard let text = String(data: line, encoding: .utf8) else {
            throw HTTP1ParseError.malformedChunk
        }
        // Chunk size may carry extensions after a ';'.
        let sizePart = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        guard !sizePart.isEmpty, let size = Int(sizePart, radix: 16), size >= 0 else {
            throw HTTP1ParseError.malformedChunk
        }
        return size
    }

    // MARK: - Reset

    /// Resets to await the next pipelined response (keep-alive).
    private mutating func reset() {
        state = .statusLine
        status = 0
        headers = [:]
    }
}
