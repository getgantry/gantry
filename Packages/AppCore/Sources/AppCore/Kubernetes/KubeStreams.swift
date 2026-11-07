import Foundation
import Observation

/// Streams the logs of one pod container into a bounded line buffer.
@MainActor
@Observable
public final class KubeLogStream {
    public private(set) var lines: [String] = []
    public private(set) var isRunning = false
    /// The error text when the stream stopped with a failure.
    public private(set) var failure: String?

    /// The most lines that stay in memory.
    public let lineLimit: Int

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    public init(lineLimit: Int = 5000) {
        self.lineLimit = lineLimit
    }

    /// Starts a new stream and drops the old one.
    public func start(_ client: KubeAPIClient, pod: KubeResource, container: String?, follow: Bool, tail: Int = 500, previous: Bool = false) {
        stop()
        generation += 1
        let current = generation
        lines = []
        failure = nil
        isRunning = true
        let stream = client.lines(KubeRequests.logs(pod: pod, container: container, follow: follow, tail: tail, previous: previous))
        task = Task { [weak self] in
            var batch: [String] = []
            var lastFlush = ContinuousClock.now
            do {
                for try await line in stream {
                    batch.append(line)
                    // Group lines, so a fast log does not redraw per line.
                    if batch.count >= 200 || ContinuousClock.now - lastFlush > .milliseconds(100) {
                        self?.receive(batch, generation: current)
                        batch = []
                        lastFlush = .now
                    }
                }
                self?.receive(batch, generation: current)
                self?.finish(nil, generation: current)
            } catch {
                self?.receive(batch, generation: current)
                self?.finish(error, generation: current)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    public func clear() { lines = [] }

    /// All lines as one text, for Copy.
    public var text: String { lines.joined(separator: "\n") }

    private func receive(_ batch: [String], generation: Int) {
        guard generation == self.generation, !batch.isEmpty else { return }
        lines.append(contentsOf: batch)
        if lines.count > lineLimit { lines.removeFirst(lines.count - lineLimit) }
    }

    private func finish(_ error: Error?, generation: Int) {
        guard generation == self.generation else { return }
        if let error, !(error is CancellationError) {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        task = nil
        isRunning = false
    }
}

/// An interactive shell in a pod container over the exec WebSocket.
@MainActor
public final class KubePodShellSession: TerminalSession {
    public var bytes: AsyncThrowingStream<Data, Error> { output }
    public var onError: ((String) -> Void)?

    private let socket: KubeWebSocket
    private let output: AsyncThrowingStream<Data, Error>
    private let outbox: AsyncStream<Data>.Continuation
    private var tasks: [Task<Void, Never>] = []

    /// Opens the shell. Offers v5 first, then v4 of the channel protocol.
    public static func connect(_ client: KubeAPIClient, pod: KubeResource, container: String?, command: [String] = KubeRequests.shellCommand) async throws -> KubePodShellSession {
        let socket = try await KubeWebSocket.connect(
            client,
            request: KubeRequests.exec(pod: pod, container: container, command: command),
            protocols: [KubeChannelFrames.v5Protocol, KubeChannelFrames.v4Protocol]
        )
        return KubePodShellSession(socket: socket)
    }

    init(socket: KubeWebSocket) {
        self.socket = socket
        let (output, sink) = AsyncThrowingStream<Data, Error>.makeStream()
        self.output = output
        let (queue, outbox) = AsyncStream<Data>.makeStream()
        self.outbox = outbox
        // One writer keeps the input in order.
        tasks.append(Task { [socket, weak self] in
            for await message in queue {
                do { try await socket.send(message) } catch {
                    self?.onError?(error.localizedDescription)
                    break
                }
            }
        })
        tasks.append(Task { [socket] in
            do {
                for try await message in socket.messages {
                    guard let (channel, payload) = KubeChannelFrames.decode(message) else { continue }
                    switch channel {
                    case KubeChannelFrames.stdout, KubeChannelFrames.stderr:
                        sink.yield(payload)
                    case KubeChannelFrames.error:
                        if let text = KubeChannelFrames.execResult(payload).message {
                            sink.yield(Data("\r\n\(text)\r\n".utf8))
                        }
                    default:
                        break
                    }
                }
                sink.finish()
            } catch {
                sink.finish(throwing: error)
            }
        })
    }

    public func send(_ data: Data) {
        outbox.yield(KubeChannelFrames.encode(channel: KubeChannelFrames.stdin, data))
    }

    public func resize(cols: Int, rows: Int) {
        outbox.yield(KubeChannelFrames.resizeMessage(cols: cols, rows: rows))
    }

    public func terminate() {
        outbox.finish()
        socket.close()
        tasks.forEach { $0.cancel() }
    }
}

/// The output of a command that ran to its end in a pod.
public struct KubeExecOutput: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int?
    public var message: String?
}

extension KubeAPIClient {
    /// Runs a command without a TTY and collects its output.
    public func execute(pod: KubeResource, container: String?, command: [String]) async throws -> KubeExecOutput {
        let socket = try await KubeWebSocket.connect(
            self,
            request: KubeRequests.exec(pod: pod, container: container, command: command, stdin: false, tty: false),
            protocols: [KubeChannelFrames.v5Protocol, KubeChannelFrames.v4Protocol]
        )
        defer { socket.close() }
        var output = KubeExecOutput(stdout: "", stderr: "", exitCode: nil, message: nil)
        var stdout = Data()
        var stderr = Data()
        for try await message in socket.messages {
            guard let (channel, payload) = KubeChannelFrames.decode(message) else { continue }
            switch channel {
            case KubeChannelFrames.stdout: stdout.append(payload)
            case KubeChannelFrames.stderr: stderr.append(payload)
            case KubeChannelFrames.error:
                (output.exitCode, output.message) = KubeChannelFrames.execResult(payload)
            default: break
            }
        }
        output.stdout = String(decoding: stdout, as: UTF8.self)
        output.stderr = String(decoding: stderr, as: UTF8.self)
        return output
    }
}

/// One port forward that runs in the background.
public struct KubePortForward: Identifiable, Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case starting
        case active
        case failed(String)
    }

    public let id: UUID
    public var context: String
    public var namespace: String?
    /// `pod/web-1` or `service/web`.
    public var target: String
    /// The local port; 0 until the listener is open.
    public var localPort: Int
    public var remotePort: Int
    public var state: State
    /// The pod that gets the traffic (for a service, the pod that Gantry chose).
    public var pod: String?
    /// The last error of one forwarded connection; the forward keeps running.
    public var lastConnectionError: String?

    public var url: URL? { localPort > 0 ? URL(string: "http://127.0.0.1:\(localPort)") : nil }
}

/// The active port forwards of the app. Each one is a listener on
/// 127.0.0.1 that opens one WebSocket per accepted connection.
@MainActor
@Observable
public final class KubePortForwards {
    public private(set) var forwards: [KubePortForward] = []

