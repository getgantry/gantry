import Foundation

/// Why `container cluster` cannot reach its service (apple/container 1.7+).
/// The 1.7 cluster commands talk to the `container-core-clusters` plugin over
/// XPC; when the plugin is missing or its service is not loaded, every cluster
/// command fails with "cluster service unavailable".
public enum ClusterServiceProblem: Sendable, Equatable {
    /// A Homebrew build without the `container-core-clusters` (or `cluster-hoststore`) plugin.
    case homebrewMissingPlugin(version: String)
    /// The signed package layout without the plugin.
    case pluginMissing
    /// The plugin is installed, but its service does not answer.
    case servicesNotRunning

    /// The headline for the Clusters section and the cluster sheets.
    public var title: String {
        String(localized: "The cluster services are not installed or not running.", bundle: .module)
    }

    /// What to do next.
    public var advice: String {
        switch self {
        case .homebrewMissingPlugin(let version):
            String(
                localized: "This Homebrew build of container \(version) lacks the cluster services. Install the signed package from github.com/apple/container/releases.",
                bundle: .module
            )
        case .pluginMissing:
            String(
                localized: "This installation of container lacks the cluster services. Install the signed package from github.com/apple/container/releases.",
                bundle: .module
            )
        case .servicesNotRunning:
            String(
                localized: "Restart the apple/container services, then try again. After an upgrade, a restart loads the new cluster service.",
                bundle: .module
            )
        }
    }

    /// The fix is to install the signed package (else: restart the services).
    public var needsInstaller: Bool {
        switch self {
        case .homebrewMissingPlugin, .pluginMissing: true
        case .servicesNotRunning: false
        }
    }

    /// The releases page with the signed package.
    public static let releasesURL = URL(string: "https://github.com/apple/container/releases")!
}

public enum ClusterServiceDiagnosis {
    /// The plugins the 1.7 cluster commands need: the XPC service and the
    /// shared image store host. The Homebrew 1.7.1 bottle ships neither.
    static let requiredPlugins = ["container-core-clusters", "cluster-hoststore"]

    /// Whether a CLI error says that the cluster service is not reachable:
    /// "cluster service unavailable (…)" from ClusterClient, or the XPC
    /// "Connection invalid" error the CLI prints without that prefix.
    public static func isServiceUnavailable(_ message: String) -> Bool {
        let text = message.lowercased()
        if text.contains("cluster service unavailable") { return true }
        return text.contains("xpc connection error") && text.contains("connection invalid")
    }

    /// The problem behind a failed cluster command, or nil when the error
    /// is something else. `cliPath` is the CLI binary that ran the command.
    public static func problem(
        forError message: String,
        cliPath: String?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        resolve: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    ) -> ClusterServiceProblem? {
        guard isServiceUnavailable(message) else { return nil }
        guard let cliPath else { return .servicesNotRunning }
        return installProblem(cliPath: resolve(cliPath), fileExists: fileExists) ?? .servicesNotRunning
    }

    /// A missing plugin for the CLI at `cliPath` (symlinks already resolved).
    /// Homebrew: `<prefix>/Cellar/container/<v>/bin/container` with plugins in
    /// `libexec/container-plugins/`. Package: `<prefix>/bin/container` with
    /// plugins in `libexec/container/plugins/`.
    static func installProblem(cliPath: String, fileExists: (String) -> Bool) -> ClusterServiceProblem? {
        let bin = (cliPath as NSString).deletingLastPathComponent
        let root = (bin as NSString).deletingLastPathComponent
        guard (bin as NSString).lastPathComponent == "bin" else { return nil }
        let installed = requiredPlugins.allSatisfy { plugin in
            fileExists("\(root)/libexec/container-plugins/\(plugin)")
                || fileExists("\(root)/libexec/container/plugins/\(plugin)")
        }
        if installed { return nil }
        if let version = homebrewVersion(root: root) {
            return .homebrewMissingPlugin(version: version)
        }
        // Without a plugins folder at all this is not a layout Gantry knows.
        let pluginsFolder = "\(root)/libexec/container/plugins"
        return fileExists(pluginsFolder) ? .pluginMissing : nil
    }

    /// The release version of a `…/Cellar/container/<v>` folder.
    static func homebrewVersion(root: String) -> String? {
        let parts = root.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[parts.count - 3] == "Cellar", parts[parts.count - 2] == "container" else {
            return nil
        }
        // A bottle revision (`1.7.1_1`) is not part of the release version.
        return String(parts[parts.count - 1].split(separator: "_").first ?? "")
    }
}

extension ClusterServiceDiagnosis {
    /// Whether the Kubernetes browser shows the cluster service notice: when
    /// the selected context is a cluster of the container tool, or when there
    /// is no context (the clusters of the tool cannot be listed).
    public static func showsKubernetesNotice(contexts: [KubeContext], selectedContext: String?) -> Bool {
        guard !contexts.isEmpty else { return true }
        return contexts.first { $0.name == selectedContext }?.isAppleCluster ?? false
    }
}
