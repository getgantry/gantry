import Foundation

extension DockerClient {
    /// `GET /containers/json`.
    public func listContainers(all: Bool = true) async throws -> [ContainerSummary] {
        try await getJSON("/containers/json", query: [URLQueryItem(name: "all", value: all ? "true" : "false")])
    }

    /// `GET /containers/{id}/json`.
    public func inspectContainer(id: String) async throws -> ContainerDetails {
        try await getJSON("/containers/\(id)/json")
    }

    /// `GET /containers/{id}/json` returning the raw body for the Inspect tab.
    public func rawInspectContainer(id: String) async throws -> Data {
        try await rawJSON(path: "/containers/\(id)/json")
    }

    /// `POST /containers/{id}/start`.
    public func startContainer(id: String) async throws {
        try await postExpectingNoContent("/containers/\(id)/start")
    }

    /// `POST /containers/{id}/stop`.
    public func stopContainer(id: String, timeout: Int? = nil) async throws {
        try await postExpectingNoContent("/containers/\(id)/stop", query: timeoutQuery(timeout))
    }

    /// `POST /containers/{id}/restart`.
    public func restartContainer(id: String, timeout: Int? = nil) async throws {
        try await postExpectingNoContent("/containers/\(id)/restart", query: timeoutQuery(timeout))
    }

    /// `POST /containers/{id}/kill`.
    public func killContainer(id: String, signal: String? = nil) async throws {
        var query: [URLQueryItem] = []
        if let signal { query.append(URLQueryItem(name: "signal", value: signal)) }
        try await postExpectingNoContent("/containers/\(id)/kill", query: query)
    }

    /// `POST /containers/{id}/pause`.
    public func pauseContainer(id: String) async throws {
        try await postExpectingNoContent("/containers/\(id)/pause")
    }

    /// `POST /containers/{id}/unpause`.
    public func unpauseContainer(id: String) async throws {
        try await postExpectingNoContent("/containers/\(id)/unpause")
    }

    /// `POST /containers/{id}/rename`.
    public func renameContainer(id: String, to name: String) async throws {
        try await postExpectingNoContent("/containers/\(id)/rename", query: [URLQueryItem(name: "name", value: name)])
    }

    /// `DELETE /containers/{id}`.
    public func removeContainer(id: String, force: Bool = false, removeVolumes: Bool = false) async throws {
        try await deleteExpectingNoContent("/containers/\(id)", query: [
            URLQueryItem(name: "force", value: force ? "true" : "false"),
            URLQueryItem(name: "v", value: removeVolumes ? "true" : "false")
        ])
    }

    private func timeoutQuery(_ timeout: Int?) -> [URLQueryItem] {
        guard let timeout else { return [] }
        return [URLQueryItem(name: "t", value: String(timeout))]
    }
}
