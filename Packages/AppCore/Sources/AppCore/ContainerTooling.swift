import Foundation
import DockerKit

/// Detects whether a supported `apple/container` CLI is installed and, when it
/// isn't, drives a Homebrew install/upgrade.
///
/// Gantry tracks a minimum CLI version it has been tested against; older or
/// missing installs surface a setup prompt at launch (and after Gantry itself
/// updates). The install path shells out to Homebrew — never silently — so the
/// user always confirms a system change.
public enum ContainerTooling {
    /// The oldest CLI Gantry supports. Installs below this are flagged. 1.0
    /// restructured the CLI's JSON output and dropped major-version-0 XPC
    /// compatibility, so it is the tested baseline (the JSON bridge still parses
    /// 0.12 shapes defensively, but 0.12 is no longer the supported target).
    public static let minimumVersion = "1.0.0"
    /// The version Gantry is tested against; offered on a fresh install.
    public static let recommendedVersion = "1.6.1"
    /// The Homebrew formula name (`brew install container`).
    public static let formula = "container"

    /// The first CLI release with `container machine --virtualization` and
    /// `--kernel` (nested virtualization plus custom kernels).
    public static let nestedVirtualizationVersion = "1.1.0"
    /// The first CLI release where bind-mounting a Unix domain socket also
    /// works in containers that run as a non-root user.
    public static let socketMountVersion = "1.1.0"
    /// The first CLI release with `container run/create --kernel-arg`, which
    /// appends raw boot arguments to a container's kernel command line. The
    /// per-container `--kernel` it pairs with has been there since 1.0, so only
    /// the arguments need gating.
    public static let kernelArgumentsVersion = "1.2.0"
    /// The first CLI release with `container clean` (disk TRIM for running
    /// containers). 1.4.0 was never published; 1.4.1 is the first release.
    public static let containerCleanVersion = "1.4.0"
    /// The first CLI release with the Kubernetes plugin as `container k8s`
    /// with `--cni` (1.5.0 also removed `k8s start`).
    public static let clustersVersion = "1.5.0"
    /// Multi-worker clusters (`--workers`) and `--cni NONE`.
    public static let clusterWorkersVersion = "1.6.0"
    /// `container k8s` was renamed to `container cluster`.
    public static let clusterCommandRenameVersion = "1.6.1"
    /// The first CLI release where `container system kernel set` verifies a
    /// kernel archive against `--digest` (required for a remote `--tar` URL).
    public static let kernelArchiveDigestVersion = "1.2.0"
    /// The first CLI release whose `container system status` reports the
    /// client, host, paths and resource counts (1.4.1 is the first release).
    public static let systemStatusDetailsVersion = "1.4.0"
    /// The first CLI release where `container build` and `container builder`
    /// ship as CLI plugins. A package without the plugin answers the builder
    /// commands with "unknown command"; Gantry reports that rather than gating.
    public static let builderPluginVersion = "1.6.0"

    /// CLI features Gantry gates its UI on. Everything here is derived from the
    /// detected version — the CLI has no capability query.
    public struct Features: Sendable, Equatable {
        /// `container machine create --virtualization / --kernel`.
        public var nestedVirtualization: Bool
        /// Socket mounts that work in non-root containers.
        public var nonRootSocketMounts: Bool
        /// `container run/create --kernel-arg`.
        public var kernelArguments: Bool
        /// `container clean` (disk TRIM).
        public var containerClean: Bool
        /// The Kubernetes cluster subcommand: `cluster` (1.6.1+), `k8s`
        /// (1.5.0 to 1.6.0), or nil when the CLI has no usable one.
        public var clusterCommand: String?
        /// `cluster create --workers` and `--cni NONE`.
        public var clusterWorkers: Bool

        /// Local Kubernetes clusters.
        public var clusters: Bool { clusterCommand != nil }
        /// `container system kernel set --digest`.
        public var kernelArchiveDigest: Bool
        /// Host, client, paths and resources in `container system status`.
        public var systemStatusDetails: Bool

