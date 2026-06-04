import Foundation

extension DockerClient {
    /// `GET /system/df` — aggregate disk usage across images, containers, volumes.
    public func systemDF() async throws -> SystemDiskUsage {
        try await getJSON("/system/df")
    }

    /// `POST /build/prune` — clears the builder cache.
    public func pruneBuildCache() async throws -> PruneResult {
        let response = try await requestData(method: .post, path: "/build/prune", expecting: [200])
        return try decode(PruneResult.self, from: response.body, path: "/build/prune")
    }
}
