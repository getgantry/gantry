import Foundation
import AppCore

/// The localized texts of a ``DestructiveAction`` dialog.
enum DestructiveActionText {
    static func title(_ action: DestructiveAction) -> String {
        let name = action.names.first ?? ""
        if let title = bulkTitle(action) { return title }
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
        case .deleteKubeResource: return String(localized: "Delete “\(name)”?")
        case .moveDataRoot: return String(localized: "Move the container data to “\(name)”?")
        case .deleteOldDataRoot: return String(localized: "Delete the old copy of the container data?")
        case .switchVolume: return String(localized: "Use the new location of “\(name)”?")
        case .forgetFolderVolume: return String(localized: "Remove folder volume “\(name)” from Gantry?")
        }
    }

    static func message(_ action: DestructiveAction) -> String {
        let base = isBulk(action) ? bulkBaseMessage(action.kind) : baseMessage(action.kind)
        let text = [base, impact(action.impact)]
            .compactMap { $0 }
            .joined(separator: " ")
        switch action.kind {
        case .switchVolume: return text + "\n\n" + action.names.dropFirst().joined(separator: "\n")
        case .deleteOldDataRoot, .moveDataRoot: return text + "\n\n" + (action.targets.first ?? "")
        default: break
        }
        guard isBulk(action) else { return text }
        return text + "\n\n" + nameList(action)
    }

    /// A remove of several items: the confirmation lists them.
    private static func isBulk(_ action: DestructiveAction) -> Bool {
        action.names.count > 1 && [.removeContainer, .removeImage, .removeVolume, .removeNetwork].contains(action.kind)
    }

    private static func bulkTitle(_ action: DestructiveAction) -> String? {
        guard isBulk(action) else { return nil }
        let count = action.names.count
        return switch action.kind {
        case .removeImage: String(localized: "Remove \(count) images?")
        case .removeVolume: String(localized: "Remove \(count) volumes?")
        case .removeNetwork: String(localized: "Remove \(count) networks?")
        default: String(localized: "Remove \(count) containers?")
        }
    }

    private static func bulkBaseMessage(_ kind: DestructiveAction.Kind) -> String? {
        switch kind {
        case .removeImage: String(localized: "The images are deleted from this host.")
        case .removeVolume: String(localized: "The volumes and all their data are deleted.")
        case .removeNetwork: String(localized: "The networks are deleted from this host.")
        default: baseMessage(kind)
        }
    }

    /// One name per line, and "and N more" after the limit.
    private static func nameList(_ action: DestructiveAction) -> String {
        let (shown, more) = action.listedNames()
        var lines = shown
        if more > 0 { lines.append(String(localized: "and \(more) more")) }
        return lines.joined(separator: "\n")
    }

    static func confirmLabel(_ action: DestructiveAction) -> String {
        switch action.kind {
        case .removeContainer, .removeImage, .removeVolume, .removeNetwork: String(localized: "Remove")
        case .deleteMachine, .deleteCluster, .deleteDomain, .deleteKubeResource: String(localized: "Delete")
        case .forgetCredential: String(localized: "Forget")
        case .removeHost: String(localized: "Remove Host")
        case .stopGroup: String(localized: "Stop All")
        case .restartGroup: String(localized: "Restart All")
        case .stopServices: String(localized: "Stop Services")
        case .restartServices: String(localized: "Restart Services")
        case .cancelClusterCreation: String(localized: "Stop and Delete Nodes")
        case .moveDataRoot: String(localized: "Stop Services and Move")
        case .deleteOldDataRoot: String(localized: "Delete Old Copy")
        case .switchVolume: String(localized: "Recreate Containers")
        case .forgetFolderVolume: String(localized: "Remove from Gantry")
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
        case .deleteKubeResource:
            String(localized: "Kubernetes deletes the object from the cluster. A controller can create a replacement.")
        case .moveDataRoot:
            String(localized: "The services stop while Gantry copies the data. The original stays until you delete it.")
        case .deleteOldDataRoot:
            String(localized: "The old folder and all its files are deleted. The services use the new copy.")
        case .switchVolume:
            String(localized: "Gantry removes these containers and makes them again with the new location. Data that is not in a volume is lost.")
        case .forgetFolderVolume:
            String(localized: "The folder and its files stay on the disk.")
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
        case .containersUseImages(let count):
            String(localized: "\(count) containers use these images. Use Force Remove to remove them anyway.")
        case .containersUseVolumes(let count):
            String(localized: "\(count) containers use these volumes.")
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
