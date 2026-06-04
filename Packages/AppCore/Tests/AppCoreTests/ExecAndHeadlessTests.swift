import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

// MARK: - ExecSession (fake hijacked connection)

@MainActor
@Suite struct ExecSessionTests {
    /// Builds an ExecSession over a fake hijacked connection whose write/close
    /// record calls, plus a client whose resize route is canned.
    private func makeSession(
        writeFails: Bool = false
    ) async -> (ExecSession, writes: Recorder, closed: Recorder) {
        let writes = Recorder()
        let closed = Recorder()

        let inbound = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data("hello".utf8))
            continuation.finish()
        }
        let connection = DockerHijackedConnection(
            status: 101,
            headers: [:],
            bytes: inbound,
            write: { data in
                if writeFails { throw DockerError.streamClosed }
                await writes.append(data)
            },
            close: { await closed.markClosed() }
        )

        let transport = MockTransport()
        transport.on(.get, "/version", json: Fixtures.version)
        transport.on(.post, "/exec/exec1/resize", json: "")
        let client = DockerClient(transport: transport)
        _ = try! await client.negotiate()

        let session = ExecSession(execID: "exec1", tty: true, connection: connection, client: client)
        return (session, writes, closed)
    }

    @Test func exposesIDAndTTY() async {
        let (session, _, _) = await makeSession()
        #expect(session.id == "exec1")
        #expect(session.tty)
        session.terminate()
    }

    @Test func inboundBytesFlow() async throws {
        let (session, _, _) = await makeSession()
        var received = Data()
        for try await chunk in session.bytes {
            received.append(chunk)
        }
        #expect(String(data: received, encoding: .utf8) == "hello")
        session.terminate()
    }

    @Test func sendPumpsToConnection() async {
        let (session, writes, _) = await makeSession()
        session.send(Data("abc".utf8))
        session.send(Data("def".utf8))
        // Let the ordered pump drain.
        try? await Task.sleep(for: .milliseconds(100))
        let count = await writes.count
        #expect(count == 2)
        let combined = await writes.combinedString
        #expect(combined == "abcdef")
        session.terminate()
    }

    @Test func writeFailureSurfacesViaOnError() async {
        let (session, _, _) = await makeSession(writeFails: true)
        let errorBox = Recorder()
        session.onError = { message in
            Task { await errorBox.recordError(message) }
        }
        session.send(Data("x".utf8))
        try? await Task.sleep(for: .milliseconds(100))
        let got = await errorBox.errorMessage
        #expect(got != nil)
        session.terminate()
    }

    @Test func resizeDoesNotThrow() async {
        let (session, _, _) = await makeSession()
        session.resize(cols: 80, rows: 24)
        try? await Task.sleep(for: .milliseconds(50))
        session.terminate()
    }

    @Test func terminateClosesConnection() async {
        let (session, _, closed) = await makeSession()
        session.terminate()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await closed.wasClosed)
    }

    @Test func conformsToTerminalSession() async {
        let (session, _, _) = await makeSession()
        let terminal: any TerminalSession = session
        terminal.send(Data())
        terminal.resize(cols: 1, rows: 1)
        terminal.terminate()
    }
}

/// Simple actor recorder for closure side effects.
actor Recorder {
    private var datas: [Data] = []
    private var closed = false
    private var error: String?

    func append(_ data: Data) { datas.append(data) }
    func markClosed() { closed = true }
    func recordError(_ message: String) { error = message }

    var count: Int { datas.count }
    var combinedString: String { datas.map { String(data: $0, encoding: .utf8) ?? "" }.joined() }
    var wasClosed: Bool { closed }
    var errorMessage: String? { error }
}

// MARK: - HeadlessDocker errors and local-socket paths

@Suite struct HeadlessDockerTests {
    @Test func errorDescriptions() {
        #expect(HeadlessDockerError.noLocalSocket.errorDescription?.contains("socket") == true)
        #expect(HeadlessDockerError.missingCredential("detail").errorDescription == "detail")
        #expect(HeadlessDockerError.connectionFailed("why").errorDescription == "why")
        #expect(HeadlessDockerError.hostNotFound("h").errorDescription?.contains("h") == true)
        #expect(HeadlessDockerError.containerNotFound("c").errorDescription?.contains("c") == true)
    }

    @Test func connectLocalWithBogusSocketThrows() async {
        // A non-existent socket override -> connection fails (negotiate cannot
        // reach a daemon). Exercises the local transport + error-wrapping path.
        let host = DockerHost(
            name: "Bogus",
            kind: .local,
            socketPathOverride: "/tmp/nonexistent-\(UUID().uuidString).sock"
        )
        await #expect(throws: Error.self) {
            _ = try await HeadlessDocker.connect(to: host)
        }
    }

    @Test func connectLocalNoSocketThrowsNoLocalSocket() async {
        // No override and DOCKER_HOST unset/invalid: if discovery finds nothing
        // we expect noLocalSocket. On a machine with a live daemon discovery
        // succeeds and the negotiate path is exercised instead; either way the
        // call must not crash. We only assert it throws when no socket exists.
        let found = DockerSocketDiscovery.discover()
        if found == nil {
            let host = DockerHost(name: "Local", kind: .local)
            await #expect(throws: HeadlessDockerError.self) {
                _ = try await HeadlessDocker.connect(to: host)
            }
        }
    }
}
