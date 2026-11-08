import Foundation

public enum KubeAPIError: Error, LocalizedError, Equatable {
    case noContext
    case unexpectedResponse
    /// The API server returned an error status; the text is its message.
    case status(code: Int, reason: String?, message: String)
    case transport(String)
    case credentials(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .noContext: String(localized: "Select a Kubernetes context.", bundle: .module)
        case .unexpectedResponse: String(localized: "The Kubernetes API returned data that Gantry cannot read.", bundle: .module)
        case .status(_, _, let message): message
        case .transport(let message): message
        case .credentials(let message): message
        case .timedOut(let message): message
        }
    }

    /// The HTTP status code for `.status`, else nil.
    public var statusCode: Int? {
        if case .status(let code, _, _) = self { code } else { nil }
    }

    /// Reads a `Status` object from an error response body.
    public static func from(statusCode: Int, body: Data) -> KubeAPIError {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let reason = object?["reason"] as? String
        var message = (object?["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if message.isEmpty {
            let text = String(decoding: body.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            message = text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: statusCode) : text
            message = String(localized: "HTTP \(statusCode): \(message)", bundle: .module)
        }
        return .status(code: statusCode, reason: reason, message: message)
    }
}

extension KubeAPIError {
    /// The error with every credential value of `auth` masked.
    func redacted(_ auth: KubeAuth) -> KubeAPIError {
        let secrets = KubeRedaction.secrets(of: auth)
        switch self {
        case .status(let code, let reason, let message): return .status(code: code, reason: reason, message: KubeRedaction.redact(message, secrets: secrets))
        case .transport(let message): return .transport(KubeRedaction.redact(message, secrets: secrets))
        case .credentials(let message): return .credentials(KubeRedaction.redact(message, secrets: secrets))
        case .timedOut(let message): return .timedOut(KubeRedaction.redact(message, secrets: secrets))
        case .noContext, .unexpectedResponse: return self
        }
    }
}

/// Masks credential values in texts that can reach the UI or a log.
public enum KubeRedaction {
    public static let mask = "••••••"

    /// The token, password and key of a user, and the lines of a PEM key.
    public static func secrets(of auth: KubeAuth) -> [String] {
        var values = [auth.token, auth.password].compactMap { $0 }
        if let user = auth.username, let password = auth.password {
            values.append(Data("\(user):\(password)".utf8).base64EncodedString())
        }
        if let key = auth.clientKeyPEM.map({ String(decoding: $0, as: UTF8.self) }) {
            values += key.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("-----") }
        }
        values += auth.exec?.env.values.map { $0 } ?? []
        return values
    }

    /// `text` with each secret of 4 or more characters replaced by ``mask``.
    public static func redact(_ text: String, secrets: [String]) -> String {
        secrets.filter { $0.count >= 4 }.sorted { $0.count > $1.count }.reduce(text) {
            $0.replacingOccurrences(of: $1, with: mask)
        }
    }
}

/// One API request, built without a network so tests can check it.
public struct KubeRequest: Hashable, Sendable {
    public enum Method: String, Sendable {
        case get = "GET", post = "POST", patch = "PATCH", delete = "DELETE"
    }

    public var method: Method
    public var path: String
    public var query: [URLQueryItem]
    public var contentType: String?
    public var body: Data?
    /// The request may stream for a long time (watch, follow logs, exec).
    public var streaming: Bool

    public init(
        _ method: Method = .get,
        _ path: String,
        query: [URLQueryItem] = [],
        contentType: String? = nil,
        body: Data? = nil,
        streaming: Bool = false
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.contentType = contentType
        self.body = body
        self.streaming = streaming
    }

    /// The full URL on `server`. The path of the server URL (a proxy prefix)
    /// stays in front.
    public func url(server: URL) -> URL? {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
        let base = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = base + path
        // Strict encoding: Go servers drop parameters with `;` and read `+` as a space.
        components.percentEncodedQuery = query.isEmpty ? nil : query.map {
            "\(Self.encode($0.name))=\(Self.encode($0.value ?? ""))"
        }.joined(separator: "&")
        return components.url
    }
}

extension KubeRequest {
    static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }
}

