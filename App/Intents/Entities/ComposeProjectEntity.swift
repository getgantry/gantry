import AppIntents
import CoreSpotlight
import AppCore
import DockerKit

/// A Compose project on one host. The `id` is "hostID|project".
struct ComposeProjectEntity: AppEntity, IndexedEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Compose Project")
    }

    static let defaultQuery = ComposeProjectQuery()

    var id: String
    @Property(title: "Name") var name: String
    @Property(title: "Host") var hostName: String
    @Property(title: "Running") var running: Int
    @Property(title: "Containers") var total: Int

    init(id: String, name: String, hostName: String, running: Int, total: Int) {
        self.id = id
        self.name = name
        self.hostName = hostName
        self.running = running
        self.total = total
    }

    init(_ ref: ComposeProjectRef) {
        self.init(id: ref.id, name: ref.name, hostName: ref.hostName, running: ref.running, total: ref.total)
    }

    var hostID: UUID? { ComposeProjectRef.split(id)?.hostID }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(running)/\(total) running · \(hostName)",
            image: .init(systemName: "square.stack.3d.up")
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .content)
        set.displayName = name
        set.contentDescription = hostName
        set.keywords = ["compose", "docker", "stack", hostName]
        return set
    }
}

struct ComposeProjectQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ComposeProjectEntity] {
        let hostIDs = Set(identifiers.compactMap { ComposeProjectRef.split($0)?.hostID })
        var found: [ComposeProjectEntity] = []
        for hostID in hostIDs {
            found += await Self.projects(hostID: hostID)
        }
        let wanted = Set(identifiers)
        return found.filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [ComposeProjectEntity] {
        EntityMatching.ranked(await Self.allProjects(), query: string) { $0.name }
    }

    func suggestedEntities() async throws -> [ComposeProjectEntity] {
        await Self.allProjects()
    }

    @MainActor
    static func projects(hostID: UUID) async -> [ComposeProjectEntity] {
        guard let host = try? LiveFleet.host(hostID),
              let list = try? await LiveFleet.containers(on: host) else { return [] }
        return ComposeProjectRef.projects(hostID: hostID, hostName: host.name, containers: list)
            .map(ComposeProjectEntity.init)
    }

    @MainActor
    static func allProjects() async -> [ComposeProjectEntity] {
        if let model = LiveFleet.model {
            return model.sessions.filter(\.status.isConnected).flatMap { session in
                ComposeProjectRef.projects(hostID: session.id, hostName: session.host.name, containers: session.containers)
                    .map(ComposeProjectEntity.init)
            }
        }
        var result: [ComposeProjectEntity] = []
        for host in HeadlessDocker.loadHosts() {
            result += await projects(hostID: host.id)
        }
        return result
    }
}
