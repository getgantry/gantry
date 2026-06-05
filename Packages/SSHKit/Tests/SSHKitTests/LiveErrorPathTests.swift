import Testing
import Foundation
import DockerKit
@testable import SSHKit

/// Live error-path tests against the real SSH host. These exercise the parts of
/// `SSHConnector` (error mapping), `SSHDialStdioTransport` (dial-stdio failures,
/// shutdown idempotence), `SSHHostShell` and `SSHHostFileSystem` (failure
/// branches) that the happy-path live suite does not reach.
///
/// Gated identically to LiveSSHTests: GANTRY_SSH_TEST_HOST + the ed25519 key.

private let liveHost = ProcessInfo.processInfo.environment["GANTRY_SSH_TEST_HOST"] ?? ""

private let testKeyPath = ProcessInfo.processInfo.environment["GANTRY_SSH_TEST_KEY"]
    ?? NSHomeDirectory() + "/.ssh/gantry_test_ed25519"

private func hostReachable() -> Bool {
    guard !liveHost.isEmpty else { return false }
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

/// Builds connection parameters for the live host with the ed25519 test key.
private func liveParameters() throws -> SSHConnectionParameters {
    let resolved = SSHConfig.resolve(host: liveHost)
    let key = try SSHKeyLoader.load(contentsOf: testKeyPath, passphrase: nil)
    return SSHConnectionParameters(
        host: resolved.hostName,
        port: resolved.port,
        username: resolved.user ?? NSUserName(),
        auth: .key(key)
    )
}

private func autoTrustStore(_ tag: String) -> KnownHostsStore {
    KnownHostsStore(appStorePath: NSTemporaryDirectory() + "gantry-\(tag)-\(UUID().uuidString).json")
}

/// A store fully isolated from the user's real `~/.ssh/known_hosts`, so the live
/// host's already-trusted system key cannot short-circuit unknown/mismatch
/// host-key flows. Returns the store and the temp paths to clean up.
private func isolatedStore(_ tag: String) -> (store: KnownHostsStore, appPath: String, systemPath: String) {
    let appPath = NSTemporaryDirectory() + "gantry-\(tag)-app-\(UUID().uuidString).json"
    let systemPath = NSTemporaryDirectory() + "gantry-\(tag)-sys-\(UUID().uuidString)"
    // An empty system known_hosts so nothing is implicitly trusted.
    FileManager.default.createFile(atPath: systemPath, contents: Data())
    return (
        KnownHostsStore(appStorePath: appPath, systemKnownHosts: systemPath),
        appPath,
        systemPath
    )
}

// MARK: - SSHConnector error mapping

/// A bad TCP port that no SSH server listens on maps to `.unreachable`
/// (connection refused) without needing DNS to fail.
@Test(.enabled(if: liveSSHAvailable()), .timeLimit(.minutes(2)))
func connectUnreachablePortMapsToUnreachable() async throws {
    let resolved = SSHConfig.resolve(host: liveHost)
    let key = try SSHKeyLoader.load(contentsOf: testKeyPath, passphrase: nil)
    let parameters = SSHConnectionParameters(
        host: resolved.hostName,
        port: 1,  // nothing listens here
        username: resolved.user ?? NSUserName(),
        auth: .key(key)
    )
    let store = autoTrustStore("unreach")

    do {
        _ = try await SSHConnector.connect(
            parameters: parameters,
            policy: .acceptKnown(store, onUnknown: { _, _ in .trust })
        )
        Issue.record("expected connect to a dead port to fail")
    } catch let error as SSHConnectError {
        guard case .unreachable = error else {
            Issue.record("expected .unreachable, got \(error)")
            return
        }
    }
}

/// An unresolvable hostname maps to `.unreachable` (name-resolution failure).
@Test(.enabled(if: liveSSHAvailable()), .timeLimit(.minutes(2)))
func connectUnresolvableHostMapsToUnreachable() async throws {
    let key = try SSHKeyLoader.load(contentsOf: testKeyPath, passphrase: nil)
    let parameters = SSHConnectionParameters(
        host: "no-such-host.invalid.gantry.test",
        port: 22,
        username: "tester",
        auth: .key(key)
    )
    let store = autoTrustStore("dns")

    do {
        _ = try await SSHConnector.connect(
            parameters: parameters,
            policy: .acceptKnown(store, onUnknown: { _, _ in .trust })
        )
        Issue.record("expected connect to an unresolvable host to fail")
    } catch let error as SSHConnectError {
        guard case .unreachable = error else {
            Issue.record("expected .unreachable, got \(error)")
            return
        }
    }
}

/// Wrong credentials against the real SSH server map to `.authenticationFailed`.
/// Uses a freshly generated, unauthorized ed25519 key.
@Test(.enabled(if: liveSSHAvailable()), .timeLimit(.minutes(2)))
func connectBadKeyMapsToAuthenticationFailed() async throws {
    // Generate a throwaway key the server does not authorize.
    let dir = NSTemporaryDirectory()
    let keyPath = (dir as NSString).appendingPathComponent("gantry-badkey-\(UUID().uuidString)")
    let keygen = Process()
    keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    keygen.arguments = ["-t", "ed25519", "-N", "", "-f", keyPath, "-q"]
    keygen.standardOutput = FileHandle.nullDevice
    keygen.standardError = FileHandle.nullDevice
    try keygen.run()
    keygen.waitUntilExit()
    defer {
        try? FileManager.default.removeItem(atPath: keyPath)
        try? FileManager.default.removeItem(atPath: keyPath + ".pub")
    }
    try #require(keygen.terminationStatus == 0)

    let resolved = SSHConfig.resolve(host: liveHost)
    let key = try SSHKeyLoader.load(contentsOf: keyPath, passphrase: nil)
    let parameters = SSHConnectionParameters(
        host: resolved.hostName,
        port: resolved.port,
        username: resolved.user ?? NSUserName(),
        auth: .key(key)
    )
    let store = autoTrustStore("badauth")

    do {
        _ = try await SSHConnector.connect(
            parameters: parameters,
            policy: .acceptKnown(store, onUnknown: { _, _ in .trust })
        )
        Issue.record("expected unauthorized key to fail authentication")
    } catch let error as SSHConnectError {
        guard case .authenticationFailed = error else {
            Issue.record("expected .authenticationFailed, got \(error)")
            return
        }
    }
}

/// The user declining an unknown host key surfaces `.hostKeyRejected`.
@Test(.enabled(if: liveSSHAvailable()), .timeLimit(.minutes(2)))
func connectUserRejectsHostKeyMapsToHostKeyRejected() async throws {
    let parameters = try liveParameters()
    // Isolated store => the real host key is unknown => prompt fires => reject.
    let (store, appPath, systemPath) = isolatedStore("reject")
    defer {
        try? FileManager.default.removeItem(atPath: appPath)
        try? FileManager.default.removeItem(atPath: systemPath)
    }

    do {
        _ = try await SSHConnector.connect(
            parameters: parameters,
            policy: .acceptKnown(store, onUnknown: { _, _ in .reject })
        )
        Issue.record("expected host-key rejection to fail the connect")
    } catch let error as SSHConnectError {
        guard case .hostKeyRejected = error else {
            Issue.record("expected .hostKeyRejected, got \(error)")
            return
        }
    }
}

/// A pre-seeded mismatching host key for the live host surfaces
/// `HostKeyMismatchError` (flows through `mapConnectError` untouched).
@Test(.enabled(if: liveSSHAvailable()), .timeLimit(.minutes(2)))
func connectHostKeyMismatchSurfacesMismatchError() async throws {
    let resolved = SSHConfig.resolve(host: liveHost)
    let key = try SSHKeyLoader.load(contentsOf: testKeyPath, passphrase: nil)
    let parameters = SSHConnectionParameters(
        host: resolved.hostName,
        port: resolved.port,
        username: resolved.user ?? NSUserName(),
        auth: .key(key)
    )

    // Seed an isolated app store with a bogus ed25519 key for this host so the
    // real server key (also ed25519) is a same-algorithm mismatch. The system
    // known_hosts is isolated to an empty file so the real trusted key cannot
    // short-circuit to .trusted.
    let (store, appPath, systemPath) = isolatedStore("mismatch")
    defer {
        try? FileManager.default.removeItem(atPath: appPath)
        try? FileManager.default.removeItem(atPath: systemPath)
    }
    let bogus = HostKeyCandidate(
        keyType: "ssh-ed25519",
        base64: "AAAAC3NzaC1lZDI1NTE5AAAAIFR3OdStNkl4oJzrg2zguLPFegCHdqMTg1NQ3Ye2NQ2L"
    )
    store.persist(host: resolved.hostName, port: resolved.port, candidate: bogus)

    await #expect(throws: HostKeyMismatchError.self) {
        _ = try await SSHConnector.connect(
            parameters: parameters,
            policy: .acceptKnown(store, onUnknown: { _, _ in .trust })
        )
    }
}

