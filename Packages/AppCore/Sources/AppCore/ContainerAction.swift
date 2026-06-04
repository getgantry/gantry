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
        case .start: "Start"
        case .stop: "Stop"
        case .restart: "Restart"
        case .kill: "Kill"
        case .pause: "Pause"
        case .unpause: "Resume"
        case .remove: "Remove"
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
