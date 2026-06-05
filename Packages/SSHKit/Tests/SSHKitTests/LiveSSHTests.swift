import Testing
import Foundation
import DockerKit
@testable import SSHKit

/// Live end-to-end tests against a real SSH Docker host.
///
/// Gated on environment variables so the suite is inert by default:
///   GANTRY_SSH_TEST_HOST  — SSH host (or ssh_config alias) running Docker.
///   GANTRY_SSH_TEST_KEY   — path to a passphrase-free private key authorized
///                           on that host (default: ~/.ssh/gantry_test_ed25519).
///   GANTRY_SSH_TEST_RSA_KEY — optional RSA key for the rsa-sha2-256 test
///                           (default: ~/.ssh/id_rsa).
private let liveHost = ProcessInfo.processInfo.environment["GANTRY_SSH_TEST_HOST"] ?? ""

/// Dedicated ed25519 test key used by the bulk of the live suite.
private let testKeyPath = ProcessInfo.processInfo.environment["GANTRY_SSH_TEST_KEY"]
    ?? NSHomeDirectory() + "/.ssh/gantry_test_ed25519"

/// An RSA key authorized on the host, used to prove rsa-sha2-256 (RFC 8332) auth.
private let rsaKeyPath = ProcessInfo.processInfo.environment["GANTRY_SSH_TEST_RSA_KEY"]
    ?? NSHomeDirectory() + "/.ssh/id_rsa"

