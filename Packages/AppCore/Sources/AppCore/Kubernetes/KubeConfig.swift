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
    /// Missing files are dropped. The first file that defines a name wins.
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

    /// The context to show first: the remembered one, the current one, then
    /// the first (apple/container contexts are first in the list).
    public static func preferredContext(_ contexts: [KubeContext], remembered: String?) -> String? {
        if let remembered, contexts.contains(where: { $0.name == remembered }) { return remembered }
        return (contexts.first(where: \.isCurrent) ?? contexts.first)?.name
    }
}
