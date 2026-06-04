import Foundation

extension DockerClient {
    /// `GET /containers/{id}/logs` — follows the container's log stream.
    ///
    /// For non-TTY containers the bytes are Docker's multiplexed frame format
    /// and are demultiplexed via `DockerLogDemuxer`; for TTY containers the
    /// bytes are plain stdout and parsed via `RawLogLineParser`.
    public func containerLogs(
        id: String,
        tty: Bool,
        follow: Bool = true,
        tail: Int? = 500,
        timestamps: Bool = false,
        since: Int64? = nil
    ) async throws -> AsyncThrowingStream<LogEntry, Error> {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "stdout", value: "true"),
            URLQueryItem(name: "stderr", value: "true"),
            URLQueryItem(name: "follow", value: follow ? "true" : "false"),
            URLQueryItem(name: "timestamps", value: timestamps ? "true" : "false")
        ]
        query.append(URLQueryItem(name: "tail", value: tail.map(String.init) ?? "all"))
        if let since {
            query.append(URLQueryItem(name: "since", value: String(since)))
        }

        let byteStream = try await byteStream(path: "/containers/\(id)/logs", query: query)
        guard byteStream.status == 200 else {
            throw DockerError.apiError(status: byteStream.status, message: "Failed to open log stream")
        }

        let parser: LogLineParsing = tty
            ? RawLogLineParser(parseTimestamps: timestamps)
            : DockerLogDemuxer(parseTimestamps: timestamps)
        return DockerClient.makeStream(from: byteStream, parser: parser)
    }

    /// `GET /containers/{id}/stats?stream=true` — streams stats samples.
    public func containerStats(id: String) async throws -> AsyncThrowingStream<ContainerStatsSample, Error> {
        let byteStream = try await byteStream(
            path: "/containers/\(id)/stats",
            query: [URLQueryItem(name: "stream", value: "true")]
        )
        guard byteStream.status == 200 else {
            throw DockerError.apiError(status: byteStream.status, message: "Failed to open stats stream")
        }
        return DockerClient.makeJSONLineStream(from: byteStream, type: ContainerStatsSample.self)
    }

    /// `GET /containers/{id}/stats?stream=false` — a single stats sample.
    ///
    /// The daemon waits one collection interval (~1s) before answering so the
    /// `precpu` fields are populated and a CPU percentage can be derived.
    public func containerStatsOnce(id: String) async throws -> ContainerStatsSample {
        let response = try await requestData(
            method: .get,
            path: "/containers/\(id)/stats",
            query: [URLQueryItem(name: "stream", value: "false")],
            expecting: [200]
        )
        return try decode(ContainerStatsSample.self, from: response.body, path: "/containers/\(id)/stats")
    }

    /// `GET /events` — streams daemon events.
    public func events() async throws -> AsyncThrowingStream<DockerEvent, Error> {
        let byteStream = try await byteStream(path: "/events", query: [])
        guard byteStream.status == 200 else {
            throw DockerError.apiError(status: byteStream.status, message: "Failed to open event stream")
        }
        return DockerClient.makeJSONLineStream(from: byteStream, type: DockerEvent.self)
    }

    // MARK: - Pumps (nonisolated, run off the actor)

    /// Pumps a byte stream through a line parser into a `LogEntry` stream.
    ///
    /// Built outside the actor so each chunk is processed without an actor hop.
    nonisolated private static func makeStream(
        from byteStream: DockerByteStream,
        parser: sending any LogLineParsing
    ) -> AsyncThrowingStream<LogEntry, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [parser] in
                var parser = parser
                do {
                    for try await chunk in byteStream.bytes {
                        for entry in parser.ingest(chunk) {
                            continuation.yield(entry)
                        }
                    }
                    for entry in parser.finish() {
                        continuation.yield(entry)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Pumps a byte stream through a `JSONLinesDecoder` into a model stream.
    nonisolated private static func makeJSONLineStream<T: Decodable & Sendable>(
        from byteStream: DockerByteStream,
        type: T.Type
    ) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var decoder = JSONLinesDecoder<T>()
                do {
                    for try await chunk in byteStream.bytes {
                        for value in decoder.ingest(chunk) {
                            continuation.yield(value)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Shared interface so the log demuxer and the raw TTY parser can be selected
/// at runtime and pumped through the same code path.
protocol LogLineParsing: Sendable {
    mutating func ingest(_ data: Data) -> [LogEntry]
    mutating func finish() -> [LogEntry]
}

extension DockerLogDemuxer: LogLineParsing {}
extension RawLogLineParser: LogLineParsing {}
