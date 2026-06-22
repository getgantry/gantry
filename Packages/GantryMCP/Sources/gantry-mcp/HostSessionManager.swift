import Foundation
import DockerKit
import AppCore

/// Caches connected `HostSession`s for the MCP process lifetime.
///
/// Most tools talk to a stateless `DockerClient` (via `HeadlessDocker`), but a
/// few operations are owned by a live `HostSession`: Compose `up`, Cloudflare
/// tunnels and SSH port forwards. Those keep state (running `cloudflared`
/// processes, listening sockets) that must survive across tool calls, so this
/// manager holds one connected session per host until the server shuts down.
///
/// `HostSession` is `@MainActor`; the MCP server's top-level runs on the main
/// actor and parks in `waitUntilCompleted()`, so hopping here from the
/// `GantryTools` actor is safe and the sessions stay alive.
@MainActor
final class HostSessionManager {
    static let shared = HostSessionManager()

    private var sessions: [UUID: HostSession] = [:]

    private init() {}

    /// A connected session for `host`, connecting on first use and reusing it
    /// after. SSH connects can hang waiting for a credential prompt that has no
    /// UI to answer it, so the connect is bounded by a timeout that turns a
    /// stuck prompt into a clean failure (same trusted-only caveat as the rest
    /// of the server).
    func session(for host: DockerHost) async throws -> HostSession {
        if let existing = sessions[host.id], existing.status.isConnected {
            return existing
        }
        let session = HostSession(host: host)
        // Connect on an unstructured task and poll its status to a deadline: a
        // mixed-isolation task group trips the region-isolation checker, and a
        // stuck SSH credential prompt (no UI to answer it) would otherwise hang.
        let connectTask = Task { @MainActor in await session.connect() }
        let maxTicks = 225 // ~45s at 200ms
        var ticks = 0
        while true {
            if session.status.isConnected {
                sessions[host.id] = session
                return session
            }
            if case .failed(let reason) = session.status {
                await session.disconnect()
                throw ToolError("Could not connect to \(host.name): \(reason).")
            }
            ticks += 1
            if ticks >= maxTicks {
                connectTask.cancel()
                await session.disconnect()
                throw ToolError("Timed out connecting to \(host.name). SSH hosts must be already trusted with their secret in the Keychain.")
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// The already-connected session for a host id, or nil if none is live.
    func liveSession(forHostID id: UUID) -> HostSession? {
        guard let s = sessions[id], s.status.isConnected else { return nil }
        return s
    }

    /// Every live session (for cross-host listing of tunnels/forwards).
    func allLiveSessions() -> [HostSession] {
        sessions.values.filter { $0.status.isConnected }
    }

    func shutdown() async {
        for session in sessions.values {
            await session.disconnect()
        }
        sessions.removeAll()
    }

    // MARK: - Compose

    /// Brings a parsed Compose project up on `host`, collecting progress lines.
    func composeUp(host: DockerHost, project: ComposeProject, options: ComposeUpOptions) async throws -> (started: Int, log: [String]) {
        let session = try await session(for: host)
        var log: [String] = []
        let runner = ComposeRunner(session: session, project: project, options: options)
        let started = try await runner.up { event in
            log.append(Self.describe(event))
        }
        return (started, log)
    }

    private static func describe(_ event: ComposeUpEvent) -> String {
        switch event {
        case .info(let s): return s
        case .warning(let s): return "warning: \(s)"
        case .buildingImage(let service): return "building image for \(service)"
        case .pullingImage(let service, let reference): return "pulling \(reference) for \(service)"
        case .creatingNetwork(let n): return "creating network \(n)"
        case .creatingVolume(let v): return "creating volume \(v)"
        case .startingService(let s): return "starting \(s)"
        case .startedService(let service, let containerID): return "started \(service) (\(containerID))"
        case .finished(let project, let started): return "finished \(project): \(started) service(s)"
        }
    }

    // MARK: - Cloudflare tunnels

    /// Starts a tunnel for a published container port, resolving the local
    /// target by host kind (apple/container is reached at the container IP).
    func startTunnel(host: DockerHost, containerID: String, port: Int, mode: CloudflareTunnel.Mode) async throws -> CloudflareTunnel {
        let session = try await session(for: host)
        let label = containerID
        var ip: String? = nil
        if host.isAppleContainer {
            let details = await session.details(for: containerID)
            ip = details?.networkSettings.ipAddress
        }
        let binding = PortBinding(ip: ip, privatePort: port, publicPort: port, type: "tcp")
        guard let tunnel = await session.startCloudflareTunnel(
            containerID: containerID, label: label, port: binding, mode: mode
        ) else {
            throw ToolError(session.lastError ?? "Could not start the tunnel.")
        }
        return tunnel
    }

    func listTunnels() -> [(hostID: UUID, tunnel: CloudflareTunnel)] {
        sessions.flatMap { id, session in session.cloudflareTunnels.map { (id, $0) } }
    }

    func stopTunnel(id: UUID) async -> Bool {
        for session in sessions.values where session.cloudflareTunnels.contains(where: { $0.id == id }) {
            await session.stopCloudflareTunnel(id)
            return true
        }
        return false
    }

    // MARK: - Port forwards

    func startForward(host: DockerHost, containerID: String, remotePort: Int, localPort: Int?) async throws -> PortForward {
        let session = try await session(for: host)
        guard session.supportsPortForwarding else {
            throw ToolError("Port forwarding is only available for connected SSH hosts.")
        }
        guard let forward = await session.startPortForward(
            containerID: containerID, label: containerID, remotePort: remotePort, desiredLocalPort: localPort
        ) else {
            throw ToolError(session.lastError ?? "Could not start the port forward.")
        }
        return forward
    }

    func listForwards() -> [(hostID: UUID, forward: PortForward)] {
        sessions.flatMap { id, session in session.portForwards.map { (id, $0) } }
    }

    func stopForward(id: UUID) async -> Bool {
        for session in sessions.values where session.portForwards.contains(where: { $0.id == id }) {
            await session.stopPortForward(id)
            return true
        }
        return false
    }
}
