import Foundation
import Testing
@testable import AppCore

/// Parsers and argument building for the apple/container system commands:
/// builder, registry logins, kernel, system logs, properties, version and
/// status. No CLI needed.
@Suite struct AppleSystemTests {
    // MARK: - Version and status

    @Test func parsesSystemVersions() {
        let json = #"[{"appName":"container","buildType":"release","commit":"abc","version":"1.6.1"},{"appName":"container-apiserver","buildType":"release","commit":"unspecified","version":"1.6.1"}]"#
        let versions = AppleContainerControl.parseSystemVersions(json)
        #expect(versions.count == 2)
        #expect(versions[0] == AppleComponentVersion(appName: "container", version: "1.6.1", build: "release", commit: "abc"))
        #expect(versions[1].appName == "container-apiserver")
        #expect(AppleContainerControl.parseSystemVersions("not json").isEmpty)
    }

    @Test func parsesSystemStatus() throws {
        let json = #"{"client":{"appName":"container","build":"release","commit":"unspecified","version":"1.6.1"},"host":{"architecture":"arm64","cpus":8,"operatingSystem":"Version 27.2 (Build 26B123)"},"paths":{"appRoot":"/Users/me/Library/Application Support/com.apple.container/","installRoot":"/opt/homebrew/Cellar/container/1.6.1/"},"resources":{"containersRunning":4,"containersTotal":5,"images":7},"server":{"appName":"container-apiserver","build":"release","commit":"unspecified","version":"1.6.0"},"status":"running"}"#
        let status = try #require(AppleContainerControl.parseSystemStatus(json))
        #expect(status.isRunning)
        #expect(status.client?.version == "1.6.1")
        #expect(status.client?.build == "release")
        #expect(status.server?.version == "1.6.0")
        #expect(status.hostArchitecture == "arm64")
        #expect(status.hostCPUs == 8)
        #expect(status.hostOperatingSystem == "Version 27.2 (Build 26B123)")
        #expect(status.appRoot == "/Users/me/Library/Application Support/com.apple.container/")
        #expect(status.installRoot == "/opt/homebrew/Cellar/container/1.6.1/")
        #expect(status.logRoot == nil)
        #expect(status.containersRunning == 4)
        #expect(status.containersTotal == 5)
        #expect(status.images == 7)
    }

    @Test func parsesOlderSystemStatus() throws {
        let status = try #require(AppleContainerControl.parseSystemStatus(#"{"status":"running","appRoot":"/a","installRoot":"/b"}"#))
        #expect(status.isRunning)
        #expect(status.client == nil)
        #expect(status.appRoot == "/a")
        #expect(status.installRoot == "/b")
        #expect(status.containersRunning == nil)
        #expect(AppleContainerControl.parseSystemStatus("[]") == nil)
    }

    @Test func detectsMissingPlugin() {
        let stderr = "Error: unknown command 'builder'\n\nIf 'builder' is a plugin, check that it exists under:"
        let error = AppleContainerControl.commandError(arguments: ["builder", "status"], stdout: "", stderr: stderr)
        #expect(error as? AppleSystemError == .pluginMissing("builder"))
        let other = AppleContainerControl.commandError(arguments: ["builder", "stop"], stdout: "", stderr: "boom")
        #expect(other.localizedDescription == "boom")
    }

    @Test func stripsANSIAndSplitsProgressLines() {
        #expect(AppleContainerControl.stripANSI("\u{1B}[2K\u{1B}[1G[1/3] Downloading 40%") == "[1/3] Downloading 40%")
        let splitter = LineSplitter()
        var lines = splitter.append(Data("first\r[1/3] 10%\rsecond\npart".utf8))
        lines += splitter.append(Data("ial\n\n".utf8))
        lines += splitter.flush()
        #expect(lines == ["first", "[1/3] 10%", "second", "partial"])
        #expect(splitter.recentLines.last == "partial")
    }

    // MARK: - Builder

