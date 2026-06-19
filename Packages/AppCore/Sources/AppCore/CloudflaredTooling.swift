import Foundation

/// Detects whether Cloudflare's `cloudflared` CLI is installed and, when it
/// isn't, drives a Homebrew install. Also reports whether the user has logged
/// in to Cloudflare (a prerequisite for named tunnels) and can launch the
/// browser-based login.
///
/// Mirrors `ContainerTooling`: the install path shells out to Homebrew — never
/// silently — so the user always confirms a system change.
public enum CloudflaredTooling {
    /// The Homebrew formula name (`brew install cloudflared`).
    public static let formula = "cloudflared"

    /// Cloudflare's download/install docs, offered when Homebrew is absent.
    public static let installPageURL = URL(string: "https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/")!

    /// Override for the `cloudflared` binary path (tests / non-standard installs).
    public static let cliEnvOverride = "GANTRY_CLOUDFLARED"

    /// The outcome of a tooling check.
    public enum State: Sendable, Equatable {
        /// `cloudflared` is installed (carrying its version, "unknown" if the
        /// binary exists but didn't report one).
        case ok(version: String)
        /// No `cloudflared` binary was found.
        case notInstalled
    }

    public struct Status: Sendable, Equatable {
        public var state: State
        /// Whether Homebrew is available to run the install.
        public var brewAvailable: Bool
        /// Whether a Cloudflare login certificate is present (named tunnels need it).
        public var loggedIn: Bool

        public init(state: State, brewAvailable: Bool, loggedIn: Bool) {
            self.state = state
            self.brewAvailable = brewAvailable
            self.loggedIn = loggedIn
        }

        public var isInstalled: Bool {
            if case .ok = state { return true }
            return false
        }
    }

    // MARK: - Detection

    /// The cert Cloudflare writes after `cloudflared tunnel login`. Its presence
    /// is what unlocks named tunnels (DNS routing against the account's zones).
    public static var loginCertPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".cloudflared/cert.pem")
    }

    /// Whether the user has completed `cloudflared tunnel login`.
    public static func isLoggedIn() -> Bool {
        FileManager.default.fileExists(atPath: loginCertPath)
    }

    /// Locates the `cloudflared` binary: env override first, then the common
    /// Homebrew prefixes.
    public static func cliPath() -> String? {
        if let override = ProcessInfo.processInfo.environment[cliEnvOverride],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        return ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Inspects the install: binary, version, Homebrew, and login state.
    public static func check() async -> Status {
        let brew = brewPath() != nil
        let loggedIn = isLoggedIn()
        guard let cli = cliPath() else {
            return Status(state: .notInstalled, brewAvailable: brew, loggedIn: loggedIn)
        }
        guard let raw = try? await runCapture(cli, ["--version"]),
              let version = parseVersion(raw) else {
            return Status(state: .ok(version: "unknown"), brewAvailable: brew, loggedIn: loggedIn)
        }
        return Status(state: .ok(version: version), brewAvailable: brew, loggedIn: loggedIn)
    }

    /// Extracts an `x.y.z` version from `cloudflared --version` output, e.g.
    /// "cloudflared version 2024.8.3 (built ...)".
    public static func parseVersion(_ text: String) -> String? {
        guard let match = text.firstMatch(of: /(\d+\.\d+\.\d+)/) else { return nil }
        return String(match.1)
    }

    // MARK: - Install / login

    /// Installs the `cloudflared` formula via Homebrew, streaming each line.
    public static func install(progress: @escaping @Sendable (String) -> Void) async throws {
        guard let brew = brewPath() else { throw CloudflaredError.homebrewMissing }
        try await runStreaming(brew, ["install", formula], progress: progress)
    }

    /// Runs `cloudflared tunnel login`, which opens a browser for the user to
    /// authorize a zone and writes `cert.pem`. Streams progress (the auth URL is
    /// printed there) and returns once the cert exists.
    public static func login(progress: @escaping @Sendable (String) -> Void) async throws {
        guard let cli = cliPath() else { throw CloudflaredError.notInstalled }
        try await runStreaming(cli, ["tunnel", "login"], progress: progress)
    }

    /// Locates the Homebrew binary.
    public static func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Process plumbing

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
            throw CloudflaredError.commandFailed(Int(process.terminationStatus))
        }
    }
}

public enum CloudflaredError: Error, LocalizedError, Equatable {
    case homebrewMissing
    case notInstalled
    case commandFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .homebrewMissing:
            "Homebrew isn't installed. Install it from https://brew.sh, then try again."
        case .notInstalled:
            "cloudflared isn't installed."
        case .commandFailed(let code):
            "The command exited with code \(code)."
        }
    }
}
