import Foundation
import DockerKit

/// The fleet activity table: one row for each running container of each
/// connected host. Pure: the app passes `HostSession.activityInput`, the MCP
/// server its own samples, tests fixtures.
public enum FleetActivity {
    /// The connection state of a host, as the table shows it.
    public enum HostState: Sendable, Hashable {
        case connected
        case connecting
        case disconnected
        case failed(String)

        public init(_ status: ConnectionStatus) {
            switch status {
            case .connected: self = .connected
            case .connecting: self = .connecting
            case .disconnected: self = .disconnected
            case .failed(let message): self = .failed(message)
            }
        }

        /// A connecting host waits; the others can try again.
        public var canRetry: Bool {
            switch self {
            case .failed, .disconnected: true
            case .connected, .connecting: false
            }
        }
    }

    public struct HostInput: Sendable {
        public var id: UUID
        public var name: String
        public var isAppleContainer: Bool
        public var state: HostState
        public var containers: [ContainerSummary]
        /// The latest load point of each sampled container, by container id.
        public var load: [String: ContainerLoadPoint]

        public init(
            id: UUID, name: String, isAppleContainer: Bool, state: HostState,
            containers: [ContainerSummary], load: [String: ContainerLoadPoint]
        ) {
            self.id = id
            self.name = name
            self.isAppleContainer = isAppleContainer
            self.state = state
            self.containers = containers
            self.load = load
        }
    }

    public struct Row: Identifiable, Sendable, Hashable {
        /// `"<hostID>/<containerID>"`: two hosts can have the same container id.
        public let id: String
        public let hostID: UUID
        public let hostName: String
        public let isAppleContainer: Bool
        public let containerID: String
        public let name: String
        public let image: String
        /// nil until the host's sampler has a point for the container.
        public let load: ContainerLoadPoint?
        public let uptime: TimeInterval?

        public init(
            hostID: UUID, hostName: String, isAppleContainer: Bool,
            containerID: String, name: String, image: String,
            load: ContainerLoadPoint?, uptime: TimeInterval?
        ) {
            self.id = Self.makeID(hostID: hostID, containerID: containerID)
            self.hostID = hostID
            self.hostName = hostName
            self.isAppleContainer = isAppleContainer
            self.containerID = containerID
            self.name = name
            self.image = image
            self.load = load
            self.uptime = uptime
        }

        public static func makeID(hostID: UUID, containerID: String) -> String {
            "\(hostID.uuidString)/\(containerID)"
        }

        public var cpuPercent: Double? { load?.cpuPercent }
        public var memoryBytes: Int64? { load?.memoryBytes }
        public var networkRate: Double? { load?.networkRate }
        public var diskRate: Double? { load?.diskRate }
    }

    public struct UnavailableHost: Identifiable, Sendable, Hashable {
        public let id: UUID
        public let name: String
        public let state: HostState
    }

    public struct Snapshot: Sendable, Hashable {
        public var rows: [Row]
        /// Hosts that are not connected, in host list order.
        public var unavailableHosts: [UnavailableHost]
        public var connectedHostCount: Int

        public init(rows: [Row] = [], unavailableHosts: [UnavailableHost] = [], connectedHostCount: Int = 0) {
            self.rows = rows
            self.unavailableHosts = unavailableHosts
            self.connectedHostCount = connectedHostCount
        }
    }

    /// The builder and debug sidecars are left out, as in the lists.
    public static func snapshot(hosts: [HostInput]) -> Snapshot {
        var snapshot = Snapshot()
        for host in hosts {
            guard host.state == .connected else {
                snapshot.unavailableHosts.append(UnavailableHost(id: host.id, name: host.name, state: host.state))
                continue
            }
            snapshot.connectedHostCount += 1
            for container in host.containers
            where container.state.isRunning && ContainerCounts.isUserVisible(container) {
                snapshot.rows.append(Row(
                    hostID: host.id,
                    hostName: host.name,
                    isAppleContainer: host.isAppleContainer,
                    containerID: container.id,
                    name: container.displayName,
                    image: container.image,
                    load: host.load[container.id],
                    uptime: ContainerUptime.seconds(fromStatus: container.status)
                ))
            }
        }
        return snapshot
    }

    // MARK: - Sort

    /// The raw value is the MCP `sort` argument.
    public enum Column: String, Sendable, Hashable, CaseIterable {
        case host, name, image, cpu, memory, network, disk, uptime

        public var defaultOrder: SortOrder {
            switch self {
            case .host, .name, .image: .forward
            case .cpu, .memory, .network, .disk, .uptime: .reverse
            }
        }
    }

