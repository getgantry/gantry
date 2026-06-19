import Foundation
import DockerKit

/// A public Cloudflare tunnel exposing a container's published port to the
/// internet. The running `cloudflared` process is owned privately by a
/// `CloudflaredTunnelService`; this value is the UI-facing mirror, kept on the
/// `HostSession` next to `portForwards`.
public struct CloudflareTunnel: Identifiable, Sendable, Hashable {
    /// How the tunnel is published.
    public enum Mode: Sendable, Hashable {
        /// Quick tunnel — no Cloudflare account, an ephemeral `*.trycloudflare.com`.
        case quick
        /// Named tunnel routed to a hostname on a zone in the user's account
        /// (requires a prior `cloudflared tunnel login`).
        case named(hostname: String)
    }

    public enum Status: Sendable, Hashable {
        case starting
        case active(url: URL)
        case failed(String)
    }

    public let id: UUID
    /// Container the tunnel belongs to (so the UI can group/clean up).
    public let containerID: String
    /// Human label, e.g. the container name.
    public var label: String
    /// The published container port being shared.
    public var port: Int
    public var mode: Mode
    public var status: Status

    public init(
        id: UUID = UUID(),
        containerID: String,
        label: String,
        port: Int,
        mode: Mode,
        status: Status = .starting
    ) {
        self.id = id
        self.containerID = containerID
        self.label = label
        self.port = port
        self.mode = mode
        self.status = status
    }

    /// The public URL once the tunnel is active.
    public var publicURL: URL? {
        if case .active(let url) = status { return url }
        return nil
    }

    // MARK: - Command construction (static, for testing)

    /// Normalizes a local target URL for `cloudflared`'s origin dial. `localhost`
    /// can resolve to IPv6 `::1` first while the published port (or SSH forward)
    /// only listens on IPv4 `127.0.0.1` — cloudflared then can't reach the origin
    /// and the edge serves a 502. Pinning the host to `127.0.0.1` avoids that.
    /// A concrete address (e.g. an apple/container IP) is left untouched.
    public static func originTarget(from url: URL) -> String {
        guard url.host == "localhost",
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        comps.host = "127.0.0.1"
        return comps.url?.absoluteString ?? url.absoluteString
    }

    /// The `cloudflared` arguments for a tunnel pointing at `targetURL`
    /// (a local `http://host:port` the daemon publishes the port onto).
    public static func arguments(mode: Mode, targetURL: String) -> [String] {
        switch mode {
        case .quick:
            return ["tunnel", "--no-autoupdate", "--url", targetURL]
        case .named(let hostname):
            return ["tunnel", "--no-autoupdate", "--hostname", hostname, "--url", targetURL]
        }
    }

    /// Extracts the `https://<sub>.trycloudflare.com` URL that a quick tunnel
    /// prints once the edge connection is up. Returns nil for other lines.
    public static func extractQuickTunnelURL(from line: String) -> URL? {
        guard let match = line.firstMatch(of: /https:\/\/[a-z0-9-]+\.trycloudflare\.com/) else {
            return nil
        }
        return URL(string: String(match.0))
    }

    /// Whether a log line indicates a named tunnel has registered an edge
    /// connection (its public URL is the hostname, known up front).
    public static func indicatesNamedTunnelReady(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("registered tunnel connection")
            || lower.contains("connection registered")
    }
}

/// Owns a running `cloudflared` process for one tunnel. Reads its merged
/// stdout/stderr, surfaces the public URL once the edge connection is up, and
/// reports process exit. Tearing it down terminates the child.
public actor CloudflaredTunnelService {
    private var process: Process?
    private var readTask: Task<Void, Never>?
    private var reportedActive = false

    public init() {}

    /// Launches `cloudflared` with `arguments`. `expectedURL` is non-nil for
    /// named tunnels (the hostname URL, known before the connection is up); when
    /// nil the public URL is parsed from the quick-tunnel banner.
    ///
    /// - `onLine`: every output line (for a live log).
    /// - `onActive`: the public URL, once.
    /// - `onExit`: the process exit code (e.g. on crash or failed start).
    public func start(
        cliPath: String,
        arguments: [String],
        expectedURL: URL?,
        onLine: @escaping @Sendable (String) -> Void,
        onActive: @escaping @Sendable (URL) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = env["PATH"].map { "\(extraPath):\($0)" } ?? extraPath
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let handle = pipe.fileHandleForReading

        process.terminationHandler = { proc in
            onExit(proc.terminationStatus)
        }

        try process.run()
        self.process = process

        readTask = Task.detached { [weak self] in
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    let line = String(decoding: lineData, as: UTF8.self)
                    onLine(line)
                    await self?.consider(line: line, expectedURL: expectedURL, onActive: onActive)
                }
            }
            if !buffer.isEmpty {
                let line = String(decoding: buffer, as: UTF8.self)
                onLine(line)
                await self?.consider(line: line, expectedURL: expectedURL, onActive: onActive)
            }
        }
    }

    /// Inspects one line for the readiness signal and fires `onActive` once.
    private func consider(
        line: String,
        expectedURL: URL?,
        onActive: @escaping @Sendable (URL) -> Void
    ) {
        guard !reportedActive else { return }
        if let expectedURL {
            if CloudflareTunnel.indicatesNamedTunnelReady(line) {
                reportedActive = true
                onActive(expectedURL)
            }
        } else if let url = CloudflareTunnel.extractQuickTunnelURL(from: line) {
            reportedActive = true
            onActive(url)
        }
    }

    /// Terminates the child and stops reading. Idempotent.
    public func stop() async {
        readTask?.cancel()
        readTask = nil
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
        process = nil
    }
}

