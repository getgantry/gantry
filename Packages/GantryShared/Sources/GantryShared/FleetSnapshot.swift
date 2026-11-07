import Foundation

/// A small summary of the fleet that the app writes for the widget extension.
/// The extension is sandboxed and cannot reach Docker, so this file is all
/// that it knows.
public struct FleetSnapshot: Codable, Equatable, Sendable {
    /// Increment when a change makes old files unreadable.
    public static let currentVersion = 1

    public var version: Int
    public var generatedAt: Date
    public var hosts: [Host]
    /// The most important problem in the fleet, or nil when all is well.
    public var topProblem: Problem?
    /// The apple/container services, or nil when no apple host is configured.
    public var appleServices: AppleServices?
    /// Containers that a control can start or stop (capped, see `containerLimit`).
    public var containers: [ContainerRef]
    /// Proves that a control request comes from the extension (see ``ControlRequest``).
    public var controlToken: String

    public static let containerLimit = 200

    public init(
        version: Int = FleetSnapshot.currentVersion,
        generatedAt: Date,
        hosts: [Host],
        topProblem: Problem?,
        appleServices: AppleServices?,
        containers: [ContainerRef],
        controlToken: String
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.hosts = hosts
        self.topProblem = topProblem
        self.appleServices = appleServices
        self.containers = Array(containers.prefix(Self.containerLimit))
        self.controlToken = controlToken
    }

    /// An empty snapshot, for previews and the widget placeholder.
    public static let placeholder = FleetSnapshot(
        generatedAt: Date(timeIntervalSince1970: 0),
        hosts: [Host(id: UUID(), name: "Local", state: .connected, running: 4, stopped: 2, unhealthy: 0, attention: 0)],
        topProblem: nil,
        appleServices: nil,
        containers: [],
        controlToken: ""
    )

    // MARK: Totals

    public var hostsUp: Int { hosts.filter { $0.state == .connected }.count }
    public var running: Int { hosts.reduce(0) { $0 + $1.running } }
    public var unhealthy: Int { hosts.reduce(0) { $0 + $1.unhealthy } }
    /// Unhealthy, restarting or dead containers plus failed hosts.
    public var problemCount: Int {
        hosts.reduce(0) { $0 + $1.attention + ($1.state == .failed ? 1 : 0) }
    }

    /// True when only `generatedAt` differs. The app skips a write then.
    public func hasSameContent(as other: FleetSnapshot) -> Bool {
        var copy = other
        copy.generatedAt = generatedAt
        return copy == self
    }

    /// The control entry for a container, found by host and name.
    public func container(hostID: UUID, name: String) -> ContainerRef? {
        containers.first { $0.hostID == hostID && $0.name == name }
    }
}

extension FleetSnapshot {
    public enum HostState: String, Codable, Sendable {
        case connected
        case connecting
        case disconnected
        case failed
    }

    public struct Host: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var state: HostState
        public var running: Int
        public var stopped: Int
        public var unhealthy: Int
        /// Unhealthy, restarting and dead containers.
        public var attention: Int

        public init(id: UUID, name: String, state: HostState, running: Int, stopped: Int, unhealthy: Int, attention: Int) {
            self.id = id
            self.name = name
            self.state = state
            self.running = running
            self.stopped = stopped
            self.unhealthy = unhealthy
            self.attention = attention
        }
    }

    public enum ProblemKind: String, Codable, Sendable {
        case hostFailed
        case unhealthy
        case dead
        case restarting

        /// Lower is more important.
        public var rank: Int {
            switch self {
            case .hostFailed: 0
            case .unhealthy: 1
            case .dead: 2
            case .restarting: 3
            }
        }
    }

    public struct Problem: Codable, Equatable, Sendable {
        public var kind: ProblemKind
        public var hostID: UUID
        public var hostName: String
        /// The container name, or nil for a host problem.
        public var containerName: String?

        public init(kind: ProblemKind, hostID: UUID, hostName: String, containerName: String?) {
            self.kind = kind
            self.hostID = hostID
            self.hostName = hostName
            self.containerName = containerName
        }
    }

    public struct AppleServices: Codable, Equatable, Sendable {
        public var running: Bool
        public init(running: Bool) { self.running = running }
    }

    public struct ContainerRef: Codable, Equatable, Sendable, Hashable {
        public var hostID: UUID
        public var hostName: String
        public var name: String
        public var isRunning: Bool

        public init(hostID: UUID, hostName: String, name: String, isRunning: Bool) {
            self.hostID = hostID
            self.hostName = hostName
            self.name = name
            self.isRunning = isRunning
        }

        /// Stable across a re-create of the container: "hostID|name".
        public var id: String { "\(hostID.uuidString)|\(name)" }

        /// Splits an `id` back into its host and name.
        public static func split(_ id: String) -> (hostID: UUID, name: String)? {
            guard let bar = id.firstIndex(of: "|"),
                  let hostID = UUID(uuidString: String(id[..<bar])) else { return nil }
            let name = String(id[id.index(after: bar)...])
            return name.isEmpty ? nil : (hostID, name)
        }
    }
}
