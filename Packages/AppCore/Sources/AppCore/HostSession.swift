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

    /// True while the daemon event stream is delivering live updates; false
    /// when we have fallen back to polling.
    public private(set) var liveUpdatesActive = false

    private var client: DockerClient?

    /// Background task that consumes the daemon event stream and, when events
    /// are unavailable, polls for container changes instead.
    private var eventTask: Task<Void, Never>?

    /// In-flight debounced container refresh; coalesces bursts of container
    /// events into a single list reload.
    private var pendingContainerRefresh: Task<Void, Never>?

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
                startEventMonitoring()
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
        eventTask?.cancel()
        eventTask = nil
        pendingContainerRefresh?.cancel()
        pendingContainerRefresh = nil
        liveUpdatesActive = false
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

    // MARK: - Live monitoring

    /// Starts (or restarts) the background monitor: subscribes to the daemon
    /// event stream and refreshes the affected resource lists as changes
    /// arrive. If events are unavailable it falls back to periodic polling.
    /// Safe to call repeatedly — any previous task is cancelled first.
    public func startEventMonitoring() {
        guard let client else { return }
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            await self?.monitorLoop(client: client)
        }
    }

    /// Long-lived loop driving live updates. Each iteration tries the event
    /// stream; on stream end or error it falls back to polling, then retries
    /// the event stream with backoff.
    private func monitorLoop(client: DockerClient) async {
        var backoff = 2  // seconds; grows up to 10 between event-stream retries.

        while !Task.isCancelled {
            do {
                let events = try await client.events()
                liveUpdatesActive = true
                backoff = 2
                try await consumeEvents(events)
                // Clean stream end (rare): treat like any other reconnect.
                liveUpdatesActive = false
            } catch is CancellationError {
                break
            } catch {
                liveUpdatesActive = false
            }

            if Task.isCancelled { break }

            // Events unavailable: poll while we wait, so the UI stays fresh, and
            // sleep the configured interval before retrying the event stream.
            if status.isConnected {
                await refreshContainers()
            }

            let waited = await sleepForPollInterval(retryBackoff: backoff)
            if !waited { break }
            backoff = min(backoff * 2, 10)
        }

        liveUpdatesActive = false
    }

    /// Sleeps for the polling cadence: the larger of the user's configured
    /// `refreshInterval` (default 5s) and the current reconnect backoff.
    /// Returns false if the sleep was cancelled.
    private func sleepForPollInterval(retryBackoff: Int) async -> Bool {
        let stored = UserDefaults.standard.integer(forKey: "refreshInterval")
        let interval = stored > 0 ? stored : 5
        let seconds = max(interval, retryBackoff)
        do {
            try await Task.sleep(for: .seconds(seconds))
            return true
        } catch {
            return false
        }
    }

    /// Consumes the event stream, debouncing bursts of container events so a
    /// rapid sequence (e.g. create → start → health) triggers a single refresh.
    private func consumeEvents(_ events: AsyncThrowingStream<DockerEvent, Error>) async throws {
        for try await event in events {
            if Task.isCancelled { break }
            switch event.type {
            case "container":
                scheduleContainerRefresh()
            case "image":
                await refreshImages()
            case "volume":
                await refreshVolumes()
            case "network":
                await refreshNetworks()
            default:
                break
            }
        }

        pendingContainerRefresh?.cancel()
        pendingContainerRefresh = nil
    }

    /// Schedules a container list refresh ~300ms out, coalescing any further
    /// container events that arrive within that window into the same reload.
    private func scheduleContainerRefresh() {
        guard pendingContainerRefresh == nil else { return }
        pendingContainerRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refreshContainers()
            self?.pendingContainerRefresh = nil
        }
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

    // MARK: - Log / stats streams

    /// Opens a follow log stream for a container. Inspects the container first
    /// to learn whether it allocated a TTY (which changes the wire framing),
    /// then tails the last 500 lines and follows new output.
    public func logStream(for containerID: String) async throws -> AsyncThrowingStream<LogEntry, Error> {
        guard let client else {
            throw DockerError.connectionFailed("Not connected")
        }
        let details = try await client.inspectContainer(id: containerID)
        return try await client.containerLogs(
            id: containerID,
            tty: details.config.tty,
            follow: true,
            tail: 500,
            timestamps: true,
            since: nil
        )
    }

    /// Opens a streaming stats feed for a container.
    public func statsStream(for containerID: String) async throws -> AsyncThrowingStream<ContainerStatsSample, Error> {
        guard let client else {
            throw DockerError.connectionFailed("Not connected")
        }
        return try await client.containerStats(id: containerID)
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
