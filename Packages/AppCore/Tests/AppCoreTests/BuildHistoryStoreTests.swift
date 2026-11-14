import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

/// Keeps the saved records in memory.
private final class MemoryPersistence: BuildHistoryPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [BuildRecord]
    private(set) var saves = 0

    init(_ records: [BuildRecord] = []) { stored = records }

    func load() -> [BuildRecord] { lock.withLock { stored } }
    func save(_ records: [BuildRecord]) throws { lock.withLock { stored = records; saves += 1 } }
    var saved: [BuildRecord] { lock.withLock { stored } }
}

@MainActor
@Suite struct BuildHistoryStoreTests {
    private let host = UUID()
    private let spec = ImageBuildSpec(
        contextPath: "/tmp/app", dockerfile: "Dockerfile", tag: "app:1",
        buildArgs: ["TOKEN": "s3cr3t-value-123", "MODE": "release"], noCache: true
    )

    @Test func beginAndFinishARecord() async {
        let persistence = MemoryPersistence()
        let store = BuildHistoryStore(persistence: persistence)
        let start = Date(timeIntervalSince1970: 1_000)
        let id = store.begin(spec, hostID: host, at: start)
        #expect(store.records(for: host).first?.status == .running)
        store.finish(id: id, status: .succeeded, log: "#1 [1/1] FROM x\n#1 CACHED\n", imageID: "sha256:abc",
                     at: start.addingTimeInterval(2.5))
        await store.flush()
        let record = try? #require(persistence.saved.first)
        #expect(record?.status == .succeeded)
        #expect(record?.duration == 2.5)
        #expect(record?.imageID == "sha256:abc")
        #expect(record?.summary.cached == 1)
        #expect(record?.buildArgNames == ["MODE", "TOKEN"])
        #expect(record?.noCache == true)
    }

    @Test func theFileHasNoBuildArgumentValue() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gantry-bh-\(UUID().uuidString)/build-history.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = BuildHistoryStore(persistence: BuildHistoryFile(url: url))
        let id = store.begin(spec, hostID: host)
        store.finish(id: id, status: .succeeded, log: "done\n")
        await store.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("TOKEN"))
        #expect(!text.contains("s3cr3t-value-123"))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // A new store reads the record back.
        #expect(BuildHistoryStore(persistence: BuildHistoryFile(url: url)).records(for: host).count == 1)
    }

    @Test func keepsAtMost100RecordsPerHost() {
        let store = BuildHistoryStore(persistence: nil)
        let other = UUID()
        store.begin(spec, hostID: other, at: Date(timeIntervalSince1970: 0))
        for index in 0..<105 {
            store.begin(spec, hostID: host, at: Date(timeIntervalSince1970: Double(index + 1)))
        }
        let own = store.records(for: host)
        #expect(own.count == BuildHistoryStore.maxRecordsPerHost)
        #expect(own.last?.startedAt == Date(timeIntervalSince1970: 6))
        #expect(store.records(for: other).count == 1)
    }

    @Test func runningRecordsAreInterruptedOnLoad() async {
        let running = BuildRecord(starting: spec, hostID: host)
        let persistence = MemoryPersistence([running])
        let store = BuildHistoryStore(persistence: persistence)
        #expect(store.records(for: host).first?.status == .interrupted)
        await store.flush()
        #expect(persistence.saved.first?.status == .interrupted)
    }

    @Test func clearRemovesOneHostOnly() {
        let store = BuildHistoryStore(persistence: nil)
        let other = UUID()
        store.begin(spec, hostID: host)
        store.begin(spec, hostID: other)
        store.clear(hostID: host)
        #expect(store.records(for: host).isEmpty)
        #expect(store.records(for: other).count == 1)
        store.removeHost(other)
        #expect(store.records.isEmpty)
    }

    @Test func logKeepsTheEnd() {
        let lines = (0..<20_000).map { "line \($0) of the build output" }.joined(separator: "\n") + "\n"
        let capped = BuildLogLimit.cap(lines, maxBytes: 1_000)
        #expect(capped.truncated)
        #expect(capped.log.utf8.count <= 1_000)
        #expect(capped.log.hasSuffix("line 19999 of the build output\n"))
        #expect(capped.log.hasPrefix("line "))
        #expect(!BuildLogLimit.cap("short").truncated)
    }

    @Test func errorTextBecomesTheLogWhenTheLogIsEmpty() {
        let store = BuildHistoryStore(persistence: nil)
        let id = store.begin(spec, hostID: host)
        store.finish(id: id, status: .failed, log: "", errorMessage: "#1 [1/1] RUN exit 3\n#1 ERROR: exit code: 3")
        let record = store.record(id: id)
        #expect(record?.log.contains("ERROR") == true)
        #expect(record?.steps.first?.state == .failed)
    }

    @Test(arguments: [
        ("Completed", BuildStatus.succeeded), ("completed", .succeeded), ("Error", .failed),
        ("failed", .failed), ("Canceled", .cancelled), ("Running", .running), ("Weird", .failed)
    ])
    func buildxStatusText(text: String, status: BuildStatus) {
        #expect(BuildStatus(buildxStatus: text) == status)
    }
}

