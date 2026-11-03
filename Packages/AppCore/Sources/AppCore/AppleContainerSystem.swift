import Foundation

/// Errors from the apple/container system-management commands (builder,
/// registry logins, kernel, logs, properties).
public enum AppleSystemError: Error, LocalizedError, Sendable, Equatable {
    /// The CLI does not know the command: in 1.6+ `container builder` is a CLI
    /// plugin, and a package can ship without it.
    case pluginMissing(String)
    /// A value the user typed failed validation before it reached the CLI.
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .pluginMissing(let command):
            "The `container \(command)` command is not installed. Install the official apple/container package, which includes the plugin."
        case .invalidInput(let message):
            message
        }
    }
}

/// One component of `container system version` (the CLI or the API server).
public struct AppleComponentVersion: Sendable, Equatable, Identifiable, Codable {
    public var appName: String
    public var version: String
    public var build: String
    public var commit: String

    public var id: String { appName }

    public init(appName: String, version: String, build: String = "", commit: String = "") {
        self.appName = appName
        self.version = version
        self.build = build
        self.commit = commit
    }
}

/// `container system status --format json`. Fields other than `status` arrive
/// with apple/container 1.4+; on older CLIs they stay nil.
public struct AppleSystemStatus: Sendable, Equatable, Codable {
    public var status: String
    public var client: AppleComponentVersion?
    public var server: AppleComponentVersion?
    public var hostOperatingSystem: String?
    public var hostArchitecture: String?
    public var hostCPUs: Int?
    public var appRoot: String?
    public var installRoot: String?
    public var logRoot: String?
    public var containersRunning: Int?
    public var containersTotal: Int?
    public var images: Int?

    public var isRunning: Bool { status == "running" }

    public init(status: String) {
        self.status = status
    }
}

extension AppleContainerControl {
    // MARK: - Version and status

    /// `container system version --format json`: the CLI and the API server
    /// versions. The server entry is missing while the services are stopped.
    public static func systemVersions(cliOverride: String? = nil) async throws -> [AppleComponentVersion] {
        let output = try await runContainer(["system", "version", "--format", "json"], cliOverride: cliOverride)
        return parseSystemVersions(output)
    }

    /// `container system status --format json`. A stopped service still
    /// answers; the CLI only fails when it cannot run at all.
    public static func systemStatus(cliOverride: String? = nil) async throws -> AppleSystemStatus {
        guard let cli = cliPath(override: cliOverride) else { throw AppleControlError.cliNotFound }
        let result = await run(cli, ["system", "status", "--format", "json"])
        if let parsed = parseSystemStatus(result.stdout) { return parsed }
        if result.exitCode != 0 { return AppleSystemStatus(status: "stopped") }
        throw AppleControlError.command("Could not read `container system status`.")
    }

    static func parseSystemVersions(_ json: String) -> [AppleComponentVersion] {
        guard let any = jsonObject(json) else { return [] }
        let objects: [[String: Any]]
        if let array = any as? [[String: Any]] {
            objects = array
        } else if let object = any as? [String: Any] {
            objects = [object]
        } else {
            return []
        }
        return objects.compactMap(componentVersion)
    }

    static func parseSystemStatus(_ json: String) -> AppleSystemStatus? {
        guard let object = jsonObject(json) as? [String: Any],
              let status = object["status"] as? String else { return nil }
        var result = AppleSystemStatus(status: status)
        result.client = (object["client"] as? [String: Any]).flatMap(componentVersion)
        result.server = (object["server"] as? [String: Any]).flatMap(componentVersion)
        if let host = object["host"] as? [String: Any] {
            result.hostOperatingSystem = nonEmpty(host["operatingSystem"] as? String)
            result.hostArchitecture = nonEmpty(host["architecture"] as? String)
            result.hostCPUs = intValue(host["cpus"])
        }
        // Pre-1.4 status put the paths at the top level.
        let paths = object["paths"] as? [String: Any] ?? object
        result.appRoot = nonEmpty(paths["appRoot"] as? String)
        result.installRoot = nonEmpty(paths["installRoot"] as? String)
        result.logRoot = nonEmpty(paths["logRoot"] as? String)
        if let resources = object["resources"] as? [String: Any] {
            result.containersRunning = intValue(resources["containersRunning"])
            result.containersTotal = intValue(resources["containersTotal"])
            result.images = intValue(resources["images"])
        }
        return result
    }