/// Builders for the requests that the browser sends.
public enum KubeRequests {
    static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }

    /// `/api/v1/namespaces/web/pods`, or `/api/v1/pods` for all namespaces.
    public static func collectionPath(prefix: String, resource: String, namespace: String?) -> String {
        if let namespace, !namespace.isEmpty {
            return "\(prefix)/namespaces/\(segment(namespace))/\(resource)"
        }
        return "\(prefix)/\(resource)"
    }

    public static func objectPath(_ resource: KubeResource) -> String {
        collectionPath(
            prefix: resource.kind.apiPrefix,
            resource: resource.kind.resourceName,
            namespace: resource.kind.isNamespaced ? resource.namespace : nil
        ) + "/" + segment(resource.name)
    }

    public static func list(_ kind: KubeResourceKind, namespace: String?, labelSelector: String? = nil) -> KubeRequest {
        var query: [URLQueryItem] = []
        if let labelSelector, !labelSelector.isEmpty { query.append(URLQueryItem(name: "labelSelector", value: labelSelector)) }
        return KubeRequest(.get, collectionPath(prefix: kind.apiPrefix, resource: kind.resourceName, namespace: kind.isNamespaced ? namespace : nil), query: query)
    }

    /// A watch from `resourceVersion`. The server ends it after
    /// `timeoutSeconds`; the client then watches again.
    public static func watch(_ kind: KubeResourceKind, namespace: String?, resourceVersion: String, timeoutSeconds: Int = 240) -> KubeRequest {
        var request = list(kind, namespace: namespace)
        request.query += [
            URLQueryItem(name: "watch", value: "true"),
            URLQueryItem(name: "resourceVersion", value: resourceVersion),
            URLQueryItem(name: "allowWatchBookmarks", value: "true"),
            URLQueryItem(name: "timeoutSeconds", value: String(timeoutSeconds)),
        ]
        request.streaming = true
        return request
    }

    public static var namespaces: KubeRequest { KubeRequest(.get, "/api/v1/namespaces") }

    public static func get(_ resource: KubeResource) -> KubeRequest {
        KubeRequest(.get, objectPath(resource))
    }

    /// Deletes in the background, like `kubectl delete --wait=false`.
    public static func delete(_ resource: KubeResource) -> KubeRequest {
        KubeRequest(.delete, objectPath(resource), query: [URLQueryItem(name: "propagationPolicy", value: "Background")])
    }

    /// A merge patch of the `scale` subresource.
    public static func scale(_ resource: KubeResource, replicas: Int) -> KubeRequest {
        let body = #"{"spec":{"replicas":\#(max(0, replicas))}}"#
        return KubeRequest(.patch, objectPath(resource) + "/scale", contentType: "application/merge-patch+json", body: Data(body.utf8))
    }

    /// The annotation that `kubectl rollout restart` sets.
    public static let restartedAtAnnotation = "kubectl.kubernetes.io/restartedAt"

    /// A strategic merge patch that changes the pod template, so the
    /// controller replaces every pod.
    public static func restart(_ resource: KubeResource, at date: Date = Date()) -> KubeRequest {
        let stamp = ISO8601DateFormatter().string(from: date)
        let patch: [String: Any] = ["spec": ["template": ["metadata": ["annotations": [restartedAtAnnotation: stamp]]]]]
        let body = (try? JSONSerialization.data(withJSONObject: patch, options: [.sortedKeys])) ?? Data()
        return KubeRequest(.patch, objectPath(resource), contentType: "application/strategic-merge-patch+json", body: body)
    }

    public static func logs(pod: KubeResource, container: String?, follow: Bool, tail: Int, previous: Bool = false) -> KubeRequest {
        var query: [URLQueryItem] = []
        if let container, !container.isEmpty { query.append(URLQueryItem(name: "container", value: container)) }
        if follow { query.append(URLQueryItem(name: "follow", value: "true")) }
        if previous { query.append(URLQueryItem(name: "previous", value: "true")) }
        query.append(URLQueryItem(name: "tailLines", value: String(max(0, tail))))
        return KubeRequest(.get, objectPath(pod) + "/log", query: query, streaming: follow)
    }

    /// The command of the pod shell: bash when the image has it, else sh.
    public static let shellCommand = ["sh", "-c", "command -v bash >/dev/null 2>&1 && exec bash || exec sh"]

    /// The exec WebSocket request. With a TTY, stderr goes to stdout.
    public static func exec(pod: KubeResource, container: String?, command: [String], stdin: Bool = true, tty: Bool = true) -> KubeRequest {
        var query = command.map { URLQueryItem(name: "command", value: $0) }
        if let container, !container.isEmpty { query.append(URLQueryItem(name: "container", value: container)) }
        query.append(URLQueryItem(name: "stdin", value: stdin ? "true" : "false"))
        query.append(URLQueryItem(name: "stdout", value: "true"))
        query.append(URLQueryItem(name: "stderr", value: tty ? "false" : "true"))
        query.append(URLQueryItem(name: "tty", value: tty ? "true" : "false"))
        return KubeRequest(.get, objectPath(pod) + "/exec", query: query, streaming: true)
    }

    /// The port-forward WebSocket request for one pod port.
    public static func portForward(pod: KubeResource, port: Int) -> KubeRequest {
        KubeRequest(.get, objectPath(pod) + "/portforward", query: [URLQueryItem(name: "ports", value: String(port))], streaming: true)
    }

    /// Server-side apply of one object, like `kubectl apply --server-side`.
    public static func apply(path: String, yaml: String, force: Bool = false) -> KubeRequest {
        KubeRequest(
            .patch, path,
            query: [URLQueryItem(name: "fieldManager", value: "gantry"), URLQueryItem(name: "force", value: force ? "true" : "false")],
            contentType: "application/apply-patch+yaml",
            body: Data(yaml.utf8)
        )
    }

    /// The resource list of one group version, for kinds that the table
    /// does not know.
    public static func discovery(apiVersion: String) -> KubeRequest {
        KubeRequest(.get, apiVersion.contains("/") ? "/apis/\(apiVersion)" : "/api/\(apiVersion)")
    }
}
