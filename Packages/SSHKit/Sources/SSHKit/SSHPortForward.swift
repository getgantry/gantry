import Foundation
import Citadel
import NIOCore
import NIOPosix
import NIOSSH

/// A local-to-remote TCP forward over SSH — the equivalent of `ssh -L`.
///
/// Owns a dedicated SSH connection (built via `makeClient`) so forwarded
/// traffic never contends with the Docker dial-stdio tunnel, and tearing the
/// forward down cannot disturb Docker traffic. A listener on
/// `127.0.0.1:<localPort>` accepts connections and, for each one, opens a
/// direct-tcpip channel to `<remoteHost>:<remotePort>` on the SSH server and
/// splices the two channels together.
public actor SSHPortForward {
    public typealias MakeClient = @Sendable () async throws -> SSHClient

    private let makeClient: MakeClient
    private let group: EventLoopGroup
    private var client: SSHClientBox?
    private var serverChannel: Channel?
    private var started = false

    public init(makeClient: @escaping MakeClient) {
        self.makeClient = makeClient
        self.group = MultiThreadedEventLoopGroup.singleton
    }

    /// Starts forwarding `127.0.0.1:localPort` to `remoteHost:remotePort` as
    /// reached from the SSH server (so `127.0.0.1` there means the server's own
    /// loopback, where Docker publishes ports). Returns the port actually bound,
    /// which differs from `localPort` only when `localPort` is 0. If the
    /// requested port is busy, `bind` throws and the caller can retry on another.
    @discardableResult
    public func start(
        localHost: String = "127.0.0.1",
        localPort: Int,
        remoteHost: String,
        remotePort: Int
    ) async throws -> Int {
        guard !started else { throw PortForwardError.alreadyStarted }
        let box = SSHClientBox(client: try await makeClient())
        self.client = box

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { localChannel in
                // Defer activation of the accepted connection until the matching
                // remote channel is open and both ends are spliced. Returning a
                // pending future keeps NIO from reading before the bridge exists.
                let promise = localChannel.eventLoop.makePromise(of: Void.self)
                Task {
                    do {
                        let remote = try await Self.openRemoteChannel(
                            box: box,
                            remoteHost: remoteHost,
                            remotePort: remotePort
                        )
                        try await Self.splice(localChannel, remote)
                        promise.succeed(())
                    } catch {
                        localChannel.close(promise: nil)
                        promise.fail(error)
                    }
                }
                return promise.futureResult
            }

        do {
            let channel = try await bootstrap.bind(host: localHost, port: localPort).get()
            self.serverChannel = channel
            self.started = true
            return channel.localAddress?.port ?? localPort
        } catch {
            await box.close()
            self.client = nil
            throw error
        }
    }

    /// Stops accepting new connections and drops the dedicated SSH connection.
    /// In-flight connections close as their channels tear down.
    public func stop() async {
        if let serverChannel {
            try? await serverChannel.close().get()
        }
        serverChannel = nil
        if let client {
            await client.close()
        }
        client = nil
        started = false
    }

    // MARK: - Bridging

    private static func openRemoteChannel(
        box: SSHClientBox,
        remoteHost: String,
        remotePort: Int
    ) async throws -> Channel {
        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let settings = SSHChannelType.DirectTCPIP(
            targetHost: remoteHost,
            targetPort: remotePort,
            originatorAddress: originator
        )
        return try await box.client.createDirectTCPIPChannel(using: settings) { channel in
            channel.eventLoop.makeSucceededVoidFuture()
        }
    }

    /// Wires two channels so each one's reads are written to the other. Both
    /// channels deal in `ByteBuffer` (the direct-tcpip channel via Citadel's
    /// codec), and `Channel.writeAndFlush` is thread-safe, so the two ends may
    /// live on different event loops.
    private static func splice(_ a: Channel, _ b: Channel) async throws {
        try await a.pipeline.addHandler(ForwardHandler(peer: b)).get()
        try await b.pipeline.addHandler(ForwardHandler(peer: a)).get()
    }
}

public enum PortForwardError: Error, LocalizedError, Sendable {
    case alreadyStarted

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted: "This forward is already running."
        }
    }
}

/// Copies inbound bytes to a peer channel and propagates close in both
/// directions. Cross-event-loop safe because it only calls the peer's
/// thread-safe `Channel` methods.
private final class ForwardHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let peer: Channel

    init(peer: Channel) {
        self.peer = peer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        peer.writeAndFlush(buffer, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        peer.close(promise: nil)
        context.close(promise: nil)
    }
}