private func hostReachable() -> Bool {
    guard !liveHost.isEmpty else { return false }
    // Probe the resolved endpoint so ssh_config aliases and non-22 ports work.
    let resolved = SSHConfig.resolve(host: liveHost)
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
    probe.arguments = ["-z", "-G", "3", resolved.hostName, String(resolved.port)]
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
    let policy = HostKeyPolicy.acceptKnown(store, onUnknown: { _, candidate in
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
    // from the first container, if any exists. Bounded: a container that never
    // produced output can stall the non-follow read on some daemons, which is
    // incidental to what this test proves (dial-stdio request/stream plumbing).
    if let first = containers.first {
        let logs = try await client.containerLogs(
            id: first.id, tty: false, follow: false, tail: 5
        )
        let count = await withTaskGroup(of: Int?.self) { group in
            group.addTask {
                var lines = 0
                do {
                    for try await _ in logs { lines += 1 }
                } catch {}
                return lines
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        print("LIVE SSH: read \(count.map(String.init) ?? "timed-out") log lines from \(first.displayName)")
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
            policy: .acceptKnown(store, onUnknown: { _, _ in .trust })
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
    let policy = HostKeyPolicy.acceptKnown(store, onUnknown: { _, candidate in
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

/// One-shot stats must not starve the serialized execute tunnel: fire a
/// stats burst for every running container concurrently with an inspect and
/// assert the whole round completes quickly. Guards against the daemon-side
/// collection wait (~1s/container) that `one-shot=true` exists to avoid.
@Test(.enabled(if: liveSSHAvailable()), .timeLimit(.minutes(2)))
func liveSSHOneShotStatsBurst() async throws {
    let resolved = SSHConfig.resolve(host: liveHost)
    let key = try SSHKeyLoader.load(contentsOf: testKeyPath, passphrase: nil)
    let store = KnownHostsStore(
        appStorePath: NSTemporaryDirectory() + "gantry-oneshot-\(UUID().uuidString).json"
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
            policy: .acceptKnown(store, onUnknown: { _, _ in .trust })
        )
    })
    let client = DockerClient(transport: transport)
    _ = try await client.negotiate()

    let running = try await client.listContainers(all: false)
    let start = ContinuousClock.now
    try await withThrowingTaskGroup(of: Void.self) { group in
        for container in running {
            group.addTask { _ = try await client.containerStatsOnce(id: container.id) }
        }
        if let first = running.first {
            group.addTask { _ = try await client.inspectContainer(id: first.id) }
        }
        try await group.waitForAll()
    }
    let elapsed = ContinuousClock.now - start
    print("LIVE ONE-SHOT: \(running.count) stats + inspect in \(elapsed)")
    // Generous bound: with one-shot each request is tens of ms; the old
    // behavior (1s daemon wait per container, serialized) would blow this.
    #expect(elapsed < .seconds(Double(max(running.count, 1)) * 0.7 + 3))
    await client.shutdown()
}

/// Interactive host shell: open a PTY, run a command, expect its output to
/// round-trip, then close cleanly.
@Test(.enabled(if: liveSSHAvailable()), .timeLimit(.minutes(2)))
func liveHostShellRoundTrip() async throws {
    let resolved = SSHConfig.resolve(host: liveHost)
    let key = try SSHKeyLoader.load(contentsOf: testKeyPath, passphrase: nil)
    let store = KnownHostsStore(
        appStorePath: NSTemporaryDirectory() + "gantry-shell-\(UUID().uuidString).json"
    )
    let parameters = SSHConnectionParameters(
        host: resolved.hostName,
        port: resolved.port,
        username: resolved.user ?? NSUserName(),
        auth: .key(key)
    )

    let shell = SSHHostShell(makeClient: {
        try await SSHConnector.connect(
            parameters: parameters,
            policy: .acceptKnown(store, onUnknown: { _, _ in .trust })
        )
    })

    let marker = "gantry-shell-\(UUID().uuidString.prefix(8))"
    shell.send(Data("echo \(marker)\n".utf8))

    var transcript = ""
    var sawMarker = false
    for try await chunk in shell.bytes {
        transcript += String(decoding: chunk, as: UTF8.self)
        // The echo command itself is in the transcript too (PTY echo); require
        // the marker on its own line to prove the shell executed it.
        if transcript.contains("\n") || transcript.contains("\r") {
            let lines = transcript.split(whereSeparator: \.isNewline)
            if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == marker }) {
                sawMarker = true
                break
            }
        }
    }
    #expect(sawMarker, "expected marker in shell output, got: \(transcript.suffix(400))")
    shell.terminate()
    print("LIVE SHELL: marker round-tripped")
}

/// SFTP host filesystem: list "/" and download a small file.
@Test(.enabled(if: liveSSHAvailable()), .timeLimit(.minutes(2)))
func liveHostFileSystem() async throws {
    let resolved = SSHConfig.resolve(host: liveHost)
    let key = try SSHKeyLoader.load(contentsOf: testKeyPath, passphrase: nil)
    let store = KnownHostsStore(
        appStorePath: NSTemporaryDirectory() + "gantry-sftp-\(UUID().uuidString).json"
    )
    let parameters = SSHConnectionParameters(
        host: resolved.hostName,
        port: resolved.port,
        username: resolved.user ?? NSUserName(),
        auth: .key(key)
    )

    let fs = SSHHostFileSystem(makeClient: {
        try await SSHConnector.connect(
            parameters: parameters,
            policy: .acceptKnown(store, onUnknown: { _, _ in .trust })
        )
    })

    let root = try await fs.listDirectory("/")
    #expect(!root.isEmpty)
    #expect(root.contains { $0.name == "etc" && $0.isDirectory })

    final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        func append(_ data: Data) { lock.lock(); storage.append(data); lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    }
    let downloaded = DataBox()
    try await fs.downloadFile("/etc/hostname") { chunk in
        downloaded.append(chunk)
    }
    #expect(!downloaded.data.isEmpty)
    print("LIVE SFTP: \(root.count) root entries, hostname=\(String(decoding: downloaded.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
    await fs.close()
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
            policy: .acceptKnown(store, onUnknown: { _, _ in .trust })
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

// MARK: - ProxyJump

/// An ssh_config alias whose entry carries `ProxyJump` and whose target runs
/// Docker — proves the bastion-tunneled dial end to end.
private let jumpAlias = ProcessInfo.processInfo.environment["GANTRY_SSH_TEST_JUMP_HOST"] ?? ""

/// Loads every readable key from the given paths plus the ~/.ssh defaults.
/// GANTRY_SSH_TEST_JUMP_SINGLE_KEY=1 narrows to ~/.ssh/id_rsa to isolate
/// multi-key offer issues from jump-path issues.
private func loadableKeys(_ identityFiles: [String]) -> [LoadedKey] {
    if ProcessInfo.processInfo.environment["GANTRY_SSH_TEST_JUMP_SINGLE_KEY"] == "1",
       let key = try? SSHKeyLoader.load(contentsOf: rsaKeyPath, passphrase: nil) {
        return [key]
    }
    var keys: [LoadedKey] = []
    for path in identityFiles + SSHKeyLoader.defaultKeyCandidates() {
        if let key = try? SSHKeyLoader.load(contentsOf: path, passphrase: nil) {
            keys.append(key)
        }
    }
    return keys
}

@Test(.enabled(if: !jumpAlias.isEmpty), .timeLimit(.minutes(2)))
func proxyJumpDockerNegotiate() async throws {
    let resolved = SSHConfig.resolve(host: jumpAlias)
    try #require(!resolved.jumps.isEmpty, "\(jumpAlias) has no ProxyJump in ssh_config")

    let store = KnownHostsStore(
        appStorePath: NSTemporaryDirectory() + "gantry-jump-\(UUID().uuidString).json"
    )
    let parameters = SSHConnectionParameters(
        host: resolved.hostName,
        port: resolved.port,
        username: resolved.user ?? NSUserName(),
        auth: .keys(loadableKeys(resolved.identityFiles)),
        jumps: resolved.jumps.map { hop in
            SSHJumpHop(
                host: hop.hostName,
                port: hop.port,
                username: hop.user ?? NSUserName(),
                auth: .keys(loadableKeys(hop.identityFiles))
            )
        }
    )
    let policy = HostKeyPolicy.acceptKnown(store, onUnknown: { host, candidate in
        print("LIVE JUMP: trusting \(host) \(candidate.keyType) \(candidate.fingerprintSHA256)")
        return .trust
    })

    let transport = SSHDialStdioTransport(makeClient: {
        try await SSHConnector.connect(parameters: parameters, policy: policy)
    })
    let client = DockerClient(transport: transport)

    let version = try await client.negotiate()
    print("LIVE JUMP: through \(resolved.jumps.map(\.hostName).joined(separator: " → ")) to \(resolved.hostName): Docker \(version.version), api \(version.apiVersion)")
    #expect(!version.apiVersion.isEmpty)

    let containers = try await client.listContainers(all: true)
    print("LIVE JUMP: \(containers.count) containers visible")

    await client.shutdown()
}

/// Direct (no jump) multi-key probe: offers a key the server rejects, then
/// one it accepts, over a single connection. Proves the second offer of
/// MultiKeyAuthDelegate against a real sshd.
@Test(.enabled(if: !jumpAlias.isEmpty), .timeLimit(.minutes(2)))
func multiKeySecondOfferLive() async throws {
    let resolved = SSHConfig.resolve(host: jumpAlias)
    let bastion = try #require(resolved.jumps.first)

    let rejected = try SSHKeyLoader.load(
        contentsOf: NSHomeDirectory() + "/.ssh/gantry_ed25519", passphrase: nil
    )
    let accepted = try SSHKeyLoader.load(contentsOf: rsaKeyPath, passphrase: nil)

    let store = KnownHostsStore(
        appStorePath: NSTemporaryDirectory() + "gantry-mk-\(UUID().uuidString).json"
    )
    let client = try await SSHConnector.connect(
        parameters: SSHConnectionParameters(
            host: bastion.hostName,
            port: bastion.port,
            username: bastion.user ?? NSUserName(),
            auth: .keys([rejected, accepted])
        ),
        policy: .acceptKnown(store, onUnknown: { _, _ in .trust })
    )
    print("LIVE MULTIKEY: second offer accepted by \(bastion.hostName)")
    try await client.close()
}
