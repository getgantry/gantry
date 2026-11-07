import Foundation
import DockerKit

/// A Compose project on one host, built from its containers' labels.
public struct ComposeProjectRef: Equatable, Sendable, Identifiable {
    public var hostID: UUID
    public var hostName: String
    public var name: String
    public var containerIDs: [String]
    public var running: Int
    public var total: Int
    public var workingDirectory: String?

    /// "hostID|project", unique across hosts.
    public var id: String { Self.makeID(hostID: hostID, project: name) }

    public static func makeID(hostID: UUID, project: String) -> String {
        "\(hostID.uuidString)|\(project)"
    }

    public static func split(_ id: String) -> (hostID: UUID, project: String)? {
        guard let bar = id.firstIndex(of: "|"),
              let hostID = UUID(uuidString: String(id[..<bar])) else { return nil }
        let project = String(id[id.index(after: bar)...])
        return project.isEmpty ? nil : (hostID, project)
    }

    /// The projects among `containers`, sorted by name. Containers without a
    /// Compose label and hidden containers do not count.
    public static func projects(hostID: UUID, hostName: String, containers: [ContainerSummary]) -> [ComposeProjectRef] {
        let visible = containers.filter(ContainerCounts.isUserVisible)
        let grouped = Dictionary(grouping: visible.filter { $0.composeProject != nil }) { $0.composeProject! }
        return grouped.map { name, members in
            ComposeProjectRef(
                hostID: hostID,
                hostName: hostName,
                name: name,
                containerIDs: members.map(\.id),
                running: members.filter { $0.state.isRunning }.count,
                total: members.count,
                workingDirectory: members.lazy.compactMap { $0.labels[ComposeRunner.Label.workingDir] }.first
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Text matching for entity queries ("open container web").
public enum EntityMatching {
    /// True when `query` is empty or every word of it occurs in `text`,
    /// ignoring case and diacritics.
    public static func matches(_ text: String, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The best matches first: exact name, then prefix, then the rest.
    public static func ranked<T>(_ items: [T], query: String, name: (T) -> String) -> [T] {
        let lowered = query.lowercased()
        func rank(_ item: T) -> Int {
            let value = name(item).lowercased()
            if value == lowered { return 0 }
            if value.hasPrefix(lowered) { return 1 }
            return 2
        }
        return items
            .filter { matches(name($0), query: query) }
            .enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }
}

/// Which Spotlight entries to add and which to remove.
public struct SpotlightIndexPlan: Equatable, Sendable {
    public var index: [String]
    public var delete: [String]

    /// Keeps the first `limit` of `current` (callers sort by priority) and
    /// removes every earlier entry that is not kept.
    public static func make(previous: Set<String>, current: [String], limit: Int) -> SpotlightIndexPlan {
        var seen = Set<String>()
        var kept: [String] = []
        for id in current where kept.count < limit && seen.insert(id).inserted {
            kept.append(id)
        }
        let keptSet = Set(kept)
        let delete = previous.subtracting(keptSet).sorted()
        return SpotlightIndexPlan(index: kept, delete: delete)
    }
}

/// The URL that "Open in Browser" opens for a container.
public enum BrowserTarget {
    public enum Failure: Error, Equatable, Sendable {
        /// The container publishes no port and has no address of its own.
        case noPort
        /// An SSH host's port listens only on the remote loopback.
        case needsForward(port: Int)
    }

    private static let wildcards: Set<String> = ["", "0.0.0.0", "::", "[::]"]

    /// Picks the first published TCP port (lowest container port first). An
    /// apple/container container has its own address: the DNS name (when a
    /// domain is set) or the IP, on its first exposed port.
    public static func url(
        host: DockerHost,
        ports: [PortBinding],
        ipAddress: String?,
        domain: String?,
        containerName: String
    ) -> Result<URL, Failure> {
        let tcp = ports.filter { $0.type.lowercased() == "tcp" }
            .sorted { ($0.privatePort, $0.publicPort ?? 0) < ($1.privatePort, $1.publicPort ?? 0) }
        if host.isAppleContainer {
            guard let port = tcp.first?.privatePort else { return .failure(.noPort) }
            if let domain, !domain.isEmpty {
                return make("\(containerName).\(domain)", port)
            }
            if let ip = ipAddress?.trimmingCharacters(in: .whitespaces), !ip.isEmpty {
                return make(ip, port)
            }
            return .failure(.noPort)
        }
        guard let binding = tcp.first(where: { ($0.publicPort ?? 0) > 0 }), let publicPort = binding.publicPort else {
            return .failure(.noPort)
        }
        let bind = binding.ip ?? ""
        if case .ssh(let endpoint) = host.kind {
            if wildcards.contains(bind) { return make(endpoint.host, publicPort) }
            if bind.hasPrefix("127.") || bind == "::1" { return .failure(.needsForward(port: publicPort)) }
            return make(bind, publicPort)
        }
        return make(wildcards.contains(bind) ? "localhost" : bind, publicPort)
    }

    private static func make(_ host: String, _ port: Int) -> Result<URL, Failure> {
        let needsBrackets = host.contains(":") && !host.hasPrefix("[")
        let shown = needsBrackets ? "[\(host)]" : host
        guard let url = URL(string: "http://\(shown):\(port)") else { return .failure(.noPort) }
        return .success(url)
    }
}