// MARK: - Transport dial-stdio failure + shutdown idempotence

/// A bogus dial command exits non-zero on the remote, so the first `execute`
/// fails with the remote stderr surfaced. Then a second `shutdown()` proves
/// shutdown is idempotent (no client, no tunnels left).
@Test(.enabled(if: liveSSHAvailable()), .timeLimit(.minutes(2)))
func transportBadDialCommandSurfacesRemoteError() async throws {
    let parameters = try liveParameters()
    let store = autoTrustStore("baddial")

    let transport = SSHDialStdioTransport(
        makeClient: {
            try await SSHConnector.connect(
                parameters: parameters,
                policy: .acceptKnown(store, onUnknown: { _, _ in .trust })
            )
        },
        dialCommand: "this-command-does-not-exist-gantry 1>&2; exit 127"
    )

    await #expect(throws: (any Error).self) {
        _ = try await transport.execute(DockerRequest(method: .get, path: "/_ping"))
    }

    // Shutdown twice: must not crash and must be safe with no live client.
    await transport.shutdown()
    await transport.shutdown()
}

/// `shutdown()` on a transport that never connected is a no-op and idempotent.
@Test(.timeLimit(.minutes(1)))
func transportShutdownWithoutConnectIsNoOp() async {
    let transport = SSHDialStdioTransport(makeClient: {
        throw DockerError.connectionFailed("never called")
    })
    await transport.shutdown()
    await transport.shutdown()
}

