import Testing
import Foundation
import DockerKit
@testable import SSHKit

/// Live end-to-end test against a real SSH Docker host.
/// Gated: runs only when ~/.ssh/id_rsa exists and nettop.local:22 is reachable.
private let liveHost = "nettop.local"

/// Dedicated ed25519 test key used by the bulk of the live suite.
private let testKeyPath = NSHomeDirectory() + "/.ssh/gantry_test_ed25519"

/// The user's standard RSA key, used to prove rsa-sha2-256 (RFC 8332) auth.
private let rsaKeyPath = NSHomeDirectory() + "/.ssh/id_rsa"

private func hostReachable() -> Bool {
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
    probe.arguments = ["-z", "-G", "3", liveHost, "22"]
    probe.standardOutput = FileHandle.nullDevice
    probe.standardError = FileHandle.nullDevice
    do {
        try probe.run()
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    } catch {
        return false
    }
}

private func liveSSHAvailable() -> Bool {
    FileManager.default.fileExists(atPath: testKeyPath) && hostReachable()
}

private func liveRSAAvailable() -> Bool {
    FileManager.default.fileExists(atPath: rsaKeyPath) && hostReachable()
}

@Test(.enabled(if: liveSSHAvailable()), .timeLimit(.minutes(2)))
func liveSSHDialStdio() async throws {
    // Resolve like the app would: ssh_config first, fill in defaults.
    let resolved = SSHConfig.resolve(host: liveHost)
    let username = resolved.user ?? NSUserName()
    let key = try SSHKeyLoader.load(contentsOf: testKeyPath, passphrase: nil)

    // Isolated trust store in a temp dir; auto-trust and log the fingerprint.
    let tempStore = NSTemporaryDirectory() + "gantry-test-trusted-\(UUID().uuidString).json"
    let store = KnownHostsStore(appStorePath: tempStore)

    let parameters = SSHConnectionParameters(
        host: resolved.hostName,
        port: resolved.port,
        username: username,
        auth: .key(key)
    )
    let policy = HostKeyPolicy.acceptKnown(store, onUnknown: { candidate in
        print("LIVE SSH: trusting \(candidate.keyType) \(candidate.fingerprintSHA256)")
        return .trust
    })

    let transport = SSHDialStdioTransport(makeClient: {
        try await SSHConnector.connect(parameters: parameters, policy: policy)
    })
    let client = DockerClient(transport: transport)

    let version = try await client.negotiate()
    print("LIVE SSH: server \(version.version), api \(version.apiVersion)")
    #expect(!version.apiVersion.isEmpty)

    let containers = try await client.listContainers(all: true)
    let images = try await client.listImages()
    print("LIVE SSH: \(containers.count) containers, \(images.count) images over dial-stdio")

    // Streaming over a dedicated tunnel: read a short burst of non-follow logs
    // from the first container, if any exists.
    if let first = containers.first {
        let logs = try await client.containerLogs(
            id: first.id, tty: false, follow: false, tail: 5
        )
        var count = 0
        for try await _ in logs { count += 1 }
        print("LIVE SSH: read \(count) log lines from \(first.displayName)")
    }

    await client.shutdown()
    try? FileManager.default.removeItem(atPath: tempStore)
}

/// Live exec over dial-stdio: connect, find a running container, create + start
/// a hijacked TTY exec running `echo`, read raw output until EOF (15s budget),
/// and assert the marker round-trips through the SSH tunnel. Exercises
/// `SSHDialStdioTransport.hijack` end to end.
@Test(.enabled(if: liveSSHAvailable()), .timeLimit(.minutes(2)))
func liveSSHExec() async throws {
    let resolved = SSHConfig.resolve(host: liveHost)
    let key = try SSHKeyLoader.load(contentsOf: testKeyPath, passphrase: nil)
    let store = KnownHostsStore(
        appStorePath: NSTemporaryDirectory() + "gantry-exec-\(UUID().uuidString).json"
    )
    let parameters = SSHConnectionParameters(
        host: resolved.hostName,
        port: resolved.port,
        username: resolved.user ?? NSUserName(),
        auth: .key(key)
    )
    let transport = SSHDialStdioTransport(makeClient: {
        try await SSHConnector.connect(
            parameters: parameters,
            policy: .acceptKnown(store, onUnknown: { _ in .trust })
        )
    })
    let client = DockerClient(transport: transport)
    defer { Task { await client.shutdown() } }
    _ = try await client.negotiate()

    let containers = try await client.listContainers(all: true)
    let running = try #require(
        containers.first(where: { $0.state.isRunning }),
        "no running container on \(liveHost) to exec into"
    )

    let marker = "gantry-ssh-exec-\(UUID().uuidString.prefix(8))"
    let execID = try await client.createExec(
        containerID: running.id,
        command: ["/bin/sh", "-c", "echo \(marker); exit 0"],
        tty: true
    )
    let connection = try await client.startExecHijacked(execID: execID, tty: true)
    #expect(connection.status == 101 || connection.status == 200)

    let text = try await withThrowingTaskGroup(of: String?.self) { group in
        group.addTask {
            var acc = Data()
            for try await chunk in connection.bytes { acc.append(chunk) }
            return String(data: acc, encoding: .utf8) ?? ""
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(15))
            return nil
        }
        let first = try await group.next() ?? nil
        group.cancelAll()
        return first ?? ""
    }
    await connection.close()

    #expect(text.contains(marker), "expected SSH exec output to contain \(marker), got \(text.debugDescription)")

    let inspect = try await client.inspectExec(execID: execID)
    #expect(inspect.running == false)
    #expect(inspect.exitCode == 0)
    print("LIVE SSH exec: container=\(running.displayName) marker found=\(text.contains(marker)) exit=\(inspect.exitCode ?? -1)")
}

