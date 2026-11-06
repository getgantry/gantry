import AppIntents
import CoreSpotlight
import AppCore

/// An App Intents entity representing a configured Docker host. Backed by the
/// persisted host list (`HeadlessDocker.loadHosts`), so it resolves whether or
/// not the Gantry GUI is running.
struct HostEntity: AppEntity, IndexedEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Docker Host")
    }

    static let defaultQuery = HostQuery()

    var id: UUID
    @Property(title: "Name") var name: String

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    init(host: DockerHost) {
        self.init(id: host.id, name: host.name)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "server.rack"))
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .content)
        set.displayName = name
        set.keywords = ["docker", "host"]
        return set
    }
}

/// Resolves `HostEntity` values from the persisted host list.
struct HostQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [HostEntity] {
        let hosts = HeadlessDocker.loadHosts()
        let wanted = Set(identifiers)
        return hosts.filter { wanted.contains($0.id) }.map(HostEntity.init)
    }

    func entities(matching string: String) async throws -> [HostEntity] {
        EntityMatching.ranked(HeadlessDocker.loadHosts().map(HostEntity.init), query: string) { $0.name }
    }

    func suggestedEntities() async throws -> [HostEntity] {
        HeadlessDocker.loadHosts().map(HostEntity.init)
    }
}
