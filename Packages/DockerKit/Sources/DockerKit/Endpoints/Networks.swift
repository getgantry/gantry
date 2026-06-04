import Foundation

extension DockerClient {
    /// `GET /networks`.
    public func listNetworks() async throws -> [NetworkResource] {
        try await getJSON("/networks")
    }

    /// `GET /networks/{id}` returning the raw body for the Inspect tab.
    public func rawInspectNetwork(id: String) async throws -> Data {
        try await rawJSON(path: "/networks/\(id)")
    }

    /// `DELETE /networks/{id}`.
    public func removeNetwork(id: String) async throws {
        try await deleteExpectingNoContent("/networks/\(id)")
    }
}
