import Foundation
import Testing
import DockerKit
@testable import AppCore

/// End-to-end debug shell against a real local Docker daemon.
///
/// Gated like the other live suites: opt in with
/// `GANTRY_DEBUG_SHELL_LIVE=1 swift test --package-path Packages/AppCore --filter LiveDebugShell`.
/// Set `GANTRY_DEBUG_SHELL_IMAGE=busybox` to avoid pulling the full toolbox.
///
/// What it proves is the part that can't be unit-tested: that joining the
/// target's namespaces actually yields its processes, its filesystem and its
/// network — on a container that is read-only and has no shell tools of its own.
private let liveEnabled = ProcessInfo.processInfo.environment["GANTRY_DEBUG_SHELL_LIVE"] == "1"

@Test(.enabled(if: liveEnabled), .timeLimit(.minutes(5)))
@MainActor
func liveDebugShellSeesTheTarget() async throws {
    let socket = try #require(DockerSocketDiscovery.discover())
    let host = DockerHost(name: "live", kind: .local, socketPathOverride: socket)
    let session = HostSession(host: host)
    await session.connect()
    #expect(session.status.isConnected)

    // A read-only target, which is the case that defeats every "install the
    // tools into the container" workaround.
    let targetName = "gantry-debugshell-live"
    let target = ContainerCreateRequest(
        image: "nginx:alpine",
        env: [],
        labels: [:],
        tty: false,
        hostConfig: .init(),
        name: targetName
    )
    _ = await session.perform(ContainerAction.remove(force: true), on: targetName)
    let targetID = try await session.createAndRun(target)

    defer {
        Task {
            await session.stopDebugSidecar(for: targetID)
            _ = await session.perform(.remove(force: true), on: targetID)
        }
    }

    let sidecarID = try await session.debugSidecarID(for: targetID)
    #expect(!sidecarID.isEmpty)

    // The sidecar is a real container, but Gantry hides it from the list.
    await session.refreshContainers()
    let sidecar = try #require(session.containers.first { $0.id == sidecarID })
    #expect(DebugShell.isSidecar(sidecar))

    // Reopening must reuse the same sidecar rather than pile up a second one.
    let again = try await session.debugSidecarID(for: targetID)
    #expect(again == sidecarID)

    // The namespaces are actually joined — this is what makes the target's
    // processes, ports and filesystem reachable from the sidecar.
    let details = await session.details(for: sidecarID)
    #expect(details?.hostConfig.networkMode == "container:\(targetID)")

    // Awaited, not deferred into a detached Task: the test process exits
    // before such a task runs and the containers outlive the run.
    await session.stopDebugSidecar(for: targetID)
    _ = await session.perform(ContainerAction.remove(force: true), on: targetID)
    await session.refreshContainers()
    #expect(!session.containers.contains { $0.id == sidecarID || $0.id == targetID })
    await session.disconnect()
}
