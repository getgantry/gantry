import Foundation
import Darwin

/// How a child process ended.
public struct ChildProcessExit: Sendable, Equatable {
    /// The exit status, or the signal number when `signaled` is true.
    public var status: Int32
    /// True when a signal killed the process.
    public var signaled: Bool

    public init(status: Int32, signaled: Bool) {
        self.status = status
        self.signaled = signaled
    }

    /// True for a normal exit with status 0.
    public var succeeded: Bool { !signaled && status == 0 }

    /// A short description for error messages.
    public var summary: String {
        signaled ? "killed by signal \(status)" : "exit status \(status)"
    }
}

/// One chunk of child process output, tagged with its stream.
public enum ChildProcessChunk: Sendable {
    case stdout(Data)
    case stderr(Data)
}

/// The buffered result of a child process that ran to completion.
public struct ChildProcessResult: Sendable {
    public var exit: ChildProcessExit
    public var stdout: Data
    public var stderr: Data
}

/// Runs one child process with piped output. Both pipes are read with
/// `DispatchIO` on one serial queue, so output callbacks never overlap.
/// The completion runs on that queue after EOF on every pipe and after the
/// exit, so no output is lost or reordered.
public final class ChildProcess: @unchecked Sendable {
    /// Wait for EOF after the exit; a grandchild that keeps the pipe open
    /// must not hang the caller forever.
    static let eofGrace: DispatchTimeInterval = .seconds(3)

    private enum State { case idle, running, cancelled, finished }

    private let process = Process()
    private let queue = DispatchQueue(label: "gantry.child-process")
    private let lock = NSLock()
    private var state = State.idle
    private let outputPipe = Pipe()
    private let errorPipe: Pipe?
    private let inputPipe: Pipe?
    private let input: Data?
    /// Only touched on `queue`.
    private var channels: [DispatchIO] = []

    /// - Parameters:
    ///   - environment: values merged over the current environment.
    ///   - input: bytes written to stdin, which is then closed. Without it,
    ///     stdin is `/dev/null`.
    ///   - mergeOutput: sends stderr into the stdout pipe (as `.stdout`).
    public init(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        input: Data? = nil,
        mergeOutput: Bool = false
    ) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var merged = ProcessInfo.processInfo.environment
        merged.merge(environment) { _, new in new }
        process.environment = merged
        process.standardOutput = outputPipe
        errorPipe = mergeOutput ? nil : Pipe()
        process.standardError = errorPipe ?? outputPipe
        self.input = input
        inputPipe = input == nil ? nil : Pipe()
        process.standardInput = inputPipe ?? FileHandle.nullDevice
    }

    /// Launches the process. `output` gets each chunk in order; `completion`
    /// runs once, after all output. Throws `CancellationError` when
    /// `terminate()` came first, or the launch error.
    public func start(
        output: @escaping @Sendable (ChildProcessChunk) -> Void,
        completion: @escaping @Sendable (ChildProcessExit) -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == .idle else { throw CancellationError() }

        let group = DispatchGroup()
        let exitBox = ExitBox()
        group.enter()
        process.terminationHandler = { process in
            exitBox.value = ChildProcessExit(
                status: process.terminationStatus,
                signaled: process.terminationReason == .uncaughtSignal
            )
            self.lock.withLock { self.state = .finished }
            group.leave()
            self.queue.asyncAfter(deadline: .now() + Self.eofGrace) {
                self.channels.forEach { $0.close(flags: .stop) }
            }
        }

        var opened = [reader(outputPipe, group: group) { output(.stdout($0)) }]
        if let errorPipe {
            opened.append(reader(errorPipe, group: group) { output(.stderr($0)) })
        }
        let readers = opened
        if let inputPipe {
            // A child that exits before it reads stdin must not raise
            // SIGPIPE here: the write then fails with EPIPE.
            _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            readers.forEach { $0.close(flags: .stop) }
            state = .finished
            throw error
        }
        queue.async { self.channels = readers }
        state = .running
        if let inputPipe, let input {
            let writer = inputPipe.fileHandleForWriting
            DispatchQueue.global().async {
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }
        group.notify(queue: queue) {
            completion(exitBox.value ?? ChildProcessExit(status: -1, signaled: false))
        }
    }

    /// Sends SIGTERM to a running process. Before `start`, it makes `start`
    /// throw `CancellationError` instead.
    public func terminate() {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .idle: state = .cancelled
        case .running: if process.isRunning { process.terminate() }
        case .cancelled, .finished: break
        }
    }

    /// Reads `pipe` to EOF and calls `deliver` for each chunk on `queue`.
    private func reader(
        _ pipe: Pipe,
        group: DispatchGroup,
        deliver: @escaping @Sendable (Data) -> Void
    ) -> DispatchIO {
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        group.enter()
        let channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: queue) { _ in
            // Keeps the pipe alive until the channel is done with the descriptor.
            try? pipe.fileHandleForReading.close()
        }
        channel.setLimit(lowWater: 1)
        channel.read(offset: 0, length: Int.max, queue: queue) { done, data, _ in
            if let data, !data.isEmpty {
                var bytes = Data(capacity: data.count)
                data.enumerateBytes { buffer, _, _ in bytes.append(buffer) }
                deliver(bytes)
            }
            if done {
                channel.close()
                group.leave()
            }
        }
        return channel
    }
}

private final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ChildProcessExit?
    var value: ChildProcessExit? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class ResultCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func append(_ chunk: ChildProcessChunk) {
        lock.withLock {
            switch chunk {
            case .stdout(let data): stdout.append(data)
            case .stderr(let data): stderr.append(data)
            }
        }
    }

    func result(_ exit: ChildProcessExit) -> ChildProcessResult {
        lock.withLock { ChildProcessResult(exit: exit, stdout: stdout, stderr: stderr) }
    }
}

extension ChildProcess {
    /// Runs a process to completion and buffers its output. Cancelling the
    /// calling task terminates the process and throws `CancellationError`.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = [:],
        input: Data? = nil
    ) async throws -> ChildProcessResult {
        let child = ChildProcess(executable: executable, arguments: arguments, environment: environment, input: input)
        let collector = ResultCollector()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ChildProcessResult, Error>) in
                do {
                    try child.start(output: collector.append) { exit in
                        continuation.resume(returning: collector.result(exit))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            child.terminate()
        }
        try Task.checkCancellation()
        return result
    }
}
