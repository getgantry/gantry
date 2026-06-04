import Foundation

extension DockerClient {
    /// `POST /images/create?fromImage=&tag=` — pulls an image, streaming progress.
    ///
    /// The `reference` is split into `fromImage` and `tag` on the last `:`,
    /// unless the part after the colon looks like a digest (`@sha256:` is kept
    /// whole on `fromImage`). When `auth` is supplied its base64url JSON is sent
    /// in the `X-Registry-Auth` header. An `error` progress line is surfaced as
    /// a thrown `DockerError.apiError`.
    public func pullImage(
        reference: String,
        auth: RegistryAuth? = nil
    ) async throws -> AsyncThrowingStream<PullProgress, Error> {
        let (fromImage, tag) = Self.splitPullReference(reference)
        var query = [URLQueryItem(name: "fromImage", value: fromImage)]
        if let tag { query.append(URLQueryItem(name: "tag", value: tag)) }

        var headers: [String: String] = [:]
        if let auth {
            headers["X-Registry-Auth"] = try auth.headerValue()
        }

        let byteStream = try await byteStream(
            method: .post,
            path: "/images/create",
            query: query,
            headers: headers
        )
        guard byteStream.status == 200 else {
            throw DockerError.apiError(status: byteStream.status, message: "Failed to start image pull")
        }
        return Self.makePullStream(from: byteStream)
    }

    /// `GET /images/{id}/history`.
    public func imageHistory(id: String) async throws -> [ImageHistoryEntry] {
        try await getJSON("/images/\(id)/history")
    }

    /// `POST /images/{id}/tag?repo=&tag=`. Expects 201.
    public func tagImage(id: String, repo: String, tag: String) async throws {
        _ = try await requestData(
            method: .post,
            path: "/images/\(id)/tag",
            query: [
                URLQueryItem(name: "repo", value: repo),
                URLQueryItem(name: "tag", value: tag)
            ],
            expecting: [201]
        )
    }

    /// `POST /images/prune` filtered on the `dangling` predicate.
    public func pruneImages(dangling: Bool) async throws -> PruneResult {
        let filters = ["dangling": [dangling ? "true" : "false"]]
        let json = try JSONEncoder().encode(filters)
        let value = String(decoding: json, as: UTF8.self)
        let response = try await requestData(
            method: .post,
            path: "/images/prune",
            query: [URLQueryItem(name: "filters", value: value)],
            expecting: [200]
        )
        return try decode(PruneResult.self, from: response.body, path: "/images/prune")
    }

    // MARK: - Reference splitting

    /// Splits an image reference into `fromImage` and an optional `tag`.
    ///
    /// A `@digest` reference is kept whole on `fromImage` with no tag. Otherwise
    /// the reference is split on the last `:`, but only when that colon is not
    /// part of a registry host:port (i.e. the segment after it contains no `/`).
    static func splitPullReference(_ reference: String) -> (fromImage: String, tag: String?) {
        // Digest references carry no tag.
        if reference.contains("@") {
            return (reference, nil)
        }
        guard let colon = reference.lastIndex(of: ":") else {
            return (reference, nil)
        }
        let afterColon = reference[reference.index(after: colon)...]
        // A "/" after the colon means the colon belonged to a host:port, not a tag.
        if afterColon.contains("/") {
            return (reference, nil)
        }
        let name = String(reference[reference.startIndex ..< colon])
        return (name, String(afterColon))
    }

    // MARK: - Pull stream pump

    /// Pumps the pull progress JSON-lines stream, throwing on an `error` line.
    nonisolated private static func makePullStream(
        from byteStream: DockerByteStream
    ) -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var decoder = JSONLinesDecoder<PullProgress>()
                do {
                    for try await chunk in byteStream.bytes {
                        for progress in decoder.ingest(chunk) {
                            if let error = progress.error {
                                continuation.finish(
                                    throwing: DockerError.apiError(status: 500, message: error)
                                )
                                return
                            }
                            continuation.yield(progress)
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
