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

/// (d) Exec: create + hijack-start a short command in redis, read its raw
/// output, and assert the inspected exit code is zero. Exercises the real
/// upgrade path through `UnixSocketTransport.hijack`.
@Test(.enabled(if: liveSocket != nil), .timeLimit(.minutes(1)))
func liveContainerExec() async throws {
    let client = try liveClient()
    defer { Task { await client.shutdown() } }
    try await client.negotiate()

    let marker = "gantry-exec-\(UUID().uuidString.prefix(8))"
    let execID = try await client.createExec(
        containerID: "gantry-test-redis",
        command: ["echo", marker],
        tty: false
    )
    let connection = try await client.startExecHijacked(execID: execID, tty: false)
    #expect(connection.status == 101 || connection.status == 200)

    var output = Data()
    for try await chunk in connection.bytes {
        output.append(chunk)
    }
    await connection.close()

    // Non-TTY exec output is wrapped in 8-byte stdcopy frames; the marker text
    // still appears verbatim within the payload.
    let text = String(data: output, encoding: .utf8) ?? ""
    #expect(text.contains(marker), "expected exec output to contain \(marker), got \(text.debugDescription)")

    let inspect = try await client.inspectExec(execID: execID)
    #expect(inspect.running == false)
    #expect(inspect.exitCode == 0)
    print("LIVE exec: marker found=\(text.contains(marker)) exit=\(inspect.exitCode ?? -1)")
}

/// (e) Exec TTY raw: create + hijack-start a `/bin/sh -c` command with tty:true
/// so the daemon emits raw (un-multiplexed) output. Read until EOF (15s budget)
/// and assert the fixed marker appears, then inspect for clean exit.
@Test(.enabled(if: liveSocket != nil), .timeLimit(.minutes(1)))
func liveContainerExecTTYRaw() async throws {
    let client = try liveClient()
    defer { Task { await client.shutdown() } }
    try await client.negotiate()

    let execID = try await client.createExec(
        containerID: "gantry-test-redis",
        command: ["/bin/sh", "-c", "echo gantry-exec-ok; exit 0"],
        tty: true
    )
    let connection = try await client.startExecHijacked(execID: execID, tty: true)
    #expect(connection.status == 101 || connection.status == 200)

    let text = try await readUntilEOF(connection.bytes, timeout: .seconds(15))
    await connection.close()

    // TTY output is raw — no 8-byte stdcopy frames.
    #expect(text.contains("gantry-exec-ok"), "expected raw TTY exec output to contain gantry-exec-ok, got \(text.debugDescription)")

    let inspect = try await client.inspectExec(execID: execID)
    #expect(inspect.running == false)
    #expect(inspect.exitCode == 0)
    print("LIVE exec tty: ok=\(text.contains("gantry-exec-ok")) exit=\(inspect.exitCode ?? -1)")
}

/// (f) Exec bidirectional: open an interactive `/bin/sh` TTY, write a command
/// over stdin, read until its echoed output appears (10s), then write `exit`
/// and assert the stream reaches EOF. Proves the write path is wired through.
@Test(.enabled(if: liveSocket != nil), .timeLimit(.minutes(1)))
func liveContainerExecRoundtrip() async throws {
    let client = try liveClient()
    defer { Task { await client.shutdown() } }
    try await client.negotiate()

    let execID = try await client.createExec(
        containerID: "gantry-test-redis",
        command: ["/bin/sh"],
        tty: true
    )
    let connection = try await client.startExecHijacked(execID: execID, tty: true)
    #expect(connection.status == 101 || connection.status == 200)

    // Collect output on a background task; signal once "roundtrip" is seen and
    // again at EOF.
    let sawRoundtrip = AsyncSignal()
    let sawEOF = AsyncSignal()
    let reader = Task {
        var acc = ""
        do {
            for try await chunk in connection.bytes {
                acc += String(data: chunk, encoding: .utf8) ?? ""
                if acc.contains("roundtrip-") {
                    sawRoundtrip.fire()
                }
            }
        } catch {
            // Channel teardown after exit surfaces as a stream error; treat as EOF.
        }
        sawEOF.fire()
        return acc
    }

    // Drive stdin.
    try await connection.write(Data("echo roundtrip-$$\n".utf8))
    try await sawRoundtrip.wait(timeout: .seconds(10))

    try await connection.write(Data("exit\n".utf8))
    try await sawEOF.wait(timeout: .seconds(10))

    let acc = await reader.value
    await connection.close()
    #expect(acc.contains("roundtrip-"), "expected stdin echo to round-trip, got \(acc.debugDescription)")
    print("LIVE exec roundtrip: ok=\(acc.contains("roundtrip-"))")
}

// MARK: - Exec test helpers

/// Reads an byte stream until EOF, bounded by `timeout`, decoding accumulated
/// bytes as UTF-8. Returns whatever was read if the timeout fires first.
private func readUntilEOF(
    _ stream: AsyncThrowingStream<Data, Error>,
    timeout: Duration
) async throws -> String {
    try await withThrowingTaskGroup(of: Data?.self) { group in
        group.addTask {
            var acc = Data()
            for try await chunk in stream { acc.append(chunk) }
            return acc
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = try await group.next() ?? nil
        group.cancelAll()
        return String(data: first ?? Data(), encoding: .utf8) ?? ""
    }
}

/// A one-shot async signal usable from multiple tasks: `wait(timeout:)` resumes
/// when `fire()` is called or throws on timeout.
private final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func fire() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            let p = continuations
            continuations.removeAll()
            fired = true
            return p
        }
        for c in pending { c.resume() }
    }

    func wait(timeout: Duration) async throws {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [self] in
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    let alreadyFired: Bool = lock.withLock {
                        if fired { return true }
                        continuations.append(c)
                        return false
                    }
                    if alreadyFired { c.resume() }
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            _ = await group.next()
            group.cancelAll()
        }
        let didFire = lock.withLock { fired }
        if !didFire {
            throw DockerError.connectionFailed("AsyncSignal timed out")
        }
    }
}
