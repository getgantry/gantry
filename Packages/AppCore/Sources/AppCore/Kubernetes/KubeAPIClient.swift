import Foundation
import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import NIOSSL
import NIOPosix

/// The credentials of one request, after the exec plugin and token file.
struct KubeRequestAuth: Sendable {
    var authorization: String?
    var certificatePEM: Data?
    var keyPEM: Data?
}

enum KubeTLS {
    /// TLS for a context: the kubeconfig CA only (no system roots when it
    /// has one), and the client certificate when there is one. NIOSSL reads
    /// PEM keys in PKCS#1, SEC1 and PKCS#8 form, RSA and EC.
    static func configuration(_ connection: KubeConnection, certificatePEM: Data?, keyPEM: Data?) throws -> TLSConfiguration {
        var tls = TLSConfiguration.makeClientConfiguration()
        if connection.insecureSkipTLSVerify {
            tls.certificateVerification = .none
        } else if let ca = connection.certificateAuthorityPEM {
            do {
                tls.trustRoots = .certificates(try NIOSSLCertificate.fromPEMBytes(Array(ca)))
            } catch {
                throw KubeAPIError.credentials(String(localized: "The certificate authority in the kubeconfig is not valid.", bundle: .module))
            }
        }
        if let certificatePEM, let keyPEM {
            do {
                tls.certificateChain = try NIOSSLCertificate.fromPEMBytes(Array(certificatePEM)).map { .certificate($0) }
                tls.privateKey = .privateKey(try NIOSSLPrivateKey(bytes: Array(keyPEM), format: .pem))
            } catch {
                throw KubeAPIError.credentials(String(localized: "The client certificate or key in the kubeconfig is not valid.", bundle: .module))
            }
        }
        return tls
    }
}

/// One `HTTPClient` per TLS identity, kept for the life of the app.
actor KubeHTTPClientPool {
    static let shared = KubeHTTPClientPool()

    struct Key: Hashable {
        var ca: Data?
        var insecure: Bool
        var certificate: Data?
        var key: Data?
        var proxy: URL?
    }

    private var clients: [Key: HTTPClient] = [:]

    func client(_ connection: KubeConnection, auth: KubeRequestAuth) throws -> HTTPClient {
        let key = Key(
            ca: connection.certificateAuthorityPEM, insecure: connection.insecureSkipTLSVerify,
            certificate: auth.certificatePEM, key: auth.keyPEM, proxy: connection.proxyURL
        )
        if let client = clients[key] { return client }
        var configuration = HTTPClient.Configuration(
            tlsConfiguration: try KubeTLS.configuration(connection, certificatePEM: auth.certificatePEM, keyPEM: auth.keyPEM)
        )
        configuration.timeout = .init(connect: .seconds(5))
        configuration.decompression = .disabled
        if let proxy = connection.proxyURL, let host = proxy.host {
            switch proxy.scheme {
            case "socks5", "socks5h": configuration.proxy = .socksServer(host: host, port: proxy.port ?? 1080)
            default: configuration.proxy = .server(host: host, port: proxy.port ?? 8080)
            }
        }
        // NIOSSL client certificates need NIO sockets, not Network.framework.
        let client = HTTPClient(eventLoopGroup: MultiThreadedEventLoopGroup.singleton, configuration: configuration)
        clients[key] = client
        return client
    }
}

/// Sends API requests. The HTTP transport is the real one; tests give a
/// fake, so they do not need a network or a cluster.
public protocol KubeTransport: Sendable {
    /// Runs a request to completion. Throws ``KubeAPIError/status`` for a
    /// status outside 200–299.
    func send(_ request: KubeRequest, timeout: Duration) async throws -> (status: Int, body: Data)
    /// The body of a streaming request, line by line.
    func lines(_ request: KubeRequest) -> AsyncThrowingStream<String, Error>
}

/// A Kubernetes API client for one context. It talks HTTPS to the API
/// server directly; no kubectl. Values of the credentials never go to logs.
public struct KubeAPIClient: Sendable, Hashable {
    public let connection: KubeConnection
    let transport: any KubeTransport

    /// Each plain request stops after this time, so a dead cluster does not
    /// hang the UI.
    public static let requestTimeout: Duration = .seconds(15)

