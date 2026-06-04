import Foundation
import DockerKit
import Citadel
import NIOCore

/// `DockerTransport` that reaches a remote Docker daemon over SSH, exactly the
/// way `docker -H ssh://user@host` does.
///
/// ## The `dial-stdio` protocol
/// Recent Docker CLIs do not forward the remote unix socket directly. Instead
/// they run `docker system dial-stdio` on the remote host: that command opens a
/// bidirectional pipe between the SSH channel's stdin/stdout and the local
/// `/var/run/docker.sock`. Everything written to the channel's stdin is fed to
/// the daemon socket, and everything the daemon writes back is emitted on
/// stdout — a raw, framing-free byte tunnel. We therefore speak plain HTTP/1.1
/// over that tunnel: serialize a `DockerRequest` to bytes, write them to the
/// channel, and parse the daemon's HTTP response off the channel's stdout.
///
/// Each `withExec("docker system dial-stdio")` invocation is a single tunnel
/// (see `Tunnel`). `execute` reuses one persistent tunnel and serializes
/// requests through the actor; `stream` opens a dedicated tunnel per stream so
/// long-lived follow endpoints (logs/stats/events) never block other traffic.
/// A `101 Switching Protocols` upgrade turns the tunnel into an eternal raw
/// passthrough, which the streaming path relies on for the exec terminal (M4).
public actor SSHDialStdioTransport: DockerTransport {
    private let makeClient: @Sendable () async throws -> SSHClient
    private let dialCommand: String

    /// Cached SSH client; dropped and recreated when it reports disconnected.
    private var client: SSHClient?

    /// Persistent tunnel used by `execute`.
    private var persistentTunnel: Tunnel?

    /// Live stream tunnels, tracked so `shutdown` can tear them all down.
    private var streamTunnels: [UUID: Tunnel] = [:]

    /// Keepalive bookkeeping.
    private var keepaliveTask: Task<Void, Never>?
    private var lastActivity = Date()

    /// `execute` request timeout.
    private static let requestTimeout: Duration = .seconds(60)
    /// Idle interval after which the keepalive pings.
    private static let keepaliveInterval: Duration = .seconds(30)

    public init(
        makeClient: @Sendable @escaping () async throws -> SSHClient,
        dialCommand: String = "docker system dial-stdio"
    ) {
        self.makeClient = makeClient
        self.dialCommand = dialCommand
    }

    // MARK: - DockerTransport

    /// Tail of the FIFO chain that serializes `execute` calls.
    ///
    /// Actors are reentrant: two concurrent `execute` calls interleave at every
    /// suspension point, which would pipeline two HTTP requests onto the shared
    /// persistent tunnel and desynchronize the response parser. Each call chains
    /// behind the previous one and only starts once it finished.
    private var executeChainTail: Task<Void, Never>?

    public func execute(_ request: DockerRequest) async throws -> DockerResponse {
        let requestData = HTTP1RequestSerializer.serialize(request)
        let previous = executeChainTail

        let slot = Task<DockerResponse, Error> {
            // Wait for the predecessor regardless of its outcome; ordering is
            // all that matters here.
            await previous?.value
            return try await self.executeSerialized(requestData)
        }
        executeChainTail = Task { _ = try? await slot.value }

        return try await slot.value
    }

    private func executeSerialized(_ requestData: Data) async throws -> DockerResponse {
        do {
            return try await withThrowingTaskGroup(of: DockerResponse.self) { group in
                group.addTask {
                    try await self.runExecute(requestData)
                }
                group.addTask {
                    try await Task.sleep(for: Self.requestTimeout)
                    throw DockerError.connectionFailed("request timed out")
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch let error as DockerError {
            await dropPersistentTunnel()
            throw error
        } catch is CancellationError {
            // The tunnel may hold a half-read response; do not reuse it.
            await dropPersistentTunnel()
            throw DockerError.cancelled
        } catch {
            await dropPersistentTunnel()
            throw DockerError.connectionFailed(String(describing: error))
        }
    }

    public func stream(_ request: DockerRequest) async throws -> DockerByteStream {
        let requestData = HTTP1RequestSerializer.serialize(request)
        let tunnel = try await openTunnel()
        let id = UUID()
        streamTunnels[id] = tunnel

        do {
            try await tunnel.write(requestData)
        } catch {
            streamTunnels[id] = nil
            let mapped = await mapTunnelError(error, on: tunnel)
            await tunnel.close()
            throw mapped
        }

        // Parse until the response head arrives, buffering any early body bytes
        // that came in the same chunk.
        var parser = HTTP1ResponseParser()
        var head: (status: Int, headers: [String: String])?
        var earlyBodies: [Data] = []
        let inbound = tunnel.inbound

        do {
            outer: for try await chunk in inbound {
                let events = try parser.ingest(chunk)
                for event in events {
                    switch event {
                    case .head(let status, let headers):
                        head = (status, headers)
                    case .body(let data):
                        earlyBodies.append(data)
                    case .end:
                        // Response completed before we returned: still hand back
                        // a stream that yields the buffered bodies then finishes.
                        break outer
                    }
                }
                if head != nil { break }
            }
        } catch {
            streamTunnels[id] = nil
            let mapped = await mapTunnelError(error, on: tunnel)
            await tunnel.close()
            throw mapped
        }

        guard let head else {
            streamTunnels[id] = nil
            let detail = await tunnel.stderrTail()
            await tunnel.close()
            throw DockerError.connectionFailed(
                "stream closed before response headers" + (detail.isEmpty ? "" : ": \(detail)")
            )
        }

        let bytes = AsyncThrowingStream<Data, Error> { continuation in
            for body in earlyBodies where !body.isEmpty {
                continuation.yield(body)
            }
            let pump = Task {
                await self.pumpStream(tunnel: tunnel, parser: parser, continuation: continuation)
                await self.removeStreamTunnel(id)
            }
            continuation.onTermination = { _ in
                pump.cancel()
                Task { await self.closeStreamTunnel(id) }
            }
        }

        return DockerByteStream(status: head.status, headers: head.headers, bytes: bytes)
    }

    public func hijack(_ request: DockerRequest) async throws -> DockerHijackedConnection {
        let requestData = HTTP1RequestSerializer.serialize(request)
        let tunnel = try await openTunnel()
        let id = UUID()
        streamTunnels[id] = tunnel

        do {
            try await tunnel.write(requestData)
        } catch {
            streamTunnels[id] = nil
            let mapped = await mapTunnelError(error, on: tunnel)
            await tunnel.close()
            throw mapped
        }

        // Parse until the response head arrives. On a 101 the parser flips to
        // passthrough and any trailing bytes from the same chunk are already
        // body; capture them so the consumer does not lose the first frames.
        var parser = HTTP1ResponseParser()
        var head: (status: Int, headers: [String: String])?
        var earlyBodies: [Data] = []
        let inbound = tunnel.inbound

        do {
            outer: for try await chunk in inbound {
                let events = try parser.ingest(chunk)
                for event in events {
                    switch event {
                    case .head(let status, let headers):
                        head = (status, headers)
                    case .body(let data):
                        earlyBodies.append(data)
                    case .end:
                        break outer
                    }
                }
                if head != nil { break }
            }
        } catch {
            streamTunnels[id] = nil
            let mapped = await mapTunnelError(error, on: tunnel)
            await tunnel.close()
            throw mapped
        }

        guard let head else {
            streamTunnels[id] = nil
            let detail = await tunnel.stderrTail()
            await tunnel.close()
            throw DockerError.connectionFailed(
                "connection closed before response headers" + (detail.isEmpty ? "" : ": \(detail)")
            )
        }

        // Anything other than a successful upgrade (101) or a plain 200 that
        // streams until close is an error: drain the buffered body for a
        // message and tear the tunnel down.
        guard head.status == 101 || head.status == 200 else {
            var message = earlyBodies.reduce(into: Data()) { $0.append($1) }
            // Best-effort: pull any remaining buffered error body without
            // blocking forever — the daemon closes the connection on error.
            do {
                for try await chunk in inbound {
                    let events = try parser.ingest(chunk)
                    for event in events {
                        if case .body(let data) = event { message.append(data) }
                    }
                }
            } catch {
                // Ignore: we already have the head and whatever body arrived.
            }
            streamTunnels[id] = nil
            await tunnel.close()
            let text = String(decoding: message, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DockerError.apiError(status: head.status, message: text)
        }

        let bytes = AsyncThrowingStream<Data, Error> { continuation in
            for body in earlyBodies where !body.isEmpty {
                continuation.yield(body)
            }
            let pump = Task {
                await self.pumpStream(tunnel: tunnel, parser: parser, continuation: continuation)
                await self.removeStreamTunnel(id)
            }
            continuation.onTermination = { _ in
                pump.cancel()
                Task { await self.closeStreamTunnel(id) }
            }
        }

        return DockerHijackedConnection(
            status: head.status,
            headers: head.headers,
            bytes: bytes,
            write: { [weak self] data in
                guard let self else { throw DockerError.streamClosed }
                try await self.writeHijack(id, data)
            },
            close: { [weak self] in
                await self?.closeStreamTunnel(id)
            }
        )
    }

    /// Routes a hijacked-connection write through the actor to the owning
    /// tunnel; the `@Sendable` closure handed to the caller never touches the
    /// non-`Sendable` writer directly.
    private func writeHijack(_ id: UUID, _ data: Data) async throws {
        guard let tunnel = streamTunnels[id] else { throw DockerError.streamClosed }
        do {
            try await tunnel.write(data)
        } catch {
            throw await mapTunnelError(error, on: tunnel)
        }
    }

    public func shutdown() async {
        keepaliveTask?.cancel()
        keepaliveTask = nil

        if let persistentTunnel {
            await persistentTunnel.close()
        }
        persistentTunnel = nil

        let tunnels = streamTunnels.values
        streamTunnels.removeAll()
        for tunnel in tunnels {
            await tunnel.close()
        }

        if let client {
            // A child channel whose close promise never completes (seen with
            // keep-alive dial-stdio tunnels torn down mid-read) can wedge
            // client.close() forever; bound it so shutdown always returns.
            let box = SSHClientBox(client: client)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await box.close() }
                group.addTask { try? await Task.sleep(for: .seconds(3)) }
                await group.next()
                group.cancelAll()
            }
        }
        client = nil
    }

    // MARK: - Execute internals

    private func runExecute(_ requestData: Data) async throws -> DockerResponse {
        lastActivity = Date()
        let tunnel = try await ensurePersistentTunnel()

        try await tunnel.write(requestData)

        var parser = HTTP1ResponseParser()
        var status: Int?
        var headers: [String: String] = [:]
        var body = Data()
        let inbound = tunnel.inbound

        do {
            loop: for try await chunk in inbound {
                let events = try parser.ingest(chunk)
                for event in events {
                    switch event {
                    case .head(let s, let h):
                        if s == 101 {
                            throw DockerError.connectionFailed(
                                "unexpected protocol upgrade (101) on buffered request"
                            )
                        }
                        status = s
                        headers = h
                    case .body(let data):
                        body.append(data)
                    case .end:
                        break loop
                    }
                }
            }
            // Inbound ended without an explicit `.end`: flush any trailing
            // events (read-until-close framing) and tear the tunnel down so the
            // next call gets a fresh one.
            if status != nil {
                let tail = try parser.finish()
                for event in tail {
                    if case .body(let data) = event { body.append(data) }
                }
                await dropPersistentTunnel()
            }
        } catch {
            throw await mapTunnelError(error, on: tunnel)
        }

        guard let status else {
            let detail = await tunnel.stderrTail()
            await dropPersistentTunnel()
            throw DockerError.connectionFailed(
                "no response from remote daemon" + (detail.isEmpty ? "" : ": \(detail)")
            )
        }

        lastActivity = Date()
        return DockerResponse(status: status, headers: headers, body: body)
    }

    // MARK: - Stream pump

    private func pumpStream(
        tunnel: Tunnel,
        parser: HTTP1ResponseParser,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async {
        var parser = parser
        let inbound = tunnel.inbound
        do {
            for try await chunk in inbound {
                let events = try parser.ingest(chunk)
                for event in events {
                    switch event {
                    case .head:
                        // A fresh head after the first one only happens on
                        // keep-alive reuse, which streams never do.
                        break
                    case .body(let data):
                        if !data.isEmpty { continuation.yield(data) }
                    case .end:
                        continuation.finish()
                        return
                    }
                }
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish(throwing: DockerError.cancelled)
        } catch {
            continuation.finish(throwing: await mapTunnelError(error, on: tunnel))
        }
    }

    private func removeStreamTunnel(_ id: UUID) {
        streamTunnels[id] = nil
    }

    private func closeStreamTunnel(_ id: UUID) async {
        guard let tunnel = streamTunnels.removeValue(forKey: id) else { return }
        await tunnel.close()
    }

    // MARK: - Tunnel lifecycle

    /// Returns a connected, alive SSH client, recreating it on demand.
    private func ensureClient() async throws -> SSHClient {
        if let client, client.isConnected {
            return client
        }
        client = nil
        do {
            let fresh = try await makeClient()
            client = fresh
            return fresh
        } catch let error as DockerError {
            throw error
        } catch {
            throw DockerError.connectionFailed(String(describing: error))
        }
    }

    private func openTunnel() async throws -> Tunnel {
        let client = try await ensureClient()
        return Tunnel(client: client, command: dialCommand)
    }

    private func ensurePersistentTunnel() async throws -> Tunnel {
        if let persistentTunnel {
            return persistentTunnel
        }
        let tunnel = try await openTunnel()
        persistentTunnel = tunnel
        startKeepaliveIfNeeded()
        return tunnel
    }

    private func dropPersistentTunnel() async {
        guard let tunnel = persistentTunnel else { return }
        persistentTunnel = nil
        await tunnel.close()
    }

    // MARK: - Error mapping

    /// Maps a tunnel-side error into a `DockerError`, surfacing the remote
    /// stderr tail for `dial-stdio` failures (e.g. docker missing on remote).
    private func mapTunnelError(_ error: Error, on tunnel: Tunnel) async -> DockerError {
        if let docker = error as? DockerError { return docker }
        if let failed = error as? SSHClient.CommandFailed {
            let tail = await tunnel.stderrTail()
            return DockerError.connectionFailed(
                "docker not available on remote host (dial-stdio exit \(failed.exitCode)): \(tail)"
            )
        }
        return DockerError.connectionFailed(String(describing: error))
    }

    // MARK: - Keepalive

    private func startKeepaliveIfNeeded() {
        guard keepaliveTask == nil else { return }
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.keepaliveInterval)
                guard let self else { return }
                await self.keepalivePulse()
            }
        }
    }

    private func keepalivePulse() async {
        guard persistentTunnel != nil else { return }
        if Date().timeIntervalSince(lastActivity) < 30 { return }
        let ping = DockerRequest(method: .get, path: "/_ping")
        _ = try? await execute(ping)
    }
}

// MARK: - Tunnel

/// A single `docker system dial-stdio` channel.
///
/// The channel lives entirely inside the `withExec` `perform` closure, which
/// runs in a nonisolated context and exclusively owns the non-`Sendable`
/// `TTYStdinWriter` and the inbound iterator. We bridge it to the actor through
/// `Sendable` primitives only:
/// - an `AsyncStream<Data>` carrying decoded stdout chunks (inbound),
/// - an `AsyncStream<WriteItem>` of outbound write requests the closure drains
///   and applies to its private `TTYStdinWriter`, so that writer never crosses
///   an isolation boundary,
/// - a `Diagnostics` actor holding the last ~2KB of stderr for error messages,
/// - a `Shutdown` latch (a `CheckedContinuation`) the closure awaits so the
///   channel stays open until `close()` is called or inbound ends.
///
/// stderr is collected (last ~2KB) for diagnostics only, never mixed into the
/// HTTP byte stream.
final class Tunnel: Sendable {
    /// One queued outbound write; `done` reports the write's success/failure
    /// back to the caller waiting on the actor side.
    private struct WriteItem: Sendable {
        let data: Data
        let done: CheckedContinuation<Void, Error>
    }

    /// Accumulates the tail of remote stderr for diagnostics.
    private actor Diagnostics {
        private var tail = Data()
        private static let maxBytes = 2 * 1024

        func append(_ data: Data) {
            tail.append(data)
            if tail.count > Self.maxBytes {
                tail.removeFirst(tail.count - Self.maxBytes)
            }
        }

        func snapshot() -> String {
            String(decoding: tail, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Carries the non-`Sendable` `TTYStdinWriter` into the writer child task.
    ///
    /// Safety: `TTYStdinWriter`'s only stored property is a NIO `Channel`,
    /// which is `Sendable`, and `write` merely forwards to `channel.writeAndFlush`
    /// — fully thread-safe in NIO. The struct is unmarked solely because Citadel
    /// did not annotate it. Only the writer task ever touches the box.
    private struct OutboundBox: @unchecked Sendable {
        let writer: TTYStdinWriter
    }

    let inbound: AsyncStream<Data>
    private let outboundContinuation: AsyncStream<WriteItem>.Continuation
    private let diagnostics = Diagnostics()
    private let shutdown = Shutdown()
    private let task: Task<Void, Never>

    init(client: SSHClient, command: String) {
        let diagnostics = self.diagnostics
        let shutdown = self.shutdown
        let clientBox = SSHClientBox(client: client)

        let (inboundStream, inboundContinuation) = AsyncStream<Data>.makeStream()
        let (outboundStream, outboundContinuation) = AsyncStream<WriteItem>.makeStream()
        self.inbound = inboundStream
        self.outboundContinuation = outboundContinuation

        self.task = Task {
            do {
                try await clientBox.client.withExec(command) { inbound, outbound in
                    // Drain queued writes on a child task. `outbound` is boxed
                    // (see OutboundBox) so it can cross into the task; it still
                    // never reaches the actor.
                    let outboundBox = OutboundBox(writer: outbound)
                    let writerTask = Task {
                        for await item in outboundStream {
                            do {
                                try await outboundBox.writer.write(ByteBuffer(bytes: item.data))
                                item.done.resume()
                            } catch {
                                item.done.resume(throwing: error)
                            }
                        }
                        // Stream finished: fail any items that slipped past the
                        // yield/terminated check without a resume.
                    }
                    defer { writerTask.cancel() }

                    do {
                        for try await output in inbound {
                            switch output {
                            case .stdout(let buffer):
                                inboundContinuation.yield(Data(buffer.readableBytesView))
                            case .stderr(let buffer):
                                await diagnostics.append(Data(buffer.readableBytesView))
                            }
                        }
                        // Remote closed stdout: end the byte stream, then keep
                        // the closure alive until `close()` releases the latch
                        // so a late reader still drains buffered bytes.
                        inboundContinuation.finish()
                        await shutdown.wait()
                    } catch {
                        // Remote non-zero exit surfaces here (CommandFailed).
                        inboundContinuation.finish()
                        throw error
                    }
                }
            } catch {
                inboundContinuation.finish()
            }
            // Fail any writes still queued after the channel is gone.
            outboundContinuation.finish()
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let item = WriteItem(data: data, done: continuation)
            switch outboundContinuation.yield(item) {
            case .terminated:
                continuation.resume(throwing: DockerError.streamClosed)
            case .enqueued, .dropped:
                break
            @unknown default:
                break
            }
        }
    }

    func stderrTail() async -> String {
        await diagnostics.snapshot()
    }

    func close() async {
        // Stop accepting writes, then release the latch so the perform closure
        // returns and the SSH channel closes; cancel the backing task as a
        // backstop in case the closure is blocked on inbound iteration.
        outboundContinuation.finish()
        await shutdown.release()
        task.cancel()
    }
}

/// A `Sendable` wrapper around the non-`Sendable` `SSHClient` so it can cross
/// isolation boundaries (into the tunnel's `Task`, or out of the actor to be
/// closed) without tripping region-based data-race analysis.
///
/// Safety: `SSHClient` is a `final class` whose concurrency-facing surface
/// (`withExec`, `close`, `isConnected`) is internally serialized on its NIO
/// event loop and accepts `@Sendable` callbacks; Citadel is built to be driven
/// from arbitrary tasks. We never mutate shared client state from two places at
/// once — the actor owns the lifecycle and a tunnel only invokes `withExec`.
struct SSHClientBox: @unchecked Sendable {
    let client: SSHClient

    func close() async {
        try? await client.close()
    }
}

/// A one-shot latch the `perform` closure awaits so the SSH channel stays open
/// for the tunnel's lifetime. Releasing it (or cancelling the task) lets the
/// closure return, which closes the channel.
private actor Shutdown {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if released {
                c.resume()
            } else {
                continuation = c
            }
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
