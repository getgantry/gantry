import Foundation
import Observation
import DockerKit

/// Observable per-host session: owns the DockerClient and mirrors the daemon's
/// resources into UI-friendly state on the main actor.
@MainActor
@Observable
public final class HostSession: Identifiable {
    public let host: DockerHost
    public nonisolated var id: UUID { host.id }

    public private(set) var status: ConnectionStatus = .disconnected
    public private(set) var containers: [ContainerSummary] = []
    public private(set) var images: [ImageSummary] = []
    public private(set) var volumes: [Volume] = []
    public private(set) var networks: [NetworkResource] = []
    public private(set) var info: SystemInfo?

    /// Last error surfaced to the UI; settable so a view can dismiss it.
    public var lastError: String?

    private var client: DockerClient?

    public init(host: DockerHost) {
        self.host = host
    }

    // MARK: - Connection

    public func connect() async {
        status = .connecting
        lastError = nil

        switch host.kind {
        case .local:
            let socketPath: String?
            if let override = host.socketPathOverride {
                socketPath = override
            } else {
                socketPath = DockerSocketDiscovery.discover()
            }
            guard let socketPath else {
                status = .failed("No Docker socket found")
                return
            }

            let transport = UnixSocketTransport(socketPath: socketPath)
            let client = DockerClient(transport: transport)
            do {
                let version = try await client.negotiate()
                self.client = client
                status = .connected(version)
                await refreshAll()
            } catch {
                await client.shutdown()
                self.client = nil
                status = .failed(error.localizedDescription)
            }

        case .ssh:
            // TODO(M3): SSH transport lands in milestone 3.
            status = .failed("SSH hosts arrive in M3")
        }
    }

    public func disconnect() async {
        if let client {
            await client.shutdown()
        }
        client = nil
        containers = []
        images = []
        volumes = []
        networks = []
        info = nil
        status = .disconnected
    }

    // MARK: - Refresh

    public func refreshAll() async {
        guard let client else { return }

        async let containersResult = fetch { try await client.listContainers(all: true) }
        async let imagesResult = fetch { try await client.listImages() }
        async let volumesResult = fetch { try await client.listVolumes() }
        async let networksResult = fetch { try await client.listNetworks() }
        async let infoResult = fetch { try await client.systemInfo() }

        if let value = await containersResult { containers = value }
        if let value = await imagesResult { images = value }
        if let value = await volumesResult { volumes = value }
        if let value = await networksResult { networks = value }
        if let value = await infoResult { info = value }
    }

    public func refreshContainers() async {
        guard let client else { return }
        if let value = await fetch({ try await client.listContainers(all: true) }) {
            containers = value
        }
    }

    public func refreshImages() async {
        guard let client else { return }
        if let value = await fetch({ try await client.listImages() }) {
            images = value
        }
    }

    public func refreshVolumes() async {
        guard let client else { return }
        if let value = await fetch({ try await client.listVolumes() }) {
            volumes = value
        }
    }

    public func refreshNetworks() async {
        guard let client else { return }
        if let value = await fetch({ try await client.listNetworks() }) {
            networks = value
        }
    }

    // MARK: - Container actions

    public func perform(_ action: ContainerAction, on id: String) async -> Bool {
        guard let client else {
            lastError = "Not connected"
            return false
        }

        do {
            switch action {
            case .start:
                try await client.startContainer(id: id)
            case .stop:
                try await client.stopContainer(id: id, timeout: nil)
            case .restart:
                try await client.restartContainer(id: id, timeout: nil)
            case .kill:
                try await client.killContainer(id: id, signal: nil)
            case .pause:
                try await client.pauseContainer(id: id)
            case .unpause:
                try await client.unpauseContainer(id: id)
            case .remove(let force):
                try await client.removeContainer(id: id, force: force, removeVolumes: false)
            }
            await refreshContainers()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    public func details(for containerID: String) async -> ContainerDetails? {
        guard let client else {
            lastError = "Not connected"
            return nil
        }
        do {
            return try await client.inspectContainer(id: containerID)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Raw inspection

    public func rawInspectContainer(id: String) async -> String {
        await rawInspect { client in try await client.rawInspectContainer(id: id) }
    }

    public func rawInspectImage(id: String) async -> String {
        await rawInspect { client in try await client.rawInspectImage(id: id) }
    }

    public func rawInspectVolume(name: String) async -> String {
        await rawInspect { client in try await client.rawInspectVolume(name: name) }
    }

    public func rawInspectNetwork(id: String) async -> String {
        await rawInspect { client in try await client.rawInspectNetwork(id: id) }
    }

    // MARK: - Helpers

    /// Runs a throwing client call, records any error, returns the value or nil.
    private func fetch<T>(_ body: () async throws -> T) async -> T? {
        do {
            return try await body()
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func rawInspect(_ body: (DockerClient) async throws -> Data) async -> String {
        guard let client else { return "Not connected" }
        do {
            let data = try await body(client)
            return Self.prettyJSON(from: data)
        } catch {
            return error.localizedDescription
        }
    }

    /// Re-encodes JSON data sorted and indented; falls back to the raw string.
    private static func prettyJSON(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(
               withJSONObject: object,
               options: [.prettyPrinted, .sortedKeys]
           ),
           let string = String(data: pretty, encoding: .utf8) {
            return string
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
