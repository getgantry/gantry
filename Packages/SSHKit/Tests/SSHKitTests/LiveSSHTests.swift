import Testing
import Foundation
import DockerKit
@testable import SSHKit

/// Live end-to-end test against a real SSH Docker host.
/// Gated: runs only when ~/.ssh/id_rsa exists and nettop.local:22 is reachable.
private let liveHost = "nettop.local"

/// Dedicated test key: Citadel signs RSA as legacy ssh-rsa (SHA-1), which
/// modern sshd rejects, so the live test uses an ed25519 key.
private let testKeyPath = NSHomeDirectory() + "/.ssh/gantry_test_ed25519"

private func liveSSHAvailable() -> Bool {
    guard FileManager.default.fileExists(atPath: testKeyPath) else { return false }

    // Cheap TCP reachability probe with a short deadline.
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
