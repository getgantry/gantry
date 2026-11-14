import Foundation
import DockerKit
import SSHKit

/// The output of one `docker` command.
public struct DockerCLIResult: Sendable, Equatable {
    public var exitCode: Int
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int, stdout: String, stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs `docker <arguments>` for one host.
public protocol DockerCLIRunner: Sendable {
    func run(_ arguments: [String]) async throws -> DockerCLIResult
}

/// Thrown by a runner when no `docker` executable is there.
public struct DockerCLIMissing: Error, Equatable {}

/// The local `docker` CLI, pointed at the socket of a local host.
public struct LocalDockerCLIRunner: DockerCLIRunner {
    public static let envOverride = "GANTRY_DOCKER"

    public let executable: String
    public let socketPath: String

    public init(executable: String, socketPath: String) {
        self.executable = executable
        self.socketPath = socketPath
    }

    /// The paths where Docker Desktop, Homebrew and the static binaries put `docker`.
    public static func searchPaths(home: String = NSHomeDirectory()) -> [String] {
        [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            home + "/.docker/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker"
        ]
    }

    public static func cliPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let override = environment[envOverride], isExecutable(override) { return override }
        return searchPaths().first(where: isExecutable)
    }

    public func run(_ arguments: [String]) async throws -> DockerCLIResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw DockerCLIMissing() }
        var environment = ProcessInfo.processInfo.environment
        environment["DOCKER_HOST"] = "unix://" + socketPath
        environment.removeValue(forKey: "DOCKER_CONTEXT")
        let directory = (executable as NSString).deletingLastPathComponent
        environment["PATH"] = [directory, environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        return try await Self.runProcess(executable, arguments, environment: environment)
    }

    static func runProcess(
        _ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval = 30
    ) async throws -> DockerCLIResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = environment
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                // A daemon that does not answer must not hold the view.
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
                // Read both pipes before the wait so a large output cannot block the child.
                let group = DispatchGroup()
                let errBox = DataBox()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                let errData = errBox.data
                continuation.resume(returning: DockerCLIResult(
                    exitCode: Int(process.terminationStatus),
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }
}

/// Written by one reader thread, read after `DispatchGroup.wait`.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// The `docker` CLI on an SSH host, over a new exec channel.
public struct SSHDockerCLIRunner: DockerCLIRunner {
    let makeClient: @Sendable () async throws -> SSHClient

    public init(makeClient: @escaping @Sendable () async throws -> SSHClient) {
        self.makeClient = makeClient
    }

    public func run(_ arguments: [String]) async throws -> DockerCLIResult {
        let command = (["docker"] + arguments).map(SSHCommand.quote).joined(separator: " ")
        let result = try await SSHCommand.run(command, makeClient: makeClient)
        // 127: the shell did not find `docker`.
        if result.exitCode == 127 { throw DockerCLIMissing() }
        return DockerCLIResult(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
    }
}

/// Whether a host can show `docker buildx history`.
public enum BuildxAvailability: Sendable, Equatable {
    case available(version: String)
    /// Apple container hosts have no buildx.
    case notDockerHost
    case noDockerCLI
    case noBuildx
    case tooOld(version: String)
    case failed(message: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// Reads `docker buildx history` with a runner. Read-only: see
/// `specs/010-build-history/contracts/buildx-cli.md`.
public enum BuildxHistoryService {
    public static func availability(runner: DockerCLIRunner?) async -> BuildxAvailability {
        guard let runner else { return .noDockerCLI }
        let result: DockerCLIResult
        do {
            result = try await runner.run(["buildx", "version"])
        } catch is DockerCLIMissing {
            return .noDockerCLI
        } catch {
            return .failed(message: error.localizedDescription)
        }
        guard result.exitCode == 0, let version = BuildxHistoryParser.version(from: result.stdout) else {
            return .noBuildx
        }
        return BuildxHistoryParser.isSupported(version) ? .available(version: version) : .tooOld(version: version)
    }

    /// The buildx records of the default builder, newest first.
    public static func records(runner: DockerCLIRunner, hostID: UUID) async throws -> [BuildRecord] {
        let result = try await runner.run(["buildx", "history", "ls", "--format", "json", "--no-trunc"])
        guard result.exitCode == 0 else { throw BuildxCommandError(result) }
        return try BuildxHistoryParser.records(from: result.stdout)
            .map { BuildRecord(buildx: $0, hostID: hostID) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// `record` with its log, steps and error from `inspect` and `logs`.
    public static func detail(of record: BuildRecord, runner: DockerCLIRunner) async throws -> BuildRecord {
        let id = record.id.split(separator: "/").last.map(String.init) ?? record.id
        guard isSafeID(id) else { throw BuildxCommandError(message: "invalid build record reference") }
        var detailed = record
        let inspect = try await runner.run(["buildx", "history", "inspect", "--format", "json", id])
        if inspect.exitCode == 0, let info = try? BuildxHistoryParser.inspect(from: inspect.stdout) {
            detailed.dockerfile = info.dockerfile ?? detailed.dockerfile
            detailed.contextPath = info.context ?? detailed.contextPath
            detailed.errorMessage = info.errorMessage
            if let started = info.startedAt { detailed.startedAt = started }
            if let ended = info.completedAt { detailed.endedAt = ended }
        } else if inspect.exitCode != 0 {
            throw BuildxCommandError(inspect)
        }
        let logs = try await runner.run(["buildx", "history", "logs", id])
        guard logs.exitCode == 0 else { throw BuildxCommandError(logs) }
        let capped = BuildLogLimit.cap(logs.stdout)
        detailed.log = capped.log
        detailed.logTruncated = capped.truncated
        detailed.steps = BuildProgressParser.steps(fromLog: logs.stdout, failed: detailed.status == .failed)
        return detailed
    }

    /// Build record IDs are base-36 text; nothing else goes into a command.
    public static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }
}

/// A `docker buildx history` command that ended with an error.
public struct BuildxCommandError: Error, LocalizedError, Equatable {
    public let message: String

    public init(message: String) { self.message = message }

    init(_ result: DockerCLIResult) {
        let text = (result.stderr.isEmpty ? result.stdout : result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        message = text.hasPrefix("ERROR: ") ? String(text.dropFirst(7)) : text
    }

    public var errorDescription: String? { message }
}
