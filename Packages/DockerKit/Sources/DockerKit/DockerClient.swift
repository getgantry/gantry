import Foundation

/// High-level client for the Docker Engine API.
///
/// Wraps a `DockerTransport` (unix socket or SSH dial-stdio), handles API
/// version negotiation, JSON decoding and uniform error mapping.
public actor DockerClient {
    private let transport: DockerTransport
    private var versionPrefix = "/v1.47"
    private let decoder = JSONDecoder()

    /// The version reported by the daemon at the last `negotiate()` call.
    private var negotiatedVersion: SystemVersion?

    public init(transport: DockerTransport) {
        self.transport = transport
    }

    // MARK: - Lifecycle / handshake

    /// Negotiates the API version with the daemon.
    ///
    /// Issues an unversioned `GET /version`. If the daemon's reported API
    /// version is older than ours, the client downgrades its path prefix so
    /// every subsequent call targets a version the daemon understands.
    @discardableResult
    public func negotiate() async throws -> SystemVersion {
        let response = try await requestData(
            method: .get,
            path: "/version",
            expecting: [200],
            versioned: false
        )
        let version = try decode(SystemVersion.self, from: response.body, path: "/version")
        if let daemonValue = Double(version.apiVersion), daemonValue < 1.47 {
            versionPrefix = "/v" + version.apiVersion
        }
        negotiatedVersion = version
        return version
    }

    /// Pings the daemon. Throws if the daemon does not answer with 200.
    public func ping() async throws {
        _ = try await requestData(
            method: .get,
            path: "/_ping",
            expecting: [200],
            versioned: false
        )
    }

    /// Releases the underlying transport.
    public func shutdown() async {
        await transport.shutdown()
    }

    // MARK: - Raw / streaming access

    /// Performs a versioned `GET` and returns the raw response body.
    /// Used by the Inspect tabs which render the unmodified JSON.
    public func rawJSON(path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await requestData(method: .get, path: path, query: query, expecting: [200]).body
    }

    /// Opens a versioned streaming response (logs, stats, events).
    public func byteStream(path: String, query: [URLQueryItem]) async throws -> DockerByteStream {
        let request = DockerRequest(method: .get, path: versionPrefix + path, query: query)
        return try await transport.stream(request)
    }

    // MARK: - Internal helpers

    /// Core request primitive. Prefixes the API version (unless `versioned`
    /// is false) and validates the response status, mapping unexpected
    /// statuses to `DockerError.apiError` using the daemon's `{"message": …}`.
    func requestData(
        method: DockerRequest.Method,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        expecting: [Int],
        versioned: Bool = true
    ) async throws -> DockerResponse {
        let fullPath = versioned ? versionPrefix + path : path
        let request = DockerRequest(method: method, path: fullPath, query: query, body: body)
        let response = try await transport.execute(request)
        guard expecting.contains(response.status) else {
            throw DockerError.apiError(status: response.status, message: errorMessage(from: response.body))
        }
        return response
    }

    /// Versioned `GET` decoded into a `Decodable` model.
    func getJSON<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let response = try await requestData(method: .get, path: path, query: query, expecting: [200])
        return try decode(T.self, from: response.body, path: path)
    }

    /// Versioned `POST` expecting `204 No Content` (also tolerates `304`).
    func postExpectingNoContent(_ path: String, query: [URLQueryItem] = []) async throws {
        _ = try await requestData(method: .post, path: path, query: query, expecting: [204, 304])
    }

    /// Versioned `DELETE` expecting `204 No Content`.
    func deleteExpectingNoContent(_ path: String, query: [URLQueryItem] = []) async throws {
        _ = try await requestData(method: .delete, path: path, query: query, expecting: [204])
    }

    /// Decodes a model, mapping `DecodingError` to `DockerError.decodingFailed`
    /// with the originating path for context.
    func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch let error as DecodingError {
            throw DockerError.decodingFailed("\(path): \(describe(error))")
        }
    }

    private func errorMessage(from body: Data) -> String {
        struct APIMessage: Decodable { let message: String }
        if let decoded = try? decoder.decode(APIMessage.self, from: body) {
            return decoded.message
        }
        if let text = String(data: body, encoding: .utf8), !text.isEmpty {
            return text
        }
        return "Unknown error"
    }

    private func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _):
            "missing key '\(key.stringValue)'"
        case .typeMismatch(let type, let ctx):
            "type mismatch for \(type) at \(path(ctx))"
        case .valueNotFound(let type, let ctx):
            "missing value for \(type) at \(path(ctx))"
        case .dataCorrupted(let ctx):
            "data corrupted at \(path(ctx)): \(ctx.debugDescription)"
        @unknown default:
            String(describing: error)
        }
    }

    private func path(_ context: DecodingError.Context) -> String {
        context.codingPath.map(\.stringValue).joined(separator: ".")
    }
}
