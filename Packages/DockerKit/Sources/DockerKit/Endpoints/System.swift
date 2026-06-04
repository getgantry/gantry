import Foundation

extension DockerClient {
    /// `GET /info`.
    public func systemInfo() async throws -> SystemInfo {
        try await getJSON("/info")
    }

    /// `GET /version`.
    public func version() async throws -> SystemVersion {
        try await getJSON("/version")
    }
}
