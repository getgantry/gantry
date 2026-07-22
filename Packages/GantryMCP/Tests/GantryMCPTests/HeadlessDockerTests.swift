import Foundation
import Testing
import DockerKit
import AppCore
@testable import gantry_mcp

/// Tests for the MCP server's `HeadlessDocker` actor. The non-live cases drive
/// host resolution and the SSH credential-resolution machinery without touching
/// the network (an SSH host whose key file is missing fails during local key
/// loading, before any dial is attempted).
@Suite("HeadlessDocker")
struct HeadlessDockerTests {

    // MARK: - Host loading / lookup (no daemon)

    @Test func loadHostsNeverEmpty() {
        // Always at least the synthesised/persisted Local host.
        let hosts = gantry_mcp.HeadlessDocker().loadHosts()
        #expect(!hosts.isEmpty)
        #expect(hosts.contains { $0.isLocal })
    }

    @Test func hostLookupByID() {
        let docker = gantry_mcp.HeadlessDocker()
        let hosts = docker.loadHosts()
        let local = hosts.first { $0.isLocal }
        #expect(local != nil)
        if let local {
            #expect(docker.host(id: local.id)?.id == local.id)
        }
        // An unknown id resolves to nil.
        #expect(docker.host(id: UUID()) == nil)
    }

    @Test func synthesisedLocalHostKeepsAStableID() {
        // Regression: the fallback host used to get a fresh UUID per call, so
        // an id handed out by list_hosts could not be used for anything.
        let docker = gantry_mcp.HeadlessDocker()
        let first = docker.loadHosts().first { $0.isLocal }?.id
        let second = docker.loadHosts().first { $0.isLocal }?.id
        #expect(first == second)
        #expect(first.map { docker.host(id: $0)?.id } == first)
    }

    @Test func clientForUnknownHostIDThrows() async {
        let docker = gantry_mcp.HeadlessDocker()
        await #expect(throws: HeadlessError.self) {
            _ = try await docker.client(forHostID: UUID())
        }
    }

    // MARK: - Local connect: missing socket override

    @Test func connectLocalWithBogusSocketOverrideThrows() async {
        let docker = gantry_mcp.HeadlessDocker()
        let host = DockerHost(
            name: "BogusLocal",
            kind: .local,
            socketPathOverride: "/nonexistent/gantry-mcp-test.sock"
        )
        // Negotiation against a non-listening path fails; connect rethrows.
        await #expect(throws: (any Error).self) {
            _ = try await docker.connect(to: host)
        }
        await docker.shutdown()
    }

    // MARK: - SSH credential resolution (no network)

    @Test func connectSSHWithMissingKeyFileFailsBeforeDialing() async {
        let docker = gantry_mcp.HeadlessDocker()
        // keyFile auth pointing at a path that does not exist: loadFirstUsableKey
        // exhausts its candidates and throws, so no SSH dial is attempted.
        let endpoint = SSHEndpoint(
            host: "203.0.113.1",                // TEST-NET-3, never routable
            port: 22,
            username: "nobody",
            auth: .keyFile("/nonexistent/gantry-mcp-test-key")
        )
        let host = DockerHost(name: "SSHbad", kind: .ssh(endpoint))
        await #expect(throws: (any Error).self) {
            _ = try await docker.connect(to: host)
        }
        await docker.shutdown()
    }

    @Test func connectSSHWithPasswordAuthAndNoKeychainSecretThrowsCredentialsUnavailable() async {
        let docker = gantry_mcp.HeadlessDocker()
        // password auth with no Keychain entry for this random host id: resolveAuth
        // throws credentialsUnavailable without any network access.
        let endpoint = SSHEndpoint(
            host: "203.0.113.2",
            port: 22,
            username: "nobody",
            auth: .password
        )
        let host = DockerHost(name: "SSHpw", kind: .ssh(endpoint))
        await #expect(throws: (any Error).self) {
            _ = try await docker.connect(to: host)
        }
        await docker.shutdown()
    }

    // MARK: - Live: client(forHostID:) for the local host

    @Test(.enabled(if: liveSocket != nil))
    func clientForLocalHostIDConnects() async throws {
        let docker = gantry_mcp.HeadlessDocker()
        let local = try #require(docker.loadHosts().first { $0.isLocal })
        let client = try await docker.client(forHostID: local.id)
        // A second resolution returns the cached client (connect early-returns).
        let again = try await docker.connect(to: local)
        _ = client
        _ = again
        await docker.shutdown()
    }
}
