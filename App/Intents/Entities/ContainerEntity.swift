import AppIntents
import AppCore
import DockerKit

/// An App Intents entity representing a container on a specific host. The `id`
/// is a composite "hostID|containerID" so a container is uniquely addressable
/// across hosts (Docker container ids are only unique per daemon).
struct ContainerEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Container")
    }

    static let defaultQuery = ContainerQuery()

    /// Composite identifier: "hostID|containerID".
    var id: String
    @Property(title: "Name") var name: String
    @Property(title: "Image") var image: String
    @Property(title: "State") var state: String

    init(id: String, name: String, image: String, state: String) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
    }

    init(hostID: UUID, summary: ContainerSummary) {
        self.init(
            id: Self.makeID(hostID: hostID, containerID: summary.id),
            name: summary.displayName,
            image: summary.image,
            state: summary.state.rawValue
        )
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(image) · \(state)"
        )
    }

    // MARK: - Composite id helpers

    static func makeID(hostID: UUID, containerID: String) -> String {
        "\(hostID.uuidString)|\(containerID)"
    }

    /// Splits the composite id into its host UUID and container id parts.
    static func split(_ id: String) -> (hostID: UUID, containerID: String)? {
        guard let separator = id.firstIndex(of: "|") else { return nil }
        let hostPart = String(id[..<separator])
        let containerPart = String(id[id.index(after: separator)...])
        guard let hostID = UUID(uuidString: hostPart), !containerPart.isEmpty else {
            return nil
        }
        return (hostID, containerPart)
    }

    var hostID: UUID? { Self.split(id)?.hostID }
    var containerID: String? { Self.split(id)?.containerID }
}

/// Resolves `ContainerEntity` values. Suggestions are intentionally empty
/// (containers are dynamic); `entities(for:)` connects per host and inspects.
struct ContainerQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ContainerEntity] {
        // Group requested container ids by host so we connect to each host once.
        var byHost: [UUID: Set<String>] = [:]
        for identifier in identifiers {
            guard let parts = ContainerEntity.split(identifier) else { continue }
            byHost[parts.hostID, default: []].insert(parts.containerID)
        }
        guard !byHost.isEmpty else { return [] }

        let hosts = HeadlessDocker.loadHosts()
        var result: [ContainerEntity] = []

        for (hostID, wantedContainers) in byHost {
            guard let host = hosts.first(where: { $0.id == hostID }) else { continue }
            // A failure connecting to one host should not fail resolution of the
            // others; skip silently.
            guard let client = try? await HeadlessDocker.connect(to: host) else { continue }
            defer { Task { await client.shutdown() } }

            if let summaries = try? await client.listContainers(all: true) {
                for summary in summaries where wantedContainers.contains(summary.id)
                    || wantedContainers.contains(where: { summary.id.hasPrefix($0) }) {
                    result.append(ContainerEntity(hostID: hostID, summary: summary))
                }
            }
        }

        return result
    }

    func suggestedEntities() async throws -> [ContainerEntity] {
        []
    }
}
