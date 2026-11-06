import Foundation
import Testing
@testable import AppCore
import DockerKit

@Suite struct PortInputTests {
    @Test func parsesPorts() {
        #expect(PortInput("") == .empty)
        #expect(PortInput("  ") == .empty)
        #expect(PortInput("22") == .valid(22))
        #expect(PortInput(" 2222 ") == .valid(2222))
        #expect(PortInput("65535").value == 65535)
        #expect(PortInput("1").value == 1)
    }

    @Test func rejectsBadPorts() {
        for text in ["0", "65536", "-1", "abc", "22a", "2 2", "٢٢", "99999999999999999999"] {
            #expect(PortInput(text) == .invalid, "\(text)")
            #expect(PortInput(text).message != nil)
        }
        #expect(PortInput("22").message == nil)
    }
}

@Suite struct SSHHostInputTests {
    @Test func acceptsHostNames() {
        for text in ["", "server.local", "192.168.1.10", "my-alias", "fe80::1"] {
            #expect(SSHHostInput.message(for: text) == nil, "\(text)")
        }
    }

    @Test func rejectsWhatIsNotAHost() {
        #expect(SSHHostInput.message(for: "ssh://server") != nil)
        #expect(SSHHostInput.message(for: "root@server") != nil)
        #expect(SSHHostInput.message(for: "my server") != nil)
    }
}

@Suite struct SSHConnectionSummaryTests {
    private func writeConfig(_ text: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gantry-ssh-config-\(UUID().uuidString)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test func resolvesAliasUserPortKeyAndJump() throws {
        let path = try writeConfig("""
        Host box
          HostName 203.0.113.7
          User deploy
          Port 2222
          IdentityFile ~/.ssh/box_ed25519
          ProxyJump jump

        Host jump
          HostName 198.51.100.1
          User hop
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let summary = SSHConnectionSummary(endpoint: SSHEndpoint(host: "box"), configPath: path)
        #expect(summary.destination == "deploy@203.0.113.7:2222")
        #expect(summary.key == "box_ed25519")
        #expect(summary.jumps == ["hop@198.51.100.1:22"])
    }

    @Test func typedValuesWin() throws {
        let path = try writeConfig("Host box\n  User deploy\n  Port 2222\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let endpoint = SSHEndpoint(host: "box", port: 2200, username: "me", auth: .keyFile("/keys/id_test"))
        let summary = SSHConnectionSummary(endpoint: endpoint, configPath: path)
        #expect(summary.destination == "me@box:2200")
        #expect(summary.key == "id_test")
        #expect(summary.jumps.isEmpty)
    }
}

/// Lets a test decide when and how a probe finishes.
@MainActor
private final class ProbeGate {
    private var continuations: [CheckedContinuation<ConnectionTest.State, Never>] = []
    private(set) var started = 0

    func probe(_ session: HostSession) async -> ConnectionTest.State {
        started += 1
        return await withCheckedContinuation { continuations.append($0) }
    }

    func finish(_ index: Int, with state: ConnectionTest.State) {
        continuations[index].resume(returning: state)
    }
}

@MainActor
@Suite struct ConnectionTestTests {
    private let host = DockerHost(name: "Probe", kind: .local, socketPathOverride: "/nonexistent/docker.sock")
    private let version = try! JSONDecoder().decode(SystemVersion.self, from: Data(#"{"Version":"27.3.1","ApiVersion":"1.47"}"#.utf8))

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func waitUntil(seconds: Int = 1, _ condition: () -> Bool) async {
        for _ in 0..<(seconds * 200) where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func reportsSuccess() async {
        let gate = ProbeGate()
        let test = ConnectionTest(probe: gate.probe)
        #expect(test.state == .idle)
        test.start(host)
        #expect(test.state == .testing)
        #expect(test.session != nil)
        await waitUntil { gate.started == 1 }
        gate.finish(0, with: .succeeded(version))
        await waitUntil { test.state != .testing }
        #expect(test.state == .succeeded(version))
        #expect(test.session == nil)
    }

    @Test func reportsFailure() async {
        let gate = ProbeGate()
        let test = ConnectionTest(probe: gate.probe)
        test.start(host)
        await waitUntil { gate.started == 1 }
        gate.finish(0, with: .failed("Permission denied"))
        await waitUntil { test.state != .testing }
        #expect(test.state == .failed("Permission denied"))
    }

    @Test func aNewRunDropsTheOldResult() async {
        let gate = ProbeGate()
        let test = ConnectionTest(probe: gate.probe)
        test.start(host)
        await waitUntil { gate.started == 1 }
        test.start(host)
        await waitUntil { gate.started == 2 }
        gate.finish(0, with: .failed("stale"))
        await settle()
        #expect(test.state == .testing)
        gate.finish(1, with: .succeeded(version))
        await waitUntil { test.state != .testing }
        #expect(test.state == .succeeded(version))
    }

    @Test func resetForgetsRunningAndFinishedTests() async {
        let gate = ProbeGate()
        let test = ConnectionTest(probe: gate.probe)
        test.start(host)
        await waitUntil { gate.started == 1 }
        test.reset()
        #expect(test.state == .idle)
        #expect(test.session == nil)
        gate.finish(0, with: .succeeded(version))
        await settle()
        #expect(test.state == .idle)

        test.start(host)
        await waitUntil { gate.started == 2 }
        gate.finish(1, with: .failed("no route"))
        await waitUntil { test.state != .testing }
        test.reset()
        #expect(test.state == .idle)
    }

    @Test func realProbeReportsAMissingSocket() async {
        let test = ConnectionTest()
        test.start(host)
        await waitUntil(seconds: 30) { test.state != .testing }
        guard case .failed(let message) = test.state else {
            Issue.record("expected a failure, got \(test.state)")
            return
        }
        #expect(!message.isEmpty)
    }
}
