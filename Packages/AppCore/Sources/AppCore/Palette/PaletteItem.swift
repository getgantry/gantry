import Foundation

/// What a command palette result stands for.
public enum PaletteKind: String, Sendable, CaseIterable, Hashable {
    case command
    case section
    case host
    case container
    case composeProject
    case image
    case volume
    case network
    case machine
    case cluster

    /// The kind as shown next to each result.
    public var title: String {
        switch self {
        case .command: String(localized: "Command", bundle: .module)
        case .section: String(localized: "Section", bundle: .module)
        case .host: String(localized: "Host", bundle: .module)
        case .container: String(localized: "Container", bundle: .module)
        case .composeProject: String(localized: "Compose Project", bundle: .module)
        case .image: String(localized: "Image", bundle: .module)
        case .volume: String(localized: "Volume", bundle: .module)
        case .network: String(localized: "Network", bundle: .module)
        case .machine: String(localized: "Machine", bundle: .module)
        case .cluster: String(localized: "Cluster", bundle: .module)
        }
    }

    public var systemImage: String {
        switch self {
        case .command: "command"
        case .section: "sidebar.left"
        case .host: "server.rack"
        case .container: "shippingbox"
        case .composeProject: "square.stack.3d.down.right"
        case .image: "square.stack.3d.up"
        case .volume: "externaldrive"
        case .network: "network"
        case .machine: "cube.transparent"
        case .cluster: "steeringwheel"
        }
    }

    /// Order of kinds when scores tie: things people jump to most come first.
    var rankOrder: Int {
        switch self {
        case .container: 0
        case .composeProject: 1
        case .command: 2
        case .host: 3
        case .section: 4
        case .image: 5
        case .volume: 6
        case .network: 7
        case .machine: 8
        case .cluster: 9
        }
    }
}

/// An action that the palette can run on a result.
public enum PaletteAction: String, Sendable, CaseIterable, Hashable {
    case open
    case start
    case stop
    case restart
    case logs
    case shell
    case remove

    /// The menu title for this action on a result of `kind`.
    public func title(for kind: PaletteKind) -> String {
        switch self {
        case .open:
            switch kind {
            case .command: String(localized: "Run", bundle: .module)
            default: String(localized: "Open", bundle: .module)
            }
        case .start: String(localized: "Start", bundle: .module)
        case .stop: String(localized: "Stop", bundle: .module)
        case .restart: String(localized: "Restart", bundle: .module)
        case .logs: String(localized: "Show Logs", bundle: .module)
        case .shell: String(localized: "Open Shell", bundle: .module)
        case .remove:
            switch kind {
            case .machine, .cluster: String(localized: "Delete…", bundle: .module)
            default: String(localized: "Remove…", bundle: .module)
            }
        }
    }

    public var systemImage: String {
        switch self {
        case .open: "arrow.right.circle"
        case .start: "play.fill"
        case .stop: "stop.fill"
        case .restart: "arrow.clockwise"
        case .logs: "text.alignleft"
        case .shell: "terminal"
        case .remove: "trash"
        }
    }

    /// Whether the app asks for confirmation before it runs the action.
    public var isDestructive: Bool { self == .remove }
}

/// One command palette result.
public struct PaletteItem: Identifiable, Hashable, Sendable {
    /// Stable across launches, so recent items survive a restart.
    public let id: String
    public let kind: PaletteKind
    public let title: String
    /// The host name, or nil for app-wide results.
    public let hostName: String?
    public let hostID: UUID?
    /// The resource id, section name or command name the item acts on.
    public let target: String
    /// A short status, for example "Running"; nil when there is none.
    public let status: String?
    /// Whether the item is up (running, connected). Shown as a symbol and in
    /// the status text, never by color only.
    public let isActive: Bool?
    /// Extra search terms: image name, ids, compose service.
    public let keywords: [String]
    /// Actions in menu order; the first is the default (Return).
    public let actions: [PaletteAction]
    public let systemImage: String

    public init(
        kind: PaletteKind,
        title: String,
        hostID: UUID? = nil,
        hostName: String? = nil,
        target: String,
        status: String? = nil,
        isActive: Bool? = nil,
        keywords: [String] = [],
        actions: [PaletteAction] = [.open],
        systemImage: String? = nil
    ) {
        self.id = PaletteItem.makeID(kind: kind, hostID: hostID, target: target)
        self.kind = kind
        self.title = title
        self.hostID = hostID
        self.hostName = hostName
        self.target = target
        self.status = status
        self.isActive = isActive
        self.keywords = keywords
        self.actions = actions.isEmpty ? [.open] : actions
        self.systemImage = systemImage ?? kind.systemImage
    }

    public static func makeID(kind: PaletteKind, hostID: UUID?, target: String) -> String {
        "\(kind.rawValue):\(hostID?.uuidString ?? "-"):\(target)"
    }

    public var defaultAction: PaletteAction { actions[0] }

    /// Actions other than the default, for the secondary list.
    public var secondaryActions: [PaletteAction] { Array(actions.dropFirst()) }
}
