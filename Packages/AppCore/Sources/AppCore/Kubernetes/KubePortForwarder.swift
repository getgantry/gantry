import Foundation
import NIOCore
import NIOPosix

/// The pod and port that a port forward reaches.
public struct KubePortForwardTarget: Hashable, Sendable {
    public var pod: KubeResource
    public var port: Int
}

public enum KubeServiceTarget {
    typealias Object = [String: Any]

    /// Picks the pod and pod port behind a service port, like kubectl: the
    /// selector finds the pods, the first running and ready one wins, and a
    /// named `targetPort` maps to the container port with that name.
    public static func resolve(service: Data, pods: Data, port: Int) throws -> KubePortForwardTarget {
        guard let object = try JSONSerialization.jsonObject(with: service) as? Object,
              let list = try JSONSerialization.jsonObject(with: pods) as? Object else { throw KubeAPIError.unexpectedResponse }
        let metadata = object["metadata"] as? Object ?? [:]
        let namespace = metadata["namespace"] as? String
        let name = metadata["name"] as? String ?? ""
        let ports = (object["spec"] as? Object)?["ports"] as? [Object] ?? []
        let servicePort = ports.first { KubeResourceParser.int($0["port"]) == port }
        let target = servicePort?["targetPort"]
        let items = list["items"] as? [Object] ?? []
        guard let pod = items.first(where: isReady) else {
            throw KubeAPIError.status(code: 0, reason: nil, message: String(localized: "The service \(name) has no running pod.", bundle: .module))
        }
        let podName = (pod["metadata"] as? Object)?["name"] as? String ?? ""
        let resource = KubeResource(kind: .pods, name: podName, namespace: namespace)
        if let text = target as? String, Int(text) == nil {
            let containers = (pod["spec"] as? Object)?["containers"] as? [Object] ?? []
            let named = containers.flatMap { $0["ports"] as? [Object] ?? [] }.first { $0["name"] as? String == text }
            guard let number = KubeResourceParser.int(named?["containerPort"]) else {
                throw KubeAPIError.status(code: 0, reason: nil, message: String(localized: "The pod \(podName) has no port named \(text).", bundle: .module))
            }
            return KubePortForwardTarget(pod: resource, port: number)
        }
        return KubePortForwardTarget(pod: resource, port: KubeResourceParser.int(target) ?? port)
    }

    /// The label selector of a service as `key=value,…`, or nil without one.
    public static func selector(service: Data) throws -> String? {
        guard let object = try JSONSerialization.jsonObject(with: service) as? Object else { throw KubeAPIError.unexpectedResponse }
        guard let selector = (object["spec"] as? Object)?["selector"] as? [String: Any], !selector.isEmpty else { return nil }
        return selector.keys.sorted().map { "\($0)=\(selector[$0] as? String ?? "")" }.joined(separator: ",")
    }

    static func isReady(_ pod: Object) -> Bool {
        let metadata = pod["metadata"] as? Object ?? [:]
        let status = pod["status"] as? Object ?? [:]
        guard metadata["deletionTimestamp"] == nil, status["phase"] as? String == "Running" else { return false }
        let conditions = status["conditions"] as? [Object] ?? []
        return conditions.contains { $0["type"] as? String == "Ready" && $0["status"] as? String == "True" }
    }
}

extension KubeAPIClient {
    /// The pod and port for a forward to a pod or a service.
    public func portForwardTarget(_ resource: KubeResource, port: Int) async throws -> KubePortForwardTarget {
        guard resource.kind == .services else { return KubePortForwardTarget(pod: resource, port: port) }
        let service = try await json(for: resource)
        guard let selector = try KubeServiceTarget.selector(service: service) else {
            throw KubeAPIError.status(code: 0, reason: nil, message: String(localized: "The service \(resource.name) has no selector.", bundle: .module))
        }
        let pods = try await send(KubeRequests.list(.pods, namespace: resource.namespace, labelSelector: selector))
        return try KubeServiceTarget.resolve(service: service, pods: pods, port: port)
    }
}

/// A listener on 127.0.0.1 that forwards each TCP connection to a pod port
/// over its own port-forward WebSocket.
public final class KubePortForwarder: Sendable {
    public let localPort: Int
    private let server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
    private let task: Task<Void, Never>

    private init(localPort: Int, server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>, task: Task<Void, Never>) {
        self.localPort = localPort
        self.server = server
        self.task = task
    }

    /// Opens the listener. A `localPort` of 0 takes a free port.
    /// `connectionError` gets the error of a single forwarded connection.
    public static func start(
        _ client: KubeAPIClient,
        pod: KubeResource,
        port: Int,
        localPort: Int,
        connectionError: @escaping @Sendable (String) -> Void
    ) async throws -> KubePortForwarder {
        let server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
        do {
            server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: localPort) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                    }
                }
        } catch {
            throw KubeAPIError.transport(String(localized: "Gantry cannot listen on 127.0.0.1:\(localPort). The port may be in use.", bundle: .module))
        }
        let bound = server.channel.localAddress?.port ?? localPort
        let task = Task<Void, Never> {
            _ = try? await server.executeThenClose { inbound in
                await withDiscardingTaskGroup { group in
                    do {
                        for try await connection in inbound {
                            group.addTask {
                                do {
                                    try await forward(connection, client: client, pod: pod, port: port)
                                } catch is CancellationError {
                                } catch {
                                    connectionError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                                }
                            }
                        }
                    } catch {}
                    group.cancelAll()
                }
            }
        }
        return KubePortForwarder(localPort: bound, server: server, task: task)
    }

    public func stop() {
        task.cancel()
        server.channel.close(promise: nil)
    }

    /// Copies bytes both ways until one side closes or the pod reports an error.
    static func forward(_ connection: NIOAsyncChannel<ByteBuffer, ByteBuffer>, client: KubeAPIClient, pod: KubeResource, port: Int) async throws {
        try await connection.executeThenClose { inbound, outbound in
            let socket = try await KubeWebSocket.connect(
                client,
                request: KubeRequests.portForward(pod: pod, port: port),
                protocols: [KubeChannelFrames.v4Protocol]
            )
            defer { socket.close() }
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await buffer in inbound {
                        try await socket.send(KubePortForwardDemux.dataMessage(Data(buffer.readableBytesView)))
                    }
                }
                group.addTask {
                    var demux = KubePortForwardDemux(port: port)
                    for try await message in socket.messages {
                        for event in demux.feed(message) {
                            switch event {
                            case .data(let data): try await outbound.write(ByteBuffer(bytes: data))
                            case .error(let text): throw KubeAPIError.transport(text)
                            }
                        }
                    }
                }
                try await group.next()
                group.cancelAll()
            }
        }
    }
}
