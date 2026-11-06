import Foundation
import UserNotifications
import AppKit
import AppCore
import DockerKit

/// The buttons on Gantry's notifications and what they do.
@MainActor
enum NotificationActions {
    /// Whether new notifications get buttons (Settings > General).
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: GantryNotification.actionsPreferenceKey) as? Bool ?? true
    }

    static func categories() -> Set<UNNotificationCategory> {
        let restart = UNNotificationAction(
            identifier: GantryNotification.Action.restart,
            title: String(localized: "Restart"),
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "arrow.clockwise")
        )
        let logs = UNNotificationAction(
            identifier: GantryNotification.Action.viewLogs,
            title: String(localized: "View Logs"),
            options: [.foreground],
            icon: UNNotificationActionIcon(systemImageName: "doc.plaintext")
        )
        let prompt = UNNotificationAction(
            identifier: GantryNotification.Action.copyPrompt,
            title: String(localized: "Copy as Prompt"),
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "text.badge.star")
        )
        let show = UNNotificationAction(
            identifier: GantryNotification.Action.showActivity,
            title: String(localized: "Show"),
            options: [.foreground],
            icon: UNNotificationActionIcon(systemImageName: "list.bullet")
        )
        return [
            UNNotificationCategory(
                identifier: GantryNotification.Category.containerAlert,
                actions: [restart, logs, prompt],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: GantryNotification.Category.operationFinished,
                actions: [show],
                intentIdentifiers: []
            )
        ]
    }

    static func handle(_ route: NotificationRoute) {
        switch route {
        case .openContainer(let hostID, let containerID):
            let jump = ContainerJump(hostID: hostID, containerID: containerID)
            PendingContainerJump.set(jump)
            NotificationCenter.default.post(name: .gantrySelectContainer, object: jump)
            MainWindowActivation.activate()
        case .viewLogs(let hostID, let containerID):
            PendingContainerJump.set(ContainerJump(hostID: hostID, containerID: containerID))
            ContainerTabRequest.open(.logs, hostID: hostID, containerID: containerID)
            MainWindowActivation.activate()
        case .restart(let hostID, let containerID):
            Task { await restart(hostID: hostID, containerID: containerID) }
        case .copyPrompt(let hostID, let containerID):
            Task { await copyPrompt(hostID: hostID, containerID: containerID) }
        case .showActivity:
            MainWindowActivation.activate()
            // The window may still be opening; ask again once it is there.
            NotificationCenter.default.post(name: .gantryShowActivity, object: nil)
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                NotificationCenter.default.post(name: .gantryShowActivity, object: nil)
            }
        case .ignore:
            break
        }
    }

    private static func restart(hostID: UUID, containerID: String) async {
        do {
            try await LiveFleet.perform(.restart, hostID: hostID, containerID: containerID)
        } catch {
            ContainerNotifier.shared.presentFailure(
                title: String(localized: "Could not restart the container"),
                body: error.localizedDescription
            )
        }
    }

    private static func copyPrompt(hostID: UUID, containerID: String) async {
        if let session = LiveFleet.connectedSession(hostID),
           let container = session.containers.first(where: { $0.id == containerID }) {
            ContainerPromptCopy.run(session: session, container: container)
            return
        }
        do {
            let host = try LiveFleet.host(hostID)
            let prompt = try await LiveFleet.withClient(host) { client -> String in
                let list = try await client.listContainers(all: true)
                guard let container = list.first(where: { $0.id == containerID }) else {
                    throw HeadlessDockerError.containerNotFound(containerID)
                }
                let details = try? await client.inspectContainer(id: containerID)
                return ContainerPrompt.build(host: host, container: container, details: details)
            }
            copyToPasteboard(prompt)
        } catch {
            ContainerNotifier.shared.presentFailure(
                title: String(localized: "Could not copy the prompt"),
                body: error.localizedDescription
            )
        }
    }
}
