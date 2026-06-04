import Foundation

extension DockerClient {
    /// `POST /containers/create?name=` — creates a container, returning its id.
    public func createContainer(config: ContainerCreateRequest, name: String? = nil) async throws -> String {
        var query: [URLQueryItem] = []
        if let name { query.append(URLQueryItem(name: "name", value: name)) }
        let body = try JSONEncoder().encode(config)
        let response = try await requestData(
            method: .post,
            path: "/containers/create",
            query: query,
            headers: ["Content-Type": "application/json"],
            body: body,
            expecting: [201]
        )
        return try decode(ContainerCreateResponse.self, from: response.body, path: "/containers/create").id
    }

    /// `POST /commit?container=&repo=&tag=&comment=` — commits a container to a
    /// new image, returning the image id.
    public func commitContainer(
        id: String,
        repo: String,
        tag: String,
        comment: String? = nil
    ) async throws -> String {
        var query = [
            URLQueryItem(name: "container", value: id),
            URLQueryItem(name: "repo", value: repo),
            URLQueryItem(name: "tag", value: tag)
        ]
        if let comment { query.append(URLQueryItem(name: "comment", value: comment)) }
        let response = try await requestData(
            method: .post,
            path: "/commit",
            query: query,
            expecting: [201]
        )
        return try decode(IDResponse.self, from: response.body, path: "/commit").id
    }

    /// `GET /containers/{id}/export` — streams the container filesystem as a tar.
    public func exportContainer(id: String) async throws -> DockerByteStream {
        let stream = try await byteStream(path: "/containers/\(id)/export", query: [])
        guard stream.status == 200 else {
            throw DockerError.apiError(status: stream.status, message: "Failed to export container")
        }
        return stream
    }

    /// `GET /containers/{id}/top` — the container's running processes.
    public func containerProcesses(id: String) async throws -> ContainerTop {
        try await getJSON("/containers/\(id)/top")
    }

    /// `POST /containers/{id}/update` — changes the container restart policy.
    public func updateRestartPolicy(id: String, policy: String, maxRetries: Int = 0) async throws {
        struct UpdateRequest: Encodable {
            var restartPolicy: ContainerCreateRequest.RestartPolicy
            enum CodingKeys: String, CodingKey { case restartPolicy = "RestartPolicy" }
        }
        let payload = UpdateRequest(
            restartPolicy: .init(name: policy, maximumRetryCount: maxRetries)
        )
        let body = try JSONEncoder().encode(payload)
        _ = try await requestData(
            method: .post,
            path: "/containers/\(id)/update",
            headers: ["Content-Type": "application/json"],
            body: body,
            expecting: [200]
        )
    }

    /// `POST /containers/prune`.
    public func pruneContainers() async throws -> PruneResult {
        let response = try await requestData(
            method: .post,
            path: "/containers/prune",
            expecting: [200]
        )
        return try decode(PruneResult.self, from: response.body, path: "/containers/prune")
    }

    /// `POST /containers/{id}/wait` — blocks until the container exits, returning
    /// its exit status code.
    public func waitContainer(id: String) async throws -> Int {
        struct WaitResponse: Decodable {
            var statusCode: Int
            enum CodingKeys: String, CodingKey { case statusCode = "StatusCode" }
        }
        let response = try await requestData(
            method: .post,
            path: "/containers/\(id)/wait",
            expecting: [200]
        )
        return try decode(WaitResponse.self, from: response.body, path: "/containers/\(id)/wait").statusCode
    }
}

/// Generic `{ "Id": "…" }` response shared by several create/commit endpoints.
struct IDResponse: Decodable {
    var id: String
    enum CodingKeys: String, CodingKey { case id = "Id" }
}
