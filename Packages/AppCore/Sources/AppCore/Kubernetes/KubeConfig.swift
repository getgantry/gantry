import Foundation

/// One context of the merged kubeconfig.
public struct KubeContext: Identifiable, Hashable, Sendable {
    public var name: String
    public var cluster: String
    public var user: String
    /// The default namespace of the context, or nil for `default`.
    public var namespace: String?
    /// The API server URL of the context cluster.
    public var server: String?
    /// True for the `current-context` of the kubeconfig.
    public var isCurrent: Bool
    /// True for a cluster that apple/container made (`container cluster`).
    public var isAppleCluster: Bool

    public var id: String { name }

    public init(
        name: String,
        cluster: String = "",
        user: String = "",
        namespace: String? = nil,
        server: String? = nil,
        isCurrent: Bool = false,
        isAppleCluster: Bool = false
    ) {
        self.name = name
        self.cluster = cluster
        self.user = user
        self.namespace = namespace
        self.server = server
        self.isCurrent = isCurrent
        self.isAppleCluster = isAppleCluster
    }
}

/// The kubeconfig files and contexts that the Kubernetes browser reads.
public enum KubeConfig {
    /// The files for `KUBECONFIG`: the value of the app environment (or
    /// `~/.kube/config`), then the files of apple/container clusters.
    /// Missing files are dropped; kubectl reads them in this order.
    public static func paths(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        clusterFiles: [String] = ClusterKubeconfigStore.entries().map(\.path),
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String] {
        let base: [String]
        if let value = environment["KUBECONFIG"], !value.isEmpty {
            base = value.split(separator: ":").map(String.init)
        } else {
            base = [(home as NSString).appendingPathComponent(".kube/config")]
        }
        var result: [String] = []
        for raw in base + clusterFiles {
            let path = raw.hasPrefix("~/") ? (home as NSString).appendingPathComponent(String(raw.dropFirst(2))) : raw
            if !path.isEmpty, !result.contains(path), fileExists(path) { result.append(path) }
        }
        return result
    }

    /// Parses `kubectl config view -o json`. Contexts of apple/container
    /// clusters (by name in `appleClusters`) come first, the rest keep the
    /// file order.
    public static func parseContexts(_ data: Data, appleClusters: Set<String> = []) throws -> [KubeContext] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KubectlError.unexpectedOutput
        }
        let current = root["current-context"] as? String
        var servers: [String: String] = [:]
        for cluster in root["clusters"] as? [[String: Any]] ?? [] {
            if let name = cluster["name"] as? String,
               let server = (cluster["cluster"] as? [String: Any])?["server"] as? String {
                servers[name] = server
            }
        }
        let contexts: [KubeContext] = (root["contexts"] as? [[String: Any]] ?? []).compactMap { item in
            guard let name = item["name"] as? String, !name.isEmpty else { return nil }
            let body = item["context"] as? [String: Any] ?? [:]
            let cluster = body["cluster"] as? String ?? ""
            let namespace = (body["namespace"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return KubeContext(
                name: name,
                cluster: cluster,
                user: body["user"] as? String ?? "",
                namespace: namespace,
                server: servers[cluster],
                isCurrent: name == current,
                isAppleCluster: appleClusters.contains(name) || appleClusters.contains(cluster)
            )
        }
        return contexts.filter(\.isAppleCluster) + contexts.filter { !$0.isAppleCluster }
    }

    /// The context to show first: the remembered one, the current one, then
    /// the first (apple/container contexts are first in the list).
    public static func preferredContext(_ contexts: [KubeContext], remembered: String?) -> String? {
        if let remembered, contexts.contains(where: { $0.name == remembered }) { return remembered }
        return (contexts.first(where: \.isCurrent) ?? contexts.first)?.name
    }
}
