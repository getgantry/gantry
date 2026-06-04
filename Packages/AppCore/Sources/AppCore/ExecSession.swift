import Foundation
import DockerKit

/// A live interactive exec session backed by a hijacked Docker connection.
///
/// Owned by the UI on the main actor. Inbound bytes (daemon → terminal) are
/// exposed directly via `bytes`; outbound bytes (keystrokes → daemon) are
/// funnelled through a single ordered pump so keystrokes can never reorder.
@MainActor
public final class ExecSession: Identifiable {
    public let id: String
    public let tty: Bool

    /// Raw bytes flowing from the daemon to the terminal.
    public var bytes: AsyncThrowingStream<Data, Error> { connection.bytes }

    /// Surfaced on a write failure so the UI can react (and is invoked on the
    /// main actor).
    public var onError: ((String) -> Void)?

    private let connection: DockerHijackedConnection
    private let client: DockerClient

    /// Ordered outbound queue: every `send` enqueues here and a single pump
    /// Task drains it, guaranteeing keystrokes reach the peer in order.
    private let outbound: AsyncStream<Data>
    private let outboundContinuation: AsyncStream<Data>.Continuation
    private var pump: Task<Void, Never>?

    public init(
        execID: String,
        tty: Bool,
        connection: DockerHijackedConnection,
        client: DockerClient
    ) {
        self.id = execID
        self.tty = tty
        self.connection = connection
        self.client = client

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.outbound = stream
        self.outboundContinuation = continuation

        startPump()
    }

    /// Drains the outbound queue one chunk at a time on a single task, writing
    /// each to the peer. On the first write error we surface it and stop.
    private func startPump() {
        let write = connection.write
        let stream = outbound
        pump = Task { @MainActor [weak self] in
            for await data in stream {
                do {
                    try await write(data)
                } catch {
                    self?.onError?(error.localizedDescription)
                    break
                }
            }
        }
    }

    /// Fire-and-forget: enqueue bytes for ordered delivery to the peer.
    public func send(_ data: Data) {
        outboundContinuation.yield(data)
    }

    /// Fire-and-forget terminal resize. Errors are ignored — resizing a session
    /// that has already exited is expected.
    public func resize(cols: Int, rows: Int) {
        let client = client
        let execID = id
        Task {
            try? await client.resizeExec(execID: execID, width: cols, height: rows)
        }
    }

    /// Tears the session down: stops the pump and closes the connection.
    public func terminate() {
        outboundContinuation.finish()
        pump?.cancel()
        pump = nil
        let close = connection.close
        Task { await close() }
    }
}