    /// Rows without a value come last in both orders. Ties always sort by
    /// host, name and id A to Z, so rows do not jump between refreshes.
    public struct Comparator: SortComparator, Sendable, Hashable {
        public var column: Column
        public var order: SortOrder

        public init(_ column: Column, order: SortOrder? = nil) {
            self.column = column
            self.order = order ?? column.defaultOrder
        }

        public func compare(_ lhs: Row, _ rhs: Row) -> ComparisonResult {
            let primary = primaryCompare(lhs, rhs)
            if primary != .orderedSame { return primary }
            return FleetActivity.tieBreak(lhs, rhs)
        }

        private func primaryCompare(_ lhs: Row, _ rhs: Row) -> ComparisonResult {
            switch column {
            case .host: ordered(lhs.hostName.localizedStandardCompare(rhs.hostName))
            case .name: ordered(lhs.name.localizedStandardCompare(rhs.name))
            case .image: ordered(lhs.image.localizedStandardCompare(rhs.image))
            case .cpu: metric(lhs.cpuPercent, rhs.cpuPercent)
            case .memory: metric(lhs.memoryBytes.map(Double.init), rhs.memoryBytes.map(Double.init))
            case .network: metric(lhs.networkRate, rhs.networkRate)
            case .disk: metric(lhs.diskRate, rhs.diskRate)
            case .uptime: metric(lhs.uptime, rhs.uptime)
            }
        }

        private func ordered(_ result: ComparisonResult) -> ComparisonResult {
            guard order == .reverse else { return result }
            switch result {
            case .orderedAscending: return .orderedDescending
            case .orderedDescending: return .orderedAscending
            case .orderedSame: return .orderedSame
            }
        }

        private func metric(_ lhs: Double?, _ rhs: Double?) -> ComparisonResult {
            switch (lhs, rhs) {
            case (nil, nil): return .orderedSame
            case (nil, _): return .orderedDescending
            case (_, nil): return .orderedAscending
            case let (l?, r?):
                if l == r { return .orderedSame }
                return ordered(l < r ? .orderedAscending : .orderedDescending)
            }
        }
    }

    static func tieBreak(_ lhs: Row, _ rhs: Row) -> ComparisonResult {
        let host = lhs.hostName.localizedStandardCompare(rhs.hostName)
        if host != .orderedSame { return host }
        let name = lhs.name.localizedStandardCompare(rhs.name)
        if name != .orderedSame { return name }
        if lhs.id == rhs.id { return .orderedSame }
        return lhs.id < rhs.id ? .orderedAscending : .orderedDescending
    }

    /// Without comparators: CPU, highest first.
    public static func sorted(_ rows: [Row], using comparators: [Comparator]) -> [Row] {
        rows.sorted(using: comparators.isEmpty ? [Comparator(.cpu)] : comparators)
    }

    // MARK: - Filter

    public struct Filter: Sendable, Hashable {
        public var text: String
        /// nil shows all hosts.
        public var hostID: UUID?

        public init(text: String = "", hostID: UUID? = nil) {
            self.text = text
            self.hostID = hostID
        }

        public var isActive: Bool { hostID != nil || !trimmedText.isEmpty }

        private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

        /// Text matches the name, the image or the host name.
        public func matches(_ row: Row) -> Bool {
            if let hostID, row.hostID != hostID { return false }
            let needle = trimmedText
            guard !needle.isEmpty else { return true }
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            return row.name.range(of: needle, options: options) != nil
                || row.image.range(of: needle, options: options) != nil
                || row.hostName.range(of: needle, options: options) != nil
        }

        public func apply(_ rows: [Row]) -> [Row] {
            isActive ? rows.filter(matches) : rows
        }

        /// Drops a host that was removed, so the table does not stay empty.
        public func pruned(hostIDs: Set<UUID>) -> Filter {
            guard let hostID, !hostIDs.contains(hostID) else { return self }
            var copy = self
            copy.hostID = nil
            return copy
        }
    }
}

extension HostSession {
    /// Reads the 5-second load sampler; it opens no stats stream.
    public var activityInput: FleetActivity.HostInput {
        let containers = visibleContainers
        var load: [String: ContainerLoadPoint] = [:]
        for container in containers where container.state.isRunning {
            if let point = containerLoadHistory.latest(container.id) { load[container.id] = point }
        }
        return FleetActivity.HostInput(
            id: host.id,
            name: host.name,
            isAppleContainer: host.isAppleContainer,
            state: FleetActivity.HostState(status),
            containers: containers,
            load: load
        )
    }
}