    public init(connection: KubeConnection, transport: (any KubeTransport)? = nil) {
        self.connection = connection
        self.transport = transport ?? KubeHTTPTransport(connection: connection)
    }

    public static func == (lhs: KubeAPIClient, rhs: KubeAPIClient) -> Bool { lhs.connection == rhs.connection }
    public func hash(into hasher: inout Hasher) { hasher.combine(connection) }

    public var context: String? { connection.context }

    func requestAuth(refresh: Bool = false) async throws -> KubeRequestAuth {
        try await KubeHTTPTransport.requestAuth(connection, refresh: refresh)
    }

    /// The headers of every request, the WebSocket ones included.
    static func headers(for request: KubeRequest, auth: KubeRequestAuth, accept: String = "application/json") -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.add(name: "Accept", value: accept)
        headers.add(name: "User-Agent", value: "Gantry")
        if let authorization = auth.authorization { headers.add(name: "Authorization", value: authorization) }
        if let contentType = request.contentType { headers.add(name: "Content-Type", value: contentType) }
        return headers
    }

    /// Runs a request to completion and returns the body.
    @discardableResult
    public func send(_ request: KubeRequest, timeout: Duration = KubeAPIClient.requestTimeout) async throws -> Data {
        try await transport.send(request, timeout: timeout).body
    }

    /// The status code of a request that succeeds (for 200 vs 201).
    func sendWithStatus(_ request: KubeRequest) async throws -> (Int, Data) {
        let result = try await transport.send(request, timeout: Self.requestTimeout)
        return (result.status, result.body)
    }

    /// The body of a streaming request, line by line. The stream ends when
    /// the server closes it; cancel the consuming task to stop it.
    public func lines(_ request: KubeRequest) -> AsyncThrowingStream<String, Error> {
        transport.lines(request)
    }

    static func describe(_ error: Error, server: URL) -> String {
        if let error = error as? NIOSSLError {
            return String(localized: "The TLS connection to \(server.absoluteString) failed: \(String(describing: error)).", bundle: .module)
        }
        if let error = error as? BoringSSLError {
            return String(localized: "The TLS connection to \(server.absoluteString) failed: \(String(describing: error)).", bundle: .module)
        }
        if let error = error as? HTTPClientError, error == .connectTimeout {
            return String(localized: "Gantry cannot connect to \(server.absoluteString).", bundle: .module)
        }
        if error is IOError || error is ChannelError {
            return String(localized: "Gantry cannot connect to \(server.absoluteString). Make sure that the cluster runs.", bundle: .module)
        }
        return String(describing: error)
    }
}

/// The real transport: AsyncHTTPClient with the TLS identity of the context.
struct KubeHTTPTransport: KubeTransport {
    let connection: KubeConnection

    /// The most bytes of one plain response.
    static let maxBody = 64 << 20

    static func requestAuth(_ connection: KubeConnection, refresh: Bool = false) async throws -> KubeRequestAuth {
        let auth = connection.auth
        var result = KubeRequestAuth(certificatePEM: auth.clientCertificatePEM, keyPEM: auth.clientKeyPEM)
        if let exec = auth.exec {
            let credential = try await KubeCredentialCache.shared.credential(for: exec, connection: connection, refresh: refresh)
            if let token = credential.token { result.authorization = "Bearer \(token)" }
            if let certificate = credential.clientCertificatePEM, let key = credential.clientKeyPEM {
                result.certificatePEM = certificate
                result.keyPEM = key
            }
        }
        if result.authorization == nil {
            if let file = auth.tokenFile, let text = try? String(contentsOfFile: file, encoding: .utf8) {
                result.authorization = "Bearer \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
            } else if let token = auth.token {
                result.authorization = "Bearer \(token)"
            } else if let user = auth.username {
                let pair = Data("\(user):\(auth.password ?? "")".utf8).base64EncodedString()
                result.authorization = "Basic \(pair)"
            }
        }
        return result
    }

