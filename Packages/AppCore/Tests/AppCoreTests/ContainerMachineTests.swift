import Foundation
import Testing
@testable import AppCore

// Fixtures captured from `container machine` (apple/container 1.0.0, pkg build).

struct ContainerMachineTests {
    @Test func decodesRunningMachineFromList() throws {
        let data = Data("""
        [{"diskSize":78643200,"cpus":5,"default":true,"memory":8589934592,"createdDate":"2026-06-09T08:52:06Z","id":"gantry-m1","status":"running","ipAddress":"192.168.65.2"}]
        """.utf8)
        let machines = try ContainerMachine.list(fromJSON: data)
        let m = try #require(machines.first)
        #expect(m.id == "gantry-m1")
        #expect(m.isRunning)
        #expect(m.cpus == 5)
        #expect(m.memory == 8_589_934_592)
        #expect(m.diskSize == 78_643_200)
        #expect(m.ipAddress == "192.168.65.2")
        #expect(m.isDefault)
        #expect(m.created == "2026-06-09T08:52:06Z")
    }

    @Test func decodesStoppedMachineWithoutIP() throws {
        // When stopped the CLI omits ipAddress entirely.
        let data = Data("""
        [{"cpus":5,"status":"stopped","diskSize":78675968,"memory":8589934592,"id":"gantry-m1","createdDate":"2026-06-09T08:52:06Z","default":true}]
        """.utf8)
        let m = try #require(try ContainerMachine.list(fromJSON: data).first)
        #expect(!m.isRunning)
        #expect(m.ipAddress.isEmpty)
        #expect(m.isDefault)
    }

    @Test func decodesInspectExtras() throws {
        let data = Data("""
        [{"containerId":"gantry-m1-d5b964","cpus":5,"createdDate":"2026-06-09T08:52:06Z","diskSize":78643200,"homeMount":"rw","id":"gantry-m1","image":{"descriptor":{"digest":"sha256:310c","size":9218},"reference":"docker.io/library/alpine:3.22"},"ipAddress":"192.168.65.2","memory":8589934592,"platform":{"architecture":"arm64","os":"linux"},"startedDate":"2026-06-09T08:52:09Z","status":"running","userSetup":{"gid":20,"uid":501,"username":"andrewkomkov"}}]
        """.utf8)
        let m = try #require(try ContainerMachine.list(fromJSON: data).first)
        #expect(m.imageReference == "docker.io/library/alpine:3.22")
        #expect(m.homeMount == "rw")
        #expect(m.username == "andrewkomkov")
        #expect(m.startedDate == "2026-06-09T08:52:09Z")
    }

    @Test func emptyListDecodes() throws {
        #expect(try ContainerMachine.list(fromJSON: Data("[]".utf8)).isEmpty)
    }
}
