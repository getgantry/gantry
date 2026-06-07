import Foundation
import Darwin

/// Result of a buffered `container` CLI invocation.
public struct AppleCLIResult: Sendable {
    public var exitCode: Int
    public var stdout: Data
    public var stderr: Data

    public init(exitCode: Int, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// One chunk of output from an interactive CLI process: which standard stream
/// it came from matters for Docker's multiplexed exec framing.
public enum AppleCLIOutputChunk: Sendable {
    case stdout(Data)
    case stderr(Data)
}

/// A live interactive `container exec` process (PTY or pipes), bridged by the
/// transport into a `DockerHijackedConnection`.
public protocol AppleCLIInteractiveProcess: Sendable {
    /// Output chunks until the process exits; finishes (never throws) at EOF.
    var output: AsyncStream<AppleCLIOutputChunk> { get }
    /// Writes bytes to the process's stdin.
    func write(_ data: Data) async throws
    /// Resizes the PTY, when one backs the process. No-op otherwise.
    func resize(columns: Int, rows: Int)
    /// Waits for the process to finish and returns its exit code.
    func waitForExit() async -> Int
    /// Terminates the process and releases its descriptors.
    func close() async
}

/// How the transport invokes the `container` CLI. The seam exists so unit
/// tests can script the CLI's behavior without spawning processes.
public protocol AppleContainerCLIRunning: Sendable {
    /// Runs the CLI to completion, buffering stdout/stderr.
    func run(_ arguments: [String]) async throws -> AppleCLIResult

    /// Runs the CLI and streams its stdout as raw bytes (logs, export, pull).
    /// A non-zero exit surfaces as a thrown error at the end of the stream.
    func stream(_ arguments: [String]) -> AsyncThrowingStream<Data, Error>

    /// Spawns an interactive CLI process (exec). `tty` allocates a PTY so the
    /// child sees a terminal; otherwise plain pipes keep stdout/stderr apart.
    func interactive(_ arguments: [String], tty: Bool) throws -> any AppleCLIInteractiveProcess
}

/// Locates the `container` binary across common installations.
public enum AppleContainerCLIDiscovery {
    /// Standard install locations, in preference order.
    public static func candidates() -> [String] {
        [
            "/opt/homebrew/bin/container",
            "/opt/homebrew/opt/container/bin/container",
            "/usr/local/bin/container",
            "/usr/local/opt/container/bin/container",
            "/usr/bin/container"
        ]
    }

    /// Returns the first existing CLI path. `override` (a host-configured
    /// path or the `GANTRY_APPLE_CONTAINER_CLI` environment variable) wins
    /// when it points at an existing file.
    public static func discover(
        override: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let override, !override.isEmpty {
            return fileExists(override) ? override : nil
        }
        if let env = environment["GANTRY_APPLE_CONTAINER_CLI"], !env.isEmpty {
            return fileExists(env) ? env : nil
        }
        return candidates().first(where: fileExists)
    }
}

/// Production CLI runner: spawns the real `container` binary.
public struct AppleContainerProcessRunner: AppleContainerCLIRunning {
    public let executablePath: String

    public init(executablePath: String) {
        self.executablePath = executablePath
    }

    private func makeProcess(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        // The CLI talks XPC to container-apiserver; a clean environment plus
        // HOME (for its app-root resolution) is all it needs.
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        process.environment = environment
        return process
    }

    public func run(_ arguments: [String]) async throws -> AppleCLIResult {
        let process = makeProcess(arguments)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            // Drain both pipes off the calling thread; readDataToEndOfFile on
            // the termination handler can deadlock once the pipe buffer fills.
            let collector = OutputCollector()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                collector.appendStdout(data)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                collector.appendStderr(data)
            }
            process.terminationHandler = { process in
                // Flush whatever the readability handlers have not seen yet.
                let trailingOut = try? stdoutPipe.fileHandleForReading.readToEnd()
                let trailingErr = try? stderrPipe.fileHandleForReading.readToEnd()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let (stdout, stderr) = collector.snapshot(
                    trailingStdout: trailingOut ?? Data(),
                    trailingStderr: trailingErr ?? Data()
                )
                continuation.resume(returning: AppleCLIResult(
                    exitCode: Int(process.terminationStatus),
                    stdout: stdout,
                    stderr: stderr
                ))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: DockerError.connectionFailed(
                    "Could not run \(executablePath): \(error.localizedDescription)"
                ))
            }
        }
    }

    public func stream(_ arguments: [String]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let process = makeProcess(arguments)
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = FileHandle.nullDevice

            let collector = OutputCollector()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    continuation.yield(data)
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                collector.appendStderr(data)
            }
            process.terminationHandler = { process in
                if let trailing = try? stdoutPipe.fileHandleForReading.readToEnd(), !trailing.isEmpty {
                    continuation.yield(trailing)
                }
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                if process.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    let (_, stderr) = collector.snapshot(trailingStdout: Data(), trailingStderr: Data())
                    continuation.finish(throwing: AppleContainerCLIError.fromStderr(
                        String(decoding: stderr, as: UTF8.self),
                        exitCode: Int(process.terminationStatus)
                    ))
                }
            }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.finish(throwing: DockerError.connectionFailed(
                    "Could not run \(executablePath): \(error.localizedDescription)"
                ))
            }
        }
    }

    public func interactive(_ arguments: [String], tty: Bool) throws -> any AppleCLIInteractiveProcess {
        if tty {
            return try PTYProcess(executablePath: executablePath, arguments: arguments)
        }
        return try PipeProcess(executablePath: executablePath, arguments: arguments)
    }
}

