import Foundation
import Darwin
import DockerKit
import SSHKit

/// A local TCP port forward to a container port reachable on an SSH host.
/// Mirrored into `HostSession.portForwards` for the UI; the running tunnel is
/// owned privately by the session.
public struct PortForward: Identifiable, Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        case starting
        case active
        case failed(String)
    }

    public let id: UUID
    /// Container the forward belongs to (so the UI can group/clean up).
    public let containerID: String
    /// Human label, e.g. the container name.
    public var label: String
    /// The port bound on `127.0.0.1` locally.
    public var localPort: Int
    /// Host reached from the SSH server's perspective (loopback, where Docker
    /// publishes the port).
    public var remoteHost: String
    /// The published port on the remote Docker host.
    public var remotePort: Int
    public var status: Status

    public init(
        id: UUID = UUID(),
        containerID: String,
        label: String,
        localPort: Int,
        remoteHost: String,
        remotePort: Int,
        status: Status = .starting
    ) {
        self.id = id
        self.containerID = containerID
        self.label = label
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.status = status
    }

    /// The URL to open in a browser once the forward is active.
    public var localURL: URL? {
        URL(string: "http://localhost:\(localPort)")
    }
}

/// Small helpers for choosing a usable local TCP port.
public enum LocalPort {
    /// Whether `127.0.0.1:port` can currently be bound (i.e. is free).
    public static func isAvailable(_ port: Int) -> Bool {
        guard port > 0, port <= 65535 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    /// A free local port: the caller's preference when free, otherwise one the
    /// kernel hands out by binding to port 0. Returns nil only if no socket can
    /// be opened at all.
    public static func free(preferring preferred: Int? = nil) -> Int? {
        if let preferred, isAvailable(preferred) { return preferred }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var bound_addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &bound_addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        guard got == 0 else { return nil }
        return Int(UInt16(bigEndian: bound_addr.sin_port))
    }
}

// MARK: - HostSession integration

extension HostSession {
    /// Whether this host can establish local port forwards (SSH only — local
    /// and apple/container ports are reachable directly).
    public var supportsPortForwarding: Bool {
        host.isSSH && supportsHostAccess
    }

    /// A directly-openable local URL for a published port, when the host kind
    /// exposes one without a tunnel. Local Docker and apple/container publish
    /// ports onto the Mac (loopback, or a concrete bind address), so they open
    /// directly; SSH returns nil and must go through a forward instead.
    public func directBrowserURL(for port: PortBinding) -> URL? {
        guard !host.isSSH, let publicPort = port.publicPort, publicPort > 0 else { return nil }
        // A wildcard bind (0.0.0.0 / :: / unset) is reached via localhost; a
        // concrete address (e.g. apple/container's host IP) is used verbatim.
        let wildcards: Set<String> = ["", "0.0.0.0", "::", "[::]"]
        let bind = port.ip ?? ""
        let host = wildcards.contains(bind) ? "localhost" : bind
        return URL(string: "http://\(host):\(publicPort)")
    }

    /// Starts a local forward to a published port on the remote Docker host,
    /// picking a free local port (preferring `desiredLocalPort` when given and
    /// free). Reuses an existing active forward to the same remote port. The
    /// returned `PortForward` is also appended to `portForwards`; on failure its
    /// `status` is `.failed` and `lastError` is set.
    @discardableResult
    public func startPortForward(
        containerID: String,
        label: String,
        remotePort: Int,
        remoteHost: String = "127.0.0.1",
        desiredLocalPort: Int? = nil
    ) async -> PortForward? {
        guard let factory = sshClientFactory else {
            lastError = "Port forwarding requires a connected SSH host"
            return nil
        }

        // Reuse an already-active forward to the same remote endpoint.
        if desiredLocalPort == nil,
           let existing = portForwards.first(where: {
               $0.remotePort == remotePort && $0.remoteHost == remoteHost && $0.status == .active
           }) {
            return existing
        }

        guard let localPort = LocalPort.free(preferring: desiredLocalPort) else {
            lastError = "Could not find a free local port"
            return nil
        }

        var forward = PortForward(
            containerID: containerID,
            label: label,
            localPort: localPort,
            remoteHost: remoteHost,
            remotePort: remotePort,
            status: .starting
        )
        portForwards.append(forward)

        let service = SSHPortForward(makeClient: factory)
        portForwardServices[forward.id] = service

        do {
            let bound = try await service.start(
                localPort: localPort,
                remoteHost: remoteHost,
                remotePort: remotePort
            )
            forward.localPort = bound
            forward.status = .active
            update(forward)
            return forward
        } catch {
            forward.status = .failed(error.localizedDescription)
            update(forward)
            portForwardServices[forward.id] = nil
            await service.stop()
            lastError = error.localizedDescription
            return forward
        }
    }

    /// Tears down a single forward and removes it from `portForwards`.
    public func stopPortForward(_ id: UUID) async {
        portForwards.removeAll { $0.id == id }
        guard let service = portForwardServices.removeValue(forKey: id) else { return }
        await service.stop()
    }

    /// Rebinds an existing forward to a new local port (used when the user edits
    /// the port, or to move off a now-busy one). Keeps the same `id`.
    @discardableResult
    public func rebindPortForward(_ id: UUID, toLocalPort newPort: Int) async -> Bool {
        guard let index = portForwards.firstIndex(where: { $0.id == id }) else { return false }
        let existing = portForwards[index]
        await stopPortForward(id)
        let restarted = await startPortForward(
            containerID: existing.containerID,
            label: existing.label,
            remotePort: existing.remotePort,
            remoteHost: existing.remoteHost,
            desiredLocalPort: newPort
        )
        return restarted?.status == .active
    }

    /// Stops every forward (on disconnect). Fire-and-forget teardown.
    func stopAllPortForwards() {
        let services = portForwardServices
        portForwardServices.removeAll()
        portForwards.removeAll()
        guard !services.isEmpty else { return }
        Task {
            for service in services.values {
                await service.stop()
            }
        }
    }

    private func update(_ forward: PortForward) {
        guard let index = portForwards.firstIndex(where: { $0.id == forward.id }) else { return }
        portForwards[index] = forward
    }
}