// MARK: - HostSession integration

extension HostSession {
    /// Resolves the local `http://host:port` that `cloudflared` should point at
    /// for a published port, establishing an SSH forward first when the port
    /// lives on a remote daemon. Returns nil if no local endpoint can be reached.
    private func localTargetURL(for port: PortBinding, containerID: String, label: String) async -> URL? {
        if let direct = directBrowserURL(for: port) {
            return direct
        }
        // SSH host: the port lives on the remote daemon — forward it locally,
        // then tunnel that local port.
        guard host.isSSH, let publicPort = port.publicPort else { return nil }
        let forward = await startPortForward(
            containerID: containerID,
            label: label,
            remotePort: publicPort
        )
        guard let forward, forward.status == .active else { return nil }
        return forward.localURL
    }

    /// Starts a Cloudflare tunnel exposing a published `port` (Docker local or
    /// SSH) to the internet. Resolves a local target — forwarding first for SSH
    /// hosts — then delegates to the explicit-target overload. On failure
    /// `lastError` is set and the result is nil or `.failed`.
    @discardableResult
    public func startCloudflareTunnel(
        containerID: String,
        label: String,
        port: PortBinding,
        mode: CloudflareTunnel.Mode,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async -> CloudflareTunnel? {
        guard let publicPort = port.publicPort, publicPort > 0 else {
            lastError = "This port isn't published, so it can't be shared."
            return nil
        }
        guard CloudflaredTooling.cliPath() != nil else {
            lastError = "cloudflared isn't installed."
            return nil
        }
        guard let target = await localTargetURL(for: port, containerID: containerID, label: label) else {
            lastError = "Could not reach this port locally to tunnel it."
            return nil
        }
        return await startCloudflareTunnel(
            containerID: containerID,
            label: label,
            port: publicPort,
            targetURL: target,
            mode: mode,
            onLine: onLine
        )
    }

    /// Starts a Cloudflare tunnel pointing `cloudflared` at an explicit local
    /// `targetURL` (e.g. an apple/container's `http://<ip>:<port>`, which is
    /// reachable directly without publishing). Launches `cloudflared`, mirrors a
    /// `CloudflareTunnel` into `cloudflareTunnels`, and on failure sets the
    /// tunnel's `status` to `.failed` and `lastError`.
    @discardableResult
    public func startCloudflareTunnel(
        containerID: String,
        label: String,
        port: Int,
        targetURL: URL,
        mode: CloudflareTunnel.Mode,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async -> CloudflareTunnel? {
        guard let cli = CloudflaredTooling.cliPath() else {
            lastError = "cloudflared isn't installed."
            return nil
        }

        var tunnel = CloudflareTunnel(
            containerID: containerID,
            label: label,
            port: port,
            mode: mode,
            status: .starting
        )
        cloudflareTunnels.append(tunnel)
        let target = targetURL

        let expectedURL: URL?
        if case .named(let hostname) = mode {
            expectedURL = URL(string: "https://\(hostname)")
        } else {
            expectedURL = nil
        }

        let service = CloudflaredTunnelService()
        cloudflaredServices[tunnel.id] = service
        let id = tunnel.id

        do {
            try await service.start(
                cliPath: cli,
                arguments: CloudflareTunnel.arguments(mode: mode, targetURL: CloudflareTunnel.originTarget(from: target)),
                expectedURL: expectedURL,
                onLine: { line in onLine?(line) },
                onActive: { [weak self] url in
                    Task { @MainActor [weak self] in
                        self?.updateCloudflareTunnel(id) { $0.status = .active(url: url) }
                    }
                },
                onExit: { [weak self] code in
                    Task { @MainActor [weak self] in
                        guard let self, let existing = self.cloudflareTunnels.first(where: { $0.id == id }) else { return }
                        // A clean stop removes the tunnel first, so reaching here
                        // with the tunnel still present and not active is a failure.
                        if existing.publicURL == nil {
                            self.updateCloudflareTunnel(id) {
                                $0.status = .failed("cloudflared exited (code \(code)) before the tunnel came up.")
                            }
                        }
                    }
                }
            )
            return tunnel
        } catch {
            tunnel.status = .failed(error.localizedDescription)
            updateCloudflareTunnel(id) { $0 = tunnel }
            cloudflaredServices[id] = nil
            await service.stop()
            lastError = error.localizedDescription
            return tunnel
        }
    }

    /// Tears down a single tunnel and removes it from `cloudflareTunnels`.
    public func stopCloudflareTunnel(_ id: UUID) async {
        cloudflareTunnels.removeAll { $0.id == id }
        guard let service = cloudflaredServices.removeValue(forKey: id) else { return }
        await service.stop()
    }

    /// Stops every tunnel (on disconnect). Fire-and-forget teardown.
    func stopAllCloudflareTunnels() {
        let services = cloudflaredServices
        cloudflaredServices.removeAll()
        cloudflareTunnels.removeAll()
        guard !services.isEmpty else { return }
        Task {
            for service in services.values {
                await service.stop()
            }
        }
    }

    private func updateCloudflareTunnel(_ id: UUID, _ mutate: (inout CloudflareTunnel) -> Void) {
        guard let index = cloudflareTunnels.firstIndex(where: { $0.id == id }) else { return }
        mutate(&cloudflareTunnels[index])
    }
}
