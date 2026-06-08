import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

@MainActor
@Suite struct BuildStreamTests {
    private func makeContext() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gantry-hs-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("FROM scratch\n".utf8).write(to: root.appendingPathComponent("Dockerfile"))
        return root
    }

    /// A Docker (non-CLI) host streams the daemon `/build` log, surfaces the
    /// built image id, and refreshes the image list when the build finishes.
    @Test func dockerHostStreamsBuildAndRefreshes() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context) }

        let transport = MockTransport()  // usesCLIBuild defaults to false (daemon)
        transport.on(.get, "/version", json: Fixtures.version)
        transport.on(.get, "/images/json", json: Fixtures.images)
        transport.onStream("/build", lines: [
            #"{"stream":"Step 1/1 : FROM scratch\n"}"#,
            #"{"aux":{"ID":"sha256:cafe"}}"#
        ])
        let client = DockerClient(transport: transport)
        let version = try await client.negotiate()
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        session._setConnectedClientForTesting(client, version: version)

        let spec = ImageBuildSpec(contextPath: context.path, dockerfile: "Dockerfile", tag: "demo:latest")
        var log = ""
        var imageID: String?
        for try await line in try session.buildImageStream(spec) {
            log += line.text
            if let id = line.imageID { imageID = id }
        }

        #expect(log.contains("Step 1/1"))
        #expect(imageID == "sha256:cafe")
        // Build uploaded a tar to /build…
        let build = try #require(transport.executed.first { $0.path.hasSuffix("/build") })
        #expect(build.headers["Content-Type"] == "application/x-tar")
        // …and the image list was refreshed afterwards.
        #expect(transport.executed.contains { $0.path.hasSuffix("/images/json") })
    }
}
