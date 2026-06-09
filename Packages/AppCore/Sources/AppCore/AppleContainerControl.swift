import Foundation
import DockerKit

/// State of the apple/container background services (`container system`).
public enum AppleServiceStatus: Sendable, Equatable {
    case running
    case stopped
    /// The `container` CLI could not be located.
    case unavailable
    case unknown

    public var isRunning: Bool { self == .running }
}

public enum AppleControlError: Error, LocalizedError, Sendable {
    case cliNotFound
    case invalidDomain(String)
    case command(String)

    public var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "The apple/container CLI could not be found."
        case .invalidDomain(let name):
            "“\(name)” is not a valid domain name. Use letters, digits, dots and hyphens."
        case .command(let message):
            message
        }
    }
}

/// apple/container operations that have no Docker-API equivalent and so live
/// outside `DockerClient`: managing the background services and the local DNS
/// domains that make containers resolvable by name. Everything shells out to
/// the same `container` binary the transport uses.
///
/// DNS create/delete require administrator rights; those run through an
/// `osascript` authorization prompt so the user approves once via the standard
/// macOS dialog rather than Gantry holding a privileged helper.
public enum AppleContainerControl {
    /// Resolves the `container` binary, honoring a host's CLI path override.
    public static func cliPath(override: String? = nil) -> String? {
        AppleContainerCLIDiscovery.discover(override: override)
    }

    // MARK: - Services

    public static func serviceStatus(cliOverride: String? = nil) async -> AppleServiceStatus {
        guard let cli = cliPath(override: cliOverride) else { return .unavailable }
        let result = await run(cli, ["system", "status"])
        guard result.exitCode == 0 else { return .stopped }
        for line in result.stdout.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).filter { !$0.isEmpty }
            if fields.first == "status" {
                return fields.dropFirst().first == "running" ? .running : .stopped
            }
        }
        return .unknown
    }

    public static func startServices(cliOverride: String? = nil) async throws {
        guard let cli = cliPath(override: cliOverride) else { throw AppleControlError.cliNotFound }
        // `--disable-kernel-install` keeps 1.0 from blocking on the interactive
        // kernel-download prompt when stdin is not a terminal.
        let result = await run(cli, ["system", "start", "--disable-kernel-install"])
        // `system start` can still exit non-zero (e.g. the machine API server
        // check) while bringing the core services up, so confirm by re-checking.
        if result.exitCode != 0, await serviceStatus(cliOverride: cliOverride) != .running {
            throw AppleControlError.command(
                result.stderr.isEmpty ? "Could not start apple/container services." : result.stderr
            )
        }
    }

    public static func stopServices(cliOverride: String? = nil) async throws {
        guard let cli = cliPath(override: cliOverride) else { throw AppleControlError.cliNotFound }
        let result = await run(cli, ["system", "stop"])
        if result.exitCode != 0 {
            throw AppleControlError.command(
                result.stderr.isEmpty ? "Could not stop apple/container services." : result.stderr
            )
        }
    }

    // MARK: - Local DNS domains

    public static func listDomains(cliOverride: String? = nil) async throws -> [String] {
        guard let cli = cliPath(override: cliOverride) else { throw AppleControlError.cliNotFound }
        let result = await run(cli, ["system", "dns", "list", "--format", "json"])
        guard result.exitCode == 0 else {
            throw AppleControlError.command(result.stderr.isEmpty ? "Could not list DNS domains." : result.stderr)
        }
        return parseDomains(result.stdout)
    }

    /// Creates a local DNS domain (admin). After this, a container started with
    /// `--dns-domain <name>` resolves as `<container>.<name>`.
    public static func createDomain(_ name: String, cliOverride: String? = nil) async throws {
        let domain = try validatedDomain(name)
        guard let cli = cliPath(override: cliOverride) else { throw AppleControlError.cliNotFound }
        try await runPrivileged(cli, ["system", "dns", "create", domain])
    }

    public static func deleteDomain(_ name: String, cliOverride: String? = nil) async throws {
        let domain = try validatedDomain(name)
        guard let cli = cliPath(override: cliOverride) else { throw AppleControlError.cliNotFound }
        try await runPrivileged(cli, ["system", "dns", "delete", domain])
    }

    // MARK: - Validation

    /// A domain name safe to interpolate into the privileged shell command:
    /// letters, digits, dots and hyphens only.
    private static func validatedDomain(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !trimmed.hasPrefix("-"), !trimmed.hasPrefix(".") else {
            throw AppleControlError.invalidDomain(name)
        }
        return trimmed
    }

    private static func parseDomains(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let strings = any as? [String] { return strings.sorted() }
        if let objects = any as? [[String: Any]] {
            let keys = ["domainName", "domain", "name", "Domain", "Name"]
            return objects.compactMap { object in
                keys.lazy.compactMap { object[$0] as? String }.first
            }.sorted()
        }
        return []
    }

    // MARK: - Process plumbing

    struct RunResult: Sendable {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    static func run(_ executable: String, _ arguments: [String]) async -> RunResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["NO_COLOR"] = "1"
            process.environment = environment
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            do {
                try process.run()
            } catch {
                continuation.resume(returning: RunResult(exitCode: -1, stdout: "", stderr: error.localizedDescription))
                return
            }
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            continuation.resume(returning: RunResult(
                exitCode: process.terminationStatus,
                stdout: String(decoding: outData, as: UTF8.self),
                stderr: String(decoding: errData, as: UTF8.self)
            ))
        }
    }

    /// Runs a `container` command with administrator rights via the standard
    /// macOS authorization dialog. Arguments are validated upstream and quoted.
    private static func runPrivileged(_ executable: String, _ arguments: [String]) async throws {
        let command = ([executable] + arguments).map { "'\($0)'" }.joined(separator: " ")
        let script = "do shell script \"\(command)\" with administrator privileges"
        let result = await run("/usr/bin/osascript", ["-e", script])
        if result.exitCode != 0 {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            // -128 is AppleScript's user-cancelled code.
            if message.contains("-128") || message.localizedCaseInsensitiveContains("cancel") {
                throw AppleControlError.command("Authorization was cancelled.")
            }
            throw AppleControlError.command(message.isEmpty ? "The privileged command failed." : message)
        }
    }
}
