import Foundation
import Testing
@testable import DockerKit

/// A transport that records the build request and replays a scripted
/// newline-delimited JSON `/build` response, with the default `usesCLIBuild`
/// (false) so `DockerClient` takes the daemon tar-upload path.
private actor RecordingBuildTransport: DockerTransport {
    private(set) var streamRequest: DockerRequest?
    private let lines: [String]
    private let status: Int

    init(lines: [String], status: Int = 200) {
        self.lines = lines
        self.status = status
    }

    func execute(_ request: DockerRequest) async throws -> DockerResponse {
        DockerResponse(status: 200, headers: [:], body: Data("{}".utf8))
    }

    func stream(_ request: DockerRequest) async throws -> DockerByteStream {
        streamRequest = request
        let lines = lines
        let status = status
        return DockerByteStream(status: status, headers: [:], bytes: AsyncThrowingStream { cont in
            for line in lines { cont.yield(Data((line + "\n").utf8)) }
            cont.finish()
        })
    }

    func hijack(_ request: DockerRequest) async throws -> DockerHijackedConnection {
        DockerHijackedConnection(
            status: 101, headers: [:],
            bytes: AsyncThrowingStream { $0.finish() },
            write: { _ in }, close: {}
        )
    }

    func shutdown() async {}

    func recordedRequest() -> DockerRequest? { streamRequest }
}

struct DaemonBuildStreamTests {
    /// Creates a throwaway context dir with a Dockerfile and returns its path.
    private func makeContextPath() throws -> String {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gantry-daemon-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("FROM scratch\n".utf8).write(to: root.appendingPathComponent("Dockerfile"))
        return root.path
    }

    @Test func streamsDaemonLinesAndCapturesImageID() async throws {
        let context = try makeContextPath()
        defer { try? FileManager.default.removeItem(atPath: context) }

        let transport = RecordingBuildTransport(lines: [
            #"{"stream":"Step 1/1 : FROM scratch\n"}"#,
            #"{"stream":" ---> abc123\n"}"#,
            #"{"aux":{"ID":"sha256:deadbeef"}}"#
        ])
        let client = DockerClient(transport: transport)
        let spec = ImageBuildSpec(contextPath: context, dockerfile: "Dockerfile", tag: "demo:latest")

        var text = ""
        var imageID: String?
        for try await line in client.buildImageStream(spec) {
            text += line.text
            if let id = line.imageID { imageID = id }
        }

        #expect(text.contains("Step 1/1"))
        #expect(imageID == "sha256:deadbeef")

        // The request carries the tar context and the right content type.
        let request = try #require(await transport.recordedRequest())
        #expect(request.headers["Content-Type"] == "application/x-tar")
        #expect(request.path.hasSuffix("/build"))
        #expect(request.query.contains { $0.name == "t" && $0.value == "demo:latest" })
        let body = try #require(request.body)
        #expect(body.count >= 512)  // at least one tar header block
    }

    @Test func daemonErrorLineThrows() async throws {
        let context = try makeContextPath()
        defer { try? FileManager.default.removeItem(atPath: context) }

        let transport = RecordingBuildTransport(lines: [
            #"{"stream":"Step 1/2 : FROM scratch\n"}"#,
            #"{"errorDetail":{"message":"missing file"},"error":"missing file"}"#
        ])
        let client = DockerClient(transport: transport)
        let spec = ImageBuildSpec(contextPath: context, tag: "demo:latest")

        await #expect(throws: DockerError.self) {
            for try await _ in client.buildImageStream(spec) {}
        }
    }
}
