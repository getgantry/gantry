import AppIntents
import AppCore
import DockerKit

/// Shared plumbing for Gantry's App Intents: host resolution and a dynamic
/// options provider that lists a host's containers.
enum IntentSupport {
    /// Loads the `DockerHost` for an entity, throwing a descriptive error if it
    /// is no longer in the persisted list.
    static func host(for entity: HostEntity) throws -> DockerHost {
        guard let host = HeadlessDocker.loadHosts().first(where: { $0.id == entity.id }) else {
            throw HeadlessDockerError.hostNotFound(entity.name)
        }
        return host
    }

    /// Resolves a `ContainerEntity` to its (host, container id), throwing if the
    /// composite id is malformed or the host is gone.
    static func resolve(_ entity: ContainerEntity) throws -> (host: DockerHost, containerID: String) {
        guard let parts = ContainerEntity.split(entity.id) else {
            throw HeadlessDockerError.containerNotFound(entity.name)
        }
        guard let host = HeadlessDocker.loadHosts().first(where: { $0.id == parts.hostID }) else {
            throw HeadlessDockerError.hostNotFound(entity.name)
        }
        return (host, parts.containerID)
    }
}

/// Lists the containers for a chosen host. Shared by the per-intent dynamic
/// options providers below.
func containerOptions(for host: HostEntity?) async throws -> [ContainerEntity] {
    guard let host else { return [] }
    let dockerHost = try IntentSupport.host(for: host)
    let client = try await HeadlessDocker.connect(to: dockerHost)
    defer { Task { await client.shutdown() } }

    let summaries = try await client.listContainers(all: true)
    return summaries.map { ContainerEntity(hostID: dockerHost.id, summary: $0) }
}
