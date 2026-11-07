import Foundation

/// The kubeconfig a cluster was created with, by host and cluster name, so
/// a later delete removes the context from the same file. The app and
/// `gantry-mcp` share the file (`cluster-kubeconfigs.json` beside
/// `hosts.json`). Clusters made with the default `~/.kube/config` are not stored.
public enum ClusterKubeconfigStore {
    private static let lock = NSLock()

    /// TEST SEAM: `GANTRY_CLUSTER_KUBECONFIGS_PATH` replaces the file.
    static func fileURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["GANTRY_CLUSTER_KUBECONFIGS_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return HostsStore.fileURL()?.deletingLastPathComponent().appendingPathComponent("cluster-kubeconfigs.json")
    }

    private static func key(host: String, cluster: String) -> String { "\(host)/\(cluster)" }

    /// The kubeconfig recorded for `cluster` on `host`, or nil for the default.
    public static func path(host: String, cluster: String) -> String? {
        path(host: host, cluster: cluster, file: fileURL())
    }

    /// Records the kubeconfig of a new cluster; nil or empty removes the entry.
    public static func record(_ path: String?, host: String, cluster: String) {
        record(path, host: host, cluster: cluster, file: fileURL())
    }

    /// Every recorded kubeconfig, as cluster name and file path.
    public static func entries() -> [(cluster: String, path: String)] {
        entries(file: fileURL())
    }

    static func entries(file: URL?) -> [(cluster: String, path: String)] {
        lock.lock(); defer { lock.unlock() }
        return read(file)
            .map { (cluster: String($0.key.split(separator: "/", maxSplits: 1).last ?? ""), path: $0.value) }
            .sorted { $0.cluster == $1.cluster ? $0.path < $1.path : $0.cluster < $1.cluster }
    }

    static func path(host: String, cluster: String, file: URL?) -> String? {
        lock.lock(); defer { lock.unlock() }
        return read(file)[key(host: host, cluster: cluster)]
    }

    static func record(_ path: String?, host: String, cluster: String, file: URL?) {
        lock.lock(); defer { lock.unlock() }
        guard let file else { return }
        var entries = read(file)
        let trimmed = path?.trimmingCharacters(in: .whitespaces) ?? ""
        let name = key(host: host, cluster: cluster)
        guard entries[name] != (trimmed.isEmpty ? nil : trimmed) else { return }
        entries[name] = trimmed.isEmpty ? nil : trimmed
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: file, options: .atomic)
        }
    }

    private static func read(_ file: URL?) -> [String: String] {
        guard let file, let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return entries
    }
}
