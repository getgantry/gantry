import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

// Live check of spec 017, gated. Before the run, make a container `upd-web`
// from `alpine:3.21` that is tagged from an older local alpine image:
//   GANTRY_UPD_LIVE_DOCKER_SOCKET=/path/to/forwarded.sock (a Docker host)
//   GANTRY_UPD_LIVE_APPLE=1 (the Apple `container` host of this Mac)
// The test updates `upd-web`; the caller removes it and `alpine:3.21`.

private let environment = ProcessInfo.processInfo.environment
private let dockerSocket = environment["GANTRY_UPD_LIVE_DOCKER_SOCKET"] ?? ""
private let appleEnabled = environment["GANTRY_UPD_LIVE_APPLE"] == "1"
    && AppleContainerCLIDiscovery.discover() != nil

@MainActor
@Suite(.serialized)
struct LiveImageUpdateTests {
    @Test(.enabled(if: !dockerSocket.isEmpty), .timeLimit(.minutes(5)))
    func dockerHostMarksAndUpdates() async throws {
        try await run(DockerHost(name: "upd-docker", kind: .local, socketPathOverride: dockerSocket))
    }

    @Test(.enabled(if: appleEnabled), .timeLimit(.minutes(5)))
    func appleHostMarksAndUpdates() async throws {
        try await run(DockerHost(name: "upd-apple", kind: .appleContainer))
    }

    private func run(_ host: DockerHost) async throws {
        let session = HostSession(host: host)
        session.imageUpdateMonitor = ImageUpdateMonitor(fileURL: nil)
        await session.connect()
        defer { Task { await session.disconnect() } }
        #expect(session.status.isConnected)
        await session.refreshAll()
        let web = try #require(session.containers.first { $0.displayName == "upd-web" })
        let target = try #require(session.imageUpdateTarget(for: web))
        #expect(target.key == "docker.io/library/alpine:3.21")

        await session.checkImageUpdates(force: true)
        let remote = try #require(session.imageUpdateMonitor.remoteDigest(for: target.key))
        print("LIVE \(host.name): local \(target.localDigest) remote \(remote)")
        #expect(session.imageUpdateStatus(for: web) == .updateAvailable)

        try await session.performUpdate(web, reference: target.key, operation: nil)
        await session.refreshAll()
        let updated = try #require(session.containers.first { $0.displayName == "upd-web" })
        #expect(updated.imageID != web.imageID)
        #expect(updated.state.isRunning)
        #expect(session.imageUpdateStatus(for: updated) == .upToDate)
        let details = try #require(await session.details(for: updated.id))
        #expect(details.config.cmd == ["sleep", "3600"])
    }
}
