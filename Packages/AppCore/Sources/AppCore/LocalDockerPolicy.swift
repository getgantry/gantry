import Foundation
import DockerKit

/// Decides whether the built-in "Local" Docker host shows. Gantry must work as
/// an apple/container-only app: on a Mac without Docker the Local host is
/// hidden by default, and it comes back by itself when Docker appears, unless
/// the user removed or added it on purpose.
public enum LocalDockerPolicy {
    /// What the user did with the Local host, persisted in UserDefaults.
    public enum Choice: String, Sendable {
        /// No explicit choice: Gantry may hide and restore the host.
        case automatic
        /// Gantry hid the host because Docker was missing.
        case autoHidden
        /// The user removed the host. Gantry does not add it back.
        case removed
        /// The user added the host. Gantry does not hide it.
        case added
    }

    public enum Action: Equatable, Sendable {
        case none
        /// Remove the default Local host from the host list.
        case hide(UUID)
        /// Add a default Local host back to the list.
        case restore
    }

    public static let choiceKey = "localDockerChoice"
    public static let defaultName = "Local"

    /// The pure decision. `socketFound` means a Docker socket exists at one of
    /// the usual places; `appleCLIFound` means the `container` CLI exists.
    public static func action(
        hosts: [DockerHost],
        choice: Choice,
        socketFound: Bool,
        appleCLIFound: Bool
    ) -> Action {
        // A Local host with a custom socket path is the user's own setup.
        let defaultLocal = hosts.first { $0.isLocal && $0.socketPathOverride == nil }
        switch choice {
        case .automatic:
            if let defaultLocal, !socketFound, appleCLIFound { return .hide(defaultLocal.id) }
            return .none
        case .autoHidden:
            if socketFound, !hosts.contains(where: \.isLocal) { return .restore }
            return .none
        case .removed, .added:
            return .none
        }
    }

    /// The choice after `action` was applied.
    public static func choice(after action: Action, from choice: Choice) -> Choice {
        switch action {
        case .none: choice
        case .hide: .autoHidden
        case .restore: .automatic
        }
    }

    /// The hosts to seed on a first launch. Without Docker but with the apple
    /// CLI, the app starts on apple/container alone; with neither, it keeps
    /// the Local host so the sidebar is not empty.
    public static func seedHosts(socketFound: Bool, appleCLIFound: Bool) -> (hosts: [DockerHost], choice: Choice) {
        var hosts: [DockerHost] = []
        if socketFound || !appleCLIFound {
            hosts.append(DockerHost(name: defaultName, kind: .local))
        }
        if appleCLIFound {
            hosts.append(DockerHost(name: "Apple Container", kind: .appleContainer))
        }
        let choice: Choice = (!socketFound && appleCLIFound) ? .autoHidden : .automatic
        return (hosts, choice)
    }

}

/// How ``AppModel`` looks for a Docker socket and the apple CLI. Tests pass
/// fixed answers so they do not depend on what the Mac has installed.
public struct LocalDockerDetection: Sendable {
    public var socketFound: @Sendable () -> Bool
    public var appleCLIFound: @Sendable () -> Bool

    public init(socketFound: @escaping @Sendable () -> Bool, appleCLIFound: @escaping @Sendable () -> Bool) {
        self.socketFound = socketFound
        self.appleCLIFound = appleCLIFound
    }

    /// Checks the real file system.
    public static let live = LocalDockerDetection(
        socketFound: { DockerSocketDiscovery.discover() != nil },
        appleCLIFound: { AppleContainerCLIDiscovery.discover() != nil }
    )

    public static func fixed(socketFound: Bool, appleCLIFound: Bool) -> LocalDockerDetection {
        LocalDockerDetection(socketFound: { socketFound }, appleCLIFound: { appleCLIFound })
    }
}
