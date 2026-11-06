import Foundation
import AppCore

/// The localized texts of a ``DestructiveAction`` dialog.
enum DestructiveActionText {
    static func title(_ action: DestructiveAction) -> String {
        let name = action.names.first ?? ""
        switch action.kind {
        case .removeContainer:
            return action.names.count == 1
                ? String(localized: "Remove “\(name)”?")
                : String(localized: "Remove \(action.names.count) containers?")
        case .removeImage: return String(localized: "Remove image “\(name)”?")
        case .removeVolume: return String(localized: "Remove volume “\(name)”?")
        case .removeNetwork: return String(localized: "Remove network “\(name)”?")
        case .deleteMachine: return String(localized: "Delete machine “\(name)”?")
        case .deleteCluster: return String(localized: "Delete cluster “\(name)”?")
        case .deleteDomain: return String(localized: "Delete local domain “\(name)”?")
        case .forgetCredential: return String(localized: "Forget the saved secret for “\(name)”?")
        case .removeHost: return String(localized: "Remove host “\(name)”?")
        case .stopGroup: return String(localized: "Stop all containers in “\(name)”?")
        case .restartGroup: return String(localized: "Restart all containers in “\(name)”?")
        case .stopServices: return String(localized: "Stop apple/container services?")
        case .restartServices: return String(localized: "Restart apple/container services?")
        case .cancelClusterCreation: return String(localized: "Stop creating cluster “\(name)”?")
        }
    }

    static func message(_ action: DestructiveAction) -> String {
        [baseMessage(action.kind), impact(action.impact)]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    static func confirmLabel(_ action: DestructiveAction) -> String {
        switch action.kind {
        case .removeContainer, .removeImage, .removeVolume, .removeNetwork: String(localized: "Remove")
        case .deleteMachine, .deleteCluster, .deleteDomain: String(localized: "Delete")
        case .forgetCredential: String(localized: "Forget")
        case .removeHost: String(localized: "Remove Host")
        case .stopGroup: String(localized: "Stop All")
        case .restartGroup: String(localized: "Restart All")
        case .stopServices: String(localized: "Stop Services")
        case .restartServices: String(localized: "Restart Services")
        case .cancelClusterCreation: String(localized: "Stop and Delete Nodes")
        }
    }

    static func forceLabel(_ action: DestructiveAction) -> String {
        String(localized: "Force Remove")
    }

    /// The Touch ID prompt text.
    static func reason(_ action: DestructiveAction) -> String {
        title(action)
    }

    private static func baseMessage(_ kind: DestructiveAction.Kind) -> String? {
        switch kind {
        case .removeContainer:
            String(localized: "Data that is not in a volume is lost. Force Remove also stops a running container.")
        case .removeImage: String(localized: "The image is deleted from this host.")
        case .removeVolume: String(localized: "The volume and all its data are deleted.")
        case .removeNetwork: String(localized: "The network is deleted from this host.")
        case .deleteMachine: String(localized: "The machine and its disk are deleted.")
        case .deleteCluster: String(localized: "All nodes of the cluster and its kubeconfig context are deleted.")
        case .deleteDomain: String(localized: "Containers can no longer use this local domain.")
        case .forgetCredential:
            String(localized: "The password or passphrase is deleted from the Keychain. Gantry asks for it on the next connection.")
        case .removeHost:
            String(localized: "Gantry disconnects and removes the host. Containers on the host do not change.")
        case .stopServices: String(localized: "Containers cannot run until the services start again.")
        case .restartServices: String(localized: "The services stop and start again.")
        case .stopGroup, .restartGroup, .cancelClusterCreation: nil
        }
    }

    private static func impact(_ impact: DestructiveAction.Impact) -> String? {
        switch impact {
        case .none:
            nil
        case .runningContainersStop(let count):
            count == 1
                ? String(localized: "1 running container will stop.")
                : String(localized: "\(count) running containers will stop.")
        case .containersUseImage(let count):
            count == 1
                ? String(localized: "1 container uses this image. Use Force Remove to remove it anyway.")
                : String(localized: "\(count) containers use this image. Use Force Remove to remove it anyway.")
        case .containersUseVolume(let count):
            count == 1
                ? String(localized: "1 container uses this volume.")
                : String(localized: "\(count) containers use this volume.")
        case .partialNodesDeleted:
            String(localized: "The nodes that this creation made so far are deleted.")
        case .machineStops:
            String(localized: "The machine is running and will stop.")
        }
    }
}

extension AppModel {
    /// Running containers on the apple/container host: the impact of a
    /// service stop or restart.
    var appleRunningContainerCount: Int {
        sessions.first { $0.host.isAppleContainer }?.containers.filter { $0.state.isRunning }.count ?? 0
    }
}
