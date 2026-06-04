import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

// MARK: - DockerHost / SSHEndpoint Codable

@Suite struct DockerHostTests {
    @Test func localHostFlags() {
        let host = DockerHost(name: "Local", kind: .local)
        #expect(host.isLocal)
        #expect(!host.removable)
    }

    @Test func sshHostFlags() {
        let host = DockerHost(name: "Box", kind: .ssh(SSHEndpoint(host: "h")))
        #expect(!host.isLocal)
        #expect(host.removable)
    }

    @Test func roundTripLocal() throws {
        let host = DockerHost(name: "Local", kind: .local, socketPathOverride: "/x.sock")
        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(DockerHost.self, from: data)
        #expect(decoded == host)
        #expect(decoded.socketPathOverride == "/x.sock")
    }

    @Test func roundTripSSHAllAuthModes() throws {
        let modes: [SSHAuthMode] = [.automatic, .keyFile("/k"), .password]
        for mode in modes {
            let host = DockerHost(
                name: "B",
                kind: .ssh(SSHEndpoint(host: "h", port: 2222, username: "u", identityFile: "/i", auth: mode))
            )
            let data = try JSONEncoder().encode(host)
            let decoded = try JSONDecoder().decode(DockerHost.self, from: data)
            #expect(decoded == host)
        }
    }

    @Test func legacyEndpointDecodeFillsDefaults() throws {
        // Older persisted host: only `host` present. port->22, username->"",
        // identityFile->nil, auth->.automatic.
        let json = #"{"host":"legacy.example"}"#
        let endpoint = try JSONDecoder().decode(SSHEndpoint.self, from: Data(json.utf8))
        #expect(endpoint.host == "legacy.example")
        #expect(endpoint.port == 22)
        #expect(endpoint.username == "")
        #expect(endpoint.identityFile == nil)
        #expect(endpoint.auth == .automatic)
    }

    @Test func endpointDecodeWithNullPortFallsBack() throws {
        let json = #"{"host":"h","username":"bob","port":0}"#
        let endpoint = try JSONDecoder().decode(SSHEndpoint.self, from: Data(json.utf8))
        #expect(endpoint.username == "bob")
        #expect(endpoint.port == 0)
    }

    @Test func endpointEncodeIncludesAuth() throws {
        let endpoint = SSHEndpoint(host: "h", auth: .password)
        let data = try JSONEncoder().encode(endpoint)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["auth"] != nil)
        #expect(object?["host"] as? String == "h")
    }
}

// MARK: - ConnectionStatus

@Suite struct ConnectionStatusTests {
    private func version() -> SystemVersion {
        let json = #"{"Version":"27.0","ApiVersion":"1.47"}"#
        return try! JSONDecoder().decode(SystemVersion.self, from: Data(json.utf8))
    }

    @Test func isConnected() {
        #expect(ConnectionStatus.connected(version()).isConnected)
        #expect(!ConnectionStatus.disconnected.isConnected)
        #expect(!ConnectionStatus.connecting.isConnected)
        #expect(!ConnectionStatus.failed("x").isConnected)
    }

    @Test func shortDescriptions() {
        #expect(ConnectionStatus.disconnected.shortDescription == "Disconnected")
        #expect(ConnectionStatus.connecting.shortDescription == "Connecting…")
        #expect(ConnectionStatus.failed("boom").shortDescription == "Failed: boom")
        let connected = ConnectionStatus.connected(version()).shortDescription
        #expect(connected.contains("27.0"))
        #expect(connected.contains("1.47"))
    }

    @Test func equatable() {
        #expect(ConnectionStatus.disconnected == ConnectionStatus.disconnected)
        #expect(ConnectionStatus.failed("a") != ConnectionStatus.failed("b"))
    }
}

// MARK: - ContainerAction

@Suite struct ContainerActionTests {
    @Test func displayNames() {
        #expect(ContainerAction.start.displayName == "Start")
        #expect(ContainerAction.stop.displayName == "Stop")
        #expect(ContainerAction.restart.displayName == "Restart")
        #expect(ContainerAction.kill.displayName == "Kill")
        #expect(ContainerAction.pause.displayName == "Pause")
        #expect(ContainerAction.unpause.displayName == "Resume")
        #expect(ContainerAction.remove(force: true).displayName == "Remove")
    }

    @Test func systemImages() {
        #expect(ContainerAction.start.systemImage == "play.fill")
        #expect(ContainerAction.stop.systemImage == "stop.fill")
        #expect(ContainerAction.restart.systemImage == "arrow.clockwise")
        #expect(ContainerAction.kill.systemImage == "bolt.fill")
        #expect(ContainerAction.pause.systemImage == "pause.fill")
        #expect(ContainerAction.unpause.systemImage == "play")
        #expect(ContainerAction.remove(force: false).systemImage == "trash")
    }

    @Test func hashableDistinguishesForce() {
        #expect(ContainerAction.remove(force: true) != ContainerAction.remove(force: false))
    }
}

// MARK: - NetworkAttachedContainer.decode

@Suite struct NetworkAttachedContainerTests {
    @Test func decodesAndSorts() {
        let json = """
        {"Containers":{
          "id-zeta":{"Name":"zeta","IPv4Address":"10.0.0.2/24","IPv6Address":""},
          "id-alpha":{"Name":"alpha","IPv4Address":"10.0.0.3/24","IPv6Address":"fe80::1/64"}
        }}
        """
        let result = NetworkAttachedContainer.decode(fromInspect: Data(json.utf8))
        #expect(result.count == 2)
        #expect(result.first?.name == "alpha")
        #expect(result.first?.ipv4Address == "10.0.0.3/24")
        #expect(result.last?.ipv6Address == "")
    }

    @Test func emptyOnMissingContainers() {
        #expect(NetworkAttachedContainer.decode(fromInspect: Data("{}".utf8)).isEmpty)
    }

    @Test func emptyOnInvalidJSON() {
        #expect(NetworkAttachedContainer.decode(fromInspect: Data("not json".utf8)).isEmpty)
    }

    @Test func displayNameFallsBackToShortID() {
        let json = """
        {"Containers":{"0123456789abcdefxxxx":{"Name":"","IPv4Address":"","IPv6Address":""}}}
        """
        let result = NetworkAttachedContainer.decode(fromInspect: Data(json.utf8))
        #expect(result.first?.displayName == "0123456789ab")
    }
}

// MARK: - HostSession.prettyJSON

@MainActor
@Suite struct PrettyJSONTests {
    @Test func sortsAndIndents() {
        let input = Data(#"{"b":1,"a":2}"#.utf8)
        let pretty = HostSession.prettyJSON(from: input)
        // sorted keys -> "a" appears before "b"
        let aIndex = pretty.range(of: "\"a\"")!.lowerBound
        let bIndex = pretty.range(of: "\"b\"")!.lowerBound
        #expect(aIndex < bIndex)
        #expect(pretty.contains("\n"))
    }

    @Test func fallsBackToRawStringOnInvalidJSON() {
        let pretty = HostSession.prettyJSON(from: Data("plain text".utf8))
        #expect(pretty == "plain text")
    }
}

// MARK: - ContainerLoad value type

@Suite struct ContainerLoadTests {
    @Test func storesFields() {
        let load = ContainerLoad(cpuPercent: 12.5, memoryUsedBytes: 1024, sampled: 3)
        #expect(load.cpuPercent == 12.5)
        #expect(load.memoryUsedBytes == 1024)
        #expect(load.sampled == 3)
    }
}
