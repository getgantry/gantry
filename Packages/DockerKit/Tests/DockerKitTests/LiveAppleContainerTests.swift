import Foundation
import Testing
@testable import DockerKit

// Live tests against an installed apple/container CLI with running services.
// Gated: GANTRY_APPLE_CONTAINER_LIVE=1 swift test --filter liveApple
//
// They create (and clean up) a dedicated container `gantry-apple-live` from
// alpine:latest, which must already be pulled (`container image pull
// alpine:latest`) so the tests stay fast and network-independent.

private let liveEnabled = ProcessInfo.processInfo.environment["GANTRY_APPLE_CONTAINER_LIVE"] == "1"
    && AppleContainerCLIDiscovery.discover() != nil

private let liveContainerName = "gantry-apple-live"

private func makeLiveClient() throws -> DockerClient {
    let transport = try #require(AppleContainerTransport())
    return DockerClient(transport: transport)
}

@Test(.enabled(if: liveEnabled), .timeLimit(.minutes(3)))
func liveAppleEndToEnd() async throws {
    let client = try makeLiveClient()
    defer { Task { await client.shutdown() } }

    // Handshake
    let version = try await client.negotiate()
    #expect(version.platformName == "apple/container")
    #expect(!version.version.isEmpty)
    try await client.ping()

    // Create and start a throwaway container.
    let path = try #require(AppleContainerCLIDiscovery.discover())
    let cleanup = Process()
    cleanup.executableURL = URL(fileURLWithPath: path)
    cleanup.arguments = ["delete", "--force", liveContainerName]
    try? cleanup.run()
    cleanup.waitUntilExit()

    let config = ContainerCreateRequest(
        image: "alpine:latest",
        cmd: ["sleep", "120"],
        name: liveContainerName
    )
    let id = try await client.createContainer(config: config, name: liveContainerName)
    #expect(id == liveContainerName)
    try await client.startContainer(id: id)

    do {
        // List + inspect
        let containers = try await client.listContainers(all: true)
        let summary = try #require(containers.first { $0.id == liveContainerName })
        #expect(summary.state == .running)
        #expect(summary.command == "sleep 120")

        let details = try await client.inspectContainer(id: id)
        #expect(details.state.running)
        #expect(details.config.cmd == ["sleep", "120"])

        // Stats (one-shot, twice for the CPU baseline)
        _ = try await client.containerStatsOnce(id: id)
        let stats = try await client.containerStatsOnce(id: id)
        #expect(stats.memoryUsageBytes > 0)
        #expect(stats.cpuPercent >= 0)

        // Exec (non-TTY)
        let execID = try await client.createExec(
            containerID: id, command: ["/bin/sh", "-c", "echo live-test-ok"], tty: false
        )
        let connection = try await client.startExecHijacked(execID: execID, tty: false)
        let output = try await DockerClient.collectExecLines(from: connection.bytes)
        #expect(output.stdout.contains("live-test-ok"))
        let inspect = try await client.inspectExec(execID: execID)
        #expect(inspect.exitCode == 0)

        // Directory listing through the shell-based fast path
        let entries = try await client.listDirectoryFast(containerID: id, path: "/")
        #expect(entries.contains { $0.name == "etc" && $0.isDirectory })

        // Logs (no follow; the sleep container logs nothing, the call must
        // still succeed and end)
        let logs = try await client.containerLogs(id: id, tty: false, follow: false, tail: 10)
        for try await _ in logs {}

        // Images / volumes / networks / df
        let images = try await client.listImages()
        #expect(images.contains { $0.repoTags.contains { $0.contains("alpine") } })
        _ = try await client.listVolumes()
        let networks = try await client.listNetworks()
        #expect(networks.contains { $0.id == "default" })
        let usage = try await client.systemDF()
        #expect(usage.imagesCount > 0)
        let info = try await client.systemInfo()
        #expect(info.containersRunning >= 1)

        // Stop & delete
        try await client.stopContainer(id: id, timeout: 2)
        let stopped = try await client.listContainers(all: true)
        #expect(stopped.first { $0.id == liveContainerName }?.state == .exited)
    } catch {
        // Best-effort cleanup on failure, then rethrow.
        try? await client.removeContainer(id: id, force: true)
        throw error
    }
    try await client.removeContainer(id: id, force: true)
    let remaining = try await client.listContainers(all: true)
    #expect(!remaining.contains { $0.id == liveContainerName })
}

@Test(.enabled(if: liveEnabled), .timeLimit(.minutes(1)))
func liveAppleVolumeLifecycle() async throws {
    let client = try makeLiveClient()
    defer { Task { await client.shutdown() } }
    _ = try await client.negotiate()

    let name = "gantry-apple-live-vol"
    _ = try? await client.removeVolume(name: name, force: true)

    let created = try await client.createVolume(name: name, driver: "local", labels: ["origin": "gantry-test"])
    #expect(created.name == name)
    let volumes = try await client.listVolumes()
    #expect(volumes.contains { $0.name == name })
    try await client.removeVolume(name: name)
    let after = try await client.listVolumes()
    #expect(!after.contains { $0.name == name })
}
