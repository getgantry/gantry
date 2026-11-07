import Foundation
import Observation
import DockerKit

/// Streams `kubectl logs` of one pod container into a bounded line buffer.
@MainActor
@Observable
public final class KubeLogStream {
    public private(set) var lines: [String] = []
    public private(set) var isRunning = false
    /// The error text when kubectl stopped with a failure.
    public private(set) var failure: String?

    /// The most lines that stay in memory.
    public let lineLimit: Int

    @ObservationIgnored private var child: ChildProcess?
    @ObservationIgnored private var generation = 0

    public init(lineLimit: Int = 5000) {
        self.lineLimit = lineLimit
    }

    /// Starts a new stream and drops the old one.
    public func start(_ client: KubectlClient, pod: KubeResource, container: String?, follow: Bool, tail: Int = 500, previous: Bool = false) {
        stop()
        generation += 1
        let current = generation
        lines = []
        failure = nil
        let splitter = KubeLineSplitter()
        let errors = TextCollector()
        let child = ChildProcess(
            executable: client.executable,
            arguments: client.logsArguments(pod: pod, container: container, follow: follow, tail: tail, previous: previous),
            environment: client.environment
        )
        do {
            try child.start(output: { [weak self] chunk in
                switch chunk {
                case .stdout(let data):
                    let batch = splitter.feed(data)
                    guard !batch.isEmpty else { return }
                    Task { @MainActor in self?.receive(batch, generation: current) }
                case .stderr(let data):
                    errors.append(data)
                }
            }, completion: { [weak self] exit in
                let tailLines = splitter.flush()
                let errorText = errors.text
                Task { @MainActor in self?.finish(exit, tail: tailLines, error: errorText, generation: current) }
            })
            self.child = child
            isRunning = true
        } catch {
            failure = error.localizedDescription
        }
    }

    public func stop() {
        child?.terminate()
        child = nil
        isRunning = false
    }

    public func clear() { lines = [] }

    /// All lines as one text, for Copy.
    public var text: String { lines.joined(separator: "\n") }

    private func receive(_ batch: [String], generation: Int) {
        guard generation == self.generation else { return }
        append(batch)
    }

    private func append(_ batch: [String]) {
        lines.append(contentsOf: batch)
        if lines.count > lineLimit { lines.removeFirst(lines.count - lineLimit) }
    }

    private func finish(_ exit: ChildProcessExit, tail: [String], error: String, generation: Int) {
        guard generation == self.generation else { return }
        append(tail)
        if !exit.succeeded, !exit.signaled {
            failure = error.isEmpty ? String(localized: "kubectl failed (\(exit.summary)).", bundle: .module) : error
        }
        child = nil
        isRunning = false
    }
}

/// One `kubectl port-forward` that runs in the background.
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
    /// The local port; 0 until kubectl reports the port it chose.
    public var localPort: Int
    public var remotePort: Int
    public var state: State

    public var url: URL? { localPort > 0 ? URL(string: "http://127.0.0.1:\(localPort)") : nil }

    /// Reads the port from `Forwarding from 127.0.0.1:8080 -> 80`.
    public static func parseLocalPort(_ line: String) -> Int? {
        guard let match = line.firstMatch(of: #/Forwarding from \S*:(\d+) ->/#) else { return nil }
        return Int(match.1)
    }
}

/// The active port forwards of the app. Each one is a kubectl child process
/// that stops on ``stop(_:)``, ``stopAll()`` or when kubectl exits.
@MainActor
@Observable
public final class KubePortForwards {
    public private(set) var forwards: [KubePortForward] = []

    @ObservationIgnored private var children: [UUID: ChildProcess] = [:]

    public init() {}

    /// Forwards that run or start; failed ones do not count.
    public var activeCount: Int {
        forwards.count { if case .failed = $0.state { false } else { true } }
    }

    @discardableResult
    public func start(_ client: KubectlClient, resource: KubeResource, localPort: Int, remotePort: Int) -> UUID {
        let id = UUID()
        forwards.append(KubePortForward(
            id: id, context: client.context ?? "", namespace: resource.namespace, target: resource.reference,
            localPort: localPort, remotePort: remotePort, state: .starting
        ))
        let splitter = KubeLineSplitter()
        let errors = TextCollector()
        let child = ChildProcess(
            executable: client.executable,
            arguments: client.portForwardArguments(resource, localPort: localPort, remotePort: remotePort),
            environment: client.environment
        )
        do {
            try child.start(output: { [weak self] chunk in
                switch chunk {
                case .stdout(let data):
                    let ports = splitter.feed(data).compactMap(KubePortForward.parseLocalPort)
                    if let port = ports.first { Task { @MainActor in self?.activate(id, port: port) } }
                case .stderr(let data):
                    errors.append(data)
                }
            }, completion: { [weak self] exit in
                let message = errors.text
                Task { @MainActor in self?.ended(id, exit: exit, message: message) }
            })
            children[id] = child
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
        }
        return id
    }

    /// Stops a forward, or removes a failed one from the list.
    public func stop(_ id: UUID) {
        children.removeValue(forKey: id)?.terminate()
        forwards.removeAll { $0.id == id }
    }

    public func stopAll() {
        for child in children.values { child.terminate() }
        children.removeAll()
        forwards.removeAll()
    }

    private func activate(_ id: UUID, port: Int) {
        update(id) { forward in
            forward.localPort = port
            forward.state = .active
        }
    }

    private func ended(_ id: UUID, exit: ChildProcessExit, message: String) {
        guard children.removeValue(forKey: id) != nil else { return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = String(localized: "kubectl failed (\(exit.summary)).", bundle: .module)
        update(id) { $0.state = .failed(text.isEmpty ? fallback : text) }
    }

    private func update(_ id: UUID, _ change: (inout KubePortForward) -> Void) {
        guard let index = forwards.firstIndex(where: { $0.id == id }) else { return }
        change(&forwards[index])
    }
}

/// Collects stderr bytes from child process callbacks.
final class TextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
