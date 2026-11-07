import Foundation
import AppCore
import DockerKit

/// Access to the running app's model for intents, notification actions and
/// control requests. These can run before a window exists, so each call falls
/// back to a short-lived client from `HeadlessDocker`.
@MainActor
enum LiveFleet {
    /// Set once at launch by `GantryApp`.
    static weak var model: AppModel?

    /// The host's session when it is connected.
    static func connectedSession(_ hostID: UUID) -> HostSession? {
        guard let session = model?.session(id: hostID), session.status.isConnected else { return nil }
        return session
    }

    /// The configured hosts: the live model's, else the saved list.
    static func hosts() -> [DockerHost] {
        if let model { return model.sessions.map(\.host) }
        return HeadlessDocker.loadHosts()
    }

    static func host(_ id: UUID) throws -> DockerHost {
        guard let host = hosts().first(where: { $0.id == id }) else {
            throw HeadlessDockerError.hostNotFound(id.uuidString)
        }
        return host
    }

    /// Runs `body` with a client for the host: the live session's when it is
    /// connected, else a new connection that closes afterwards.
    static func withClient<T: Sendable>(
        _ host: DockerHost,
        _ body: (DockerClient) async throws -> T
    ) async throws -> T {
        let client = try await HeadlessDocker.connect(to: host)
        do {
            let value = try await body(client)
            await client.shutdown()
            return value
        } catch {
            await client.shutdown()
            throw error
        }
    }

    /// The containers of a host: from the live session when connected, else
    /// from a new connection.
    static func containers(on host: DockerHost) async throws -> [ContainerSummary] {
        if let session = connectedSession(host.id) { return session.containers }
        return try await withClient(host) { try await $0.listContainers(all: true) }
    }

    /// Runs a container action, through the live session when it is connected
    /// (so the lists and crash alerts know about it).
    static func perform(_ action: ContainerAction, hostID: UUID, containerID: String) async throws {
        if let session = connectedSession(hostID) {
            guard await session.perform(action, on: containerID) else {
                throw HeadlessDockerError.connectionFailed(session.lastError ?? String(localized: "The action did not complete."))
            }
            return
        }
        let host = try host(hostID)
        try await withClient(host) { client in
            switch action {
            case .start: try await client.startContainer(id: containerID)
            case .stop: try await client.stopContainer(id: containerID, timeout: nil)
            case .restart: try await client.restartContainer(id: containerID, timeout: nil)
            default: throw HeadlessDockerError.containerNotFound(containerID)
            }
        }
    }

    /// Refreshes the host's list after work that did not go through the session.
    static func refresh(_ hostID: UUID) async {
        await connectedSession(hostID)?.refreshContainers()
    }
}