    private static func componentVersion(_ object: [String: Any]) -> AppleComponentVersion? {
        guard let name = object["appName"] as? String,
              let version = object["version"] as? String else { return nil }
        return AppleComponentVersion(
            appName: name,
            version: version,
            build: (object["buildType"] as? String) ?? (object["build"] as? String) ?? "",
            commit: (object["commit"] as? String) ?? ""
        )
    }

    // MARK: - Shared helpers

    /// Runs `container <arguments>` and returns stdout. A non-zero exit throws
    /// the CLI's own message, or `pluginMissing` when the CLI does not know the
    /// command (a missing 1.6 plugin).
    static func runContainer(
        _ arguments: [String],
        cliOverride: String?,
        input: Data? = nil
    ) async throws -> String {
        guard let cli = cliPath(override: cliOverride) else { throw AppleControlError.cliNotFound }
        let result = await run(cli, arguments, input: input)
        guard result.exitCode == 0 else {
            throw commandError(arguments: arguments, stdout: result.stdout, stderr: result.stderr)
        }
        return result.stdout
    }

    static func commandError(arguments: [String], stdout: String, stderr: String) -> Error {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if isUnknownCommand(message), let command = arguments.first {
            return AppleSystemError.pluginMissing(command)
        }
        if !message.isEmpty { return AppleControlError.command(message) }
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return AppleControlError.command(out) }
        return AppleControlError.command("container \(arguments.joined(separator: " ")) failed.")
    }

    /// The CLI's answer to a command it has no built-in or plugin for.
    static func isUnknownCommand(_ message: String) -> Bool {
        message.contains("unknown command") || message.contains("is a plugin, check that it exists")
    }

    static func jsonObject(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func intValue(_ any: Any?) -> Int? {
        if let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.intValue
        }
        if let string = any as? String { return Int(string) }
        return nil
    }

    static func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.isEmpty else { return nil }
        return string
    }

    /// Removes ANSI escape sequences (colors, cursor moves of a progress bar).
    public static func stripANSI(_ text: String) -> String {
        text.replacing(/\u{1B}\[[0-9;?]*[ -\/]*[@-~]/, with: "")
    }

    // MARK: - Streaming

    /// Runs `container <arguments>` and yields each output line (stdout and
    /// stderr merged; carriage returns from progress bars also end a line).
    /// The stream finishes when the process exits and throws on a non-zero
    /// exit. Cancelling the consumer terminates the process.
    public static func streamContainer(
        _ arguments: [String],
        cliOverride: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let cli = cliPath(override: cliOverride) else {
                continuation.finish(throwing: AppleControlError.cliNotFound)
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["NO_COLOR"] = "1"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice

            let splitter = LineSplitter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                for line in splitter.append(data) { continuation.yield(line) }
            }
            process.terminationHandler = { process in
                let trailing = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                pipe.fileHandleForReading.readabilityHandler = nil
                var lines = splitter.append(trailing)
                lines += splitter.flush()
                for line in lines { continuation.yield(line) }
                if process.terminationReason == .uncaughtSignal {
                    continuation.finish()
                } else if process.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    let tail = splitter.recentLines.joined(separator: "\n")
                    continuation.finish(throwing: commandError(arguments: arguments, stdout: "", stderr: tail))
                }
            }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.finish(throwing: error)
            }
        }
    }
}

/// Splits a byte stream into lines at `\n` or `\r`, dropping empty lines and
/// ANSI escapes. Keeps the last few lines for an error message.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private(set) var recentLines: [String] = []

    func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let chunk = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            if let line = clean(chunk) { lines.append(line) }
        }
        return lines
    }

    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let rest = buffer
        buffer.removeAll()
        return clean(rest).map { [$0] } ?? []
    }

    private func clean(_ data: Data) -> String? {
        let text = AppleContainerControl.stripANSI(String(decoding: data, as: UTF8.self))
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        recentLines.append(text)
        if recentLines.count > 8 { recentLines.removeFirst(recentLines.count - 8) }
        return text
    }
}