    private func execute(_ request: KubeRequest, auth: KubeRequestAuth, deadline: NIODeadline) async throws -> HTTPClientResponse {
        guard let url = request.url(server: connection.server) else { throw KubeAPIError.unexpectedResponse }
        var http = HTTPClientRequest(url: url.absoluteString)
        http.method = HTTPMethod(rawValue: request.method.rawValue)
        http.headers = KubeAPIClient.headers(for: request, auth: auth)
        if let body = request.body { http.body = .bytes(ByteBuffer(bytes: body)) }
        let client = try await KubeHTTPClientPool.shared.client(connection, auth: auth)
        do {
            return try await client.execute(http, deadline: deadline)
        } catch let error as HTTPClientError where error == .deadlineExceeded {
            throw KubeAPIError.timedOut(String(localized: "The Kubernetes API did not answer in time.", bundle: .module))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as KubeAPIError {
            throw error
        } catch {
            throw KubeAPIError.transport(KubeAPIClient.describe(error, server: connection.server))
        }
    }

    /// Sends a request; on 401 with an exec plugin, gets a new credential once.
    private func open(_ request: KubeRequest, deadline: NIODeadline) async throws -> HTTPClientResponse {
        var response = try await execute(request, auth: try await Self.requestAuth(connection), deadline: deadline)
        if response.status == .unauthorized, connection.auth.exec != nil {
            response = try await execute(request, auth: try await Self.requestAuth(connection, refresh: true), deadline: deadline)
        }
        guard (200..<300).contains(response.status.code) else {
            let body = (try? await response.body.collect(upTo: 1 << 20)).map { Data(buffer: $0) } ?? Data()
            throw KubeAPIError.from(statusCode: Int(response.status.code), body: body).redacted(connection.auth)
        }
        return response
    }

    func send(_ request: KubeRequest, timeout: Duration) async throws -> (status: Int, body: Data) {
        let response = try await open(request, deadline: .now() + .seconds(max(1, timeout.components.seconds)))
        do {
            return (Int(response.status.code), Data(buffer: try await response.body.collect(upTo: Self.maxBody)))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw KubeAPIError.transport(KubeAPIClient.describe(error, server: connection.server))
        }
    }

    func lines(_ request: KubeRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await open(request, deadline: .now() + .hours(24))
                    var splitter = KubeLineBuffer()
                    for try await chunk in response.body {
                        for line in splitter.feed(Data(buffer: chunk)) { continuation.yield(line) }
                    }
                    if let last = splitter.flush() { continuation.yield(last) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Splits a byte stream into lines (LF or CRLF). Not thread-safe.
struct KubeLineBuffer {
    private var buffer = Data()

    mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            var line = buffer[start..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            lines.append(String(decoding: line, as: UTF8.self))
            start = buffer.index(after: newline)
        }
        buffer = Data(buffer[start...])
        return lines
    }

    mutating func flush() -> String? {
        defer { buffer.removeAll() }
        return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
    }
}

// MARK: - Operations

extension KubeAPIClient {
    public func namespaces() async throws -> [String] {
        try KubeResourceParser.namespaces(try await send(KubeRequests.namespaces))
    }

    /// Lists `kind` in `namespace`; nil or empty lists every namespace.
    public func list(_ kind: KubeResourceKind, namespace: String?) async throws -> [KubeResource] {
        try KubeResourceParser.parse(try await send(KubeRequests.list(kind, namespace: namespace)), kind: kind)
    }

    public func json(for resource: KubeResource) async throws -> Data {
        try await send(KubeRequests.get(resource))
    }

    /// The YAML of a resource. Secret values are hidden (see ``KubeSecretData``).
    public func yaml(for resource: KubeResource) async throws -> String {
        try KubeYAML.render(json: try await json(for: resource), redactSecret: resource.kind == .secrets)
    }

    public func delete(_ resource: KubeResource) async throws {
        try await send(KubeRequests.delete(resource))
    }

    public func scale(_ resource: KubeResource, replicas: Int) async throws {
        try await send(KubeRequests.scale(resource, replicas: replicas))
    }

    public func restart(_ resource: KubeResource) async throws {
        try await send(KubeRequests.restart(resource))
    }

    /// Waits until the rollout ends, like `kubectl rollout status`. Returns
    /// the last message.
    public func rolloutStatus(
        _ resource: KubeResource,
        timeout: Duration = .seconds(300),
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        let clock = ContinuousClock()
        let end = clock.now + timeout
        while true {
            let status = try KubeRolloutStatus.evaluate(try await json(for: resource), kind: resource.kind)
            if status.done { return status.message }
            progress(status.message)
            guard clock.now < end else { throw KubeAPIError.timedOut(status.message) }
            try await Task.sleep(for: .seconds(2))
        }
    }
}
