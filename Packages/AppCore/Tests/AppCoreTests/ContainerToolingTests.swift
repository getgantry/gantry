import Foundation
import Testing
@testable import AppCore

struct ContainerToolingTests {
    @Test func parsesVersionFromCLIOutput() {
        #expect(ContainerTooling.parseVersion("container CLI version 0.12.3 (build: release)") == "0.12.3")
        #expect(ContainerTooling.parseVersion("container CLI version 1.0 (build)") == "1.0")
        #expect(ContainerTooling.parseVersion("no numbers here") == nil)
    }

    @Test func versionAtLeastComparison() {
        #expect(ContainerTooling.isVersion("0.12.3", atLeast: "0.12.0"))
        #expect(ContainerTooling.isVersion("0.12.0", atLeast: "0.12.0"))
        #expect(ContainerTooling.isVersion("1.0.0", atLeast: "0.12.99"))
        #expect(!ContainerTooling.isVersion("0.11.9", atLeast: "0.12.0"))
        #expect(!ContainerTooling.isVersion("0.12", atLeast: "0.12.1"))
        #expect(ContainerTooling.isVersion("0.12.1", atLeast: "0.12"))
    }

    @Test func statusNeedsAttention() {
        #expect(ContainerTooling.Status(state: .notInstalled, brewAvailable: true).needsAttention)
        #expect(ContainerTooling.Status(state: .outdated(current: "0.11.0"), brewAvailable: true).needsAttention)
        #expect(!ContainerTooling.Status(state: .ok(version: "0.12.3"), brewAvailable: true).needsAttention)
    }

    /// A fake `container` that prints `version`.
    private func writeFakeCLI(_ url: URL, version: String) throws {
        let script = "#!/bin/sh\necho 'container CLI version \(version) (build: release)'\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func featuresFollowTheHostCLIAndItsUpgrades() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gantry-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appendingPathComponent("old-container")
        let new = folder.appendingPathComponent("new-container")
        try writeFakeCLI(old, version: "1.4.0")
        try writeFakeCLI(new, version: "1.6.1")

        // Each override has its own version.
        #expect(await ContainerTooling.currentVersion(cliOverride: old.path) == "1.4.0")
        #expect(await ContainerTooling.currentVersion(cliOverride: new.path) == "1.6.1")
        #expect(await ContainerTooling.currentFeatures(cliOverride: old.path).clusterCommand == nil)
        #expect(await ContainerTooling.currentFeatures(cliOverride: new.path).clusterCommand != nil)

        // An upgrade in place (new size and date) is noticed.
        try writeFakeCLI(old, version: "1.5.10")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: old.path)
        #expect(await ContainerTooling.currentVersion(cliOverride: old.path) == "1.5.10")

        // A symlink that moves to another keg is noticed too.
        let link = folder.appendingPathComponent("container")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: old)
        #expect(await ContainerTooling.currentVersion(cliOverride: link.path) == "1.5.10")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: new)
        #expect(await ContainerTooling.currentVersion(cliOverride: link.path) == "1.6.1")

        // A missing override has no version.
        #expect(await ContainerTooling.currentVersion(cliOverride: folder.appendingPathComponent("none").path) == nil)
    }
}
