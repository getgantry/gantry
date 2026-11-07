import Foundation
import Yams

/// The `exec` credential plugin of a kubeconfig user
/// (client.authentication.k8s.io).
public struct KubeExecConfig: Hashable, Sendable {
    public var command: String
    public var args: [String]
    public var env: [String: String]
    public var apiVersion: String
    /// `provideClusterInfo`: the plugin gets the cluster in `KUBERNETES_EXEC_INFO`.
    public var provideClusterInfo: Bool
    /// The directory of the kubeconfig file, for a relative `command`.
    public var baseDirectory: String

    public init(
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        apiVersion: String = "client.authentication.k8s.io/v1",
        provideClusterInfo: Bool = false,
        baseDirectory: String = ""
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.apiVersion = apiVersion
        self.provideClusterInfo = provideClusterInfo
        self.baseDirectory = baseDirectory
    }
}

/// How a context logs in. Paths are already read: the values are PEM or
/// token text. The type never prints its secrets (see `description`).
public struct KubeAuth: Hashable, Sendable, CustomStringConvertible {
    public var token: String?
    /// A file with the token; read on each request, so a rotated token works.
    public var tokenFile: String?
    public var username: String?
    public var password: String?
    public var clientCertificatePEM: Data?
    public var clientKeyPEM: Data?
    public var exec: KubeExecConfig?
    /// The name of a legacy `auth-provider` (for example `oidc`). Gantry
    /// does not support it and shows a message.
    public var authProvider: String?

    public init() {}

    public var description: String {
        var kinds: [String] = []
        if token != nil || tokenFile != nil { kinds.append("token") }
        if username != nil { kinds.append("basic") }
        if clientCertificatePEM != nil { kinds.append("client-certificate") }
        if exec != nil { kinds.append("exec") }
        if let authProvider { kinds.append("auth-provider:\(authProvider)") }
        return "KubeAuth(\(kinds.joined(separator: ",")))"
    }
}

/// Everything that a request to one context needs.
public struct KubeConnection: Hashable, Sendable {
    public var context: String
    public var server: URL
    public var namespace: String?
    /// PEM certificates that sign the API server certificate. Nil uses the
    /// system roots.
    public var certificateAuthorityPEM: Data?
    public var insecureSkipTLSVerify: Bool
    /// `tls-server-name`: the name to check on the server certificate.
    public var tlsServerName: String?
    public var proxyURL: URL?
    public var auth: KubeAuth

    public init(
        context: String,
        server: URL,
        namespace: String? = nil,
        certificateAuthorityPEM: Data? = nil,
        insecureSkipTLSVerify: Bool = false,
        tlsServerName: String? = nil,
        proxyURL: URL? = nil,
        auth: KubeAuth = KubeAuth()
    ) {
        self.context = context
        self.server = server
        self.namespace = namespace
        self.certificateAuthorityPEM = certificateAuthorityPEM
        self.insecureSkipTLSVerify = insecureSkipTLSVerify
        self.tlsServerName = tlsServerName
        self.proxyURL = proxyURL
        self.auth = auth
    }
}

public enum KubeConfigError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case unknownContext(String)
    case missingCluster(String)
    case invalidServer(String)
    case unreadableFile(String)
    case authProviderUnsupported(context: String, provider: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path):
            String(localized: "Gantry cannot read the kubeconfig file \(path).", bundle: .module)
        case .unknownContext(let name):
            String(localized: "The context \(name) is not in the kubeconfig.", bundle: .module)
        case .missingCluster(let name):
            String(localized: "The context \(name) has no cluster.", bundle: .module)
        case .invalidServer(let server):
            String(localized: "The server address \(server) is not valid.", bundle: .module)
        case .unreadableFile(let path):
            String(localized: "Gantry cannot read the file \(path).", bundle: .module)
        case .authProviderUnsupported(let context, let provider):
            String(localized: "The context \(context) uses the auth-provider \(provider). Kubernetes removed auth-provider in version 1.26. Change the user of the context to an exec credential plugin.", bundle: .module)
        }
    }
}

/// The merged kubeconfig files, read with Yams. The merge follows kubectl:
/// the first file that defines a name wins, and the first `current-context`
/// wins.
public struct KubeConfigFile: @unchecked Sendable {
    struct Named {
        var name: String
        var body: Node
        var directory: String
    }

    var clusters: [Named] = []
    var users: [Named] = []
    var contexts: [Named] = []
    public var currentContext: String?

    public init() {}

