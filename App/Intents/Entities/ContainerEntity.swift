import AppIntents
import CoreSpotlight
import AppCore
import DockerKit

/// An App Intents entity representing a container on a specific host. The `id`
/// is a composite "hostID|containerID" so a container is uniquely addressable
/// across hosts (Docker container ids are only unique per daemon).
struct ContainerEntity: AppEntity, IndexedEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Container")
    }

    static let defaultQuery = ContainerQuery()

    /// Composite identifier: "hostID|containerID".
    var id: String
    @Property(title: "Name") var name: String
    @Property(title: "Image") var image: String
    @Property(title: "State") var state: String
    @Property(title: "Host") var hostName: String

    init(id: String, name: String, image: String, state: String, hostName: String = "") {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.hostName = hostName
    }

    init(hostID: UUID, hostName: String = "", summary: ContainerSummary) {
        self.init(
            id: Self.makeID(hostID: hostID, containerID: summary.id),
            name: summary.displayName,
            image: summary.image,
            state: summary.state.rawValue,
            hostName: hostName
        )
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: hostName.isEmpty ? "\(image) · \(state)" : "\(image) · \(state) · \(hostName)",
            image: .init(systemName: "shippingbox")
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .content)
        set.displayName = name
        set.contentDescription = [image, state, hostName].filter { !$0.isEmpty }.joined(separator: " · ")
        set.keywords = ["container", "docker", image, hostName].filter { !$0.isEmpty }
        return set
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

/// Resolves `ContainerEntity` values: from the running app's live lists when
/// it has them, else by connecting to each host.
struct ContainerQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ContainerEntity] {
        // Group requested container ids by host so we connect to each host once.
        var byHost: [UUID: Set<String>] = [:]
        for identifier in identifiers {
            guard let parts = ContainerEntity.split(identifier) else { continue }
            byHost[parts.hostID, default: []].insert(parts.containerID)
        }
        guard !byHost.isEmpty else { return [] }

        var result: [ContainerEntity] = []
        for (hostID, wanted) in byHost {
            let listed = await Self.containers(hostID: hostID)
            for entity in listed {
                guard let containerID = entity.containerID else { continue }
                if wanted.contains(containerID) || wanted.contains(where: { containerID.hasPrefix($0) }) {
                    result.append(entity)
                }
            }
        }
        return result
    }

    func entities(matching string: String) async throws -> [ContainerEntity] {
        let all = await Self.allContainers()
        return EntityMatching.ranked(all, query: string) { $0.name }
    }

    func suggestedEntities() async throws -> [ContainerEntity] {
        let all = await Self.allContainers()
        return Array(all.filter { $0.state == ContainerState.running.rawValue }.prefix(50))
    }

    /// One host's containers. A host that fails to answer gives none.
    @MainActor
    static func containers(hostID: UUID) async -> [ContainerEntity] {
        guard let host = try? LiveFleet.host(hostID),
              let list = try? await LiveFleet.containers(on: host) else { return [] }
        return list.filter(ContainerCounts.isUserVisible).map {
            ContainerEntity(hostID: hostID, hostName: host.name, summary: $0)
        }
    }

    /// Every host's containers: the connected hosts of the running app, or
    /// each saved host when the app has no live model.
    @MainActor
    static func allContainers() async -> [ContainerEntity] {
        if let model = LiveFleet.model {
            return model.sessions.filter(\.status.isConnected).flatMap { session in
                session.visibleContainers.map {
                    ContainerEntity(hostID: session.id, hostName: session.host.name, summary: $0)
                }
            }
        }
        var result: [ContainerEntity] = []
        for host in HeadlessDocker.loadHosts() {
            result += await containers(hostID: host.id)
        }
        return result
    }
}
