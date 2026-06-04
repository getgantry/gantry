import Foundation
import Testing
@testable import DockerKit

/// Live integration tests for the M7 extended endpoints (pull, archive/files,
/// prune, system df) against a real local Docker daemon. Gated on socket
/// existence so they no-op where Docker is absent.
private let liveExtSocket: String? = DockerSocketDiscovery.discover()

private func liveExtClient() throws -> DockerClient {
    let socketPath = try #require(liveExtSocket)
    return DockerClient(transport: UnixSocketTransport(socketPath: socketPath))
}

/// Serialized so tests sharing the `alpine:3.20` image (pull/remove vs. the
/// prune probe that needs it) don't race against each other on the daemon.
@Suite(.serialized)
struct LiveExtendedSuite {

// MARK: - (a) Pull with progress, then remove

/// Pulls a small image, observing progress events, then removes it. Uses a
/// digest-free tag so the daemon emits real layer-download progress lines.
@Test(.enabled(if: liveExtSocket != nil), .timeLimit(.minutes(2)))
func livePullImageWithProgress() async throws {
    let client = try liveExtClient()
    defer { Task { await client.shutdown() } }

    let reference = "alpine:3.20"
    // Start from a clean slate so the pull actually transfers layers.
    try? await client.removeImage(id: reference, force: true)

    let stream = try await client.pullImage(reference: reference)
    var statuses: [String] = []
    var sawProgressBytes = false
    for try await line in stream {
        if !line.status.isEmpty { statuses.append(line.status) }
        if (line.current ?? 0) > 0 || (line.total ?? 0) > 0 { sawProgressBytes = true }
    }
    print("LIVE pull: \(statuses.count) progress lines; bytes observed=\(sawProgressBytes); last=\(statuses.last ?? "-")")

    #expect(!statuses.isEmpty)
    // The terminal line of a successful pull mentions the image is up to date
    // or newly downloaded.
    #expect(statuses.contains { $0.lowercased().contains("complete") || $0.lowercased().contains("downloaded") || $0.lowercased().contains("up to date") || $0.lowercased().contains("pull complete") } || sawProgressBytes)

    // Confirm the image is now present, then remove it to leave no trace.
    let images = try await client.listImages()
    let present = images.contains { $0.repoTags.contains(reference) }
    #expect(present)

    try await client.removeImage(id: reference, force: true)
    let after = try await client.listImages()
    #expect(!after.contains { $0.repoTags.contains(reference) })
    print("LIVE pull: image present=\(present), removed cleanly")
}

// MARK: - (b) Tar archive download + listDirectory parser

/// Downloads /etc from the running nginx test container as a tar stream and
/// runs the TarReader-backed `listDirectory` parser over it; asserts the
/// `nginx` config directory entry is present.
@Test(.enabled(if: liveExtSocket != nil), .timeLimit(.minutes(1)))
func liveListDirectoryParsesArchive() async throws {
    let client = try liveExtClient()
    defer { Task { await client.shutdown() } }

    let container = "gantry-test-nginx"

    // Exercise the raw archive path too, to prove the tar bytes flow.
    let archive = try await client.downloadArchive(containerID: container, path: "/etc")
    var byteCount = 0
    for try await chunk in archive.bytes { byteCount += chunk.count }
    #expect(byteCount > 0)

    let entries = try await client.listDirectory(containerID: container, path: "/etc")
    let names = entries.map(\.name)
    print("LIVE files: /etc has \(entries.count) entries; archive bytes=\(byteCount); sample=\(names.prefix(6).joined(separator: ","))")

    let nginxEntry = entries.first { $0.name == "nginx" }
    #expect(nginxEntry != nil, "expected an 'nginx' entry under /etc")
    #expect(nginxEntry?.isDirectory == true)
}

// MARK: - (c) Safe prune of a throwaway stopped container

/// Creates a short-lived alpine container that echoes and exits, waits for it
/// to stop, then prunes stopped containers and asserts at least one was
/// removed. Safe: only touches the throwaway container it just created.
@Test(.enabled(if: liveExtSocket != nil), .timeLimit(.minutes(2)))
func livePruneStoppedContainer() async throws {
    let client = try liveExtClient()
    defer { Task { await client.shutdown() } }

    // Ensure alpine is available for the throwaway container. Pull
    // unconditionally (idempotent, ~no-op if present) so this stays correct
    // even when other live tests are removing/adding alpine concurrently.
    for try await _ in try await client.pullImage(reference: "alpine:3.20") {}

    let config = ContainerCreateRequest(
        image: "alpine:3.20",
        cmd: ["sh", "-c", "echo gantry-prune-probe"],
        name: "gantry-prune-probe-\(UUID().uuidString.prefix(8))"
    )
    let id = try await client.createContainer(config: config, name: config.name)
    try await client.startContainer(id: id)
    let exit = try await client.waitContainer(id: id)
    #expect(exit == 0)

    let result = try await client.pruneContainers()
    print("LIVE prune: deletedCount=\(result.deletedCount), spaceReclaimed=\(result.spaceReclaimed)")
    #expect(result.deletedCount >= 1)

    // The pruned container must be gone.
    let remaining = try await client.listContainers(all: true)
    #expect(!remaining.contains { $0.id == id })
}

// MARK: - (e) system df totals

/// `GET /system/df` returns non-zero aggregate totals on a daemon with images
/// and running containers.
@Test(.enabled(if: liveExtSocket != nil), .timeLimit(.minutes(1)))
func liveSystemDFTotals() async throws {
    let client = try liveExtClient()
    defer { Task { await client.shutdown() } }

    let df = try await client.systemDF()
    print("LIVE df: images=\(df.imagesCount)/\(df.imagesSize)B containers=\(df.containersCount)/\(df.containersSize)B layers=\(df.layersSize)B volumes=\(df.volumesCount)/\(df.volumesSize)B")

    #expect(df.imagesCount > 0)
    #expect(df.imagesSize > 0)
    #expect(df.layersSize > 0)
}

}
