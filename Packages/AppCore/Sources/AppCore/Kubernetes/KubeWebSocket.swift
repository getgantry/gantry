import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import NIOSSL

/// A WebSocket to the API server (exec, port-forward), on SwiftNIO with
/// NIOSSL, so PEM client certificates work without the keychain.
public final class KubeWebSocket: Sendable {
    /// The subprotocol that the server chose.
    public let negotiatedProtocol: String?
    /// The binary messages from the server. The stream ends on close.
    public let messages: AsyncThrowingStream<Data, Error>

    private let channel: Channel

    init(channel: Channel, negotiatedProtocol: String?, messages: AsyncThrowingStream<Data, Error>) {
        self.channel = channel
        self.negotiatedProtocol = negotiatedProtocol
        self.messages = messages
    }

    /// Sends one binary message.
    public func send(_ data: Data) async throws {
        let frame = WebSocketFrame(fin: true, opcode: .binary, maskKey: .random(), data: ByteBuffer(bytes: data))
        try await channel.writeAndFlush(frame)
    }

    /// Sends a close frame and closes the connection.
    public func close() {
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: ByteBuffer(bytes: [0x03, 0xE8]))
        channel.writeAndFlush(frame).whenComplete { [channel] _ in channel.close(promise: nil) }
    }

    /// Opens a WebSocket for `request` on the context of `client`.
    public static func connect(_ client: KubeAPIClient, request: KubeRequest, protocols: [String]) async throws -> KubeWebSocket {
        let connection = client.connection
        guard let url = request.url(server: connection.server), let host = url.host else { throw KubeAPIError.unexpectedResponse }
        let secure = url.scheme == "https"
        let port = url.port ?? (secure ? 443 : 80)
        let auth = try await client.requestAuth()
        let tls: NIOSSLContext? = try secure ? {
            var configuration = try KubeTLS.configuration(connection, certificatePEM: auth.certificatePEM, keyPEM: auth.keyPEM)
            configuration.applicationProtocols = ["http/1.1"]
            return try NIOSSLContext(configuration: configuration)
        }() : nil
        let serverName = connection.tlsServerName ?? (isIPAddress(host) ? nil : host)

        var headers = KubeAPIClient.headers(for: request, auth: auth, accept: "*/*")
        headers.add(name: "Host", value: url.port.map { "\(host):\($0)" } ?? host)
        headers.add(name: "Sec-WebSocket-Protocol", value: protocols.joined(separator: ", "))
        var target = url.path.isEmpty ? "/" : url.path
        if let query = url.query { target += "?" + query }
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: target, headers: headers)

        let (messages, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let upgraded = KubeOncePromise(MultiThreadedEventLoopGroup.singleton.next().makePromise(of: String?.self))
        let requestHandler = KubeUpgradeRequestHandler(head: head, upgraded: upgraded)

        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let tls {
                        try channel.pipeline.syncOperations.addHandler(try NIOSSLClientHandler(context: tls, serverHostname: serverName))
                    }
                    let upgrader = NIOWebSocketClientUpgrader(maxFrameSize: 1 << 24, automaticErrorHandling: true) { channel, response in
                        let chosen = response.headers.first(name: "Sec-WebSocket-Protocol")
                        return channel.pipeline.removeHandler(name: KubeUpgradeRequestHandler.name).flatMap {
                            channel.eventLoop.makeCompletedFuture {
                                try channel.pipeline.syncOperations.addHandler(NIOWebSocketFrameAggregator(
                                    minNonFinalFragmentSize: 0, maxAccumulatedFrameCount: 1 << 16, maxAccumulatedFrameSize: 1 << 26
                                ))
                                try channel.pipeline.syncOperations.addHandler(KubeWebSocketBridge(continuation: continuation))
                            }
                        }.map { upgraded.succeed(chosen) }
                    }
                    try channel.pipeline.syncOperations.addHTTPClientHandlers(
                        withClientUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
                    )
                    try channel.pipeline.syncOperations.addHandler(requestHandler, name: KubeUpgradeRequestHandler.name)
                }
            }
        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            upgraded.fail(error)
            throw KubeAPIError.transport(KubeAPIClient.describe(error, server: connection.server))
        }
        channel.closeFuture.whenComplete { _ in
            upgraded.fail(KubeAPIError.transport(String(localized: "The connection closed before the WebSocket opened.", bundle: .module)))
        }
        do {
            let chosen = try await withTaskCancellationHandler {
                try await upgraded.future.get()
            } onCancel: {
                channel.close(promise: nil)
            }
            return KubeWebSocket(channel: channel, negotiatedProtocol: chosen, messages: messages)
        } catch let error as KubeAPIError {
            channel.close(promise: nil)
            throw error
        } catch {
            channel.close(promise: nil)
            throw KubeAPIError.transport(KubeAPIClient.describe(error, server: connection.server))
        }
    }

    static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }
}

/// Sends the upgrade request. When the server answers without an upgrade,
/// it fails the connect with the status and body of the answer.
final class KubeUpgradeRequestHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    static let name = "gantry-kube-upgrade-request"

    private let head: HTTPRequestHead
    private let upgraded: KubeOncePromise
    private var status: Int = 0
    private var body = Data()

    init(head: HTTPRequestHead, upgraded: KubeOncePromise) {
        self.head = head
        self.upgraded = upgraded
    }

    func channelActive(context: ChannelHandlerContext) {
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let response):
            status = Int(response.status.code)
        case .body(let buffer):
            if body.count < 1 << 20 { body.append(contentsOf: buffer.readableBytesView) }
        case .end:
            upgraded.fail(KubeAPIError.from(statusCode: status, body: body))
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        upgraded.fail(error)
        context.close(promise: nil)
    }
}

/// Moves frames between the channel and the message stream; answers pings.
final class KubeWebSocketBridge: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .binary, .text:
            continuation.yield(Data(frame.unmaskedData.readableBytesView))
        case .ping:
            let pong = WebSocketFrame(fin: true, opcode: .pong, maskKey: .random(), data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            continuation.finish()
            let reply = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: ByteBuffer())
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(reply)).whenComplete { _ in channel.close(promise: nil) }
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }
}

/// A promise that ignores every result after the first one.
final class KubeOncePromise: @unchecked Sendable {
    private let promise: EventLoopPromise<String?>
    private let lock = NSLock()
    private var done = false

    init(_ promise: EventLoopPromise<String?>) { self.promise = promise }

    var future: EventLoopFuture<String?> { promise.futureResult }

    func succeed(_ value: String?) {
        if claim() { promise.succeed(value) }
    }

    func fail(_ error: Error) {
        if claim() { promise.fail(error) }
    }

    private func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
