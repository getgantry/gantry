import Foundation

/// A single HTTP request to the Docker Engine API.
public struct DockerRequest: Sendable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
        case head = "HEAD"
    }

    public var method: Method
    /// Path without the API version prefix, e.g. "/containers/json".
    public var path: String
    public var query: [URLQueryItem]
    public var headers: [String: String]
    public var body: Data?

    public init(
        method: Method = .get,
        path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

/// A response from the Docker Engine API.
public struct DockerResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// Transport abstraction over how we reach a Docker daemon:
/// a local unix socket or an SSH `docker system dial-stdio` channel.
public protocol DockerTransport: Sendable {
    /// Performs a request and buffers the entire response body.
    func execute(_ request: DockerRequest) async throws -> DockerResponse

    /// Performs a request and returns the response body as a raw byte stream
    /// (used for logs, stats, events and other follow-style endpoints).
    func stream(_ request: DockerRequest) async throws -> DockerByteStream

    /// Performs a connection-upgrading request (exec/attach) and returns a
    /// bidirectional raw byte channel after the 101 (or 200) upgrade.
    func hijack(_ request: DockerRequest) async throws -> DockerHijackedConnection

    /// Shuts the transport down, releasing sockets/channels.
    func shutdown() async
}

/// A hijacked, bidirectional connection to the daemon after an HTTP upgrade
/// (used by `exec` and `attach`). Once upgraded, both directions carry raw,
/// unframed bytes (or Docker's stdcopy frames for non-TTY streams).
public struct DockerHijackedConnection: Sendable {
    public var status: Int
    public var headers: [String: String]
    /// Raw bytes received from the peer after the upgrade.
    public var bytes: AsyncThrowingStream<Data, Error>
    /// Sends raw bytes to the peer.
    public var write: @Sendable (Data) async throws -> Void
    /// Tears the connection down.
    public var close: @Sendable () async -> Void

    public init(
        status: Int,
        headers: [String: String],
        bytes: AsyncThrowingStream<Data, Error>,
        write: @escaping @Sendable (Data) async throws -> Void,
        close: @escaping @Sendable () async -> Void
    ) {
        self.status = status
        self.headers = headers
        self.bytes = bytes
        self.write = write
        self.close = close
    }
}

/// Status line + headers for a streaming response, followed by raw body bytes.
public struct DockerByteStream: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var bytes: AsyncThrowingStream<Data, Error>

    public init(status: Int, headers: [String: String], bytes: AsyncThrowingStream<Data, Error>) {
        self.status = status
        self.headers = headers
        self.bytes = bytes
    }
}

public enum DockerError: Error, LocalizedError, Sendable {
    case socketNotFound
    case connectionFailed(String)
    case apiError(status: Int, message: String)
    case decodingFailed(String)
    case streamClosed
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .socketNotFound:
            "No Docker socket found. Is Docker running?"
        case .connectionFailed(let reason):
            "Could not connect to Docker: \(reason)"
        case .apiError(let status, let message):
            "Docker API error (\(status)): \(message)"
        case .decodingFailed(let reason):
            "Failed to decode Docker API response: \(reason)"
        case .streamClosed:
            "The stream was closed unexpectedly."
        case .cancelled:
            "The operation was cancelled."
        }
    }

    /// Extracts the daemon's `{"message": …}` error body, falling back to the
    /// raw UTF-8 text, then to `fallback`.
    static func message(fromBody body: Data, fallback: String) -> String {
        struct APIMessage: Decodable { let message: String }
        if let decoded = try? JSONDecoder().decode(APIMessage.self, from: body) {
            return decoded.message
        }
        if let text = String(data: body, encoding: .utf8), !text.isEmpty {
            return text
        }
        return fallback
    }
}
