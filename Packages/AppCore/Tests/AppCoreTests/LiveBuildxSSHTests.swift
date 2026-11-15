import Foundation
import Testing
@testable import AppCore
@testable import DockerKit
import SSHKit

// Live, against a Docker host over SSH with buildx. Gated:
//   GANTRY_BUILDX_SSH_HOST=user@host swift test --filter LiveBuildxSSH
// Builds the images `gbh-live-bx:1` and `gbh-live-classic:1` on the host,
// then removes them and the buildx record of the test build.

private let target = ProcessInfo.processInfo.environment["GANTRY_BUILDX_SSH_HOST"].flatMap { $0.isEmpty ? nil : $0 }

@MainActor
@Suite(.serialized, .enabled(if: target != nil))
struct LiveBuildxSSHTests {
    private func connect() async throws -> HostSession {
        let parts = try #require(target).split(separator: "@", maxSplits: 1).map(String.init)
        let endpoint = parts.count == 2
            ? SSHEndpoint(host: parts[1], username: parts[0])
            : SSHEndpoint(host: parts[0])
        let session = HostSession(host: DockerHost(name: "gbh-live", kind: .ssh(endpoint)))
        session.buildHistory = BuildHistoryStore(persistence: nil)
        await session.connect()
        try #require(session.status.isConnected, "\(session.lastError ?? "not connected")")
        return session
    }

    private func shell(_ session: HostSession, _ command: String) async throws -> DockerCLIResult {
        let factory = try #require(session.sshClientFactory)
        let result = try await SSHCommand.run(command, makeClient: factory)
        return DockerCLIResult(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
    }

    @Test(.timeLimit(.minutes(5)))
    func buildxHistoryOverSSH() async throws {
        let session = try await connect()
        let availability = await session.buildxAvailability()
        guard case .available(let version) = availability else {
            Issue.record("buildx not available: \(availability)")
            return
        }
        #expect(BuildxHistoryParser.isSupported(version))

        // A BuildKit build with the docker CLI on the host, in a context named gbh-live-ctx.
        let build = try await shell(session, """
            set -e; d=$(mktemp -d); mkdir "$d/gbh-live-ctx"; cd "$d/gbh-live-ctx"
            printf 'FROM alpine:3.20\\nRUN echo gbh-live > /gbh\\n' > Dockerfile
            docker buildx build --load -t gbh-live-bx:1 . >/dev/null 2>&1
            docker buildx build --load -t gbh-live-bx:1 . >/dev/null 2>&1
            cd /; rm -rf "$d"
            """)
        #expect(build.exitCode == 0, "\(build.stderr)")

        let runner = try #require(session.dockerCLIRunner())
        let records = try await BuildxHistoryService.records(runner: runner, hostID: session.host.id)
        let ours = records.filter { $0.name == "gbh-live-ctx" }
        var detail: BuildRecord?
        if let newest = ours.first {
            detail = try? await BuildxHistoryService.detail(of: newest, runner: runner)
        }
        // Remove the test image and the buildx records of the test builds only.
        let refs = ours.compactMap { $0.id.split(separator: "/").last.map(String.init) }.filter(BuildxHistoryService.isSafeID)
        let cleanup = "docker image rm gbh-live-bx:1 >/dev/null 2>&1; "
            + (refs.isEmpty ? "" : "docker buildx history rm \(refs.joined(separator: " ")) >/dev/null 2>&1; ") + "true"
        _ = try await shell(session, cleanup)

        #expect(ours.count >= 2)
        let cached = try #require(ours.first)
        #expect(cached.status == .succeeded)
        #expect((cached.cachedSteps ?? 0) >= 1)
        let loaded = try #require(detail)
        let parsed = BuildStepSummary(loaded.steps)
        #expect(parsed.total == cached.totalSteps)
        #expect(parsed.cached == cached.cachedSteps)
        #expect(loaded.steps.contains { $0.name.contains("RUN echo gbh-live") && $0.state == .cached })
        #expect(loaded.dockerfile == "Dockerfile")
    }

    @Test(.timeLimit(.minutes(5)))
    func gantryBuildOverSSHIsRecorded() async throws {
        let session = try await connect()
        let context = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gbh-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: context) }
        try Data("FROM alpine:3.20\nRUN echo gbh-classic > /gbh\n".utf8).write(to: context.appendingPathComponent("Dockerfile"))

        let spec = ImageBuildSpec(contextPath: context.path, dockerfile: "Dockerfile", tag: "gbh-live-classic:1")
        var buildError: Error?
        do {
            try await session.buildImage(spec)
            try await session.buildImage(spec)
        } catch {
            buildError = error
        }
        _ = try await shell(session, "docker image rm gbh-live-classic:1 >/dev/null 2>&1; true")
        if let buildError { throw buildError }
        let records = try #require(session.buildHistory?.records(for: session.host.id))
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.status == .succeeded && $0.imageID != nil })
        let again = try #require(records.first)
        #expect(again.steps.map(\.name) == ["FROM alpine:3.20", "RUN echo gbh-classic > /gbh"])
        #expect(again.steps.last?.state == .cached)
    }
}
