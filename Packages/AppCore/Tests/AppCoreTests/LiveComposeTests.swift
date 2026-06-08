import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

// Live Compose orchestration against an installed apple/container CLI with
// running services. Gated:
//   GANTRY_APPLE_CONTAINER_LIVE=1 swift test --package-path Packages/AppCore --filter liveCompose
//
// Brings up a two-service project (one `image:`, one `build:`) in a temp dir,
// verifies the containers/network/volume exist with compose labels, then tears
// everything down. alpine:latest must already be pulled.

private let liveEnabled = ProcessInfo.processInfo.environment["GANTRY_APPLE_CONTAINER_LIVE"] == "1"
    && AppleContainerCLIDiscovery.discover() != nil

@MainActor
@Test(.enabled(if: liveEnabled), .timeLimit(.minutes(5)))
func liveComposeUpBuildsAndStartsProject() async throws {
    // 1. Scaffold a temp compose project.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("gantrycompose-live-\(Int.random(in: 1000...9999))")
    let apiDir = dir.appendingPathComponent("api")
    try FileManager.default.createDirectory(at: apiDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let composeYAML = """
    name: gantrycomposelive
    services:
      web:
        image: alpine:latest
        command: sleep 3600
        environment:
          - GREETING=hello
        volumes:
          - webdata:/data
      api:
        build: ./api
        command: sleep 3600
        depends_on: [web]
    volumes:
      webdata: {}
    """
    let composeURL = dir.appendingPathComponent("docker-compose.yml")
    try composeYAML.write(to: composeURL, atomically: true, encoding: .utf8)
    try "FROM alpine:latest\nRUN echo built > /built.txt\n".write(
        to: apiDir.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8
    )

    // 2. Connect a real apple/container session.
    let session = HostSession(host: DockerHost(name: "Apple Live", kind: .appleContainer))
    await session.connect()
    try #require(session.status.isConnected, "apple/container services must be running")
    await session.refreshAll()

    let project = try ComposeParser().parse(fileURL: composeURL)

    // Cleanup runs regardless of assertion outcome.
    func teardown() async {
        for container in session.containers
        where container.labels["com.docker.compose.project"] == "gantrycomposelive" {
            _ = await session.perform(.remove(force: true), on: container.id)
        }
        await session.refreshAll()
        _ = await session.removeNetwork(id: "gantrycomposelive_default")
        _ = await session.removeVolume(name: "gantrycomposelive_webdata", force: true)
        _ = await session.removeImage(id: "gantrycomposelive-api:latest", force: true)
    }
    await teardown()  // clear any leftovers from a prior failed run

    do {
        // 3. Bring the project up.
        var events: [ComposeUpEvent] = []
        let runner = ComposeRunner(session: session, project: project)
        let started = try await runner.up { events.append($0) }
        #expect(started == 2)
        #expect(events.contains(.buildingImage(service: "api")))

        await session.refreshAll()

        // 4. Both services exist, labeled with the project.
        let mine = session.containers.filter {
            $0.labels["com.docker.compose.project"] == "gantrycomposelive"
        }
        #expect(mine.count == 2)
        #expect(mine.allSatisfy { $0.labels["com.docker.compose.service"] != nil })

        // 5. Project network and volume were created.
        #expect(session.networks.contains { $0.name == "gantrycomposelive_default" })
        #expect(session.volumes.contains { $0.name == "gantrycomposelive_webdata" })
    } catch {
        await teardown()
        throw error
    }
    await teardown()
}
