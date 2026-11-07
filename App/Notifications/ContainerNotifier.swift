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
        content.userInfo = [
            "hostID": alert.hostID.uuidString,
            "containerID": alert.containerID
        ]
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

    /// Clicking a notification brings Gantry forward and opens the container.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let hostString = info["hostID"] as? String
        let containerID = info["containerID"] as? String
        if let hostString, let hostID = UUID(uuidString: hostString), let containerID {
            Task { @MainActor in
                ContainerNotifier.shared.openContainer(hostID: hostID, containerID: containerID)
            }
        } else {
            // An operation notification: show the window with the activity list.
            Task { @MainActor in MainWindowActivation.activate() }
        }
        completionHandler()
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
