import Foundation
import Testing
import DockerKit
@testable import AppCore

/// A probe that sleeps, fails or blocks until released, and counts calls.
private final class FakeProbe: DiskAccessProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let delay: TimeInterval
    let error: Error?

    init(delay: TimeInterval = 0, error: Error? = nil) {
        self.delay = delay
        self.error = error
    }

    var callCount: Int { lock.withLock { calls } }

    func probe(_ path: String) throws {
        lock.withLock { calls += 1 }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if let error { throw error }
    }
}

private struct ProbeError: Error {}

/// Collects the waits that the gate reports as slow.
private final class WaitLog: @unchecked Sendable {
    private let lock = NSLock()
    private var slow: [DiskAccessWait] = []
    private var done: [UUID] = []
    func addSlow(_ wait: DiskAccessWait) { lock.withLock { slow.append(wait) } }
    func addDone(_ wait: DiskAccessWait) { lock.withLock { done.append(wait.id) } }
    var slowWaits: [DiskAccessWait] { lock.withLock { slow } }
    var doneIDs: [UUID] { lock.withLock { done } }
}

struct DiskAccessGateTests {
    @Test func bootDiskPathsNeedNoProbe() async throws {
        let probe = FakeProbe(delay: 5)
        let gate = DiskAccessGate(probe: probe, timeout: .milliseconds(20))
        #expect(!gate.needsProbe("/Users/me/data"))
        #expect(await gate.check("/Users/me/data") == .accessible)
        try await gate.waitForAccess(["/Users/me/data"], onSlow: { _ in Issue.record("no wait expected") })
        #expect(probe.callCount == 0)
    }

    @Test func fastAccessPassesAndIsRemembered() async throws {
        let probe = FakeProbe()
        let gate = DiskAccessGate(probe: probe, timeout: .seconds(2))
        #expect(await gate.check("/Volumes/Fast/a") == .accessible)
        #expect(!gate.needsProbe("/Volumes/Fast/other"))
        try await gate.waitForAccess(["/Volumes/Fast/b"], onSlow: { _ in Issue.record("no wait expected") })
        #expect(probe.callCount == 1)
        #expect(gate.needsProbe("/Volumes/Other/x"))
    }

    @Test func slowCheckReportsThePermissionPrompt() async {
        let gate = DiskAccessGate(probe: FakeProbe(delay: 1), timeout: .milliseconds(30))
        let clock = ContinuousClock()
        let start = clock.now
        let state = await gate.check("/Volumes/My Disk/data")
        #expect(state == .waitingForPermission(diskName: "My Disk"))
        #expect(clock.now - start < .milliseconds(800), "the check must not wait for the probe")
        #expect(gate.needsProbe("/Volumes/My Disk/data"))
    }

    @Test func failedCheckGivesTheError() async {
        let gate = DiskAccessGate(probe: FakeProbe(error: ProbeError()), timeout: .seconds(2))
        if case .failed = await gate.check("/Volumes/Fast/a") {} else { Issue.record("expected a failure") }
    }

    @Test func slowWaitShowsAHintThenFinishes() async throws {
        let gate = DiskAccessGate(probe: FakeProbe(delay: 0.3), timeout: .milliseconds(30))
        let log = WaitLog()
        try await gate.waitForAccess(
            ["/Volumes/Fast/a", "/Volumes/Fast/b"],
            onSlow: { log.addSlow($0) },
            onDone: { log.addDone($0) }
        )
        #expect(log.slowWaits.count == 1, "one hint per disk")
        #expect(log.slowWaits.first?.diskName == "Fast")
        #expect(log.slowWaits.first?.message.contains("Fast") == true)
        #expect(!gate.needsProbe("/Volumes/Fast/c"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(log.doneIDs == log.slowWaits.map(\.id))
    }

    @Test func cancelEndsTheWaitAtOnce() async throws {
        let gate = DiskAccessGate(probe: FakeProbe(delay: 2), timeout: .milliseconds(20))
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: CancellationError.self) {
            try await gate.waitForAccess(["/Volumes/Slow/a"], onSlow: { wait in wait.cancel() })
        }
        #expect(clock.now - start < .seconds(1))
        #expect(gate.needsProbe("/Volumes/Slow/a"))
    }

    @Test func cancelOfTheTaskEndsTheWait() async throws {
        let gate = DiskAccessGate(probe: FakeProbe(delay: 2), timeout: .milliseconds(20))
        let task = Task { try await gate.waitForAccess(["/Volumes/Slow/a"], onSlow: { _ in }) }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func failedWaitThrowsTheProbeError() async {
        let gate = DiskAccessGate(probe: FakeProbe(error: ProbeError()), timeout: .seconds(2))
        await #expect(throws: ProbeError.self) {
            try await gate.waitForAccess(["/Volumes/Fast/a"], onSlow: { _ in })
        }
    }

    @Test func folderCheckShowsTheHintWhenTheProbeIsSlow() async {
        let gate = DiskAccessGate(probe: FakeProbe(delay: 1), timeout: .milliseconds(20))
        let check = await StorageCheckLoader.folderVolume(path: "/Volumes/Slow/vols", gate: gate)
        #expect(check.issues == [.waitingForPermission("Slow")])
        #expect(!check.isAllowed)
        #expect(StorageIssue.waitingForPermission("Slow").message.contains("Files and Folders"))
        #expect(DiskAccessSettings.filesAndFoldersURL.scheme == "x-apple.systempreferences")
    }

    @Test func bindCheckShowsTheHintWhenTheProbeIsSlow() async {
        let gate = DiskAccessGate(probe: FakeProbe(delay: 1), timeout: .milliseconds(20))
        let findings = await StorageCheckLoader.bindMounts(
            paths: ["/Volumes/Slow/a", "/Users/me/b"], presence: DiskPresence(mounted: ["/Volumes/Slow"]), gate: gate
        )
        #expect(findings.map(\.path) == ["/Volumes/Slow/a"])
        #expect(findings.first?.check.issues == [.waitingForPermission("Slow")])
    }

    @Test func overviewSkipsTheScanWhileMacOSAsks() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gstore-\(UUID().uuidString)/root.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = AppleDataRootStore(fileURL: url)
        try store.save(AppleDataRoot(path: "/Volumes/Slow/com.apple.container"))
        let gate = DiskAccessGate(probe: FakeProbe(delay: 1), timeout: .milliseconds(20))
        let overview = await StorageOverview.load(serviceRoot: nil, store: store, gate: gate)
        #expect(overview.permissionPending == "Slow")
        #expect(overview.usage == nil && overview.disk == nil)
    }
}