    @Test func parsesBuilderStatus() throws {
        let json = #"[{"configuration":{"id":"buildkit","image":{"reference":"ghcr.io/apple/container-builder-shim/builder:0.13.2"},"resources":{"cpus":2,"memoryInBytes":2147483648},"rosetta":true},"id":"buildkit","status":{"networks":[{"ipv4Address":"192.168.64.7/24"}],"startedDate":"2026-11-03T12:27:31Z","state":"running"}}]"#
        let status = try #require(AppleContainerControl.parseBuilderStatus(json))
        #expect(status.id == "buildkit")
        #expect(status.image == "ghcr.io/apple/container-builder-shim/builder:0.13.2")
        #expect(status.isRunning)
        #expect(status.ipAddress == "192.168.64.7")
        #expect(status.cpus == 2)
        #expect(status.memoryBytes == 2_147_483_648)
        #expect(status.rosetta == true)
        #expect(status.startedDate == "2026-11-03T12:27:31Z")
    }

    @Test func builderStatusEmptyMeansNoBuilder() {
        #expect(AppleContainerControl.parseBuilderStatus("[]") == nil)
        #expect(AppleContainerControl.parseBuilderStatus("") == nil)
        let stopped = AppleContainerControl.parseBuilderStatus(#"[{"id":"buildkit","status":"stopped","configuration":{"image":{"reference":"img"}}}]"#)
        #expect(stopped?.isRunning == false)
        #expect(stopped?.state == "stopped")
    }

    @Test func builderStartArguments() throws {
        #expect(try AppleBuilderStartOptions().arguments() == ["builder", "start"])
        let options = AppleBuilderStartOptions(
            cpus: 4,
            memory: "4g",
            dnsServers: ["1.1.1.1", " ", "2001:db8::1"],
            dnsDomain: "test",
            dnsSearchDomains: ["example.com"],
            dnsOptions: ["ndots:2"]
        )
        #expect(try options.arguments() == [
            "builder", "start", "--cpus", "4", "--memory", "4g",
            "--dns", "1.1.1.1", "--dns", "2001:db8::1", "--dns-domain", "test",
            "--dns-search", "example.com", "--dns-option", "ndots:2"
        ])
    }

    @Test func builderStartRejectsBadValues() {
        #expect(throws: AppleSystemError.self) { try AppleBuilderStartOptions(cpus: 0).arguments() }
        #expect(throws: AppleSystemError.self) { try AppleBuilderStartOptions(memory: "lots").arguments() }
        #expect(throws: AppleSystemError.self) { try AppleBuilderStartOptions(dnsServers: ["1.2.3"]).arguments() }
        #expect(throws: AppleSystemError.self) { try AppleBuilderStartOptions(dnsDomain: "-bad").arguments() }
        #expect(throws: AppleSystemError.self) { try AppleBuilderStartOptions(dnsOptions: ["a b"]).arguments() }
    }

    @Test func builderDeleteArguments() {
        #expect(AppleContainerControl.builderDeleteArguments(force: false) == ["builder", "delete"])
        #expect(AppleContainerControl.builderDeleteArguments(force: true) == ["builder", "delete", "--force"])
    }

    @Test func memorySizes() {
        for good in ["1024", "512k", "512kb", "2048mb", "2048MiB", "4g", "4GB", "1t", "1p", "8b"] {
            #expect(AppleContainerControl.isValidMemorySize(good), "\(good)")
        }
        for bad in ["", "g", "4 g", "4x", "-1g", "1.5g"] {
            #expect(!AppleContainerControl.isValidMemorySize(bad), "\(bad)")
        }
    }

    // MARK: - Registry

    @Test func parsesRegistryLogins() {
        let json = #"[{"creationDate":783000000,"id":"ghcr.io","labels":{},"modificationDate":783000100,"name":"ghcr.io","username":"me"},{"creationDate":"2026-01-02T03:04:05Z","id":"docker.io","name":"docker.io","username":"you","modificationDate":"2026-01-02T03:04:05.5Z"}]"#
        let logins = AppleContainerControl.parseRegistryLogins(json)
        #expect(logins.map(\.hostname) == ["docker.io", "ghcr.io"])
        #expect(logins[1].username == "me")
        #expect(logins[1].created == Date(timeIntervalSinceReferenceDate: 783_000_000))
        #expect(logins[0].created == ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z"))
        #expect(logins[0].modified != nil)
        #expect(AppleContainerControl.parseRegistryLogins("[]").isEmpty)
    }

    @Test func registryLoginArgumentsNeverCarryPassword() throws {
        let arguments = try AppleContainerControl.registryLoginArguments(server: " ghcr.io ", username: "me", scheme: .https)
        #expect(arguments == ["registry", "login", "--username", "me", "--password-stdin", "ghcr.io"])
        let http = try AppleContainerControl.registryLoginArguments(server: "localhost:5000", username: "me", scheme: .http)
        #expect(http == ["registry", "login", "--username", "me", "--password-stdin", "--scheme", "http", "localhost:5000"])
    }

    @Test func registryLoginRejectsBadInput() async {
        #expect(throws: AppleSystemError.self) {
            try AppleContainerControl.registryLoginArguments(server: "bad host", username: "me", scheme: .https)
        }
        #expect(throws: AppleSystemError.self) {
            try AppleContainerControl.registryLoginArguments(server: "ghcr.io", username: " ", scheme: .https)
        }
        await #expect(throws: AppleSystemError.self) {
            try await AppleContainerControl.loginRegistry(server: "ghcr.io", username: "me", password: "", cliOverride: "/nonexistent")
        }
    }

    @Test func registryServerNames() {
        for good in ["docker.io", "ghcr.io", "localhost", "localhost:5000", "[::1]:5000", "registry.example.com:443"] {
            #expect(AppleContainerControl.isValidRegistryServer(good), "\(good)")
        }
        for bad in ["", "https://ghcr.io", "a b", "-bad.io", "host:port", "ghcr.io/path"] {
            #expect(!AppleContainerControl.isValidRegistryServer(bad), "\(bad)")
        }
    }

    // MARK: - Kernel

    @Test func kernelRecommendedArguments() throws {
        #expect(try AppleKernelRequest.recommended.arguments() == ["system", "kernel", "set", "--recommended", "--force"])
        #expect(try AppleKernelRequest(source: .recommended).arguments() == ["system", "kernel", "set", "--recommended"])
    }

    @Test func kernelBinaryArguments() throws {
        let request = AppleKernelRequest(source: .binary(path: "/tmp/vmlinux"), architecture: .amd64, force: true)
        #expect(try request.arguments() == ["system", "kernel", "set", "--arch", "amd64", "--binary", "/tmp/vmlinux", "--force"])
        #expect(throws: AppleSystemError.self) {
            try AppleKernelRequest(source: .binary(path: "vmlinux")).arguments()
        }
    }

    @Test func kernelArchiveArguments() throws {
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let remote = AppleKernelRequest(source: .archive(location: "https://example.com/k.tar.zst", member: "opt/vmlinux", digest: digest))
        #expect(try remote.arguments() == [
            "system", "kernel", "set", "--arch", "arm64", "--tar", "https://example.com/k.tar.zst",
            "--binary", "opt/vmlinux", "--digest", digest
        ])
        let local = AppleKernelRequest(source: .archive(location: "/tmp/k.tar", member: "vmlinux", digest: nil))
        #expect(try local.arguments() == ["system", "kernel", "set", "--arch", "arm64", "--tar", "/tmp/k.tar", "--binary", "vmlinux"])
    }

    @Test func kernelArchiveValidation() {
        // A remote archive needs a digest on 1.2+.
        #expect(throws: AppleSystemError.self) {
            try AppleKernelRequest(source: .archive(location: "https://example.com/k.tar", member: "vmlinux", digest: nil)).arguments()
        }
        // Older CLIs have no --digest: a remote archive goes without one…
        #expect((try? AppleKernelRequest(source: .archive(location: "https://example.com/k.tar", member: "vmlinux", digest: nil))
            .arguments(supportsDigest: false)) != nil)
        // …and a digest cannot be passed.
        #expect(throws: AppleSystemError.self) {
            try AppleKernelRequest(source: .archive(location: "/k.tar", member: "vmlinux", digest: "sha256:" + String(repeating: "0", count: 64)))
                .arguments(supportsDigest: false)
        }
        #expect(throws: AppleSystemError.self) {
            try AppleKernelRequest(source: .archive(location: "/k.tar", member: "vmlinux", digest: "md5:abc")).arguments()
        }
        #expect(throws: AppleSystemError.self) {
            try AppleKernelRequest(source: .archive(location: "/k.tar", member: " ", digest: nil)).arguments()
        }
        #expect(throws: AppleSystemError.self) {
            try AppleKernelRequest(source: .archive(location: "k.tar", member: "vmlinux", digest: nil)).arguments()
        }
    }

    @Test func detectsInstalledKernel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gantry-kernel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let kernels = root.appendingPathComponent("kernels")
        try FileManager.default.createDirectory(at: kernels, withIntermediateDirectories: true)
        #expect(!AppleContainerControl.defaultKernel(appRoot: root).isInstalled)

        let file = kernels.appendingPathComponent("vmlinux-6.18")
        try Data("k".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(
            at: kernels.appendingPathComponent("default.kernel-arm64"), withDestinationURL: file
        )
        let info = AppleContainerControl.defaultKernel(appRoot: root)
        #expect(info.isInstalled)
        #expect(info.kernelFile == "vmlinux-6.18")
        #expect(!AppleContainerControl.defaultKernel(appRoot: root, architecture: .amd64).isInstalled)

        // A dangling link is not an installed kernel.
        try FileManager.default.removeItem(at: file)
        #expect(!AppleContainerControl.defaultKernel(appRoot: root).isInstalled)
    }

    @Test func recognisesMissingKernelErrors() {
        #expect(AppleContainerControl.isMissingKernelError("Error: notFound: \"default kernel not found at /x/kernels/default.kernel-arm64\""))
        #expect(AppleContainerControl.isMissingKernelError("No default kernel configured."))
        #expect(AppleContainerControl.isMissingKernelError("Please use the `container system kernel set --recommended` command"))
        #expect(!AppleContainerControl.isMissingKernelError("image not found"))
    }

    @Test func progressFractions() {
        #expect(AppleContainerControl.progressFraction(in: "[2/3] Downloading kernel 45% (13 MB/30 MB)") == 0.45)
        #expect(AppleContainerControl.progressFraction(in: "100 %") == 1.0)
        #expect(AppleContainerControl.progressFraction(in: "Installing kernel...") == nil)
        #expect(AppleContainerControl.progressFraction(in: "250%") == nil)
    }

    // MARK: - System logs

    @Test func systemLogArguments() throws {
        #expect(try AppleContainerControl.systemLogArguments(last: nil, follow: false) == ["system", "logs"])
        #expect(try AppleContainerControl.systemLogArguments(last: "30m", follow: true) == ["system", "logs", "--last", "30m", "--follow"])
        #expect(try AppleContainerControl.systemLogArguments(last: " ", follow: false) == ["system", "logs"])
        #expect(throws: AppleSystemError.self) { try AppleContainerControl.systemLogArguments(last: "5 minutes", follow: false) }
        #expect(throws: AppleSystemError.self) { try AppleContainerControl.systemLogArguments(last: "0m", follow: false) }
        #expect(AppleContainerControl.isValidLogPeriod("90"))
        #expect(AppleContainerControl.isValidLogPeriod("2d"))
        #expect(!AppleContainerControl.isValidLogPeriod("2w"))
    }

    @Test func parsesSystemLogLine() {
        let raw = "2026-11-03 13:57:00.790179+0100 0x149b338  Info        0x0                  40328  0    container-runtime-linux: [com.apple.container:RuntimeLinuxHelper] starting XPC server [uuid=x]"
        let line = AppleSystemLogLine(raw: raw)
        #expect(line.timestamp == "2026-11-03 13:57:00.790179+0100")
        #expect(line.type == "Info")
        #expect(line.process == "container-runtime-linux")
        #expect(line.message == "[com.apple.container:RuntimeLinuxHelper] starting XPC server [uuid=x]")
        #expect(!line.isHeader)
        #expect(line.level == .info)
        #expect(AppleSystemLogLine(raw: raw.replacingOccurrences(of: "Info  ", with: "Fault ")).level == .error)
        #expect(AppleSystemLogLine(raw: raw.replacingOccurrences(of: "Info  ", with: "Debug ")).level == .debug)

        let header = AppleSystemLogLine(raw: "Timestamp                       Thread     Type        Activity             PID    TTL")
        #expect(header.isHeader)
        #expect(header.message == header.raw)
        let other = AppleSystemLogLine(raw: "free text")
        #expect(other.type == nil && other.process == nil && other.message == "free text")
    }

    // MARK: - Properties

    @Test func flattensPropertyList() {
        let json = #"{"build":{"cpus":2,"image":"img:1","memory":"2048mb","rosetta":true},"dns":{},"kernel":{"url":"https://x/k.tar"},"plugin":{"foo":{"ratio":0.5}},"network":{"list":[1,2]}}"#
        let values = AppleContainerControl.parsePropertyList(json)
        #expect(values["build.cpus"] == .integer(2))
        #expect(values["build.rosetta"] == .bool(true))
        #expect(values["build.memory"] == .string("2048mb"))
        #expect(values["kernel.url"] == .string("https://x/k.tar"))
        #expect(values["plugin.foo.ratio"] == .number(0.5))
        #expect(values["network.list"] == .other("[1,2]"))
        #expect(values["dns.domain"] == nil)
    }

    @Test func mergesPropertiesWithSchemaAndUserFile() throws {
        let merged = AppleContainerControl.mergeProperties(
            effective: ["build.cpus": .integer(2), "custom.flag": .bool(true)],
            user: ["build.cpus": .integer(4), "dns.domain": .string("test")]
        )
        let keys = merged.map(\.key)
        #expect(keys.first == "build.cpus")
        #expect(keys.contains("dns.domain"))
        #expect(keys.contains("network.subnetv6"))
        #expect(keys.last == "custom.flag")
        // No `[machine]` table reported: the machine plugin keys stay hidden.
        #expect(!keys.contains("machine.cpus"))

        let cpus = try #require(merged.first { $0.key == "build.cpus" })
        #expect(cpus.kind == .count)
        #expect(cpus.isPendingRestart)
        #expect(cpus.section == "build" && cpus.name == "cpus")
        let domain = try #require(merged.first { $0.key == "dns.domain" })
        #expect(domain.effective == nil && domain.isPendingRestart)
        let custom = try #require(merged.first { $0.key == "custom.flag" })
        #expect(custom.kind == .unknown && !custom.isPendingRestart)

        let withMachine = AppleContainerControl.mergeProperties(effective: ["machine.cpus": .integer(4)], user: [:])
        #expect(withMachine.contains { $0.key == "machine.homeMount" })
    }

    @Test func validatesPropertyValues() throws {
        typealias C = AppleContainerControl
        #expect(try C.validatedPropertyValue("yes", kind: .bool) == .bool(true))
        #expect(try C.validatedPropertyValue("false", kind: .bool) == .bool(false))
        #expect(try C.validatedPropertyValue(" 8 ", kind: .count) == .integer(8))
        #expect(try C.validatedPropertyValue("4G", kind: .memory) == .string("4g"))
        #expect(try C.validatedPropertyValue("https://example.com/k.tar", kind: .url) == .string("https://example.com/k.tar"))
        #expect(try C.validatedPropertyValue("test", kind: .domain) == .string("test"))
        #expect(try C.validatedPropertyValue("localhost:5000", kind: .registryHost) == .string("localhost:5000"))
        #expect(try C.validatedPropertyValue("192.168.100.0/24", kind: .cidrV4) == .string("192.168.100.0/24"))
        #expect(try C.validatedPropertyValue("fd00:abcd::/64", kind: .cidrV6) == .string("fd00:abcd::/64"))
        #expect(try C.validatedPropertyValue("RO", kind: .homeMount) == .string("ro"))
        #expect(try C.validatedPropertyValue("12", kind: .unknown) == .integer(12))
        #expect(try C.validatedPropertyValue("ghcr.io/a/b:1", kind: .imageReference) == .string("ghcr.io/a/b:1"))

        let bad: [(String, AppleSystemPropertyKind)] = [
            ("", .string), ("maybe", .bool), ("0", .count), ("-2", .count), ("two", .count),
            ("4 gigs", .memory), ("ftp://x", .url), ("not a url", .url), ("sha1:abc", .digest),
            ("bad domain", .domain), ("https://ghcr.io", .registryHost), ("192.168.1.0/33", .cidrV4),
            ("192.168.1/24", .cidrV4), ("fd00::/129", .cidrV6), ("10.0.0.0/8", .cidrV6),
            ("rwx", .homeMount), ("a b", .imageReference), ("line\nbreak", .string)
        ]
        for (value, kind) in bad {
            #expect(throws: AppleSystemError.self, "\(value) as \(kind)") {
                try C.validatedPropertyValue(value, kind: kind)
            }
        }
    }

    @Test func parsesUserConfigTOML() {
        let toml = """
        # user config
        top = 1

        [build]
        cpus = 4 # more
        memory = "4g"
        rosetta = false
        image = 'literal:tag'

        [dns]
        domain = "te\\"st"

        [plugin.foo]
        "quoted key" = 1_000
        ratio = 0.25
        list = [1, 2]
        """
        let values = AppleContainerControl.parseConfigTOML(toml)
        #expect(values["top"] == .integer(1))
        #expect(values["build.cpus"] == .integer(4))
        #expect(values["build.memory"] == .string("4g"))
        #expect(values["build.rosetta"] == .bool(false))
        #expect(values["build.image"] == .string("literal:tag"))
        #expect(values["dns.domain"] == .string("te\"st"))
        #expect(values["plugin.foo.quoted key"] == .integer(1000))
        #expect(values["plugin.foo.ratio"] == .number(0.25))
        #expect(values["plugin.foo.list"] == .other("[1, 2]"))
    }

    @Test func updatesUserConfigTOML() throws {
        typealias C = AppleContainerControl
        // Into an empty file: a new table.
        #expect(try C.updatedConfigTOML("", key: "build.cpus", value: .integer(4)) == "[build]\ncpus = 4\n")

        let base = """
        # mine
        [build]
        cpus = 2 # old

        [dns]
        domain = "test"
        """
        // Replace an existing value, keep the rest (and the comment).
        let replaced = try C.updatedConfigTOML(base, key: "build.cpus", value: .integer(6))
        #expect(replaced == "# mine\n[build]\ncpus = 6 # old\n\n[dns]\ndomain = \"test\"")
        // Add a key to an existing table, after its last entry.
        let added = try C.updatedConfigTOML(base, key: "build.memory", value: .string("4g"))
        #expect(added == "# mine\n[build]\ncpus = 2 # old\nmemory = \"4g\"\n\n[dns]\ndomain = \"test\"")
        // Remove a key.
        let removed = try C.updatedConfigTOML(base, key: "dns.domain", value: nil)
        #expect(removed == "# mine\n[build]\ncpus = 2 # old\n\n[dns]\n")
        // Removing a key that is not there changes nothing.
        #expect(try C.updatedConfigTOML(base, key: "kernel.url", value: nil) == base)
        // A new table goes at the end, after a blank line.
        let table = try C.updatedConfigTOML(base, key: "network.subnet", value: .string("10.0.0.0/24"))
        #expect(table == base + "\n\n[network]\nsubnet = \"10.0.0.0/24\"\n")
        // Dotted tables and quoting.
        let plugin = try C.updatedConfigTOML("", key: "plugin.foo.say", value: .string("a \"b\"\\"))
        #expect(plugin == "[plugin.foo]\nsay = \"a \\\"b\\\"\\\\\"\n")
        #expect(C.parseConfigTOML(plugin)["plugin.foo.say"] == .string("a \"b\"\\"))
        // The DNS helper and the general writer agree.
        #expect(C.parseDNSDomain(try C.updatedConfigTOML(base, key: "dns.domain", value: .string("dev"))) == "dev")
    }

    @Test func splitsPropertyKeys() {
        #expect(AppleContainerControl.splitPropertyKey("build.cpus") == ("build", "cpus"))
        #expect(AppleContainerControl.splitPropertyKey("plugin.foo.bar") == ("plugin.foo", "bar"))
        #expect(AppleContainerControl.splitPropertyKey("top") == ("", "top"))
    }

    // MARK: - Version gates

    @Test func systemFeatureGates() {
        let old = ContainerTooling.features(for: "1.1.0")
        #expect(!old.kernelArchiveDigest)
        #expect(!old.systemStatusDetails)
        let mid = ContainerTooling.features(for: "1.2.0")
        #expect(mid.kernelArchiveDigest)
        #expect(!mid.systemStatusDetails)
        let current = ContainerTooling.features(for: "1.6.1")
        #expect(current.kernelArchiveDigest)
        #expect(current.systemStatusDetails)
        let unknown = ContainerTooling.features(for: nil)
        #expect(unknown.kernelArchiveDigest && unknown.systemStatusDetails)
    }
}
