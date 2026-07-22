import Foundation
import Testing
import DockerKit
@testable import AppCore

struct DebugShellTests {
    // MARK: - Sidecar spec

    @Test func sidecarJoinsProcessAndNetworkNamespaces() throws {
        let spec = DebugShell.sidecarSpec(target: "abc123", image: "toolbox:1")
        let host = try #require(spec.hostConfig)
        // PID gives the target's processes and, through /proc/1/root, its
        // filesystem; network makes localhost the target's own listener.
        #expect(host.pidMode == "container:abc123")
        #expect(host.networkMode == "container:abc123")
        #expect(host.capAdd == ["SYS_PTRACE"])
    }

    @Test func sidecarDoesNotJoinTheIPCNamespace() throws {
        // Regression, caught live: Docker gives containers a private IPC
        // namespace unless they opted into `shareable`, so requesting it fails
        // the create outright with "non-shareable IPC" on ordinary containers.
        let spec = DebugShell.sidecarSpec(target: "abc123", image: "toolbox:1")
        #expect(try #require(spec.hostConfig).ipcMode == nil)
    }

    @Test func sidecarIdlesSoTheShellCanArriveLater() {
        // The shell is a separate exec, so the sidecar itself must stay up.
        let spec = DebugShell.sidecarSpec(target: "abc123", image: "toolbox:1")
        #expect(spec.cmd == ["sleep", "infinity"])
        #expect(spec.hostConfig?.autoRemove != true)
    }

    @Test func sidecarIsLabelledWithItsTarget() {
        let spec = DebugShell.sidecarSpec(target: "abc123", image: "toolbox:1")
        #expect(spec.labels[DebugShell.targetLabel] == "abc123")
    }

    @Test func sidecarNameIsDerivedFromTheTarget() {
        // Derived, not random: reopening finds the existing sidecar instead of
        // starting a second one.
        let long = String(repeating: "f", count: 64)
        #expect(DebugShell.sidecarName(for: long) == "gantry-debug-" + String(repeating: "f", count: 12))
        #expect(DebugShell.sidecarName(for: "abc") == "gantry-debug-abc")
    }

    @Test func specEncodesNamespacesInDockersShape() throws {
        let spec = DebugShell.sidecarSpec(target: "abc123", image: "toolbox:1")
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(spec)
        ) as? [String: Any]
        let hostConfig = try #require(json?["HostConfig"] as? [String: Any])
        #expect(hostConfig["PidMode"] as? String == "container:abc123")
        #expect(hostConfig["NetworkMode"] as? String == "container:abc123")
        #expect(hostConfig["IpcMode"] == nil)
        #expect(hostConfig["CapAdd"] as? [String] == ["SYS_PTRACE"])
        #expect(hostConfig["SecurityOpt"] as? [String] == ["apparmor=unconfined"])
    }

    // MARK: - Sidecar recognition

    /// Decodes a list-endpoint summary, the way the daemon actually delivers one.
    private func summary(names: [String], labels: [String: String] = [:]) throws -> ContainerSummary {
        let json: [String: Any] = [
            "Id": "s1", "Names": names, "Image": "toolbox:1",
            "State": "running", "Labels": labels,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(ContainerSummary.self, from: data)
    }

    @Test func sidecarsAreRecognisedByLabel() throws {
        let container = try summary(
            names: ["/anything"], labels: [DebugShell.targetLabel: "abc123"]
        )
        #expect(DebugShell.isSidecar(container))
    }

    @Test func sidecarsAreRecognisedByNameWhenLabelsAreMissing() throws {
        // Some daemons omit labels from the list endpoint; the derived name is
        // the fallback so sidecars still stay out of the user's list.
        let container = try summary(names: ["/gantry-debug-abc123"])
        #expect(DebugShell.isSidecar(container))
    }

    @Test func ordinaryContainersAreNotSidecars() throws {
        #expect(!DebugShell.isSidecar(try summary(names: ["/web"])))
    }

    // MARK: - Commands

    @Test func shellStartsInTheTargetFilesystem() {
        let script = DebugShell.shellCommand.last ?? ""
        // Without this the user lands in the toolbox's filesystem and every
        // ls/cat shows the wrong container.
        #expect(script.contains("cd /proc/1/root"))
        #expect(script.contains("|| cd /"))
    }

    @Test func shellPrefersRicherShellsButAlwaysHasAFallback() {
        let script = DebugShell.shellCommand.last ?? ""
        #expect(script.contains("exec zsh"))
        #expect(script.contains("exec bash"))
        #expect(script.contains("exec sh"))
    }

    @Test func oneShotCommandRunsAgainstTheTarget() {
        let wrapped = DebugShell.oneShotCommand("curl -s localhost:8080")
        #expect(wrapped.first == "/bin/sh")
        #expect(wrapped.last?.contains("cd /proc/1/root") == true)
        #expect(wrapped.last?.hasSuffix("curl -s localhost:8080") == true)
    }

    // MARK: - Capability

    @Test func onlyDockerHostsAdvertiseTheDebugShell() {
        // apple/container gives each container its own VM, so there is nothing
        // for a sidecar to attach to — better hidden than offered broken.
        #expect(HostCapabilities.docker.debugShell)
        #expect(!HostCapabilities.appleContainer.debugShell)
    }
}
