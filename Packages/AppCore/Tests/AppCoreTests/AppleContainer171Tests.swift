import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

// Fixtures are real apple/container 1.7.1 outputs (signed package, a test
// cluster `gtest` with one worker): `system property list --format json`,
// `stats --no-stream --format json`, and the 1.7.1 source for the
// `[container.dns]` keys (ContainerSystemConfig.ContainerDNSConfig).

private let liveProperties171 = #"{"build":{"cpus":2,"image":"ghcr.io/apple/container-builder-shim/builder:0.13.3","memory":"2048mb","rosetta":true},"container":{"cpus":4,"memory":"1gb"},"dns":{},"kernel":{"binaryPath":"opt/kata/share/kata-containers/vmlinux-6.18.56-208-debug","digest":"sha256:2c5bf7cde334ad5307d482f45cceda496f91c9b6b96f5278c47f4f4eac1bbae6","url":"https://github.com/kata-containers/kata-containers/releases/download/4.3.1/kata-static-4.3.1-arm64.tar.zst"},"machine":{"cpus":4,"homeMount":"rw","memory":"8gb","virtualization":false},"network":{},"registry":{"domain":"docker.io"},"vminit":{"image":"ghcr.io/apple/containerization/vminit:0.54.0"}}"#

private func tempConfig(_ text: String?) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gantry-ac171-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("config.toml")
    if let text { try Data(text.utf8).write(to: url) }
    return url
}

@Suite struct ContainerDNSDefaultsTests {
    typealias C = AppleContainerControl

    @Test func featureStartsAt170() {
        #expect(!ContainerTooling.features(for: "1.6.1").containerDNSDefaults)
        #expect(ContainerTooling.features(for: "1.7.0").containerDNSDefaults)
        #expect(ContainerTooling.features(for: "1.7.1").containerDNSDefaults)
        #expect(ContainerTooling.features(for: nil).containerDNSDefaults)
    }

