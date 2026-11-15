import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

// Live, against the installed apple/container CLI with running services. Gated:
//   GANTRY_BUILD_HISTORY_LIVE=1 swift test --filter LiveBuildHistory
// Builds `gbh-live:*` images and removes them at the end.

private let liveBuildsEnabled =
    ProcessInfo.processInfo.environment["GANTRY_BUILD_HISTORY_LIVE"] == "1"
    && AppleContainerCLIDiscovery.discover() != nil

@MainActor
@Suite(.serialized, .enabled(if: liveBuildsEnabled))
struct LiveBuildHistoryTests {
    @Test(.timeLimit(.minutes(5)))
    func appleBuildsAreRecorded() async throws {
        let context = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gbh-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: context) }
        try Data("FROM alpine:3.20\nRUN echo one > /one\nCOPY Dockerfile /Dockerfile\n".utf8)
            .write(to: context.appendingPathComponent("Dockerfile"))
        try Data("FROM alpine:3.20\nRUN echo one > /one\nRUN exit 3\n".utf8)
            .write(to: context.appendingPathComponent("Dockerfile.fail"))

        let session = HostSession(host: DockerHost(name: "Apple", kind: .appleContainer))
        session.buildHistory = BuildHistoryStore(persistence: nil)
        await session.connect()
        try #require(session.status.isConnected)

        let ok = ImageBuildSpec(contextPath: context.path, dockerfile: "Dockerfile", tag: "gbh-live:1")
        try await session.buildImage(ok)
        try await session.buildImage(ok)
        let fail = ImageBuildSpec(contextPath: context.path, dockerfile: "Dockerfile.fail", tag: "gbh-live:fail")
        await #expect(throws: (any Error).self) { try await session.buildImage(fail) }

        let records = try #require(session.buildHistory?.records(for: session.host.id))
        #expect(records.count == 3)
        let failed = records[0], cached = records[1]
        #expect(failed.status == .failed)
        #expect(failed.steps.contains { $0.state == .failed && $0.name.contains("RUN exit 3") })
        #expect(cached.status == .succeeded)
        #expect(cached.steps.filter { !$0.isInternal }.allSatisfy { $0.state == .cached })
        #expect(cached.summary.cached >= 2)
        #expect(records.allSatisfy { $0.endedAt != nil && $0.source == .gantry })

        for tag in ["gbh-live:1"] {
            if let image = session.images.first(where: { $0.repoTags.contains { $0.hasSuffix(tag) } }) {
                _ = await session.removeImage(id: image.id, force: true)
            }
        }
    }
}
