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

    // MARK: - Boot config (apple/container 1.1)

    @Test func bootConfigIsNilWhenTheCLIOmitsIt() throws {
        // 1.1's inspect output still leaves virtualization/kernel out.
        let data = Data("""
        [{"cpus":5,"status":"running","memory":8589934592,"diskSize":0,"id":"gantry-m1","default":true}]
        """.utf8)
        let m = try #require(try ContainerMachine.list(fromJSON: data).first)
        #expect(m.nestedVirtualization == nil)
        #expect(m.kernelPath == nil)
    }

    @Test func decodesFlattenedBootConfig() throws {
        let data = Data("""
        [{"cpus":5,"status":"running","memory":8589934592,"diskSize":0,"id":"gantry-m1","virtualization":true,"kernelPath":"/opt/kernels/vmlinux"}]
        """.utf8)
        let m = try #require(try ContainerMachine.list(fromJSON: data).first)
        #expect(m.nestedVirtualization == true)
        #expect(m.kernelPath == "/opt/kernels/vmlinux")
    }

    @Test func decodesNestedBootConfig() throws {
        let data = Data("""
        [{"cpus":5,"status":"running","memory":8589934592,"diskSize":0,"id":"gantry-m1","bootConfig":{"cpus":5,"virtualization":true,"kernelPath":"/opt/kernels/vmlinux"}}]
        """.utf8)
        let m = try #require(try ContainerMachine.list(fromJSON: data).first)
        #expect(m.nestedVirtualization == true)
        #expect(m.kernelPath == "/opt/kernels/vmlinux")
    }
}

struct MachineSettingsTests {
    @Test func rendersKeyValueArguments() {
        let settings = AppleContainerControl.MachineSettings(
            cpus: 4,
            memory: "8G",
            homeMount: "ro",
            nestedVirtualization: true,
            kernelPath: "/opt/kernels/vmlinux"
        )
        #expect(settings.arguments == [
            "cpus=4", "memory=8G", "home-mount=ro",
            "virtualization=true", "kernel=/opt/kernels/vmlinux",
        ])
    }

    @Test func skipsUnsetValues() {
        let settings = AppleContainerControl.MachineSettings(cpus: 2)
        #expect(settings.arguments == ["cpus=2"])
        #expect(!settings.isEmpty)
    }

    @Test func emptyKernelResetsToTheSystemDefault() {
        // An empty (not nil) kernel path is meaningful: the CLI reads it as
        // "go back to the system kernel".
        let settings = AppleContainerControl.MachineSettings(kernelPath: "")
        #expect(settings.arguments == ["kernel="])
    }

    @Test func nothingSetIsEmpty() {
        #expect(AppleContainerControl.MachineSettings().isEmpty)
    }
}

struct ContainerToolingFeatureTests {
    @Test func nestedVirtualizationNeeds1_1() {
        #expect(!ContainerTooling.features(for: "1.0.0").nestedVirtualization)
        #expect(!ContainerTooling.features(for: "1.0.9").nestedVirtualization)
        #expect(ContainerTooling.features(for: "1.1.0").nestedVirtualization)
        #expect(ContainerTooling.features(for: "1.2").nestedVirtualization)
        #expect(ContainerTooling.features(for: "2.0.0").nestedVirtualization)
    }

    @Test func socketMountsNeed1_1() {
        #expect(!ContainerTooling.features(for: "1.0.0").nonRootSocketMounts)
        #expect(ContainerTooling.features(for: "1.1.0").nonRootSocketMounts)
    }

    @Test func kernelArgumentsNeed1_2() {
        #expect(!ContainerTooling.features(for: "1.0.0").kernelArguments)
        #expect(!ContainerTooling.features(for: "1.1.0").kernelArguments)
        #expect(ContainerTooling.features(for: "1.2.0").kernelArguments)
        #expect(ContainerTooling.features(for: "2.0.0").kernelArguments)
    }

    @Test func unknownVersionsAreTreatedOptimistically() {
        // A CLI we can't version-parse shouldn't have its options hidden.
        #expect(ContainerTooling.features(for: nil).nestedVirtualization)
        #expect(ContainerTooling.features(for: "unknown").nestedVirtualization)
        #expect(ContainerTooling.features(for: "unknown").kernelArguments)
    }
}
