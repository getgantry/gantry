import Foundation
import DockerKit

/// The containers that run the nodes of a `container cluster` cluster. The
/// cluster plugin owns them: CLI 1.7+ hides them from `container list` and
/// its start, stop, kill and delete refuse them; on 1.6 a lifecycle action
/// on a node breaks the cluster. Gantry blocks these actions on every CLI.
public enum AppleClusterNode {
    static let pluginLabel = "com.apple.container.plugin"
    static let roleLabel = "com.apple.container.resource.role"
    /// `cluster` since CLI 1.6.1; `k8s` is accepted for the 1.5 plugin.
    static let pluginValues: Set<String> = ["cluster", "k8s"]

    public static func isClusterNode(_ container: ContainerSummary) -> Bool {
        isClusterNode(labels: container.labels)
    }

    public static func isClusterNode(labels: [String: String]) -> Bool {
        labels[pluginLabel].map(pluginValues.contains) ?? false
    }

    /// The cluster of a node: workers are `<cluster>-worker-<n>`, and the
    /// control plane has the cluster name.
    public static func clusterName(forNode name: String) -> String {
        if let match = name.wholeMatch(of: /(.+)-worker-\d+/) { return String(match.1) }
        return name
    }

    /// The cluster of `container`, or nil when it is not a cluster node.
    public static func clusterName(of container: ContainerSummary) -> String? {
        guard isClusterNode(container) else { return nil }
        return clusterName(forNode: container.displayName)
    }

    /// Why the lifecycle actions are not available for a node of `cluster`.
    public static func lifecycleExplanation(cluster: String) -> String {
        String(
            localized: "This container is a node of the Kubernetes cluster \u{201C}\(cluster)\u{201D}. Start, stop and remove the cluster in Clusters.",
            bundle: .module
        )
    }
}
