import Foundation
import Testing
@testable import DockerKit

// MARK: - Recording transport

/// A `DockerTransport` that records the last request and returns canned
/// responses, letting us assert the exec request encoding without a daemon.
private actor RecordingTransport: DockerTransport {
    private(set) var lastRequest: DockerRequest?
    private let response: DockerResponse
    private let hijackHead: (status: Int, headers: [String: String])

    init(
        response: DockerResponse = DockerResponse(status: 200, headers: [:], body: Data("{}".utf8)),
        hijackHead: (status: Int, headers: [String: String]) = (101, ["upgrade": "tcp"])
    ) {
        self.response = response
        self.hijackHead = hijackHead
    }

    func execute(_ request: DockerRequest) async throws -> DockerResponse {
        lastRequest = request
        return response
    }

    func stream(_ request: DockerRequest) async throws -> DockerByteStream {
        lastRequest = request
        return DockerByteStream(status: 200, headers: [:], bytes: AsyncThrowingStream { $0.finish() })
    }

    func hijack(_ request: DockerRequest) async throws -> DockerHijackedConnection {
        lastRequest = request
        return DockerHijackedConnection(
            status: hijackHead.status,
            headers: hijackHead.headers,
            bytes: AsyncThrowingStream { $0.finish() },
            write: { _ in },
            close: {}
        )
    }

    func shutdown() async {}

    func recorded() -> DockerRequest? { lastRequest }
}

private func decodeBody(_ request: DockerRequest?) throws -> [String: Any] {
    let data = try #require(request?.body)
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any])
}

// MARK: - createExec body encoding

@Test func createExecEncodesAttachFlagsAndCommand() async throws {
    let transport = RecordingTransport(
        response: DockerResponse(status: 201, headers: [:], body: Data(#"{"Id":"exec123"}"#.utf8))
    )
    let client = DockerClient(transport: transport)

    let id = try await client.createExec(containerID: "abc", command: ["sh", "-c", "echo hi"], tty: true)
    #expect(id == "exec123")

    let request = await transport.recorded()
    #expect(request?.method == .post)
    #expect(request?.path == "/v1.47/containers/abc/exec")

    let body = try decodeBody(request)
    #expect(body["AttachStdin"] as? Bool == true)
    #expect(body["AttachStdout"] as? Bool == true)
    #expect(body["AttachStderr"] as? Bool == true)
    #expect(body["Tty"] as? Bool == true)
    #expect(body["Cmd"] as? [String] == ["sh", "-c", "echo hi"])
    // Optional fields omitted when nil.
    #expect(body["WorkingDir"] == nil)
    #expect(body["User"] == nil)
    #expect(body["Env"] == nil)
}

@Test func createExecEncodesOptionalFields() async throws {
    let transport = RecordingTransport(
        response: DockerResponse(status: 201, headers: [:], body: Data(#"{"Id":"x"}"#.utf8))
    )
    let client = DockerClient(transport: transport)

    _ = try await client.createExec(
        containerID: "c",
        command: ["bash"],
        tty: false,
        workingDir: "/srv",
        user: "1000",
        env: ["FOO=bar"]
    )

    let body = try decodeBody(await transport.recorded())
    #expect(body["Tty"] as? Bool == false)
    #expect(body["WorkingDir"] as? String == "/srv")
    #expect(body["User"] as? String == "1000")
    #expect(body["Env"] as? [String] == ["FOO=bar"])
}

// MARK: - startExecHijacked

@Test func startExecHijackedSetsUpgradeHeadersAndDetachBody() async throws {
    let transport = RecordingTransport()
    let client = DockerClient(transport: transport)

    let connection = try await client.startExecHijacked(execID: "e1", tty: true)
    #expect(connection.status == 101)

    let request = await transport.recorded()
    #expect(request?.method == .post)
    #expect(request?.path == "/v1.47/exec/e1/start")
    #expect(request?.headers["Connection"] == "Upgrade")
    #expect(request?.headers["Upgrade"] == "tcp")

    let body = try decodeBody(request)
    #expect(body["Detach"] as? Bool == false)
    #expect(body["Tty"] as? Bool == true)
}

// MARK: - resizeExec

@Test func resizeExecSendsWidthAndHeightQuery() async throws {
    let transport = RecordingTransport(response: DockerResponse(status: 200, headers: [:], body: Data()))
    let client = DockerClient(transport: transport)

    try await client.resizeExec(execID: "e1", width: 120, height: 40)

    let request = await transport.recorded()
    #expect(request?.method == .post)
    #expect(request?.path == "/v1.47/exec/e1/resize")
    #expect(request?.query.contains(URLQueryItem(name: "w", value: "120")) == true)
    #expect(request?.query.contains(URLQueryItem(name: "h", value: "40")) == true)
}

// MARK: - inspectExec decoding

@Test func inspectExecDecodesRunningAndExitCode() async throws {
    let transport = RecordingTransport(
        response: DockerResponse(status: 200, headers: [:], body: Data(#"{"Running":false,"ExitCode":7}"#.utf8))
    )
    let client = DockerClient(transport: transport)

    let inspect = try await client.inspectExec(execID: "e1")
    #expect(inspect.running == false)
    #expect(inspect.exitCode == 7)

    let request = await transport.recorded()
    #expect(request?.path == "/v1.47/exec/e1/json")
}

@Test func inspectExecToleratesMissingExitCode() async throws {
    let transport = RecordingTransport(
        response: DockerResponse(status: 200, headers: [:], body: Data(#"{"Running":true}"#.utf8))
    )
    let client = DockerClient(transport: transport)

    let inspect = try await client.inspectExec(execID: "e1")
    #expect(inspect.running == true)
    #expect(inspect.exitCode == nil)
}
