import Foundation
import DockerKit

/// Builds palette results from one host's resource lists. Pure: the app
/// passes the session's arrays, tests pass fixtures.
public enum PaletteCatalog {
    /// The host the resources belong to.
    public struct Host: Sendable, Hashable {
        public var id: UUID
        public var name: String
        public var isAppleContainer: Bool
        public var isConnected: Bool

        public init(id: UUID, name: String, isAppleContainer: Bool, isConnected: Bool) {
            self.id = id
            self.name = name
            self.isAppleContainer = isAppleContainer
            self.isConnected = isConnected
        }
    }

    /// Networks that the engine owns and that cannot be removed.
    public static let builtInNetworks: Set<String> = ["bridge", "host", "none"]

    public static func items(
        host: Host,
        containers: [ContainerSummary] = [],
        images: [ImageSummary] = [],
        volumes: [Volume] = [],
        networks: [NetworkResource] = [],
        machines: [ContainerMachine] = [],
        clusters: [ContainerCluster] = []
    ) -> [PaletteItem] {
        guard host.isConnected else { return [] }
        var items: [PaletteItem] = []
        items += containers.map { container(host, $0) }
        items += composeProjects(host, containers)
        items += images.map { image(host, $0) }
        items += volumes.map { volume(host, $0) }
        items += networks.map { network(host, $0) }
        if host.isAppleContainer {
            items += machines.map { machine(host, $0) }
            items += clusters.map { cluster(host, $0) }
        }
        return items
    }

    /// Target of the app-wide Kubernetes section item.
    public static let kubernetesTarget = "kubernetes"
    /// Prefix of the target of a kubectl context item; the rest is the name.
    public static let kubernetesContextPrefix = "kubernetes-context:"

    /// The Kubernetes section and one item per kubectl context. App-wide:
    /// contexts do not belong to a host.
    public static func kubernetes(contexts: [KubeContext]) -> [PaletteItem] {
        var items = [PaletteItem(
            kind: .section,
            title: String(localized: "Kubernetes", bundle: .module),
            target: kubernetesTarget,
            keywords: ["k8s", "kubectl", "pods"],
            systemImage: "helm"
        )]
        items += contexts.map { context in
            var keywords = [context.cluster, "k8s", "kubectl"]
            if let server = context.server { keywords.append(server) }
            return PaletteItem(
                kind: .section,
                title: context.name,
                target: kubernetesContextPrefix + context.name,
                status: context.isCurrent ? String(localized: "Current context", bundle: .module) : nil,
                keywords: keywords,
                systemImage: "helm"
            )
        }
        return items
    }

    /// The context name of a Kubernetes context item, or nil for any other target.
    public static func kubernetesContext(fromTarget target: String) -> String? {
        guard target.hasPrefix(kubernetesContextPrefix) else { return nil }
        let name = String(target.dropFirst(kubernetesContextPrefix.count))
        return name.isEmpty ? nil : name
    }

    // MARK: - Actions

    /// Container actions in menu order. Logs and the shell need the
    /// container to exist; the shell needs it running.
    public static func containerActions(_ state: ContainerState) -> [PaletteAction] {
        switch state {
        case .running, .restarting:
            [.open, .logs, .shell, .stop, .restart, .remove]
        case .paused:
            [.open, .logs, .stop, .remove]
        case .removing:
            [.open]
        case .created, .exited, .dead, .unknown:
            [.open, .start, .logs, .remove]
        }
    }

    public static func composeActions(running: Int, total: Int) -> [PaletteAction] {
        var actions: [PaletteAction] = [.open]
        if running < total { actions.append(.start) }
        if running > 0 { actions += [.stop, .restart] }
        return actions
    }

    public static func machineActions(isRunning: Bool) -> [PaletteAction] {
        isRunning ? [.open, .stop, .remove] : [.open, .start, .remove]
    }

    // MARK: - Builders

