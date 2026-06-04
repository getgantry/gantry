import Foundation
import Testing
@testable import DockerKit

/// Live smoke tests against a real local Docker daemon. Gated on socket
/// existence so they no-op on machines without Docker (CI, etc.).
private let liveSocket: String? = DockerSocketDiscovery.discover()

@Test(.enabled(if: liveSocket != nil))
func liveDaemonSmoke() async throws {
    let socketPath = try #require(liveSocket)
    let transport = UnixSocketTransport(socketPath: socketPath)
    let client = DockerClient(transport: transport)
    defer { Task { await client.shutdown() } }

    let version = try await client.negotiate()
    #expect(!version.apiVersion.isEmpty)
    #expect(!version.version.isEmpty)

    let containers = try await client.listContainers(all: true)
    let images = try await client.listImages()

    // Reaching here without throwing is the assertion; print for visibility.
    print("LIVE: apiVersion=\(version.apiVersion) serverVersion=\(version.version) containers=\(containers.count) images=\(images.count)")
}
