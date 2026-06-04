import Foundation

extension DockerClient {
    /// `GET /volumes`.
    public func listVolumes() async throws -> [Volume] {
        let response: VolumeListResponse = try await getJSON("/volumes")
        return response.volumes
    }

    /// `GET /volumes/{name}` returning the raw body for the Inspect tab.
    public func rawInspectVolume(name: String) async throws -> Data {
        try await rawJSON(path: "/volumes/\(name)")
    }

    /// `DELETE /volumes/{name}`.
    public func removeVolume(name: String, force: Bool = false) async throws {
        try await deleteExpectingNoContent(
            "/volumes/\(name)",
            query: [URLQueryItem(name: "force", value: force ? "true" : "false")]
        )
    }
}