/// Live proof that an RSA key authenticates against a modern OpenSSH server via
/// rsa-sha2-256 (RFC 8332). Uses the user's standard ~/.ssh/id_rsa, which is
/// already in the server's authorized_keys. Before the Citadel/swift-nio-ssh
/// fork changes this failed with authenticationFailed (legacy ssh-rsa/SHA-1);
/// after, it must negotiate a Docker API version over the SSH tunnel.
@Test(.enabled(if: liveRSAAvailable()), .timeLimit(.minutes(2)))
func rsaSha2Auth() async throws {
    let resolved = SSHConfig.resolve(host: liveHost)
    let username = resolved.user ?? NSUserName()
    let key = try SSHKeyLoader.load(contentsOf: rsaKeyPath, passphrase: nil)

    let tempStore = NSTemporaryDirectory() + "gantry-rsa-\(UUID().uuidString).json"
    let store = KnownHostsStore(appStorePath: tempStore)

    let parameters = SSHConnectionParameters(
        host: resolved.hostName,
        port: resolved.port,
        username: username,
        auth: .key(key)
    )
    let policy = HostKeyPolicy.acceptKnown(store, onUnknown: { candidate in
        print("LIVE RSA: trusting \(candidate.keyType) \(candidate.fingerprintSHA256)")
        return .trust
    })

    let transport = SSHDialStdioTransport(makeClient: {
        try await SSHConnector.connect(parameters: parameters, policy: policy)
    })
    let client = DockerClient(transport: transport)

    let version = try await client.negotiate()
    print("LIVE RSA: rsa-sha2-256 auth OK, server \(version.version), api \(version.apiVersion)")
    #expect(!version.apiVersion.isEmpty)

    await client.shutdown()
    try? FileManager.default.removeItem(atPath: tempStore)
}

/// Stress: abruptly cancel streams mid-flight while big requests run.
/// Reproduces the window-adjust-after-close race that crashed the app
/// before the patched swift-nio-ssh fork.
@Test(.enabled(if: liveSSHAvailable()), .timeLimit(.minutes(2)))
func liveSSHStreamCancellationStress() async throws {
    let resolved = SSHConfig.resolve(host: liveHost)
    let key = try SSHKeyLoader.load(contentsOf: testKeyPath, passphrase: nil)
    let store = KnownHostsStore(
        appStorePath: NSTemporaryDirectory() + "gantry-stress-\(UUID().uuidString).json"
    )
    let parameters = SSHConnectionParameters(
        host: resolved.hostName,
        port: resolved.port,
        username: resolved.user ?? NSUserName(),
        auth: .key(key)
    )
    let transport = SSHDialStdioTransport(makeClient: {
        try await SSHConnector.connect(
            parameters: parameters,
            policy: .acceptKnown(store, onUnknown: { _ in .trust })
        )
    })
    let client = DockerClient(transport: transport)
    _ = try await client.negotiate()

    for round in 0..<5 {
        // Big buffered responses racing with a stream that gets cancelled mid-flight.
        async let containers = client.listContainers(all: true)
        async let images = client.listImages()

        let events = try await client.events()
        let consumer = Task {
            for try await _ in events {}
        }
        // Cancel almost immediately — pending reads should not crash the process.
        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()

        let (c, i) = try await (containers, images)
        #expect(c.count > 0 && i.count > 0)
        print("LIVE STRESS round \(round): \(c.count) containers, \(i.count) images, stream cancelled")
    }
    await client.shutdown()
}
