import Foundation
import DockerKit

/// A remove, delete or stop that the user must confirm. The app shows one
/// dialog for all of them: the impact text, an optional Force button and,
/// when it is on in Settings, Touch ID before the work runs.
public struct DestructiveAction: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case removeContainer
        case removeImage
        case removeVolume
        case removeNetwork
        case deleteMachine
        case deleteCluster
        case deleteDomain
        case forgetCredential
        case removeHost
        case stopGroup
        case restartGroup
        case stopServices
        case restartServices
        case cancelClusterCreation
    }

    /// What else happens when the action runs.
    public enum Impact: Equatable, Sendable {
        case none
        /// N running containers stop.
        case runningContainersStop(Int)
        /// N containers use the image (a plain remove fails while they exist).
        case containersUseImage(Int)
        /// N containers mount the volume.
        case containersUseVolume(Int)
        /// The nodes this creation made so far are deleted.
        case partialNodesDeleted
        /// The machine is running and stops.
        case machineStops
    }

    /// The container engine, for the features that differ.
    public enum Engine: Equatable, Sendable {
        case docker
        case appleContainer

        public init(_ host: DockerHost) {
            self = host.isAppleContainer ? .appleContainer : .docker
        }
    }

    public let id: UUID
    public let kind: Kind
    /// The ids the action works on (container ids, image ids, names).
    public let targets: [String]
    /// The names shown in the dialog.
    public let names: [String]
    public let impact: Impact
    /// Whether the dialog offers a Force variant.
    public let forceAvailable: Bool

    public init(kind: Kind, targets: [String], names: [String]? = nil, impact: Impact = .none, forceAvailable: Bool = false) {
        self.id = UUID()
        self.kind = kind
        self.targets = targets
        self.names = names ?? targets
        self.impact = impact
        self.forceAvailable = forceAvailable
    }

    /// Removes, deletes and forgets ask for Touch ID when it is on; stop
    /// and restart only ask for a confirmation.
    public var isGated: Bool {
        switch kind {
        case .stopGroup, .restartGroup, .stopServices, .restartServices, .cancelClusterCreation: false
        default: true
        }
    }

    /// Whether `engine` can force this kind of action.
    public static func supportsForce(_ kind: Kind, engine: Engine) -> Bool {
        switch kind {
        case .removeContainer, .removeImage: true
        case .removeVolume: engine == .docker
        default: false
        }
    }

    // MARK: - Builders

    public static func removeContainers(_ containers: [ContainerSummary], engine: Engine) -> DestructiveAction {
        let running = containers.filter { $0.state.isRunning }.count
        return DestructiveAction(
            kind: .removeContainer,
            targets: containers.map(\.id),
            names: containers.map(\.displayName),
            impact: running > 0 ? .runningContainersStop(running) : .none,
            forceAvailable: supportsForce(.removeContainer, engine: engine)
        )
    }

    public static func removeImage(
        id: String, name: String, containers: [ContainerSummary], engine: Engine
    ) -> DestructiveAction {
        let users = containers.filter { $0.imageID == id }.count
        return DestructiveAction(
            kind: .removeImage,
            targets: [id],
            names: [name],
            impact: users > 0 ? .containersUseImage(users) : .none,
            forceAvailable: supportsForce(.removeImage, engine: engine)
        )
    }

    public static func removeVolume(name: String, containers: [ContainerSummary], engine: Engine) -> DestructiveAction {
        let users = containers.filter { $0.mounts.contains { $0.name == name } }.count
        return DestructiveAction(
            kind: .removeVolume,
            targets: [name],
            impact: users > 0 ? .containersUseVolume(users) : .none,
            forceAvailable: supportsForce(.removeVolume, engine: engine)
        )
    }

    /// Stop All / Restart All on a compose group.
    public static func group(
        _ kind: Kind, project: String, containers: [ContainerSummary]
    ) -> DestructiveAction {
        precondition(kind == .stopGroup || kind == .restartGroup)
        let running = containers.filter { $0.state.isRunning }
        return DestructiveAction(
            kind: kind,
            targets: containers.map(\.id),
            names: [project],
            impact: running.isEmpty ? .none : .runningContainersStop(running.count)
        )
    }

    /// Stop or restart the apple/container services: every running
    /// container on the host stops.
    public static func services(_ kind: Kind, runningContainers: Int) -> DestructiveAction {
        precondition(kind == .stopServices || kind == .restartServices)
        return DestructiveAction(
            kind: kind,
            targets: [],
            names: [],
            impact: runningContainers > 0 ? .runningContainersStop(runningContainers) : .none
        )
    }

    public static func deleteMachine(_ machine: ContainerMachine) -> DestructiveAction {
        DestructiveAction(
            kind: .deleteMachine,
            targets: [machine.id],
            impact: machine.status.lowercased() == "running" ? .machineStops : .none
        )
    }
}