    @Test func listsContainerDNSKeysOnlyFrom170() {
        let effective = C.parsePropertyList(liveProperties171)
        let old = C.mergeProperties(effective: effective, user: [:], containerDNSDefaults: false).map(\.key)
        #expect(!old.contains("container.dns.nameservers"))
        let new = C.mergeProperties(effective: effective, user: [:], containerDNSDefaults: true)
        let keys = new.map(\.key)
        for key in C.containerDNSKeys { #expect(keys.contains(key)) }
        #expect(new.first { $0.key == "container.dns.nameservers" }?.kind == .nameserverList)
        #expect(new.first { $0.key == "container.dns.searchDomains" }?.kind == .domainList)
        #expect(new.first { $0.key == "container.dns.options" }?.kind == .stringList)
        #expect(new.first { $0.key == "container.dns.nameservers" }?.section == "container.dns")
        // The empty [dns] table still lists dns.domain, unset.
        #expect(new.first { $0.key == "dns.domain" }?.effective == nil)
        // A user value shows even when the CLI is older.
        let user = C.parseConfigTOML("[container.dns]\nnameservers = [\"1.1.1.1\"]\n")
        let withUser = C.mergeProperties(effective: effective, user: user, containerDNSDefaults: false)
        #expect(withUser.first { $0.key == "container.dns.nameservers" }?.user == .strings(["1.1.1.1"]))
    }

    /// A 1.6.1 host: `system property list --format json` has no
    /// [container.dns] table, and the 1.6.1 features do not list the keys.
    @Test func cli161ShowsNoDNSKeys() {
        let properties161 = #"{"build":{"cpus":2,"image":"ghcr.io/apple/container-builder-shim/builder:0.12.0","memory":"2048mb","rosetta":true},"container":{"cpus":4,"memory":"1gb"},"dns":{},"kernel":{},"network":{},"registry":{"domain":"docker.io"},"vminit":{}}"#
        let features = ContainerTooling.features(for: "1.6.1")
        let keys = C.mergeProperties(
            effective: C.parsePropertyList(properties161), user: [:],
            containerDNSDefaults: features.containerDNSDefaults
        ).map(\.key)
        #expect(keys.allSatisfy { !C.containerDNSKeys.contains($0) })
        #expect(keys.contains("dns.domain"))
    }

    @Test func readsStringArrays() {
        let toml = """
        [container.dns]
        nameservers = ["1.1.1.1", '8.8.8.8']
        searchDomains = [
          "corp.example",
        ]
        options = []
        mixed = [1, "a"]
        """
        let values = C.parseConfigTOML(toml)
        #expect(values["container.dns.nameservers"] == .strings(["1.1.1.1", "8.8.8.8"]))
        #expect(values["container.dns.searchDomains"] == .strings(["corp.example"]))
        #expect(values["container.dns.options"] == .strings([]))
        #expect(values["container.dns.mixed"] == .other("[1, \"a\"]"))
        // The services print arrays as JSON.
        let effective = C.parsePropertyList(#"{"container":{"dns":{"nameservers":["1.1.1.1"]}}}"#)
        #expect(effective["container.dns.nameservers"] == .strings(["1.1.1.1"]))
    }

    @Test func displaysAndQuotesLists() {
        let value = AppleSystemPropertyValue.strings(["1.1.1.1", "a\"b"])
        #expect(value.display == "1.1.1.1, a\"b")
        #expect(value.tomlLiteral == #"["1.1.1.1", "a\"b"]"#)
        #expect(AppleSystemPropertyValue.strings([]).display == "[]")
        #expect(value.stringItems == ["1.1.1.1", "a\"b"])
        #expect(AppleSystemPropertyValue.integer(1).stringItems == nil)
    }

    @Test func validatesListRows() throws {
        #expect(try C.validatedPropertyList([" 1.1.1.1 ", "", "2606:4700:4700::1111"], kind: .nameserverList)
            == ["1.1.1.1", "2606:4700:4700::1111"])
        #expect(throws: AppleSystemError.self) { try C.validatedPropertyList(["dns.google"], kind: .nameserverList) }
        #expect(throws: AppleSystemError.self) { try C.validatedPropertyList(["1.1.1.1", "1.1.1.1"], kind: .nameserverList) }
        #expect(try C.validatedPropertyList(["corp.example"], kind: .domainList) == ["corp.example"])
        #expect(throws: AppleSystemError.self) { try C.validatedPropertyList(["bad domain"], kind: .domainList) }
        #expect(try C.validatedPropertyList(["ndots:2", "rotate"], kind: .stringList) == ["ndots:2", "rotate"])
        #expect(throws: AppleSystemError.self) { try C.validatedPropertyList(["a,b"], kind: .stringList) }
        #expect(try C.validatedPropertyValue("ndots:2 rotate", kind: .stringList) == .strings(["ndots:2", "rotate"]))
    }

    // MARK: - Round trips

    @Test func addsAListToANewTable() throws {
        let toml = "# my settings\n[build]\ncpus = 2 # two\n"
        let added = try C.updatedConfigTOML(toml, key: "container.dns.nameservers", value: .strings(["1.1.1.1", "8.8.8.8"]))
        #expect(added == "# my settings\n[build]\ncpus = 2 # two\n\n[container.dns]\nnameservers = [\"1.1.1.1\", \"8.8.8.8\"]\n")
        #expect(C.parseConfigTOML(added)["container.dns.nameservers"] == .strings(["1.1.1.1", "8.8.8.8"]))
    }

    @Test func addsAListUnderAnExistingTable() throws {
        let toml = "[container]\ncpus = 4\n\n[container.dns]\ndomain = \"test\"\nfuture = 1\n"
        let added = try C.updatedConfigTOML(toml, key: "container.dns.options", value: .strings(["ndots:2"]))
        #expect(added == "[container]\ncpus = 4\n\n[container.dns]\ndomain = \"test\"\nfuture = 1\noptions = [\"ndots:2\"]\n")
    }

    @Test func replacesAStringArrayAndKeepsTheRest() throws {
        let toml = """
        # DNS for containers
        [container.dns]
        nameservers = [
          "1.1.1.1",
          "8.8.8.8",
        ] # trailing comment
        unknown = { a = 1 }

        """
        let updated = try C.updatedConfigTOML(toml, key: "container.dns.nameservers", value: .strings(["9.9.9.9"]))
        #expect(updated == """
        # DNS for containers
        [container.dns]
        nameservers = ["9.9.9.9"] # trailing comment
        unknown = { a = 1 }

        """)
        // Round trip: write the parsed value back, nothing changes in meaning.
        let parsed = C.parseConfigTOML(updated)
        #expect(parsed["container.dns.nameservers"] == .strings(["9.9.9.9"]))
        #expect(parsed["container.dns.unknown.a"] == .integer(1))
        let again = try C.updatedConfigTOML(updated, key: "container.dns.nameservers", value: parsed["container.dns.nameservers"])
        #expect(again == updated)
        // Removing takes all the lines of a multi-line array.
        let removed = try C.updatedConfigTOML(toml, key: "container.dns.nameservers", value: nil)
        #expect(removed == "# DNS for containers\n[container.dns]\nunknown = { a = 1 }\n")
    }

    @Test func refusesArraysThatAreNotPlainStringLists() throws {
        // Comments inside the array would be lost.
        let commented = "[container.dns]\nnameservers = [\n  \"1.1.1.1\", # cloudflare\n]\n"
        #expect(throws: ConfigTOMLError.self) {
            try C.updatedConfigTOML(commented, key: "container.dns.nameservers", value: .strings(["9.9.9.9"]))
        }
        // A `#` inside a string is not a comment.
        let hashInString = "[container.dns]\noptions = [\"a#b\"]\n"
        #expect(try C.updatedConfigTOML(hashInString, key: "container.dns.options", value: .strings(["c"]))
            == "[container.dns]\noptions = [\"c\"]\n")
        let numbers = "[container.dns]\nnameservers = [1, 2]\n"
        #expect(throws: ConfigTOMLError.self) {
            try C.updatedConfigTOML(numbers, key: "container.dns.nameservers", value: .strings(["9.9.9.9"]))
        }
        // A string array cannot be replaced by a scalar.
        let strings = "[container.dns]\nnameservers = [\"1.1.1.1\"]\n"
        #expect(throws: ConfigTOMLError.self) {
            try C.updatedConfigTOML(strings, key: "container.dns.nameservers", value: .string("9.9.9.9"))
        }
    }

    @Test func writesListsToTheFile() throws {
        let url = try tempConfig("[build]\ncpus = 2\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let value = try C.setUserList("container.dns.searchDomains", to: ["corp.example", " "], configURL: url)
        #expect(value == .strings(["corp.example"]))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == "[build]\ncpus = 2\n\n[container.dns]\nsearchDomains = [\"corp.example\"]\n")
        // An empty list removes the key.
        #expect(try C.setUserList("container.dns.searchDomains", to: [""], configURL: url) == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "[build]\ncpus = 2\n\n[container.dns]\n")
        #expect(throws: AppleSystemError.self) {
            try C.setUserList("container.dns.nameservers", to: ["nope"], configURL: url)
        }
    }

    @Test func userAndRunningListsCompareByValue() {
        let property = AppleSystemProperty(
            key: "container.dns.nameservers", kind: .nameserverList,
            effective: .strings(["1.1.1.1"]), user: .strings(["1.1.1.1"])
        )
        #expect(!property.isPendingRestart)
        var changed = property
        changed.user = .strings(["8.8.8.8"])
        #expect(changed.isPendingRestart)
    }
}

@Suite struct ClusterServiceDiagnosisTests {
    typealias D = ClusterServiceDiagnosis
    static let unavailable = "Error: cluster service unavailable (XPC connection error: Connection invalid); make sure the system is running ('container system start') and restart it after upgrading"

    @Test func recognisesTheUnavailableError() {
        #expect(D.isServiceUnavailable(Self.unavailable))
        #expect(D.isServiceUnavailable("Error: XPC connection error: Connection invalid"))
        #expect(!D.isServiceUnavailable("Error: cluster gtest not found"))
        #expect(D.problem(forError: "Error: cluster gtest not found", cliPath: "/usr/local/bin/container") == nil)
    }

    @Test func homebrewWithoutThePluginNamesTheVersion() {
        let cli = "/opt/homebrew/Cellar/container/1.7.1/bin/container"
        let problem = D.problem(forError: Self.unavailable, cliPath: "/opt/homebrew/bin/container",
                                fileExists: { _ in false }, resolve: { _ in cli })
        #expect(problem == .homebrewMissingPlugin(version: "1.7.1"))
        #expect(problem?.needsInstaller == true)
        #expect(problem?.advice.contains("Homebrew build of container 1.7.1") == true)
        // A bottle revision is dropped.
        #expect(D.homebrewVersion(root: "/opt/homebrew/Cellar/container/1.7.1_1") == "1.7.1")
        // Only the XPC service plugin is not enough: the host store is required too.
        let partial = D.problem(
            forError: Self.unavailable, cliPath: cli,
            fileExists: { $0.hasSuffix("libexec/container-plugins/container-core-clusters") }, resolve: { $0 }
        )
        #expect(partial == .homebrewMissingPlugin(version: "1.7.1"))
    }

    @Test func homebrewWithThePluginsSuggestsARestart() {
        let cli = "/opt/homebrew/Cellar/container/1.7.1/bin/container"
        let problem = D.problem(forError: Self.unavailable, cliPath: cli,
                                fileExists: { $0.contains("/libexec/container-plugins/") }, resolve: { $0 })
        #expect(problem == .servicesNotRunning)
        #expect(problem?.needsInstaller == false)
    }

    @Test func signedPackageLayout() {
        let cli = "/usr/local/bin/container"
        let installed: Set<String> = [
            "/usr/local/libexec/container/plugins",
            "/usr/local/libexec/container/plugins/container-core-clusters",
            "/usr/local/libexec/container/plugins/cluster-hoststore"
        ]
        #expect(D.problem(forError: Self.unavailable, cliPath: cli, fileExists: installed.contains, resolve: { $0 })
            == .servicesNotRunning)
        let missing = installed.subtracting(["/usr/local/libexec/container/plugins/container-core-clusters"])
        #expect(D.problem(forError: Self.unavailable, cliPath: cli, fileExists: missing.contains, resolve: { $0 })
            == .pluginMissing)
        // An unknown layout (no plugins folder) falls back to a restart.
        #expect(D.problem(forError: Self.unavailable, cliPath: "/somewhere/container", fileExists: { _ in false }, resolve: { $0 })
            == .servicesNotRunning)
        #expect(D.problem(forError: Self.unavailable, cliPath: nil) == .servicesNotRunning)
    }
}

@Suite struct Builder171Tests {
    @Test func flagsAnOutdatedBuilderImage() {
        let builder = AppleBuilderStatus(id: "buildkit", image: "ghcr.io/apple/container-builder-shim/builder:0.13.2", state: "running")
        let configured = AppleContainerControl.parsePropertyList(liveProperties171)["build.image"]
        guard case .string(let image)? = configured else {
            Issue.record("no build.image")
            return
        }
        #expect(builder.imageUpdate(configuredImage: image) == "ghcr.io/apple/container-builder-shim/builder:0.13.3")
        var current = builder
        current.image = image
        #expect(current.imageUpdate(configuredImage: image) == nil)
        #expect(builder.imageUpdate(configuredImage: nil) == nil)
        #expect(builder.imageUpdate(configuredImage: "  ") == nil)
    }

    @Test func imageTags() {
        #expect(AppleBuilderStatus.imageTag("ghcr.io/apple/container-builder-shim/builder:0.13.3") == "0.13.3")
        #expect(AppleBuilderStatus.imageTag("localhost:5000/builder") == "localhost:5000/builder")
        #expect(AppleBuilderStatus.imageTag("builder:1@sha256:abc") == "1")
    }
}

@Suite struct Kernel171Tests {
    /// The recommended kernel is whatever the CLI's `[kernel]` properties
    /// name (kata 4.3.1 in 1.7.1): Gantry passes `--recommended` and never a
    /// URL of its own.
    @Test func recommendedKernelFollowsTheCLI() throws {
        #expect(try AppleKernelRequest.recommended.arguments() == ["system", "kernel", "set", "--recommended", "--force"])
        let values = AppleContainerControl.parsePropertyList(liveProperties171)
        #expect(values["kernel.url"] == .string("https://github.com/kata-containers/kata-containers/releases/download/4.3.1/kata-static-4.3.1-arm64.tar.zst"))
        #expect(values["kernel.binaryPath"] == .string("opt/kata/share/kata-containers/vmlinux-6.18.56-208-debug"))
    }
}
