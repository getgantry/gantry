import Foundation

/// A notable container event worth surfacing to the user as a system
/// notification: a crash, an out-of-memory kill, or a failed health check.
///
/// `HostSession` derives these from the daemon `/events` stream and hands them
/// to the app layer, which posts them through `UNUserNotificationCenter`.
public struct ContainerAlert: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// The container exited on its own with a non-zero status code.
        case exited(code: Int)
        /// The container was killed by the kernel out-of-memory reaper.
        case outOfMemory
        /// The container's health check transitioned to unhealthy.
        case unhealthy
    }

    public var hostID: UUID
    public var hostName: String
    public var containerID: String
    public var containerName: String
    public var kind: Kind

    public init(
        hostID: UUID,
        hostName: String,
        containerID: String,
        containerName: String,
        kind: Kind
    ) {
        self.hostID = hostID
        self.hostName = hostName
        self.containerID = containerID
        self.containerName = containerName
        self.kind = kind
    }

    /// Short notification title.
    public var title: String {
        switch kind {
        case .exited: "Container stopped"
        case .outOfMemory: "Container out of memory"
        case .unhealthy: "Container unhealthy"
        }
    }

    /// Notification body, naming the container and host.
    public var body: String {
        switch kind {
        case .exited(let code):
            "\(containerName) on \(hostName) exited with code \(code)."
        case .outOfMemory:
            "\(containerName) on \(hostName) was killed after running out of memory."
        case .unhealthy:
            "\(containerName) on \(hostName) failed its health check."
        }
    }
}
