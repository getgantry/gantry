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

// MARK: - Streaming live tests

private func liveClient() throws -> DockerClient {
    let socketPath = try #require(liveSocket)
    return DockerClient(transport: UnixSocketTransport(socketPath: socketPath))
}

/// Runs `args` via the system `docker` CLI, failing the test on non-zero exit.
@discardableResult
private func runDocker(_ args: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["docker"] + args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    #expect(process.terminationStatus == 0, "docker \(args.joined(separator: " ")) failed: \(output)")
    return output
}

/// (a) Logs: generate traffic against nginx, then read a bounded snapshot of
/// its logs (follow:false) and assert at least one entry decodes.
@Test(.enabled(if: liveSocket != nil), .timeLimit(.minutes(1)))
func liveContainerLogs() async throws {
    let client = try liveClient()
    defer { Task { await client.shutdown() } }

    for _ in 0..<3 {
        _ = try? await URLSession.shared.data(from: URL(string: "http://localhost:8085")!)
    }

    var entries: [LogEntry] = []
    let stream = try await client.containerLogs(
        id: "gantry-test-nginx",
        tty: false,
        follow: false,
        tail: 50,
        timestamps: true
    )
    for try await entry in stream {
        entries.append(entry)
    }

    #expect(!entries.isEmpty, "expected decoded nginx log entries")
    print("LIVE logs: nginx returned \(entries.count) entries; first=\(entries.first?.text ?? "<none>")")
}

/// (b) Stats: take the first two samples from redis and assert the second
/// sample reports a positive memory usage.
@Test(.enabled(if: liveSocket != nil), .timeLimit(.minutes(1)))
func liveContainerStats() async throws {
    let client = try liveClient()
    defer { Task { await client.shutdown() } }

    var samples: [ContainerStatsSample] = []
    let stream = try await client.containerStats(id: "gantry-test-redis")
    for try await sample in stream {
        samples.append(sample)
        if samples.count >= 2 { break }
    }

    #expect(samples.count >= 2, "expected at least 2 stats samples")
    let second = try #require(samples.dropFirst().first)
    #expect(second.memoryUsageBytes > 0, "expected positive memory usage, got \(second.memoryUsageBytes)")
    print("LIVE stats: redis sample2 mem=\(second.memoryUsageBytes) cpu=\(second.cpuPercent)")
}

/// (c) Events: open the events stream, pause+unpause redis, and assert at
/// least one container event for redis arrives within 10s.
@Test(.enabled(if: liveSocket != nil), .timeLimit(.minutes(1)))
func liveContainerEvents() async throws {
    let client = try liveClient()
    defer { Task { await client.shutdown() } }

    let stream = try await client.events()

    // Drive the daemon to emit events after the stream is open.
    let driver = Task {
        try? await Task.sleep(for: .milliseconds(500))
        _ = try? runDocker(["pause", "gantry-test-redis"])
        try? await Task.sleep(for: .milliseconds(300))
        _ = try? runDocker(["unpause", "gantry-test-redis"])
    }
    defer { driver.cancel() }

    let received: DockerEvent? = try await withThrowingTaskGroup(of: DockerEvent?.self) { group in
        group.addTask {
            for try await event in stream {
                if event.isContainerEvent, event.containerName == "gantry-test-redis" {
                    return event
                }
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(10))
            return nil
        }
        let first = try await group.next() ?? nil
        group.cancelAll()
        return first
    }

    let event = try #require(received, "expected a container event for redis within 10s")
    print("LIVE events: received \(event.type)/\(event.action) for \(event.containerName ?? "?")")
}
