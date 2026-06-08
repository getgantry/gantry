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
}
