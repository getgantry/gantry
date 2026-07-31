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

        // Upload a folder via the emulated archive endpoint (tar over exec),
        // then read it back through exec to confirm the extraction completed.
        let tar = TarWriter.archive(entries: [
            TarEntry(name: "gantry-upload", isDirectory: true),
            TarEntry(name: "gantry-upload/hello.txt", data: Data("uploaded-ok".utf8)),
            TarEntry(name: "gantry-upload/sub", isDirectory: true),
            TarEntry(name: "gantry-upload/sub/nested.txt", data: Data("nested-ok".utf8))
        ])
        try await client.uploadArchive(containerID: id, path: "/root", tar: tar)
        let readBack = try await client.createExec(
            containerID: id,
            command: ["/bin/sh", "-c", "cat /root/gantry-upload/hello.txt /root/gantry-upload/sub/nested.txt"],
            tty: false
        )
        let readConn = try await client.startExecHijacked(execID: readBack, tty: false)
        let readOut = try await DockerClient.collectExecLines(from: readConn.bytes)
        #expect(readOut.stdout.contains("uploaded-ok"))
        #expect(readOut.stdout.contains("nested-ok"))

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

/// Kernel boot arguments end to end: the request the create sheet builds has
/// to reach the container's actual kernel command line, and the labels it
/// stamps have to survive a round trip through the CLI so a recreate can
/// restore them. Needs apple/container 1.2 or newer for `--kernel-arg`.
@Test(.enabled(if: liveEnabled), .timeLimit(.minutes(2)))
func liveAppleKernelBootArguments() async throws {
    let client = try makeLiveClient()
    defer { Task { await client.shutdown() } }

    let version = try await client.negotiate()
    // Nothing to assert on an older CLI — the sheet hides the option there.
    try #require(
        version.version.compare("1.2.0", options: .numeric) != .orderedAscending,
        "apple/container 1.2 or newer is needed for --kernel-arg"
    )

    let name = "gantry-apple-live-kernel"
    _ = try? await client.removeContainer(id: name, force: true)

    // Exactly what CreateContainerSheet.buildRequest produces for a container
    // with one boot argument: the option itself plus its marker labels.
    let options = ContainerCreateRequest.AppleOptions(kernelArgs: ["gantry.check=1"])
    let config = ContainerCreateRequest(
        image: "alpine:latest",
        cmd: ["sleep", "120"],
        labels: options.labels,
        appleOptions: options,
        name: name
    )
    let id = try await client.createContainer(config: config, name: name)
    try await client.startContainer(id: id)

    do {
        // The argument has to show up on the kernel command line, and the
        // CLI's own defaults have to survive alongside it.
        let execID = try await client.createExec(
            containerID: id, command: ["/bin/sh", "-c", "cat /proc/cmdline"], tty: false
        )
        let connection = try await client.startExecHijacked(execID: execID, tty: false)
        let output = try await DockerClient.collectExecLines(from: connection.bytes)
        #expect(output.stdout.contains("gantry.check=1"))
        #expect(output.stdout.contains("init=/sbin/vminitd"))

        // The recreate path reads the options back out of the stamped labels.
        let details = try await client.inspectContainer(id: id)
        let restored = ContainerCreateRequest.AppleOptions(labels: details.config.labels ?? [:])
        #expect(restored == options)
    } catch {
        try? await client.removeContainer(id: id, force: true)
        throw error
    }
    try await client.removeContainer(id: id, force: true)
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