    /// Parses one file. `directory` resolves relative paths in it.
    public init(yaml: String, directory: String) throws {
        guard let root = try Yams.compose(yaml: yaml) else { return }
        currentContext = root["current-context"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        clusters = Self.named(root["clusters"], key: "cluster", directory: directory)
        users = Self.named(root["users"], key: "user", directory: directory)
        contexts = Self.named(root["contexts"], key: "context", directory: directory)
    }

    /// Reads and merges `paths`. A file that cannot be parsed throws.
    public static func load(paths: [String], read: (String) throws -> String = { try String(contentsOfFile: $0, encoding: .utf8) }) throws -> KubeConfigFile {
        var merged = KubeConfigFile()
        for path in paths {
            let text: String
            do { text = try read(path) } catch { throw KubeConfigError.unreadable(path) }
            let file: KubeConfigFile
            do { file = try KubeConfigFile(yaml: text, directory: (path as NSString).deletingLastPathComponent) } catch {
                throw KubeConfigError.unreadable(path)
            }
            merged.merge(file)
        }
        return merged
    }

    mutating func merge(_ other: KubeConfigFile) {
        if currentContext == nil { currentContext = other.currentContext }
        for item in other.clusters where !clusters.contains(where: { $0.name == item.name }) { clusters.append(item) }
        for item in other.users where !users.contains(where: { $0.name == item.name }) { users.append(item) }
        for item in other.contexts where !contexts.contains(where: { $0.name == item.name }) { contexts.append(item) }
    }

    static func named(_ node: Node?, key: String, directory: String) -> [Named] {
        guard let items = node?.sequence else { return [] }
        return items.compactMap { item in
            guard let name = item["name"]?.string, !name.isEmpty else { return nil }
            return Named(name: name, body: item[key] ?? Node.mapping(Node.Mapping([])), directory: directory)
        }
    }

    /// The contexts in merge order, for the picker.
    public func contextList(appleClusters: Set<String> = []) -> [KubeContext] {
        let list = contexts.map { item -> KubeContext in
            let cluster = item.body["cluster"]?.string ?? ""
            return KubeContext(
                name: item.name,
                cluster: cluster,
                user: item.body["user"]?.string ?? "",
                namespace: item.body["namespace"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                server: clusters.first { $0.name == cluster }?.body["server"]?.string,
                isCurrent: item.name == currentContext,
                isAppleCluster: appleClusters.contains(item.name) || appleClusters.contains(cluster)
            )
        }
        return list.filter(\.isAppleCluster) + list.filter { !$0.isAppleCluster }
    }

    /// Resolves a context into a connection: reads CA, certificate, key and
    /// token files. `readFile` is a test seam.
    public func connection(
        for name: String,
        readFile: (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) }
    ) throws -> KubeConnection {
        guard let context = contexts.first(where: { $0.name == name }) else { throw KubeConfigError.unknownContext(name) }
        let clusterName = context.body["cluster"]?.string ?? ""
        guard let cluster = clusters.first(where: { $0.name == clusterName }) else { throw KubeConfigError.missingCluster(name) }
        let serverText = cluster.body["server"]?.string ?? ""
        guard let server = URL(string: serverText), let scheme = server.scheme, ["https", "http"].contains(scheme), server.host != nil else {
            throw KubeConfigError.invalidServer(serverText)
        }
        let reader = FieldReader(directory: cluster.directory)
        var connection = KubeConnection(
            context: name,
            server: server,
            namespace: context.body["namespace"]?.string.flatMap { $0.isEmpty ? nil : $0 },
            certificateAuthorityPEM: try reader.data(cluster.body, inline: "certificate-authority-data", file: "certificate-authority", readFile: readFile),
            insecureSkipTLSVerify: cluster.body["insecure-skip-tls-verify"]?.bool ?? false,
            tlsServerName: cluster.body["tls-server-name"]?.string,
            proxyURL: cluster.body["proxy-url"]?.string.flatMap(URL.init(string:))
        )
        if let userName = context.body["user"]?.string, let user = users.first(where: { $0.name == userName }) {
            connection.auth = try Self.auth(user, readFile: readFile)
            // Kubernetes removed auth-provider in 1.26 (maintainer decision: no support).
            if let provider = connection.auth.authProvider, connection.auth.exec == nil {
                throw KubeConfigError.authProviderUnsupported(context: name, provider: provider)
            }
        }
        return connection
    }

    static func auth(_ user: Named, readFile: (String) throws -> Data) throws -> KubeAuth {
        let body = user.body
        let reader = FieldReader(directory: user.directory)
        var auth = KubeAuth()
        auth.clientCertificatePEM = try reader.data(body, inline: "client-certificate-data", file: "client-certificate", readFile: readFile)
        auth.clientKeyPEM = try reader.data(body, inline: "client-key-data", file: "client-key", readFile: readFile)
        auth.token = body["token"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        auth.tokenFile = body["tokenFile"]?.string.map(reader.resolve)
        auth.username = body["username"]?.string
        auth.password = body["password"]?.string
        if let exec = body["exec"], let command = exec["command"]?.string, !command.isEmpty {
            var env: [String: String] = [:]
            for item in exec["env"]?.sequence ?? [] {
                if let key = item["name"]?.string { env[key] = item["value"]?.string ?? "" }
            }
            auth.exec = KubeExecConfig(
                command: command,
                args: (exec["args"]?.sequence).map { $0.compactMap { $0.string } } ?? [],
                env: env,
                apiVersion: exec["apiVersion"]?.string ?? "client.authentication.k8s.io/v1",
                provideClusterInfo: exec["provideClusterInfo"]?.bool ?? false,
                baseDirectory: user.directory
            )
        }
        if let provider = body["auth-provider"] {
            auth.authProvider = provider["name"]?.string ?? "unknown"
        }
        return auth
    }

    /// Reads a `*-data` (base64) field or the file of the paired path field.
    struct FieldReader {
        var directory: String


        func resolve(_ path: String) -> String {
            if path.hasPrefix("~/") { return (NSHomeDirectory() as NSString).appendingPathComponent(String(path.dropFirst(2))) }
            if path.hasPrefix("/") || directory.isEmpty { return path }
            return (directory as NSString).appendingPathComponent(path)
        }

        func data(_ body: Node, inline: String, file: String, readFile: (String) throws -> Data) throws -> Data? {
            if let encoded = body[inline]?.string, !encoded.isEmpty {
                let compact = encoded.filter { !$0.isWhitespace }
                guard let data = Data(base64Encoded: compact) else { throw KubeConfigError.unreadableFile(inline) }
                return data
            }
            guard let path = body[file]?.string, !path.isEmpty else { return nil }
            let resolved = resolve(path)
            do { return try readFile(resolved) } catch { throw KubeConfigError.unreadableFile(resolved) }
        }
    }
}
