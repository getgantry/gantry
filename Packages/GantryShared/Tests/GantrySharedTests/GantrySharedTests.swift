import Foundation
import Testing
@testable import GantryShared

private func sampleSnapshot(at date: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> FleetSnapshot {
    let hostA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let hostB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    return FleetSnapshot(
        generatedAt: date,
        hosts: [
            .init(id: hostA, name: "Local", state: .connected, running: 3, stopped: 1, unhealthy: 1, attention: 1),
            .init(id: hostB, name: "Box", state: .failed, running: 0, stopped: 0, unhealthy: 0, attention: 0)
        ],
        topProblem: .init(kind: .hostFailed, hostID: hostB, hostName: "Box", containerName: nil),
        appleServices: .init(running: true),
        containers: [.init(hostID: hostA, hostName: "Local", name: "web", isRunning: true)],
        controlToken: "abc"
    )
}

@Suite struct FleetSnapshotTests {
    @Test func encodesAndDecodesWithoutLoss() throws {
        let snapshot = sampleSnapshot()
        let data = try SnapshotStore.encoder().encode(snapshot)
        let decoded = try SnapshotStore.decoder().decode(FleetSnapshot.self, from: data)
        #expect(decoded == snapshot)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"generatedAt\":\"2027-01-15T08:00:00Z\""))
        #expect(text.contains("\"kind\":\"hostFailed\""))
    }

    @Test func totalsCountUpHostsAndProblems() {
        let snapshot = sampleSnapshot()
        #expect(snapshot.hostsUp == 1)
        #expect(snapshot.running == 3)
        #expect(snapshot.unhealthy == 1)
        #expect(snapshot.problemCount == 2)
    }

    @Test func sameContentIgnoresTheTimestamp() {
        let a = sampleSnapshot(at: Date(timeIntervalSince1970: 1))
        var b = sampleSnapshot(at: Date(timeIntervalSince1970: 2))
        #expect(a.hasSameContent(as: b))
        b.hosts[0].running = 9
        #expect(!a.hasSameContent(as: b))
    }

    @Test func containerListIsCapped() {
        let host = UUID()
        let many = (0..<500).map { FleetSnapshot.ContainerRef(hostID: host, hostName: "h", name: "c\($0)", isRunning: false) }
        let snapshot = FleetSnapshot(generatedAt: .now, hosts: [], topProblem: nil, appleServices: nil, containers: many, controlToken: "")
        #expect(snapshot.containers.count == FleetSnapshot.containerLimit)
    }

    @Test func containerRefIDRoundTrips() {
        let ref = FleetSnapshot.ContainerRef(hostID: UUID(), hostName: "h", name: "db|primary", isRunning: true)
        let parts = FleetSnapshot.ContainerRef.split(ref.id)
        #expect(parts?.hostID == ref.hostID)
        #expect(parts?.name == "db|primary")
        #expect(FleetSnapshot.ContainerRef.split("not-a-uuid|x") == nil)
        #expect(FleetSnapshot.ContainerRef.split("\(UUID().uuidString)|") == nil)
    }
}

@Suite struct SnapshotStoreTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gantry-shared-\(UUID().uuidString)")
        return dir
    }

    @Test func writesEveryLocationAndReadsTheNewest() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("a/snap.json")
        let second = dir.appendingPathComponent("b/snap.json")
        let store = SnapshotStore(locations: [first, second])
        #expect(try store.write(sampleSnapshot()) == 2)

        // An older copy in one place must lose to the newer one.
        let older = SnapshotStore(locations: [second])
        try older.write(sampleSnapshot(at: Date(timeIntervalSince1970: 5)))
        #expect(store.read()?.generatedAt == sampleSnapshot().generatedAt)
    }

    @Test func skipsUnreadableAndOldVersionFiles() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("bad.json")
        let old = dir.appendingPathComponent("old.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: bad)
        var stale = sampleSnapshot(at: .distantFuture)
        stale.version = 0
        try SnapshotStore.encoder().encode(stale).write(to: old)
        #expect(SnapshotStore(locations: [bad, old]).read() == nil)
    }

    @Test func failsOnlyWhenNoLocationWorks() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blocker = dir.appendingPathComponent("file")
        try Data().write(to: blocker)
        let impossible = blocker.appendingPathComponent("sub/snap.json")
        let good = dir.appendingPathComponent("ok/snap.json")
        #expect(try SnapshotStore(locations: [impossible, good]).write(sampleSnapshot()) == 1)
        #expect(throws: (any Error).self) {
            try SnapshotStore(locations: [impossible]).write(sampleSnapshot())
        }
    }

    @Test func standardStoreEndsWithTheFallbackFile() {
        let store = SnapshotStore.standard()
        #expect(store.locations.count == 1)
        let last = store.locations.last?.path ?? ""
        #expect(last.hasSuffix("Library/Application Support/Gantry/Widgets/fleet-snapshot.json"))
        #expect(!last.contains("/Containers/"))
    }
}

@Suite struct ControlRequestTests {
    @Test func appleServicesRoundTrip() {
        let request = ControlRequest(action: .setAppleServices(running: false), token: "t0k")
        #expect(request.url.scheme == "gantry")
        #expect(ControlRequest.parse(request.url) == request)
    }

    @Test func containerRoundTripKeepsSpecialCharacters() {
        let host = UUID()
        let request = ControlRequest(action: .setContainer(hostID: host, name: "my app&co", running: true), token: "x y")
        #expect(ControlRequest.parse(request.url) == request)
    }

    @Test func rejectsForeignOrIncompleteURLs() {
        #expect(ControlRequest.parse(URL(string: "https://control?token=a&target=apple-services&running=1")!) == nil)
        #expect(ControlRequest.parse(URL(string: "gantry://control?target=apple-services&running=1")!) == nil)
        #expect(ControlRequest.parse(URL(string: "gantry://control?token=a&target=apple-services&running=yes")!) == nil)
        #expect(ControlRequest.parse(URL(string: "gantry://control?token=a&target=container&running=1&name=x")!) == nil)
        #expect(ControlRequest.parse(URL(string: "gantry://other?token=a&target=apple-services&running=1")!) == nil)
    }

    @Test func authorizationNeedsTheSameNonEmptyToken() {
        let request = ControlRequest(action: .setAppleServices(running: true), token: "secret")
        #expect(request.isAuthorized(expectedToken: "secret"))
        #expect(!request.isAuthorized(expectedToken: "other"))
        #expect(!ControlRequest(action: .setAppleServices(running: true), token: "").isAuthorized(expectedToken: ""))
    }
}
