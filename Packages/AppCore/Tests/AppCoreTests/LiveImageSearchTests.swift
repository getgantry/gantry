import Foundation
import Testing
import DockerKit
@testable import AppCore

// Live checks of spec 020. Each is gated, so CI and normal runs skip them:
// GANTRY_SRCH_LIVE=1                     Docker Hub and ghcr.io over HTTP
// GANTRY_SRCH_LIVE_DOCKER_SOCKET=<path>  a Docker socket (ssh -L to nettop)
// GANTRY_SRCH_LIVE_APPLE=1               pull with --platform on apple/container
private let env = ProcessInfo.processInfo.environment
private let httpLive = env["GANTRY_SRCH_LIVE"] == "1"
private let dockerSocket = env["GANTRY_SRCH_LIVE_DOCKER_SOCKET"]
private let appleLive = env["GANTRY_SRCH_LIVE_APPLE"] == "1"
/// Not on either test host before the run; the tests remove it again.
private let probeImage = "hello-world:latest"

@Test(.enabled(if: httpLive), .timeLimit(.minutes(1)))
func liveDockerHubSearchAndTags() async throws {
    let http = URLSessionImageSearchHTTP()
    let results = try await DockerHubAPI(http: http).search("nginx")
    #expect(results.contains { $0.name == "nginx" && $0.isOfficial })
    let tags = try await DockerHubAPI(http: http).tags(repository: "nginx")
    #expect(!tags.isEmpty)
    #expect(tags.allSatisfy { $0.lastPushed != nil })
    #expect(tags.contains { $0.size(for: "linux/arm64") != nil })
    print("LIVE srch: hub results=\(results.count) tags=\(tags.count) first=\(tags.first?.name ?? "")")
}

@Test(.enabled(if: httpLive), .timeLimit(.minutes(1)))
func liveRegistryTagsWithAnonymousToken() async throws {
    let api = RegistryTagsAPI(http: URLSessionImageSearchHTTP()) { _ in nil }
    let ghcr = try #require(RegistryRepository("ghcr.io/home-assistant/home-assistant"))
    let tags = try await api.tags(ghcr)
    #expect(tags.count > 1000)
    let hub = try #require(RegistryRepository("alpine"))
    let hubTags = try await api.tags(hub).map(\.name)
    #expect(hubTags.contains("3.22"))
    await #expect(throws: ImageSearchError.self) {
        _ = try await api.tags(#require(RegistryRepository("quay.io/srch-none/srch-none")))
    }
    print("LIVE srch: ghcr tags=\(tags.count) alpine tags=\(hubTags.count)")
}

@Test(.enabled(if: dockerSocket != nil), .timeLimit(.minutes(2)))
func liveDockerEngineSearchAndPlatformPull() async throws {
    let client = DockerClient(transport: UnixSocketTransport(socketPath: try #require(dockerSocket)))
    defer { Task { await client.shutdown() } }
    _ = try await client.negotiate()
    let results = try await client.searchImages(term: "nginx", limit: 5)
    #expect(results.first { $0.name == "nginx" }?.isOfficial == true)

    for try await _ in try await client.pullImage(reference: probeImage, platform: "linux/amd64") {}
    let image = try #require(try await client.listImages().first { $0.repoTags.contains(probeImage) })
    try await client.removeImage(id: image.id, force: true)
    print("LIVE srch: engine results=\(results.count) pulled+removed \(probeImage)")
}

@Test(.enabled(if: appleLive), .timeLimit(.minutes(2)))
func liveApplePullOnePlatform() async throws {
    let client = DockerClient(transport: try #require(AppleContainerTransport()))
    defer { Task { await client.shutdown() } }
    _ = try await client.negotiate()
    for try await _ in try await client.pullImage(reference: probeImage, platform: "linux/arm64") {}
    let image = try #require(try await client.listImages().first { $0.repoTags.contains(probeImage) })
    print("LIVE srch: apple pulled \(probeImage) id=\(image.id)")
    try await client.removeImage(id: probeImage, force: true)
}
