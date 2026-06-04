import Foundation
import NIOCore

/// A SwiftNIO inbound handler that drives an HTTP upgrade ("hijack") over a raw
/// channel for `exec`/`attach`.
///
/// All mutable state is confined to the channel's event loop. External callers
/// reach it only through `head(on:)` and `attach(_:on:)`, which hop onto that
/// loop, so the handler needs no locking and is `Sendable` without escapes.
///
/// On `channelActive` it writes the pre-serialized request. Inbound bytes feed
/// an `HTTP1ResponseParser`; the first `.head` resolves the head future. A 101
/// (or older-daemon 200) upgrade switches the parser to passthrough /
/// read-until-close and every subsequent `.body` is forwarded verbatim to the
/// bytes stream. Any other status buffers its body and fails as an `apiError`.
final class HijackHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    struct Head: Sendable {
        var status: Int
        var headers: [String: String]
    }

    private let requestBytes: Data
    private var parser = HTTP1ResponseParser()

    private var head: Head?
    private var headPromise: EventLoopPromise<Head>?

    /// Buffers a non-upgrade response body until `.end`/close.
    private var errorStatus: Int?
    private var errorBody = Data()

    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    /// Passthrough bytes seen before a consumer attached.
    private var pendingBytes: [Data] = []
    /// Terminal state captured before a consumer attached. `.some(nil)` is a
    /// clean finish; `.some(error)` is a failure.
    private var terminal: Error??

    init(requestBytes: Data) {
        self.requestBytes = requestBytes
    }

    // MARK: - External API (hops onto the event loop)

    /// Awaits the parsed response head. Throws `apiError` for non-upgrade
    /// responses, or a connection error on failure/close before the head.
    ///
    /// `bound` carries this handler back onto its own event loop so the cross-
    /// loop hop stays `Sendable`-clean without escaping the handler's isolation.
    static func head(bound: NIOLoopBound<HijackHandler>, on eventLoop: EventLoop) async throws -> Head {
        let promise = eventLoop.makePromise(of: Head.self)
        eventLoop.execute {
            let handler = bound.value
            if let head = handler.head {
                promise.succeed(head)
            } else if case .some(let error) = handler.terminal {
                promise.fail(error ?? DockerError.streamClosed)
            } else {
                handler.headPromise = promise
            }
        }
        return try await promise.futureResult.get()
    }

    /// Attaches the bytes-stream consumer, flushing buffered passthrough data
    /// and any terminal state captured before attachment.
    static func attach(
        _ continuation: AsyncThrowingStream<Data, Error>.Continuation,
        bound: NIOLoopBound<HijackHandler>,
        on eventLoop: EventLoop
    ) {
        eventLoop.execute {
            let handler = bound.value
            handler.continuation = continuation
            for chunk in handler.pendingBytes {
                continuation.yield(chunk)
            }
            handler.pendingBytes.removeAll()
            if case .some(let error) = handler.terminal {
                if let error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - ChannelInboundHandler

    func channelActive(context: ChannelHandlerContext) {
        let buffer = context.channel.allocator.buffer(bytes: requestBytes)
        // Write to the channel directly; this handler declares no OutboundOut.
        context.channel.writeAndFlush(buffer, promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        let events: [HTTP1ResponseParser.Event]
        do {
            events = try parser.ingest(Data(buffer.readableBytesView))
        } catch {
            finish(with: DockerError.connectionFailed("malformed upgrade response: \(error)"))
            context.close(promise: nil)
            return
        }
        process(events, context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Flush a read-until-close tail, then end the stream. Before the head
        // this is a failure; after it, a clean close.
        let trailing = (try? parser.finish()) ?? []
        process(trailing, context: context)
        finish(with: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(with: DockerError.connectionFailed(String(describing: error)))
        context.close(promise: nil)
    }

    // MARK: - Event handling

    private func process(_ events: [HTTP1ResponseParser.Event], context: ChannelHandlerContext) {
        for event in events {
            switch event {
            case .head(let status, let headers):
                if status == 101 || status == 200 {
                    let value = Head(status: status, headers: headers)
                    head = value
                    headPromise?.succeed(value)
                    headPromise = nil
                } else {
                    errorStatus = status
                }

            case .body(let chunk):
                if errorStatus != nil {
                    errorBody.append(chunk)
                } else {
                    yield(chunk)
                }

            case .end:
                if let status = errorStatus {
                    finish(with: DockerError.apiError(status: status, message: errorMessage()))
                    context.close(promise: nil)
                }
            }
        }
    }

    private func yield(_ chunk: Data) {
        if let continuation {
            continuation.yield(chunk)
        } else {
            pendingBytes.append(chunk)
        }
    }

    private func finish(with error: Error?) {
        guard terminal == nil else { return }
        terminal = .some(error)

        // A head waiter that never received a head sees the error.
        if head == nil {
            headPromise?.fail(error ?? DockerError.streamClosed)
            headPromise = nil
        }
        if let continuation {
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }

    private func errorMessage() -> String {
        struct APIMessage: Decodable { let message: String }
        if let decoded = try? JSONDecoder().decode(APIMessage.self, from: errorBody) {
            return decoded.message
        }
        if let text = String(data: errorBody, encoding: .utf8), !text.isEmpty {
            return text
        }
        return "Upgrade rejected"
    }
}