    static func container(_ host: Host, _ container: ContainerSummary) -> PaletteItem {
        var keywords = [container.image, container.shortID]
        if let service = container.composeService { keywords.append(service) }
        if let project = container.composeProject { keywords.append(project) }
        return PaletteItem(
            kind: .container,
            title: container.displayName,
            hostID: host.id,
            hostName: host.name,
            target: container.id,
            status: stateTitle(container.state),
            isActive: container.state.isRunning,
            keywords: keywords,
            actions: containerActions(container.state)
        )
    }

    static func composeProjects(_ host: Host, _ containers: [ContainerSummary]) -> [PaletteItem] {
        let groups = Dictionary(grouping: containers.filter { $0.composeProject != nil }) { $0.composeProject ?? "" }
        return groups.keys.sorted().map { project in
            let members = groups[project] ?? []
            let running = members.filter { $0.state.isRunning }.count
            return PaletteItem(
                kind: .composeProject,
                title: project,
                hostID: host.id,
                hostName: host.name,
                target: project,
                status: String(localized: "\(running) of \(members.count) running", bundle: .module),
                isActive: running > 0,
                keywords: members.compactMap(\.composeService),
                actions: composeActions(running: running, total: members.count)
            )
        }
    }

    static func image(_ host: Host, _ image: ImageSummary) -> PaletteItem {
        PaletteItem(
            kind: .image,
            title: image.displayName,
            hostID: host.id,
            hostName: host.name,
            target: image.id,
            keywords: image.repoTags + [String(image.id.replacingOccurrences(of: "sha256:", with: "").prefix(12))],
            actions: [.open, .remove]
        )
    }

    static func volume(_ host: Host, _ volume: Volume) -> PaletteItem {
        PaletteItem(
            kind: .volume,
            title: volume.name,
            hostID: host.id,
            hostName: host.name,
            target: volume.name,
            keywords: [volume.driver],
            actions: [.open, .remove]
        )
    }

    static func network(_ host: Host, _ network: NetworkResource) -> PaletteItem {
        PaletteItem(
            kind: .network,
            title: network.name,
            hostID: host.id,
            hostName: host.name,
            target: network.id,
            keywords: [network.driver, network.shortID],
            actions: builtInNetworks.contains(network.name) ? [.open] : [.open, .remove]
        )
    }

    static func machine(_ host: Host, _ machine: ContainerMachine) -> PaletteItem {
        PaletteItem(
            kind: .machine,
            title: machine.id,
            hostID: host.id,
            hostName: host.name,
            target: machine.id,
            status: machine.isRunning
                ? String(localized: "Running", bundle: .module)
                : String(localized: "Stopped", bundle: .module),
            isActive: machine.isRunning,
            keywords: [machine.imageReference ?? ""].filter { !$0.isEmpty },
            actions: machineActions(isRunning: machine.isRunning)
        )
    }

    static func cluster(_ host: Host, _ cluster: ContainerCluster) -> PaletteItem {
        let running = cluster.nodes.filter(\.isRunning).count
        return PaletteItem(
            kind: .cluster,
            title: cluster.name,
            hostID: host.id,
            hostName: host.name,
            target: cluster.name,
            status: String(localized: "\(running) of \(cluster.nodes.count) nodes running", bundle: .module),
            isActive: running > 0,
            keywords: cluster.nodes.map(\.name),
            actions: [.open, .remove]
        )
    }

    /// A short, localized container state.
    public static func stateTitle(_ state: ContainerState) -> String {
        switch state {
        case .running: String(localized: "Running", bundle: .module)
        case .paused: String(localized: "Paused", bundle: .module)
        case .restarting: String(localized: "Restarting", bundle: .module)
        case .removing: String(localized: "Removing", bundle: .module)
        case .created: String(localized: "Created", bundle: .module)
        case .exited, .dead, .unknown: String(localized: "Stopped", bundle: .module)
        }
    }
}
