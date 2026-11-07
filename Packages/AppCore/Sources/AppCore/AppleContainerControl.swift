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
            String(localized: "The apple/container CLI could not be found.", bundle: .module)
        case .invalidDomain(let name):
            String(localized: "“\(name)” is not a valid domain name. Use letters, digits, dots and hyphens.", bundle: .module)
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

    /// Starts the services on the data root that Gantry stores
    /// (``AppleDataRootStore``), or on `dataRoot` when given.
    public static func startServices(cliOverride: String? = nil, dataRoot: AppleDataRoot? = nil) async throws {
        guard let cli = cliPath(override: cliOverride) else { throw AppleControlError.cliNotFound }
        // `--disable-kernel-install` keeps 1.0 from blocking on the interactive
        // kernel-download prompt when stdin is not a terminal.
        let root = dataRoot ?? AppleDataRootStore.shared.load()
        let result = await run(cli, root.startArguments, environment: root.cliEnvironment)
        // `system start` can still exit non-zero (e.g. the machine API server
        // check) while bringing the core services up, so confirm by re-checking.
        if result.exitCode != 0, await serviceStatus(cliOverride: cliOverride) != .running {
            throw AppleControlError.command(
                result.stderr.isEmpty ? String(localized: "Could not start apple/container services.", bundle: .module) : result.stderr
            )
        }
    }

    public static func stopServices(cliOverride: String? = nil) async throws {
        guard let cli = cliPath(override: cliOverride) else { throw AppleControlError.cliNotFound }
        let result = await run(cli, ["system", "stop"])
        if result.exitCode != 0 {
            throw AppleControlError.command(
                result.stderr.isEmpty ? String(localized: "Could not stop apple/container services.", bundle: .module) : result.stderr
            )
        }
    }

    // MARK: - Local DNS domains

    public static func listDomains(cliOverride: String? = nil) async throws -> [String] {
        guard let cli = cliPath(override: cliOverride) else { throw AppleControlError.cliNotFound }
        let result = await run(cli, ["system", "dns", "list", "--format", "json"])
        guard result.exitCode == 0 else {
            throw AppleControlError.command(result.stderr.isEmpty ? String(localized: "Could not list DNS domains.", bundle: .module) : result.stderr)
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

    // MARK: - Default DNS domain (host name resolution)

    /// The system-wide default DNS domain from `~/.config/container/config.toml`,
    /// i.e. the suffix containers resolve under (`<name>.<domain>`). Empty when
    /// unset.
    public static func defaultDNSDomain() -> String {
        let url = configFileURL()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return parseDNSDomain(text) ?? ""
    }

    /// Sets (or clears, when `domain` is nil/empty) the default DNS domain in
    /// `~/.config/container/config.toml`. Containers *created after this* resolve
    /// as `<name>.<domain>` from the Mac. Takes effect once the services are
    /// restarted (`restartServices`). No admin needed — the file is in the user's
    /// home, written by the user account that runs the services.
    public static func setDefaultDNSDomain(_ domain: String?) throws {
        try setDefaultDNSDomain(domain, configURL: configFileURL())
    }

    static func setDefaultDNSDomain(_ domain: String?, configURL: URL) throws {
        let trimmed = domain?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let validated = trimmed.isEmpty ? nil : try validatedDomain(trimmed)
        try writeConfig(at: configURL) {
            try updatedConfigTOML($0, key: "dns.domain", value: validated.map { .string($0) })
        }
    }

    /// Stops then starts the background services so configuration changes (like a
    /// new default DNS domain) take effect. Running containers restart with them.
    public static func restartServices(cliOverride: String? = nil, dataRoot: AppleDataRoot? = nil) async throws {
        try? await stopServices(cliOverride: cliOverride)
        try await startServices(cliOverride: cliOverride, dataRoot: dataRoot)
        await flushDNSCache()
    }

    /// Flushes the macOS resolver cache so a freshly-registered `name.domain`
    /// resolves immediately, rather than returning a stale negative result the
    /// system cached before the container existed. Best-effort and unprivileged
    /// (`dscacheutil -flushcache`); the deeper `mDNSResponder` HUP needs admin and
    /// is not required for the local resolver to pick the record up.
    public static func flushDNSCache() async {
        _ = await run("/usr/bin/dscacheutil", ["-flushcache"])
    }

    static func configFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/container/config.toml")
    }

    /// Reads the `domain` value of the `[dns]` table from TOML text.
    static func parseDNSDomain(_ toml: String) -> String? {
        guard case .string(let domain)? = parseConfigTOML(toml)["dns.domain"], !domain.isEmpty else { return nil }
        return domain
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

    /// Runs `executable` to completion. `input`, when given, goes to stdin
    /// and the pipe is closed, so a secret such as a registry password never
    /// appears on argv. Cancelling the task terminates the process.
    static func run(
        _ executable: String,
        _ arguments: [String],
        environment extraEnvironment: [String: String] = [:],
        input: Data? = nil
    ) async -> RunResult {
        var environment = ["NO_COLOR": "1"].merging(AppleDataRootStore.shared.load().cliEnvironment) { _, new in new }
        environment.merge(extraEnvironment) { _, new in new }
        do {
            let result = try await ChildProcess.run(executable, arguments, environment: environment, input: input)
            return RunResult(
                exitCode: result.exit.signaled ? 128 + result.exit.status : result.exit.status,
                stdout: String(decoding: result.stdout, as: UTF8.self),
                stderr: String(decoding: result.stderr, as: UTF8.self)
            )
        } catch is CancellationError {
            return RunResult(exitCode: -1, stdout: "", stderr: String(localized: "Cancelled.", bundle: .module))
        } catch {
            return RunResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
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
                throw AppleControlError.command(String(localized: "Authorization was cancelled.", bundle: .module))
            }
            throw AppleControlError.command(message.isEmpty ? String(localized: "The privileged command failed.", bundle: .module) : message)
        }
    }
}
