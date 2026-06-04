import Foundation

extension DockerClient {
    /// `GET /images/json`.
    public func listImages() async throws -> [ImageSummary] {
        try await getJSON("/images/json")
    }

    /// `GET /images/{id}/json` returning the raw body for the Inspect tab.
    public func rawInspectImage(id: String) async throws -> Data {
        try await rawJSON(path: "/images/\(id)/json")
    }

    /// `DELETE /images/{id}`. Returns 200 with a delete report we ignore.
    public func removeImage(id: String, force: Bool = false) async throws {
        _ = try await requestData(
            method: .delete,
            path: "/images/\(id)",
            query: [URLQueryItem(name: "force", value: force ? "true" : "false")],
            expecting: [200]
        )
    }
}