/// Thread-safe accumulator for process output read from readability handlers.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func appendStdout(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        stdout.append(data)
    }

    func appendStderr(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        stderr.append(data)
    }

    func snapshot(trailingStdout: Data, trailingStderr: Data) -> (Data, Data) {
        lock.lock(); defer { lock.unlock() }
        stdout.append(trailingStdout)
        stderr.append(trailingStderr)
        return (stdout, stderr)
    }
}

/// Errors surfaced by CLI invocations, mapped onto Docker API status codes so
/// the existing error plumbing (alerts, retries) behaves identically.
public enum AppleContainerCLIError {
    /// Builds a `DockerError.apiError` from the CLI's stderr text.
    public static func fromStderr(_ stderr: String, exitCode: Int) -> DockerError {
        var message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.hasPrefix("Error:") {
            message = message.dropFirst("Error:".count).trimmingCharacters(in: .whitespaces)
        }
        if message.isEmpty {
            message = "container CLI exited with status \(exitCode)"
        }
        let status = message.lowercased().contains("not found") ? 404 : 500
        return DockerError.apiError(status: status, message: message)
    }
}

// MARK: - Interactive process implementations

/// Pipe-backed interactive process (non-TTY exec): stdout and stderr stay
/// separate so the transport can frame them Docker-style.
final class PipeProcess: AppleCLIInteractiveProcess, @unchecked Sendable {
    let output: AsyncStream<AppleCLIOutputChunk>
    private let process: Process
    private let stdinPipe: Pipe
    private let exitTask: Task<Int, Never>

    init(executablePath: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let (stream, continuation) = AsyncStream<AppleCLIOutputChunk>.makeStream()
        output = stream

        // Two live pipes feed one stream; finish only when both hit EOF and
        // the process has exited.
        let state = StreamCloser(continuation: continuation, openCount: 2)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                state.closeOne()
            } else {
                continuation.yield(.stdout(data))
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                state.closeOne()
            } else {
                continuation.yield(.stderr(data))
            }
        }

        self.process = process
        self.stdinPipe = stdinPipe

        try process.run()
        exitTask = Task.detached {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if !process.isRunning {
                    cont.resume()
                    return
                }
                process.terminationHandler = { _ in cont.resume() }
                // Re-check: the process may have exited between the guard and
                // installing the handler.
                if !process.isRunning, process.terminationHandler != nil {
                    process.terminationHandler = nil
                    cont.resume()
                }
            }
            return Int(process.terminationStatus)
        }
    }

    func write(_ data: Data) async throws {
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    func resize(columns: Int, rows: Int) {
        // No PTY to resize.
    }

    func waitForExit() async -> Int {
        await exitTask.value
    }

    func close() async {
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

/// PTY-backed interactive process (TTY exec): the child runs with a real
/// terminal, output arrives unframed, and the window size is adjustable.
final class PTYProcess: AppleCLIInteractiveProcess, @unchecked Sendable {
    let output: AsyncStream<AppleCLIOutputChunk>
    private let process: Process
    private let masterHandle: FileHandle
    private let masterFD: Int32
    private let exitTask: Task<Int, Never>

    init(executablePath: String, arguments: [String]) throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw DockerError.connectionFailed("openpty failed: \(String(cString: strerror(errno)))")
        }

        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        let (stream, continuation) = AsyncStream<AppleCLIOutputChunk>.makeStream()
        output = stream

        masterHandle.readabilityHandler = { handle in
            // A closed slave side surfaces as EIO on read; availableData then
            // returns empty, which is our EOF signal.
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(.stdout(data))
            }
        }

        self.process = process
        self.masterHandle = masterHandle
        self.masterFD = master

        do {
            try process.run()
        } catch {
            masterHandle.readabilityHandler = nil
            try? slaveHandle.close()
            throw DockerError.connectionFailed(
                "Could not run \(executablePath): \(error.localizedDescription)"
            )
        }
        // The child owns the slave end now; close our copy so EOF propagates.
        Darwin.close(slave)

        exitTask = Task.detached {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in cont.resume() }
                if !process.isRunning, process.terminationHandler != nil {
                    process.terminationHandler = nil
                    cont.resume()
                }
            }
            return Int(process.terminationStatus)
        }
    }

    func write(_ data: Data) async throws {
        try masterHandle.write(contentsOf: data)
    }

    func resize(columns: Int, rows: Int) {
        var size = winsize(
            ws_row: UInt16(clamping: rows),
            ws_col: UInt16(clamping: columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
    }

    func waitForExit() async -> Int {
        await exitTask.value
    }

    func close() async {
        masterHandle.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        try? masterHandle.close()
    }
}

/// Counts pipe EOFs and finishes the merged output stream after the last one.
private final class StreamCloser: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<AppleCLIOutputChunk>.Continuation
    private var openCount: Int

    init(continuation: AsyncStream<AppleCLIOutputChunk>.Continuation, openCount: Int) {
        self.continuation = continuation
        self.openCount = openCount
    }

    func closeOne() {
        lock.lock()
        openCount -= 1
        let done = openCount == 0
        lock.unlock()
        if done { continuation.finish() }
    }
}