    @ObservationIgnored private var listeners: [UUID: KubePortForwarder] = [:]
    @ObservationIgnored private var starts: [UUID: Task<Void, Never>] = [:]

    public init() {}

    /// Forwards that run or start; failed ones do not count.
    public var activeCount: Int {
        forwards.count { if case .failed = $0.state { false } else { true } }
    }

    @discardableResult
    public func start(_ client: KubeAPIClient, resource: KubeResource, localPort: Int, remotePort: Int) -> UUID {
        let id = UUID()
        forwards.append(KubePortForward(
            id: id, context: client.context ?? "", namespace: resource.namespace, target: resource.reference,
            localPort: localPort, remotePort: remotePort, state: .starting
        ))
        starts[id] = Task { [weak self] in
            do {
                let target = try await client.portForwardTarget(resource, port: remotePort)
                try Task.checkCancellation()
                let listener = try await KubePortForwarder.start(client, pod: target.pod, port: target.port, localPort: localPort) { message in
                    Task { @MainActor in self?.update(id) { $0.lastConnectionError = message } }
                }
                guard let self, self.starts[id] != nil else { listener.stop(); return }
                self.starts[id] = nil
                self.listeners[id] = listener
                self.update(id) {
                    $0.localPort = listener.localPort
                    $0.pod = target.pod.name
                    $0.state = .active
                }
            } catch {
                self?.starts[id] = nil
                self?.update(id) { $0.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
            }
        }
        return id
    }

    /// Stops a forward, or removes a failed one from the list.
    public func stop(_ id: UUID) {
        starts.removeValue(forKey: id)?.cancel()
        listeners.removeValue(forKey: id)?.stop()
        forwards.removeAll { $0.id == id }
    }

    public func stopAll() {
        for task in starts.values { task.cancel() }
        for listener in listeners.values { listener.stop() }
        starts.removeAll()
        listeners.removeAll()
        forwards.removeAll()
    }

    private func update(_ id: UUID, _ change: (inout KubePortForward) -> Void) {
        guard let index = forwards.firstIndex(where: { $0.id == id }) else { return }
        change(&forwards[index])
    }
}
