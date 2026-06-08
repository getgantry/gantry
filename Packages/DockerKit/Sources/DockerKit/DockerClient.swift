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
        // API versions are dotted (major, minor) pairs, not decimals:
        // "1.9" < "1.47". Downgrade when the daemon is older than our 1.47.
        if let daemon = Self.parseAPIVersion(version.apiVersion), daemon < (1, 47) {
            versionPrefix = "/v" + version.apiVersion
        }
        negotiatedVersion = version
        return version
    }

    /// Parses a Docker API version like "1.47" into a comparable pair.
    static func parseAPIVersion(_ string: String) -> (major: Int, minor: Int)? {
        let parts = string.split(separator: ".")
        guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]) else {
            return nil
        }
        return (major, minor)
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

    /// Opens a versioned streaming response for an arbitrary method/headers/body
    /// (used by `POST /images/create` to follow the pull progress stream).
    func byteStream(
        method: DockerRequest.Method,
        path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> DockerByteStream {
        let request = DockerRequest(
            method: method,
            path: versionPrefix + path,
            query: query,
            headers: headers,
            body: body
        )
        return try await transport.stream(request)
    }

    /// Opens a versioned connection-upgrading request (exec/attach) and returns
    /// a bidirectional raw byte channel. Mirrors `byteStream` but `POST`s and
    /// carries upgrade headers through to `transport.hijack`.
    public func hijack(
        path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> DockerHijackedConnection {
        let request = DockerRequest(
            method: .post,
            path: versionPrefix + path,
            query: query,
            headers: headers,
            body: body
        )
        return try await transport.hijack(request)
    }

    // MARK: - Build

    /// Builds an image from a local context directory, streaming the build log.
    ///
    /// Routes by transport: apple/container receives the `ImageBuildSpec` JSON
    /// on `POST /build` and its CLI output is replayed once it completes; a real
    /// Docker daemon (local or over SSH) receives a tar of the context uploaded
    /// to the standard `/build` endpoint, and its newline-delimited JSON
    /// progress is parsed line by line. An `error` line throws.
    public nonisolated func buildImageStream(_ spec: ImageBuildSpec) -> AsyncThrowingStream<BuildLogLine, Error> {
        let usesCLI = transport.usesCLIBuild
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if usesCLI {
                        let log = try await self.cliBuildLog(spec)
                        for line in Self.splitPreservingNewlines(log) {
                            continuation.yield(BuildLogLine(text: line))
                        }
                        continuation.finish()
                    } else {
                        // Pack the context off the actor (blocking disk I/O).
                        let tar = try Self.makeBuildContextTar(spec)
                        let byteStream = try await self.openDaemonBuild(spec: spec, context: tar)
                        try await Self.pumpDaemonBuild(byteStream, into: continuation)
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Builds an image and returns the concatenated log. Convenience for callers
    /// (the Compose runner) that do not surface live progress.
    @discardableResult
    public func buildImage(_ spec: ImageBuildSpec) async throws -> String {
        var log = ""
        for try await line in buildImageStream(spec) {
            log += line.text
        }
        return log
    }

    /// Buffered CLI build: posts the spec JSON and returns the transport's log
    /// (apple/container synthesizes the response from `container build`).
    private func cliBuildLog(_ spec: ImageBuildSpec) async throws -> String {
        let body = try JSONEncoder().encode(spec)
        let response = try await requestData(
            method: .post,
            path: "/build",
            headers: ["Content-Type": "application/json"],
            body: body,
            expecting: [200]
        )
        return String(decoding: response.body, as: UTF8.self)
    }

    /// Opens the daemon `/build` stream, uploading `context` as the tar body and
    /// translating the spec into Docker's query parameters.
    private func openDaemonBuild(
        spec: ImageBuildSpec,
        context: Data
    ) async throws -> DockerByteStream {
        let byteStream = try await byteStream(
            method: .post,
            path: "/build",
            query: Self.buildQuery(spec),
            headers: ["Content-Type": "application/x-tar"],
            body: context
        )
        guard byteStream.status == 200 else {
            let detail = DockerError.message(
                fromBody: Data(),
                fallback: "Build request rejected (HTTP \(byteStream.status))"
            )
            throw DockerError.apiError(status: byteStream.status, message: detail)
        }
        return byteStream
    }

    // MARK: - Build helpers

    /// Tars the build context directory at the archive root, honouring its
    /// `.dockerignore`. Runs off the actor's executor (blocking disk I/O).
    nonisolated static func makeBuildContextTar(_ spec: ImageBuildSpec) throws -> Data {
        let directory = URL(fileURLWithPath: spec.contextPath, isDirectory: true)
        let ignore = DockerIgnore.load(contextDirectory: directory)
        return try TarWriter.archiveDirectoryContents(directory, ignore: ignore)
    }

    /// Encodes an `ImageBuildSpec` into Docker `/build` query parameters.
    nonisolated static func buildQuery(_ spec: ImageBuildSpec) -> [URLQueryItem] {
        var query = [
            URLQueryItem(name: "t", value: spec.tag),
            URLQueryItem(name: "rm", value: "1")
        ]
        if let dockerfile = spec.dockerfile, !dockerfile.isEmpty {
            query.append(URLQueryItem(name: "dockerfile", value: dockerfile))
        }
        if !spec.buildArgs.isEmpty, let json = encodeJSONMap(spec.buildArgs) {
            query.append(URLQueryItem(name: "buildargs", value: json))
        }
        if let target = spec.target, !target.isEmpty {
            query.append(URLQueryItem(name: "target", value: target))
        }
        if !spec.labels.isEmpty, let json = encodeJSONMap(spec.labels) {
            query.append(URLQueryItem(name: "labels", value: json))
        }
        if spec.noCache {
            query.append(URLQueryItem(name: "nocache", value: "1"))
        }
        return query
    }

    /// JSON-encodes a string map with sorted keys (stable for tests/caching).
    nonisolated private static func encodeJSONMap(_ map: [String: String]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(map) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Splits a buffered log into lines, keeping each line's trailing newline so
    /// the UI renders the build output verbatim.
    nonisolated static func splitPreservingNewlines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "\n" {
                lines.append(current)
                current = ""
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    /// Pumps the daemon's JSON-lines build stream, yielding each line and
    /// throwing on the first `error` entry.
    nonisolated private static func pumpDaemonBuild(
        _ byteStream: DockerByteStream,
        into continuation: AsyncThrowingStream<BuildLogLine, Error>.Continuation
    ) async throws {
        var decoder = JSONLinesDecoder<BuildResponseLine>()
        for try await chunk in byteStream.bytes {
            for response in decoder.ingest(chunk) {
                guard let line = response.asLogLine() else { continue }
                if line.isError {
                    throw DockerError.apiError(status: 500, message: line.text)
                }
                continuation.yield(line)
            }
        }
    }

    // MARK: - Internal helpers

    /// Core request primitive. Prefixes the API version (unless `versioned`
    /// is false) and validates the response status, mapping unexpected
    /// statuses to `DockerError.apiError` using the daemon's `{"message": …}`.
    func requestData(
        method: DockerRequest.Method,
        path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        expecting: [Int],
        versioned: Bool = true
    ) async throws -> DockerResponse {
        let fullPath = versioned ? versionPrefix + path : path
        let request = DockerRequest(method: method, path: fullPath, query: query, headers: headers, body: body)
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
        DockerError.message(fromBody: body, fallback: "Unknown error")
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
