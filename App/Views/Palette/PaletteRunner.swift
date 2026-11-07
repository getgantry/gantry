import SwiftUI
import AppCore
import DockerKit

/// App commands offered by the palette. The raw value is the item target.
enum PaletteCommand: String, CaseIterable {
    case addHost
    case refreshAll
    case settings
    case newContainer
    case pullImage
    case cleanup
    case reconnect
    case hostTerminal

    var title: String {
        switch self {
        case .addHost: String(localized: "Add Host…")
        case .refreshAll: String(localized: "Refresh All Hosts")
        case .settings: String(localized: "Settings…")
        case .newContainer: String(localized: "New Container…")
        case .pullImage: String(localized: "Pull Image…")
        case .cleanup: String(localized: "Reclaim Space…")
        case .reconnect: String(localized: "Reconnect")
        case .hostTerminal: String(localized: "Open Host Terminal")
        }
    }

    var systemImage: String {
        switch self {
        case .addHost: "plus"
        case .refreshAll: "arrow.clockwise"
        case .settings: "gearshape"
        case .newContainer: "plus.square"
        case .pullImage: "arrow.down.circle"
        case .cleanup: "sparkles"
        case .reconnect: "arrow.triangle.2.circlepath"
        case .hostTerminal: "terminal"
        }
    }

    /// Search terms other than the title.
    var keywords: [String] {
        switch self {
        case .cleanup: ["prune", "clean", String(localized: "Prune")]
        case .newContainer: ["run", "create"]
        case .refreshAll: ["reload"]
        case .settings: ["preferences"]
        default: []
        }
    }

    @MainActor
    func item(for session: HostSession? = nil) -> PaletteItem {
        PaletteItem(
            kind: .command,
            title: title,
            hostID: session?.host.id,
            hostName: session?.host.name,
            target: rawValue,
            keywords: keywords,
            systemImage: systemImage
        )
    }
}

/// Builds the palette results from every host the app knows.
@MainActor
enum PaletteSource {
    static func items(model: AppModel) -> [PaletteItem] {
        var items = [PaletteCommand.addHost, .refreshAll, .settings].map { $0.item() }
        items.append(PaletteItem(kind: .section, title: String(localized: "Dashboard"), target: "dashboard",
                                 systemImage: "square.grid.2x2"))
        for session in model.sessions {
            items += hostItems(session)
        }
        return items
    }

    private static func hostItems(_ session: HostSession) -> [PaletteItem] {
        let host = session.host
        let connected = session.status.isConnected
        var items = [PaletteItem(
            kind: .host, title: host.name, hostID: host.id, target: "host",
            status: session.accessibilityStatus, isActive: connected, systemImage: host.badgeSystemImage
        )]
        items += HostSection.sections(for: host, clusters: session.supportsClusters).map { section in
            PaletteItem(kind: .section, title: section.title, hostID: host.id, hostName: host.name,
                        target: section.rawValue, systemImage: section.systemImage)
        }
        var commands: [PaletteCommand] = [.reconnect]
        if connected { commands += [.newContainer, .pullImage, .cleanup] }
        if session.supportsHostAccess { commands.append(.hostTerminal) }
        items += commands.map { $0.item(for: session) }
        items += PaletteCatalog.items(
            host: .init(id: host.id, name: host.name, isAppleContainer: host.isAppleContainer, isConnected: connected),
            containers: session.containers,
            images: session.images,
            volumes: session.volumes,
            networks: session.networks,
            machines: session.machines,
            clusters: session.clusters
        )
        return items
    }
}

/// Runs a palette choice through the same routes as the main window: the
/// sidebar and detail selection, the section commands and the shared
/// destructive confirmation.
@MainActor
struct PaletteRunner {
    let model: AppModel
    let navigate: (UUID, HostSection, DetailSelection?) -> Void
    let showDashboard: () -> Void
    let showAddHost: () -> Void
    let openSettings: () -> Void
    let openHostTerminal: (UUID) -> Void
    let confirm: (DestructiveAction, UUID) -> Void

    func run(_ item: PaletteItem, _ action: PaletteAction) {
        if item.kind == .command {
            runCommand(item)
            return
        }
        if item.kind == .section, item.hostID == nil {
            showDashboard()
            return
        }
        guard let hostID = item.hostID, let session = model.session(id: hostID) else { return }
        switch item.kind {
        case .host:
            navigate(hostID, .overview, nil)
        case .section:
            navigate(hostID, HostSection(rawValue: item.target) ?? .overview, nil)
        case .container:
            runContainer(item.target, action, session)
        case .composeProject:
            runCompose(item.target, action, session)
        case .image:
            runImage(item.target, action, session)
        case .volume:
            runVolume(item.target, action, session)
        case .network:
            runNetwork(item.target, action, session)
        case .machine:
            runMachine(item.target, action, session)
        case .cluster:
            runCluster(item.target, action, session)
        case .command:
            break
        }
    }

