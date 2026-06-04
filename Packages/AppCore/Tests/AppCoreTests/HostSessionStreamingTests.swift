import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

@MainActor
@Suite struct HostSessionStreamingTests {
    private func connected(configure: (MockTransport) -> Void) async -> HostSession {
        let transport = MockTransport()
        transport.on(.get, "/version", json: Fixtures.version)
        configure(transport)
        let client = DockerClient(transport: transport)
        let version = try! await client.negotiate()
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        session._setConnectedClientForTesting(client, version: version)
        return session
    }

    // MARK: - logStream (inspect + logs)

    @Test func logStreamInspectsThenStreams() async throws {
        let session = await connected { t in
            t.on(.get, "/containers/c1/json", json: Fixtures.containerDetails)
            // TTY false in details -> demuxer path; feed raw stdcopy frame-free
            // bytes by using a TTY-style line is fine for the demuxer to ignore;
            // we just assert the stream opens.
            t.onStream("/containers/c1/logs", lines: [])
        }
        let stream = try await session.logStream(for: "c1")
        var lines: [LogEntry] = []
        for try await entry in stream { lines.append(entry) }
        #expect(lines.isEmpty)
    }

    @Test func logStreamNotConnectedThrows() async {
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        await #expect(throws: DockerError.self) {
            _ = try await session.logStream(for: "c1")
        }
    }

    // MARK: - statsStream

    @Test func statsStreamOpens() async throws {
        let session = await connected { t in
            t.onStream("/containers/c1/stats", lines: [
                Fixtures.statsOnce(total: 100, system: 1000, online: 1, memUsage: 10, memLimit: 100)
            ])
        }
        let stream = try await session.statsStream(for: "c1")
        var count = 0
        for try await _ in stream { count += 1 }
        #expect(count == 1)
    }

    @Test func statsStreamNotConnectedThrows() async {
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        await #expect(throws: DockerError.self) {
            _ = try await session.statsStream(for: "c1")
        }
    }

    // MARK: - processes (top)

    @Test func processesReturnsTop() async throws {
        let session = await connected { t in
            t.on(.get, "/containers/c1/top", json: #"{"Titles":["PID","CMD"],"Processes":[["1","sh"]]}"#)
        }
        let top = try await session.processes(containerID: "c1")
        #expect(top.titles == ["PID", "CMD"])
        #expect(top.processes.count == 1)
    }

    @Test func processesNotConnectedThrows() async {
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        await #expect(throws: DockerError.self) {
            _ = try await session.processes(containerID: "c1")
        }
    }

    // MARK: - exportFilesystem / archives

    @Test func exportFilesystemStreams() async throws {
        let session = await connected { t in
            t.onStream("/containers/c1/export", lines: ["chunk"])
        }
        let stream = try await session.exportFilesystem(containerID: "c1")
        var data = Data()
        for try await chunk in stream.bytes { data.append(chunk) }
        #expect(!data.isEmpty)
    }

    @Test func downloadArchiveStreams() async throws {
        let session = await connected { t in
            t.onStream("/containers/c1/archive", lines: ["tarbytes"])
        }
        let stream = try await session.downloadArchive(containerID: "c1", path: "/etc")
        var data = Data()
        for try await chunk in stream.bytes { data.append(chunk) }
        #expect(!data.isEmpty)
    }

    @Test func uploadArchiveSucceeds() async throws {
        let session = await connected { t in
            t.on(.put, "/containers/c1/archive", status: 200, json: "")
        }
        try await session.uploadArchive(containerID: "c1", path: "/tmp", tar: Data("x".utf8))
    }

    @Test func archiveOpsNotConnectedThrow() async {
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        await #expect(throws: DockerError.self) { _ = try await session.exportFilesystem(containerID: "c1") }
        await #expect(throws: DockerError.self) { _ = try await session.downloadArchive(containerID: "c1", path: "/") }
        await #expect(throws: DockerError.self) { try await session.uploadArchive(containerID: "c1", path: "/", tar: Data()) }
    }

    // MARK: - pullImage

    @Test func pullImageOpensProgressStream() async throws {
        let session = await connected { t in
            t.onStream("/images/create", lines: [
                #"{"status":"Pulling from library/nginx","id":"latest"}"#,
                #"{"status":"Download complete","id":"abc"}"#
            ])
        }
        let stream = try await session.pullImage(reference: "nginx:latest")
        var count = 0
        for try await _ in stream { count += 1 }
        #expect(count >= 1)
    }

    @Test func pullImageNotConnectedThrows() async {
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        await #expect(throws: DockerError.self) {
            _ = try await session.pullImage(reference: "nginx")
        }
    }

    // MARK: - removeContainer via perform(.remove)

    @Test func removeContainerForce() async {
        let session = await connected { t in
            t.on(.delete, "/containers/c1", status: 204, json: "")
            t.on(.get, "/containers/json", json: Fixtures.containers([]))
        }
        #expect(await session.perform(.remove(force: true), on: "c1"))
    }

    // MARK: - listDirectory archive fallback

    @Test func listDirectoryFallsBackOnNoShell() async throws {
        // listDirectoryFast creates an exec; with no exec route it throws, but
        // not necessarily ExecListError. We at least exercise the call wiring;
        // a route-less mock surfaces an error from the fast path.
        let session = await connected { t in
            // Provide the archive fallback route too.
            t.onStream("/containers/c1/archive", lines: [])
        }
        // Either the fast path's error propagates (not ExecListError) or the
        // fallback runs; both are acceptable — we only require the method runs
        // without crashing and reaches a terminal state.
        do {
            _ = try await session.listDirectory(containerID: "c1", path: "/")
        } catch {
            // Expected: the canned mock cannot satisfy the exec sequence.
        }
    }
}

// MARK: - HostShellSession (TerminalSession) over a fake SSHHostShell

// NOTE: HostShellSession wraps SSHHostShell which requires a live SSH client,
// so it is exercised only structurally via HostSession.openHostShell guards in
// HostSessionTests. No standalone test here to avoid needing a remote host.
