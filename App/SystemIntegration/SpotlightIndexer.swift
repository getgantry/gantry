import Foundation
import CoreSpotlight
import AppIntents
import AppCore
import os

/// Keeps Spotlight's copy of the hosts, containers and Compose projects up to
/// date. Runs at most once per `minimumInterval` and only when the entities
/// changed; at most `limit` containers and projects go into the index.
@MainActor
final class SpotlightIndexer {
    private static let log = Logger(subsystem: "com.andrewkomkov.Gantry", category: "Spotlight")
    static let containerLimit = 500
    static let projectLimit = 200
    static let minimumInterval: Duration = .seconds(30)

    private var lastSignature: Int?
    private var lastRun: ContinuousClock.Instant?
    private var indexedContainers: Set<String> = []
    private var indexedProjects: Set<String> = []
    private var indexedHosts: Set<UUID> = []
    private var running = false
    private var retry: Task<Void, Never>?

    /// Indexes the model's entities when they changed and the interval passed.
    func update(from model: AppModel, force: Bool = false) {
        guard !running else { return }
        let entities = Self.entities(from: model)
        let signature = entities.signature
        guard signature != lastSignature else { return }
        if !force, let lastRun, ContinuousClock.now - lastRun < Self.minimumInterval {
            scheduleRetry(model, after: Self.minimumInterval - (ContinuousClock.now - lastRun))
            return
        }
        lastSignature = signature
        lastRun = .now
        running = true
        Task {
            defer { running = false }
            await apply(entities)
        }
    }

    /// A change inside the interval is indexed when the interval ends.
    private func scheduleRetry(_ model: AppModel, after delay: Duration) {
        guard retry == nil else { return }
        retry = Task { [weak self, weak model] in
            try? await Task.sleep(for: delay)
            self?.retry = nil
            if let model { self?.update(from: model) }
        }
    }

    private func apply(_ entities: Entities) async {
        let containerPlan = SpotlightIndexPlan.make(
            previous: indexedContainers, current: entities.containers.map(\.id), limit: Self.containerLimit
        )
        let projectPlan = SpotlightIndexPlan.make(
            previous: indexedProjects, current: entities.projects.map(\.id), limit: Self.projectLimit
        )
        let hostIDs = Set(entities.hosts.map(\.id))
        let containers = Array(entities.containers.prefix(Self.containerLimit))
        let projects = Array(entities.projects.prefix(Self.projectLimit))
        let work = IndexWork(
            deleteContainers: containerPlan.delete,
            deleteProjects: projectPlan.delete,
            deleteHosts: Array(indexedHosts.subtracting(hostIDs)),
            hosts: entities.hosts,
            containers: containers,
            projects: projects
        )
        do {
            try await Self.write(work)
            indexedContainers = Set(containerPlan.index)
            indexedProjects = Set(projectPlan.index)
            indexedHosts = hostIDs
        } catch {
            Self.log.error("Spotlight index failed: \(error.localizedDescription, privacy: .public)")
            lastSignature = nil
        }
    }

    struct IndexWork: Sendable {
        var deleteContainers: [String]
        var deleteProjects: [String]
        var deleteHosts: [UUID]
        var hosts: [HostEntity]
        var containers: [ContainerEntity]
        var projects: [ComposeProjectEntity]
    }

    /// Runs off the main actor: the index object is not `Sendable`.
    nonisolated private static func write(_ work: IndexWork) async throws {
        let index = CSSearchableIndex.default()
        if !work.deleteContainers.isEmpty {
            try await index.deleteAppEntities(identifiedBy: work.deleteContainers, ofType: ContainerEntity.self)
        }
        if !work.deleteProjects.isEmpty {
            try await index.deleteAppEntities(identifiedBy: work.deleteProjects, ofType: ComposeProjectEntity.self)
        }
        if !work.deleteHosts.isEmpty {
            try await index.deleteAppEntities(identifiedBy: work.deleteHosts, ofType: HostEntity.self)
        }
        try await index.indexAppEntities(work.hosts)
        try await index.indexAppEntities(work.containers)
        try await index.indexAppEntities(work.projects)
    }

    struct Entities {
        var hosts: [HostEntity]
        var containers: [ContainerEntity]
        var projects: [ComposeProjectEntity]

        var signature: Int {
            var hasher = Hasher()
            for host in hosts { hasher.combine(host.id); hasher.combine(host.name) }
            for container in containers {
                hasher.combine(container.id); hasher.combine(container.name); hasher.combine(container.state)
            }
            for project in projects { hasher.combine(project.id); hasher.combine(project.running) }
            return hasher.finalize()
        }
    }

    /// Running containers first, so the cap drops stopped ones.
    static func entities(from model: AppModel) -> Entities {
        var containers: [ContainerEntity] = []
        var projects: [ComposeProjectEntity] = []
        for session in model.sessions where session.status.isConnected {
            let visible = session.visibleContainers
            containers += visible.map { ContainerEntity(hostID: session.id, hostName: session.host.name, summary: $0) }
            projects += ComposeProjectRef.projects(hostID: session.id, hostName: session.host.name, containers: visible)
                .map(ComposeProjectEntity.init)
        }
        containers.sort { ($0.state == "running" ? 0 : 1) < ($1.state == "running" ? 0 : 1) }
        let hosts = model.sessions.map { HostEntity(host: $0.host) }
        return Entities(hosts: hosts, containers: containers, projects: projects)
    }
}