    private func runCommand(_ item: PaletteItem) {
        guard let command = PaletteCommand(rawValue: item.target) else { return }
        let session = item.hostID.flatMap { model.session(id: $0) }
        switch command {
        case .addHost: showAddHost()
        case .refreshAll: NotificationCenter.default.post(name: .gantryRefreshAll, object: nil)
        case .settings: openSettings()
        case .newContainer: sendSectionCommand(.newItem, .containers, session)
        case .pullImage: sendSectionCommand(.pullImage, .images, session)
        case .cleanup: sendSectionCommand(.cleanup, .overview, session)
        case .reconnect:
            guard let session else { return }
            Task {
                await session.disconnect()
                await session.connect()
            }
        case .hostTerminal:
            if let session { openHostTerminal(session.host.id) }
        }
    }

    private func sendSectionCommand(_ command: SectionCommand, _ section: HostSection, _ session: HostSession?) {
        guard let session else { return }
        navigate(session.host.id, section, nil)
        PendingSectionCommand.send(command, section, hostID: session.host.id)
    }

    private func runContainer(_ id: String, _ action: PaletteAction, _ session: HostSession) {
        guard let container = session.containers.first(where: { $0.id == id }) else { return }
        let hostID = session.host.id
        switch action {
        case .open: navigate(hostID, .containers, .container(id))
        case .logs: ContainerTabRequest.open(.logs, hostID: hostID, containerID: id)
        case .shell: ContainerTabRequest.open(.terminal, hostID: hostID, containerID: id)
        case .start: Task { _ = await session.perform(.start, on: id) }
        case .stop: Task { _ = await session.perform(.stop, on: id) }
        case .restart: Task { _ = await session.perform(.restart, on: id) }
        case .remove: confirm(.removeContainers([container], engine: .init(session.host)), hostID)
        }
    }

    private func runCompose(_ project: String, _ action: PaletteAction, _ session: HostSession) {
        let members = session.containers.filter { $0.composeProject == project }
        guard let first = members.first else { return }
        let hostID = session.host.id
        switch action {
        case .start:
            for member in members where !member.state.isRunning {
                Task { _ = await session.perform(.start, on: member.id) }
            }
        case .stop: confirm(.group(.stopGroup, project: project, containers: members), hostID)
        case .restart: confirm(.group(.restartGroup, project: project, containers: members), hostID)
        default: navigate(hostID, .containers, .container(first.id))
        }
    }

    private func runImage(_ id: String, _ action: PaletteAction, _ session: HostSession) {
        guard let image = session.images.first(where: { $0.id == id }) else { return }
        if action == .remove {
            confirm(.removeImage(id: id, name: image.displayName, containers: session.containers,
                                 engine: .init(session.host)), session.host.id)
        } else {
            navigate(session.host.id, .images, .image(id))
        }
    }

    private func runVolume(_ name: String, _ action: PaletteAction, _ session: HostSession) {
        if action == .remove {
            confirm(.removeVolume(name: name, containers: session.containers, engine: .init(session.host)),
                    session.host.id)
        } else {
            navigate(session.host.id, .volumes, .volume(name))
        }
    }

    private func runNetwork(_ id: String, _ action: PaletteAction, _ session: HostSession) {
        guard let network = session.networks.first(where: { $0.id == id }) else { return }
        if action == .remove {
            confirm(DestructiveAction(kind: .removeNetwork, targets: [id], names: [network.name]), session.host.id)
        } else {
            navigate(session.host.id, .networks, .network(id))
        }
    }

    private func runMachine(_ id: String, _ action: PaletteAction, _ session: HostSession) {
        guard let machine = session.machines.first(where: { $0.id == id }) else { return }
        switch action {
        case .start: Task { _ = await session.startMachine(id) }
        case .stop: Task { _ = await session.stopMachine(id) }
        case .remove: confirm(.deleteMachine(machine), session.host.id)
        default: navigate(session.host.id, .machines, .machine(id))
        }
    }

    private func runCluster(_ name: String, _ action: PaletteAction, _ session: HostSession) {
        if action == .remove {
            confirm(DestructiveAction(kind: .deleteCluster, targets: [name]), session.host.id)
        } else {
            navigate(session.host.id, .clusters, .cluster(name))
        }
    }

    /// Runs a confirmed palette action.
    static func perform(_ action: DestructiveAction, force: Bool, on session: HostSession) async {
        for target in action.targets {
            switch action.kind {
            case .removeContainer: _ = await session.perform(.remove(force: force), on: target)
            case .removeImage: _ = await session.removeImage(id: target, force: force)
            case .removeVolume: _ = await session.removeVolume(name: target, force: force)
            case .removeNetwork: _ = await session.removeNetwork(id: target)
            case .deleteMachine: _ = await session.deleteMachine(target)
            case .deleteCluster: _ = await session.deleteCluster(target)
            case .stopGroup: _ = await session.perform(.stop, on: target)
            case .restartGroup: _ = await session.perform(.restart, on: target)
            default: break
            }
        }
    }
}