        public init(
            nestedVirtualization: Bool,
            nonRootSocketMounts: Bool,
            kernelArguments: Bool,
            containerClean: Bool = false,
            clusterCommand: String? = nil,
            clusterWorkers: Bool = false,
            kernelArchiveDigest: Bool = false,
            systemStatusDetails: Bool = false
        ) {
            self.nestedVirtualization = nestedVirtualization
            self.nonRootSocketMounts = nonRootSocketMounts
            self.kernelArguments = kernelArguments
            self.containerClean = containerClean
            self.clusterCommand = clusterCommand
            self.clusterWorkers = clusterWorkers
            self.kernelArchiveDigest = kernelArchiveDigest
            self.systemStatusDetails = systemStatusDetails
        }
    }

    /// The features an installed CLI of `version` offers. An unknown version
    /// (the binary answered `--version` in a shape we can't parse) is treated
    /// optimistically so the UI doesn't hide options from a newer CLI.
    public static func features(for version: String?) -> Features {
        guard let version, version != "unknown" else {
            return Features(
                nestedVirtualization: true,
                nonRootSocketMounts: true,
                kernelArguments: true,
                containerClean: true,
                clusterCommand: "cluster",
                clusterWorkers: true,
                kernelArchiveDigest: true,
                systemStatusDetails: true
            )
        }
        return Features(
            nestedVirtualization: isVersion(version, atLeast: nestedVirtualizationVersion),
            nonRootSocketMounts: isVersion(version, atLeast: socketMountVersion),
            kernelArguments: isVersion(version, atLeast: kernelArgumentsVersion),
            containerClean: isVersion(version, atLeast: containerCleanVersion),
            clusterCommand: clusterCommand(for: version),
            clusterWorkers: isVersion(version, atLeast: clusterWorkersVersion),
            kernelArchiveDigest: isVersion(version, atLeast: kernelArchiveDigestVersion),
            systemStatusDetails: isVersion(version, atLeast: systemStatusDetailsVersion)
        )
    }

    private static func clusterCommand(for version: String) -> String? {
        if isVersion(version, atLeast: clusterCommandRenameVersion) { return "cluster" }
        if isVersion(version, atLeast: clustersVersion) { return "k8s" }
        return nil
    }

    /// The official signed installer releases page. Preferred over Homebrew:
    /// the Homebrew bottle ships only the core plugins and omits the machine API
    /// server, so `container machine` does not work on a brew install. The
    /// signed `.pkg` includes the full backend.
    public static let installerPageURL = URL(string: "https://github.com/apple/container/releases/latest")!

    /// The outcome of a tooling check.
    public enum State: Sendable, Equatable {
        /// A supported CLI is installed (carrying its version).
        case ok(version: String)
        /// A CLI is installed but older than `minimumVersion`.
        case outdated(current: String)
        /// No `container` CLI was found.
        case notInstalled
    }

    public struct Status: Sendable, Equatable {
        public var state: State
        /// Whether Homebrew is available to run the install/upgrade.
        public var brewAvailable: Bool

        public var needsAttention: Bool {
            if case .ok = state { return false }
            return true
        }
    }

    // MARK: - Detection

    /// Inspects the installed CLI and Homebrew availability.
    public static func check() async -> Status {
        let brew = brewPath() != nil
        guard let cli = AppleContainerCLIDiscovery.discover() else {
            return Status(state: .notInstalled, brewAvailable: brew)
        }
        guard let version = await detectVersion(cli) else {
            // The binary exists but didn't report a version — treat it as
            // present-and-usable rather than nagging on a parse miss.
            return Status(state: .ok(version: "unknown"), brewAvailable: brew)
        }
        if isVersion(version, atLeast: minimumVersion) {
            return Status(state: .ok(version: version), brewAvailable: brew)
        }
        return Status(state: .outdated(current: version), brewAvailable: brew)
    }

    /// The version of the CLI at `cliOverride` (or the discovered one). It
    /// is cached per binary and read again when the binary file changes,
    /// e.g. after a Homebrew upgrade. Nil when no CLI is found.
    public static func currentVersion(cliOverride: String? = nil) async -> String? {
        guard let cli = AppleContainerCLIDiscovery.discover(override: cliOverride) else { return nil }
        let version = await detectVersion(cli)
        return version ?? "unknown"
    }

    /// `features(for:)` against the version of the CLI at `cliOverride`
    /// (a host's CLI path override) or the discovered CLI.
    public static func currentFeatures(cliOverride: String? = nil) async -> Features {
        features(for: await currentVersion(cliOverride: cliOverride))
    }

