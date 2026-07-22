import Foundation
import DockerKit
import AppCore

/// Headless Docker access for the MCP server.
///
/// A thin caching layer over `AppCore.HeadlessDocker`: it loads the persisted
/// host list and caches one live, version-negotiated `DockerClient` per host id
/// for the lifetime of the process. All transport selection and the
/// trusted-only, non-interactive SSH credential resolution live in
/// `AppCore.HeadlessDocker` (the shared contract) so the app, App Intents, and
/// this server connect identically — including ProxyJump support.
actor HeadlessDocker {
    /// Cached, already-negotiated clients keyed by host id.
    private var clients: [UUID: DockerClient] = [:]

    init() {}

    // MARK: - Host list

    /// Loads the persisted host list (the same `hosts.json` the app writes),
    /// seeding the default local host when no file exists yet.
    /// Stable id for the synthesised fallback Local host.
    ///
    /// It must not be random: `host(id:)` re-reads the host list on every call,
    /// so a fresh UUID each time makes the host `list_hosts` just advertised
    /// impossible to look up again — an agent that reads an id and passes it
    /// straight back gets "unknown host" on a machine with no hosts.json yet.
    static let fallbackLocalHostID = UUID(uuidString: "6A6E7472-0000-4000-8000-000000000001")!

    nonisolated func loadHosts() -> [DockerHost] {
        let hosts = AppCore.HeadlessDocker.loadHosts()
        guard hosts.isEmpty else { return hosts }
        return [DockerHost(id: Self.fallbackLocalHostID, name: "Local", kind: .local)]
    }

    /// Returns the host with the given id, or nil.
    nonisolated func host(id: UUID) -> DockerHost? {
        loadHosts().first { $0.id == id }
    }

    // MARK: - Connection

    /// Returns a connected, version-negotiated client for the host, reusing a
    /// cached connection when one already exists.
    func connect(to host: DockerHost) async throws -> DockerClient {
        if let existing = clients[host.id] {
            return existing
        }
        let client = try await AppCore.HeadlessDocker.connect(to: host)
        clients[host.id] = client
        return client
    }

    /// Resolves a host id to a connected client, loading the host list on demand.
    func client(forHostID id: UUID) async throws -> DockerClient {
        guard let host = host(id: id) else {
            throw HeadlessError.unknownHost(id)
        }
        return try await connect(to: host)
    }

    /// Closes every cached connection. Call before the process exits.
    func shutdown() async {
        for client in clients.values {
            await client.shutdown()
        }
        clients.removeAll()
    }
}

enum HeadlessError: Error, LocalizedError {
    case unknownHost(UUID)

    var errorDescription: String? {
        switch self {
        case .unknownHost(let id):
            return "No host with id \(id.uuidString)."
        }
    }
}