@MainActor
@Suite struct BuildRecordingTests {
    private func makeContext() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gantry-bh-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("FROM scratch\n".utf8).write(to: root.appendingPathComponent("Dockerfile"))
        return root
    }

    private func session(lines: [String]) async throws -> HostSession {
        let transport = MockTransport()
        transport.on(.get, "/version", json: Fixtures.version)
        transport.on(.get, "/images/json", json: Fixtures.images)
        transport.onStream("/build", lines: lines)
        let client = DockerClient(transport: transport)
        let version = try await client.negotiate()
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        session._setConnectedClientForTesting(client, version: version)
        session.buildHistory = BuildHistoryStore(persistence: nil)
        return session
    }

    @Test func aSucceededBuildIsRecorded() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context) }
        let session = try await session(lines: [
            #"{"stream":"Step 1/2 : FROM alpine"}"#, #"{"stream":"\n"}"#, #"{"stream":" ---> ab3fe4defd29\n"}"#,
            #"{"stream":"Step 2/2 : RUN true"}"#, #"{"stream":"\n"}"#, #"{"stream":" ---> Using cache\n"}"#,
            #"{"aux":{"ID":"sha256:cafe"}}"#
        ])
        let spec = ImageBuildSpec(contextPath: context.path, dockerfile: "Dockerfile", tag: "demo:1")
        let log = try await session.buildImage(spec)
        #expect(log.contains("Step 2/2"))
        let record = try #require(session.buildHistory?.records(for: session.host.id).first)
        #expect(record.status == .succeeded)
        #expect(record.name == "demo:1")
        #expect(record.imageID == "sha256:cafe")
        #expect(record.steps.map(\.state) == [.run, .cached])
        #expect(record.endedAt != nil)
    }

    @Test func aFailedBuildIsRecordedWithTheError() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context) }
        let session = try await session(lines: [
            #"{"stream":"Step 1/1 : RUN exit 3"}"#, #"{"stream":"\n"}"#, #"{"stream":" ---> Running in 73b4c7bca2c7\n"}"#,
            #"{"errorDetail":{"code":3,"message":"returned a non-zero code: 3"},"error":"returned a non-zero code: 3"}"#
        ])
        let spec = ImageBuildSpec(contextPath: context.path, dockerfile: "Dockerfile", tag: "demo:fail")
        await #expect(throws: (any Error).self) { try await session.buildImage(spec) }
        let record = try #require(session.buildHistory?.records(for: session.host.id).first)
        #expect(record.status == .failed)
        #expect(record.errorMessage?.contains("non-zero code: 3") == true)
        #expect(record.steps.last?.state == .failed)
    }
}