    /// Forgets the cached versions, e.g. after an install or upgrade.
    public static func invalidateVersionCache() async {
        await versionCache.removeAll()
    }

    /// Reads `--version` unless the cache has the binary with the same
    /// identity (resolved path, size, modification date).
    private static func detectVersion(_ cli: String) async -> String? {
        let identity = BinaryIdentity(path: cli)
        if let cached = await versionCache.value(for: cli, identity: identity) { return cached }
        let raw = try? await runCapture(cli, ["--version"])
        let version = raw.flatMap(parseVersion)
        await versionCache.store(version, for: cli, identity: identity)
        return version
    }

    /// What identifies a binary on disk: a Homebrew upgrade changes the
    /// symlink target, a copied-over binary changes size or date.
    struct BinaryIdentity: Equatable, Sendable {
        var resolvedPath: String
        var size: Int?
        var modified: Date?

        init(path: String) {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            let attributes = try? FileManager.default.attributesOfItem(atPath: resolved)
            resolvedPath = resolved
            size = (attributes?[.size] as? NSNumber)?.intValue
            modified = attributes?[.modificationDate] as? Date
        }
    }

    /// Detected versions by CLI path.
    private actor VersionCache {
        private var entries: [String: (identity: BinaryIdentity, version: String?)] = [:]

        /// The cached version; nil (not cached) when the identity changed.
        func value(for path: String, identity: BinaryIdentity) -> String?? {
            guard let entry = entries[path], entry.identity == identity else { return nil }
            return .some(entry.version)
        }

        func store(_ version: String?, for path: String, identity: BinaryIdentity) {
            entries[path] = (identity, version)
        }

        func removeAll() { entries.removeAll() }
    }

    private static let versionCache = VersionCache()

    /// Extracts an `x.y[.z]` version from `container --version` output.
    public static func parseVersion(_ text: String) -> String? {
        guard let match = text.firstMatch(of: /(\d+\.\d+(?:\.\d+)?)/) else { return nil }
        return String(match.1)
    }

    /// Whether `a` is greater than or equal to `b` (dotted numeric versions).
    public static func isVersion(_ a: String, atLeast b: String) -> Bool {
        let lhs = a.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(lhs.count, rhs.count) {
            let x = i < lhs.count ? lhs[i] : 0
            let y = i < rhs.count ? rhs[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    // MARK: - Install / upgrade

    /// Installs the `container` formula via Homebrew, streaming each output
    /// line. Throws if Homebrew is missing or the command fails.
    public static func install(progress: @escaping @Sendable (String) -> Void) async throws {
        try await brew(["install", formula], progress: progress)
    }

    /// Upgrades the `container` formula via Homebrew.
    public static func upgrade(progress: @escaping @Sendable (String) -> Void) async throws {
        try await brew(["upgrade", formula], progress: progress)
    }

    /// Locates the Homebrew binary.
    public static func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Process plumbing

    private static func brew(
        _ arguments: [String],
        progress: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let brew = brewPath() else {
            throw ContainerToolingError.homebrewMissing
        }
        try await runStreaming(brew, arguments, progress: progress)
    }

    /// Runs an executable to completion, returning combined stdout (used for
    /// `--version`).
    private static func runCapture(_ executable: String, _ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs an executable, delivering each output line to `progress`, and
    /// throws on a non-zero exit. Homebrew needs `/opt/homebrew/bin` on PATH.
    private static func runStreaming(
        _ executable: String,
        _ arguments: [String],
        progress: @escaping @Sendable (String) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = env["PATH"].map { "\(extraPath):\($0)" } ?? extraPath
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let handle = pipe.fileHandleForReading
        try process.run()

        // Read line-buffered on a background queue while the process runs.
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newline]
                buffer.removeSubrange(...newline)
                progress(String(decoding: lineData, as: UTF8.self))
            }
        }
        if !buffer.isEmpty { progress(String(decoding: buffer, as: UTF8.self)) }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ContainerToolingError.commandFailed(Int(process.terminationStatus))
        }
    }
}

public enum ContainerToolingError: Error, LocalizedError, Equatable {
    case homebrewMissing
    case commandFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .homebrewMissing:
            "Homebrew isn't installed. Install it from https://brew.sh, then try again."
        case .commandFailed(let code):
            "The install command exited with code \(code)."
        }
    }
}
