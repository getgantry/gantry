import Foundation
import Testing
@testable import DockerKit

/// Answers image inspects slowly and records the peak number in flight.
private actor SlowInspectTransport: DockerTransport {
    let count: Int
    private var inFlight = 0
    private(set) var peak = 0
    private(set) var inspects = 0

    init(count: Int) { self.count = count }

    func execute(_ request: DockerRequest) async throws -> DockerResponse {
        if request.path.hasSuffix("/images/json") {
            let rows = (0..<count).map { #"{"Id":"sha256:\#($0)","RepoTags":[],"Created":0,"Size":1}"# }
            return DockerResponse(status: 200, headers: [:], body: Data("[\(rows.joined(separator: ","))]".utf8))
        }
        inFlight += 1
        inspects += 1
        peak = max(peak, inFlight)
        try await Task.sleep(for: .milliseconds(5))
        inFlight -= 1
        return DockerResponse(status: 200, headers: [:], body: Data(#"{"Architecture":"arm64","Os":"linux"}"#.utf8))
    }

    func stream(_ request: DockerRequest) async throws -> DockerByteStream {
        throw DockerError.apiError(status: 501, message: "unused")
    }

    func hijack(_ request: DockerRequest) async throws -> DockerHijackedConnection {
        throw DockerError.apiError(status: 501, message: "unused")
    }

    func shutdown() async {}
}

@Test func listImagesCapsParallelInspects() async throws {
    let transport = SlowInspectTransport(count: 60)
    let client = DockerClient(transport: transport)
    let images = try await client.listImages()
    #expect(images.count == 60)
    #expect(images.allSatisfy { $0.architecture == "arm64" })
    #expect(await transport.inspects == 60)
    let peak = await transport.peak
    #expect(peak <= DockerClient.maxParallelInspects)
    #expect(peak > 1)
}
