import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

// MARK: - DockerHost.Kind.appleContainer

@Suite struct AppleContainerHostTests {
    @Test func flags() {
        let host = DockerHost(name: "Apple Container", kind: .appleContainer)
        #expect(!host.isLocal)
        #expect(!host.isSSH)
        #expect(host.isAppleContainer)
        #expect(host.removable)
        #expect(host.badgeSystemImage == "apple.logo")
    }

    @Test func dockerHostFlagsUnchanged() {
        #expect(!DockerHost(name: "L", kind: .local).isAppleContainer)
        #expect(DockerHost(name: "L", kind: .local).badgeSystemImage == nil)
        let ssh = DockerHost(name: "S", kind: .ssh(SSHEndpoint(host: "h")))
        #expect(ssh.isSSH)
        #expect(!ssh.isAppleContainer)
        #expect(ssh.badgeSystemImage == "network")
    }

    @Test func codableRoundTrip() throws {
        let host = DockerHost(
            name: "Apple Container",
            kind: .appleContainer,
            socketPathOverride: "/opt/homebrew/bin/container"
        )
        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(DockerHost.self, from: data)
        #expect(decoded == host)
        #expect(decoded.kind == .appleContainer)
        #expect(decoded.socketPathOverride == "/opt/homebrew/bin/container")
    }

    /// Hosts persisted by older app versions must keep decoding after the
    /// enum gained a case (and a persisted apple host has a stable shape).
    @Test func legacyHostsStillDecode() throws {
        let legacy = Data("""
        [
          {"id":"7C2EB1B0-0000-0000-0000-000000000001","name":"Local","kind":{"local":{}}},
          {"id":"7C2EB1B0-0000-0000-0000-000000000002","name":"Box",
           "kind":{"ssh":{"_0":{"host":"box.local","port":22,"username":"me","auth":{"automatic":{}}}}}},
          {"id":"7C2EB1B0-0000-0000-0000-000000000003","name":"Apple","kind":{"appleContainer":{}}}
        ]
        """.utf8)
        let hosts = try JSONDecoder().decode([DockerHost].self, from: legacy)
        #expect(hosts.count == 3)
        #expect(hosts[0].isLocal)
        #expect(hosts[1].isSSH)
        #expect(hosts[2].isAppleContainer)
    }

    // MARK: Capabilities

    @Test func capabilitiesPerKind() {
        let docker = DockerHost(name: "L", kind: .local).capabilities
        #expect(docker == .docker)
        #expect(docker.pauseResume && docker.renameContainer && docker.commitContainer)
        #expect(docker.restartPolicy && docker.networkAttach && docker.buildCachePrune)
        #expect(docker.imageHistory && docker.containerFileTransfer)

        let ssh = DockerHost(name: "S", kind: .ssh(SSHEndpoint(host: "h"))).capabilities
        #expect(ssh == .docker)

        let apple = DockerHost(name: "A", kind: .appleContainer).capabilities
        #expect(apple == .appleContainer)
        #expect(!apple.pauseResume && !apple.renameContainer && !apple.commitContainer)
        #expect(!apple.restartPolicy && !apple.networkAttach && !apple.buildCachePrune)
        #expect(!apple.imageHistory && !apple.containerFileTransfer)
    }

    // MARK: Connect path

    @Test @MainActor func connectFailsClearlyWithoutCLI() async {
        // A bogus CLI path override means discovery fails and the session
        // must land in .failed with installation guidance, not crash or hang.
        let host = DockerHost(
            name: "Apple",
            kind: .appleContainer,
            socketPathOverride: "/nonexistent/gantry-test/container"
        )
        let session = HostSession(host: host)
        await session.connect()
        guard case .failed(let message) = session.status else {
            Issue.record("expected .failed, got \(session.status)")
            return
        }
        #expect(message.contains("brew install container"))
        #expect(!session.supportsHostAccess)
    }

    @Test func headlessConnectFailsClearlyWithoutCLI() async {
        let host = DockerHost(
            name: "Apple",
            kind: .appleContainer,
            socketPathOverride: "/nonexistent/gantry-test/container"
        )
        do {
            _ = try await AppCore.HeadlessDocker.connect(to: host)
            Issue.record("expected HeadlessDockerError")
        } catch let HeadlessDockerError.connectionFailed(message) {
            #expect(message.contains("brew install container"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: Copy-as-Prompt

    @Test func containerPromptDescribesAppleHost() throws {
        let host = DockerHost(name: "Apple Container", kind: .appleContainer)
        let container = try JSONDecoder().decode(
            ContainerSummary.self,
            from: Data("""
            {"Id":"web-1","Names":["/web-1"],"Image":"alpine:latest","State":"running","Status":"Up"}
            """.utf8)
        )
        let prompt = ContainerPrompt.build(host: host, container: container)
        #expect(prompt.contains("apple/container on this Mac"))
        #expect(prompt.contains("`container` CLI"))
        #expect(!prompt.contains("ssh "))
        #expect(prompt.contains(host.id.uuidString))
    }
}