/// `makeClient` throwing a `DockerError` propagates that error unchanged from
/// `execute` (the transport rethrows DockerError without wrapping).
@Test(.timeLimit(.minutes(1)))
func transportMakeClientFailurePropagates() async {
    let transport = SSHDialStdioTransport(makeClient: {
        throw DockerError.connectionFailed("boom from factory")
    })
    await #expect(throws: DockerError.self) {
        _ = try await transport.execute(DockerRequest(method: .get, path: "/_ping"))
    }
    await transport.shutdown()
}

/// `execute` against a non-existent endpoint returns a bounded 404 response
/// (head + body + end) without hanging; exercises the buffered execute path's
/// non-2xx handling and tunnel reuse afterwards.
@Test(.enabled(if: liveSSHAvailable()), .timeLimit(.minutes(2)))
func transportExecuteUnknownEndpointReturns404() async throws {
    let parameters = try liveParameters()
    let store = autoTrustStore("exec404")
    let transport = SSHDialStdioTransport(makeClient: {
        try await SSHConnector.connect(
            parameters: parameters,
            policy: .acceptKnown(store, onUnknown: { _, _ in .trust })
        )
    })

    let response = try await transport.execute(
        DockerRequest(method: .get, path: "/v1.40/no/such/endpoint")
    )
    #expect(response.status == 404)
    // The persistent tunnel is reusable for a follow-up request.
    let ping = try await transport.execute(DockerRequest(method: .get, path: "/_ping"))
    #expect(ping.status == 200)
    await transport.shutdown()
}

// MARK: - SSHHostShell failure path

/// A shell whose `makeClient` fails surfaces the error on the byte stream and
/// terminates cleanly.
@Test(.timeLimit(.minutes(1)))
func hostShellConnectFailurePropagatesOnStream() async {
    let shell = SSHHostShell(makeClient: {
        throw SSHConnectError.unreachable("no host for shell")
    })
    await #expect(throws: (any Error).self) {
        for try await _ in shell.bytes {}
    }
    // resize / terminate after failure must not crash.
    shell.resize(cols: 100, rows: 40)
    shell.terminate()
}

// MARK: - SSHHostFileSystem failure paths

/// A filesystem whose `makeClient` fails surfaces the error from listDirectory
/// and a subsequent close is safe.
@Test(.timeLimit(.minutes(1)))
func hostFileSystemConnectFailurePropagates() async {
    let fs = SSHHostFileSystem(makeClient: {
        throw SSHConnectError.unreachable("no host for sftp")
    })
    await #expect(throws: (any Error).self) {
        _ = try await fs.listDirectory("/")
    }
    await fs.close()
}

/// Listing a non-existent directory over a real SFTP connection throws; then a
/// download of a non-existent file throws; close releases the connection.
@Test(.enabled(if: liveSSHAvailable()), .timeLimit(.minutes(2)))
func hostFileSystemErrorPathsOverLiveSFTP() async throws {
    let parameters = try liveParameters()
    let store = autoTrustStore("sftperr")
    let fs = SSHHostFileSystem(makeClient: {
        try await SSHConnector.connect(
            parameters: parameters,
            policy: .acceptKnown(store, onUnknown: { _, _ in .trust })
        )
    })

    await #expect(throws: (any Error).self) {
        _ = try await fs.listDirectory("/no/such/gantry/dir/\(UUID().uuidString)")
    }
    await #expect(throws: (any Error).self) {
        try await fs.downloadFile("/no/such/gantry/file/\(UUID().uuidString)") { _ in }
    }
    // The connection survived the SFTP-level errors; a valid listing still works.
    let root = try await fs.listDirectory("/")
    #expect(!root.isEmpty)
    await fs.close()
}

/// Host shell resize over a real PTY: open, resize, run a command, then close.
/// Exercises the `.resize` command branch in SSHHostShell.
@Test(.enabled(if: liveSSHAvailable()), .timeLimit(.minutes(2)))
func hostShellResizeOverLivePTY() async throws {
    let parameters = try liveParameters()
    let store = autoTrustStore("shellresize")
    let shell = SSHHostShell(makeClient: {
        try await SSHConnector.connect(
            parameters: parameters,
            policy: .acceptKnown(store, onUnknown: { _, _ in .trust })
        )
    })

    shell.resize(cols: 120, rows: 40)
    let marker = "gantry-resize-\(UUID().uuidString.prefix(8))"
    shell.send(Data("echo \(marker)\n".utf8))

    var sawMarker = false
    var transcript = ""
    for try await chunk in shell.bytes {
        transcript += String(decoding: chunk, as: UTF8.self)
        let lines = transcript.split(whereSeparator: \.isNewline)
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == marker }) {
            sawMarker = true
            break
        }
    }
    #expect(sawMarker)
    shell.terminate()
}
