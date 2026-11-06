import Foundation
import UserNotifications
import AppKit
import AppCore

/// Bridges `HostSession` container alerts to macOS system notifications.
///
/// Requests notification authorization once, posts a banner+sound for each
/// crash / OOM / unhealthy event, and — when the user clicks a notification —
/// activates Gantry and jumps to the offending container's detail view.
@MainActor
final class ContainerNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ContainerNotifier()

    /// Preference key for the General settings toggle. Defaults to on.
    static let preferenceKey = "notifyContainerEvents"

    private let center = UNUserNotificationCenter.current()
    private var started = false

    /// Installs the delegate and asks for authorization. Safe to call repeatedly.
    func start() {
        guard !started else { return }
        started = true
        center.delegate = self
        center.setNotificationCategories(NotificationActions.categories())
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts a notification for a container alert, unless the user disabled them.
    func present(_ alert: ContainerAlert) {
        let enabled = UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool ?? true
        guard enabled else { return }

        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        // Group repeated alerts about the same container in Notification Center.
        content.threadIdentifier = alert.containerID
        content.userInfo = GantryNotification.containerInfo(hostID: alert.hostID, containerID: alert.containerID)
        if let category = GantryNotification.category(isOperation: false, actionsEnabled: NotificationActions.enabled) {
            content.categoryIdentifier = category
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }

    /// Posts a notification when a long operation finishes while Gantry is
    /// not the frontmost app. A cancel by the user posts nothing.
    func presentOperation(_ operation: LongOperation) {
        guard !NSApp.isActive, operation.state != .cancelled else { return }
        let content = UNMutableNotificationContent()
        switch operation.state {
        case .failed(let message):
            content.title = String(localized: "Failed: \(operation.title)")
            content.body = ErrorPresentation.split(message).summary
        case .succeeded(let summary):
            content.title = String(localized: "Done: \(operation.title)")
            content.body = summary ?? operation.hostName ?? ""
        case .running, .cancelled:
            return
        }
        content.sound = .default
        content.threadIdentifier = "operations"
        content.userInfo = GantryNotification.operationInfo
        if let category = GantryNotification.category(isOperation: true, actionsEnabled: NotificationActions.enabled) {
            content.categoryIdentifier = category
        }
        center.add(UNNotificationRequest(identifier: operation.id.uuidString, content: content, trigger: nil))
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner even when Gantry is the frontmost app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// A click opens the container (or the activity list); an action button
    /// runs its action, in the background for Restart and Copy as Prompt.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let route = NotificationRoute.resolve(
            actionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo
        )
        Task { @MainActor in NotificationActions.handle(route) }
        completionHandler()
    }

    /// Posts a short notification when a notification action fails.
    func presentFailure(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func openContainer(hostID: UUID, containerID: String) {
        let jump = ContainerJump(hostID: hostID, containerID: containerID)
        PendingContainerJump.set(jump)
        NotificationCenter.default.post(name: .gantrySelectContainer, object: jump)
        MainWindowActivation.activate()
    }

#if DEBUG
    func simulateClickForUITest(hostID: UUID, containerID: String) {
        openContainer(hostID: hostID, containerID: containerID)
    }
#endif
}
