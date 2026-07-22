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
    public static let recommendedVersion = "1.1.0"
    /// The Homebrew formula name (`brew install container`).
    public static let formula = "container"

    /// The first CLI release with `container machine --virtualization` and
    /// `--kernel` (nested virtualization plus custom kernels).
    public static let nestedVirtualizationVersion = "1.1.0"
    /// The first CLI release where bind-mounting a Unix domain socket also
    /// works in containers that run as a non-root user.
    public static let socketMountVersion = "1.1.0"

    /// CLI features Gantry gates its UI on. Everything here is derived from the
    /// detected version — the CLI has no capability query.
    public struct Features: Sendable, Equatable {
        /// `container machine create --virtualization / --kernel`.
        public var nestedVirtualization: Bool
        /// Socket mounts that work in non-root containers.
        public var nonRootSocketMounts: Bool

        public init(nestedVirtualization: Bool, nonRootSocketMounts: Bool) {
            self.nestedVirtualization = nestedVirtualization
            self.nonRootSocketMounts = nonRootSocketMounts
        }
    }

    /// The features an installed CLI of `version` offers. An unknown version
    /// (the binary answered `--version` in a shape we can't parse) is treated
    /// optimistically so the UI doesn't hide options from a newer CLI.
    public static func features(for version: String?) -> Features {
        guard let version, version != "unknown" else {
            return Features(nestedVirtualization: true, nonRootSocketMounts: true)
        }
        return Features(
            nestedVirtualization: isVersion(version, atLeast: nestedVirtualizationVersion),
            nonRootSocketMounts: isVersion(version, atLeast: socketMountVersion)
        )
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
            await versionCache.store(nil)
            return Status(state: .notInstalled, brewAvailable: brew)
        }
        guard let raw = try? await runCapture(cli, ["--version"]),
              let version = parseVersion(raw) else {
            // The binary exists but didn't report a version — treat it as
            // present-and-usable rather than nagging on a parse miss.
            await versionCache.store("unknown")
            return Status(state: .ok(version: "unknown"), brewAvailable: brew)
        }
        await versionCache.store(version)
        if isVersion(version, atLeast: minimumVersion) {
            return Status(state: .ok(version: version), brewAvailable: brew)
        }
        return Status(state: .outdated(current: version), brewAvailable: brew)
    }

    /// The version the last `check()` detected, running one if none has yet.
    /// Views use this to gate version-dependent options without shelling out on
    /// every redraw.
    public static func currentVersion() async -> String? {
        if await versionCache.checked { return await versionCache.value }
        _ = await check()
        return await versionCache.value
    }

    /// `features(for:)` against the detected CLI version.
    public static func currentFeatures() async -> Features {
        features(for: await currentVersion())
    }

    /// Caches the detected version for the life of the process.
    private actor VersionCache {
        private(set) var value: String?
        private(set) var checked = false
        func store(_ version: String?) {
            value = version
            checked = true
        }
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
