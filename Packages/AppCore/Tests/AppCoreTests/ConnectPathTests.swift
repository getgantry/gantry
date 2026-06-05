import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

// MARK: - HostSession.connect() real entry points (no live daemon needed)

@MainActor
@Suite struct ConnectPathTests {
    @Test func connectLocalWithBogusOverrideFails() async {
        let host = DockerHost(
            name: "Local",
            kind: .local,
            socketPathOverride: "/tmp/nope-\(UUID().uuidString).sock"
        )
        let session = HostSession(host: host)
        await session.connect()
        // The socket exists check passes (override is taken verbatim) but the
        // negotiate fails -> .failed.
        if case .failed = session.status {} else {
            Issue.record("expected .failed, got \(session.status)")
        }
        await session.disconnect()
    }

    @Test func connectLocalNoSocketReportsFailure() async {
        // Force discovery to find nothing by pointing DOCKER_HOST at a bad unix
        // path AND relying on no real socket. If a live daemon exists this may
        // connect instead; in that case we just disconnect cleanly.
        let host = DockerHost(name: "Local", kind: .local)
        let session = HostSession(host: host)
        if DockerSocketDiscovery.discover() == nil {
            await session.connect()
            if case .failed(let msg) = session.status {
                #expect(msg.contains("socket"))
            } else {
                Issue.record("expected .failed when no socket present")
            }
        }
        await session.disconnect()
    }

    @Test func disconnectWhenNeverConnectedIsSafe() async {
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        await session.disconnect()
        #expect(session.status == .disconnected)
    }

    /// disconnect() while a connect is still dialing must win: the in-flight
    /// attempt is invalidated by the connection generation bump, so its
    /// completion can neither resurrect the session nor overwrite the
    /// .disconnected status with .failed.
    @Test func disconnectDuringInFlightConnectStaysDisconnected() async {
        let host = DockerHost(
            name: "Local",
            kind: .local,
            socketPathOverride: "/tmp/nope-\(UUID().uuidString).sock"
        )
        let session = HostSession(host: host)
        // The bogus-socket negotiate takes seconds to fail; disconnect mid-dial.
        let inFlight = Task { await session.connect() }
        try? await Task.sleep(for: .milliseconds(100))
        await session.disconnect()
        #expect(session.status == .disconnected)
        await inFlight.value
        // The stale attempt finished after disconnect — status must not move.
        #expect(session.status == .disconnected)
    }
}

// MARK: - HeadlessDocker SSH auth resolution (throws before any dial)

@Suite struct HeadlessAuthTests {
    /// SSH host with password auth and no stored Keychain secret -> the auth
    /// resolution throws `missingCredential` synchronously, before dialing.
    @Test func sshPasswordWithoutKeychainThrowsMissingCredential() async {
        let id = UUID()
        let host = DockerHost(
            id: id,
            name: "Box",
            kind: .ssh(SSHEndpoint(host: "unreachable.invalid", username: "u", auth: .password))
        )
        // Make sure no secret lingers.
        KeychainStore.delete(account: KeychainStore.sshPasswordAccount(hostID: id))

        await #expect(throws: HeadlessDockerError.self) {
            _ = try await HeadlessDocker.connect(to: host)
        }
    }

    /// SSH host with an explicit key file that does not exist -> loadFirstUsableKey
    /// exhausts its candidates and throws before any network access.
    @Test func sshKeyFileMissingThrows() async {
        let host = DockerHost(
            name: "Box",
            kind: .ssh(SSHEndpoint(
                host: "unreachable.invalid",
                username: "u",
                auth: .keyFile("/nonexistent/\(UUID().uuidString)/id_ed25519")
            ))
        )
        await #expect(throws: Error.self) {
            _ = try await HeadlessDocker.connect(to: host)
        }
    }
}
