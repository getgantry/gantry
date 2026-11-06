import Foundation

/// Identifiers of Gantry's notification categories and actions.
public enum GantryNotification {
    public enum Category {
        public static let containerAlert = "gantry.category.container-alert"
        public static let operationFinished = "gantry.category.operation-finished"
    }

    public enum Action {
        public static let restart = "gantry.action.restart"
        public static let viewLogs = "gantry.action.view-logs"
        public static let copyPrompt = "gantry.action.copy-prompt"
        public static let showActivity = "gantry.action.show-activity"
        /// The system identifiers for a click on the banner and for a dismiss.
        public static let systemDefault = "com.apple.UNNotificationDefaultActionIdentifier"
        public static let systemDismiss = "com.apple.UNNotificationDismissActionIdentifier"
    }

    public enum InfoKey {
        public static let hostID = "hostID"
        public static let containerID = "containerID"
        public static let kind = "kind"
    }

    /// Defaults key of the "show actions on notifications" setting (default on).
    public static let actionsPreferenceKey = "notificationActionsEnabled"

    /// The user info of a container alert notification.
    public static func containerInfo(hostID: UUID, containerID: String) -> [String: String] {
        [InfoKey.hostID: hostID.uuidString, InfoKey.containerID: containerID]
    }

    /// The user info of an operation notification.
    public static let operationInfo: [String: String] = [InfoKey.kind: "operation"]

    /// The category for a new notification, or nil to show no actions.
    public static func category(isOperation: Bool, actionsEnabled: Bool) -> String? {
        guard actionsEnabled else { return nil }
        return isOperation ? Category.operationFinished : Category.containerAlert
    }
}

/// What the app does for a notification response.
public enum NotificationRoute: Equatable, Sendable {
    case openContainer(hostID: UUID, containerID: String)
    case restart(hostID: UUID, containerID: String)
    case viewLogs(hostID: UUID, containerID: String)
    case copyPrompt(hostID: UUID, containerID: String)
    case showActivity
    case ignore

    /// Maps an action identifier and the notification's user info to a route.
    /// A response without a container (an operation notification) shows the
    /// activity list; a dismiss does nothing.
    public static func resolve(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> NotificationRoute {
        if actionIdentifier == GantryNotification.Action.systemDismiss { return .ignore }
        let hostText = userInfo[GantryNotification.InfoKey.hostID] as? String
        let containerID = userInfo[GantryNotification.InfoKey.containerID] as? String
        guard let hostText, let hostID = UUID(uuidString: hostText),
              let containerID, !containerID.isEmpty else {
            return .showActivity
        }
        switch actionIdentifier {
        case GantryNotification.Action.restart:
            return .restart(hostID: hostID, containerID: containerID)
        case GantryNotification.Action.viewLogs:
            return .viewLogs(hostID: hostID, containerID: containerID)
        case GantryNotification.Action.copyPrompt:
            return .copyPrompt(hostID: hostID, containerID: containerID)
        default:
            return .openContainer(hostID: hostID, containerID: containerID)
        }
    }

    /// True when the route shows a window. Restart and Copy as Prompt run in
    /// the background.
    public var bringsAppForward: Bool {
        switch self {
        case .openContainer, .viewLogs, .showActivity: true
        case .restart, .copyPrompt, .ignore: false
        }
    }
}
