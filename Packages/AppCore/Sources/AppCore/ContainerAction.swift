import Foundation

/// A lifecycle operation that can be performed on a container.
public enum ContainerAction: Sendable, Hashable {
    case start
    case stop
    case restart
    case kill
    case pause
    case unpause
    case remove(force: Bool)

    public var displayName: String {
        switch self {
        case .start: String(localized: "Start", bundle: .module)
        case .stop: String(localized: "Stop", bundle: .module)
        case .restart: String(localized: "Restart", bundle: .module)
        case .kill: String(localized: "Kill", bundle: .module)
        case .pause: String(localized: "Pause", bundle: .module)
        case .unpause: String(localized: "Resume", bundle: .module)
        case .remove: String(localized: "Remove", bundle: .module)
        }
    }

    /// SF Symbol name representing the action.
    public var systemImage: String {
        switch self {
        case .start: "play.fill"
        case .stop: "stop.fill"
        case .restart: "arrow.clockwise"
        case .kill: "bolt.fill"
        case .pause: "pause.fill"
        case .unpause: "play"
        case .remove: "trash"
        }
    }
}
